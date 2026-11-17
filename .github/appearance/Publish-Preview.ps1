[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][string] $PublishRoot,
    [Parameter(Mandatory)][string] $ScreenshotsRoot
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$PublishRoot = [IO.Path]::GetFullPath($PublishRoot)
$ScreenshotsRoot = [IO.Path]::GetFullPath($ScreenshotsRoot)
New-Item -ItemType Directory -Force -Path $PublishRoot,$ScreenshotsRoot | Out-Null
$msbuild = $env:PREVIEW_MSBUILD_EXE
if (-not $msbuild) { $msbuild = (Get-Command msbuild -ErrorAction Stop).Source }
$sdk = (Get-Content (Join-Path $SourceRoot 'global.json') -Raw | ConvertFrom-Json).sdk.version
$dotnetRoot = Split-Path (Get-Command dotnet -ErrorAction Stop).Source -Parent
$env:DOTNET_ROOT = $dotnetRoot
$env:DOTNET_MSBUILD_SDK_RESOLVER_CLI_DIR = $dotnetRoot
$env:MSBuildSDKsPath = Join-Path $dotnetRoot "sdk/$sdk/Sdks"
$results = Join-Path $env:GITHUB_WORKSPACE 'results'
$previewRecord = [ordered]@{ completed = $false; portablePublished = $false; screenshots = @(); stage = 'publish'; error = $null }

function Invoke-Checked {
    param([string] $Program, [string[]] $Arguments, [string] $Log)
    & $Program @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE; see $Log" }
}

Push-Location $SourceRoot
try {
    # Upstream's Release Self-Contained Build target publishes and cleans its own
    # intermediate output. Calling Publish directly would invoke that twice.
    Invoke-Checked $msbuild @('mRemoteNG/mRemoteNG.csproj','/restore','/t:Build',
        '/p:Configuration=Release Self-Contained','/p:Platform=x64','/p:RuntimeIdentifier=win-x64',
        '/p:SelfContained=true','/p:PublishReadyToRun=false','/p:MSBuildEnableWorkloadResolver=false',
        "/p:PublishDir=$PublishRoot/",'/verbosity:minimal','/nologo') (Join-Path $results 'portable-publish.log')
    foreach ($required in @('mRemoteNG.exe','mRemoteNG.dll','Themes/Catppuccin Mocha Fluent.vstheme','Icons/mRemoteNG.ico')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PublishRoot $required))) { throw "Portable output is missing $required" }
    }
    $previewRecord.portablePublished = $true
    $previewRecord.stage = 'snapshot-host-build'
    $hostProject = Join-Path $PSScriptRoot 'preview-host/AppearancePreview.csproj'
    $hostBuild = Join-Path $env:RUNNER_TEMP 'appearance-host-build'
    Invoke-Checked $msbuild @($hostProject,'/restore','/t:Build','/p:Configuration=Release','/p:Platform=x64',
        '/p:MSBuildEnableWorkloadResolver=false',"/p:PreviewAppDirectory=$PublishRoot", "/p:OutputPath=$hostBuild/",'/verbosity:minimal','/nologo') (Join-Path $results 'snapshot-host-build.log')
    foreach ($variant in @('mocha','light','theming-disabled')) {
        $previewRecord.stage = "capture-$variant"
        $hostDirectory = Join-Path $env:RUNNER_TEMP "appearance-snapshot-$variant"
        New-Item -ItemType Directory -Force -Path $hostDirectory | Out-Null
        Copy-Item -Path (Join-Path $PublishRoot '*') -Destination $hostDirectory -Recurse -Force
        Copy-Item -Path (Join-Path $hostBuild '*') -Destination $hostDirectory -Recurse -Force
        $variantOutput = Join-Path $ScreenshotsRoot $variant
        New-Item -ItemType Directory -Force -Path $variantOutput | Out-Null
        $arguments = @($variantOutput,'/noreconnect')
        if ($variant -eq 'light') { $arguments += '--light' }
        if ($variant -eq 'theming-disabled') { $arguments += '--disabled' }
        # Each disposable runner process gets its own portable app/config directory.
        $process = Start-Process -FilePath (Join-Path $hostDirectory 'AppearancePreview.exe') `
            -ArgumentList $arguments -WorkingDirectory $hostDirectory -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $variantOutput 'host.log') `
            -RedirectStandardError (Join-Path $variantOutput 'host-error.log')
        if (-not $process.WaitForExit(120000)) {
            Stop-Process -Id $process.Id -Force
            throw "Screenshot process timed out for $variant; see its logs."
        }
        if ($process.ExitCode -ne 0) { throw "Screenshot process failed for $variant with exit $($process.ExitCode)." }
        if (@(Get-ChildItem -LiteralPath $variantOutput -Filter *.png).Count -ne 3) { throw "Expected three real-app snapshots for $variant." }
        $previewRecord.screenshots += $variant
    }
    @'
Portable appearance preview: extract this entire artifact into a NEW writable folder.
Run mRemoteNG.exe. Select Catppuccin Mocha Fluent in Tools > Options > Themes and
restart once so native Windows controls start in the matching dark mode.
This is an unsigned local test build, not a maintainer-signed release. The app was
compiled with upstream's PORTABLE configuration; use this separate folder and an
empty test connection list. Your installed program was not replaced.
If device policy blocks the build, keep that policy in place and use the real-app
screenshots from the workflow to review appearance. Live RDP still needs a build
permitted by your device policy. No private connection inventory is bundled.
'@ | Set-Content (Join-Path $PublishRoot 'START-HERE.txt') -Encoding utf8
    $previewRecord.completed = $true
    $previewRecord.stage = 'finished'
}
catch { $previewRecord.error = $_.Exception.Message; throw }
finally {
    $previewRecord | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $results 'preview-result.json') -Encoding utf8
    Pop-Location
}
