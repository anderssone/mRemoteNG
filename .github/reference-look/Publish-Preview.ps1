[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][string] $PublishRoot,
    [Parameter(Mandatory)][string] $ScreenshotsRoot,
    [switch] $UseExistingPortable,
    [string] $ValidatedResultsRoot
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
New-Item -ItemType Directory -Force -Path $results | Out-Null
$previewRecord = [ordered]@{ completed = $false; portablePublished = $false; screenshots = @(); stage = 'publish'; error = $null; sourceMode = $(if ($UseExistingPortable) {'validated-artifact'} else {'rebuilt'}); sourceRun = $null }

function Invoke-Checked {
    param([string] $Program, [string[]] $Arguments, [string] $Log)
    & $Program @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit $LASTEXITCODE; see $Log" }
}

function Copy-FixtureLogs {
    param([string] $Fixture, [string] $Destination)
    foreach ($name in @('AppearancePreview.log', 'appearance-preview.log')) {
        $path = Join-Path $Fixture $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $Destination $name) -Force }
    }
}

Push-Location $SourceRoot
try {
    if ($UseExistingPortable) {
        if (!$ValidatedResultsRoot -or !$env:PREVIEW_SOURCE_RUN -or !$env:PREVIEW_SOURCE_COMMIT -or !$env:PREVIEW_PATCH_SHA256) {
            throw 'Reusing an artifact requires its pinned source run, commit, patch and validation results.'
        }
        $prior = Get-Content (Join-Path $ValidatedResultsRoot 'result.json') -Raw | ConvertFrom-Json
        $expectedRun = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:PREVIEW_SOURCE_RUN"
        if (!$prior.completed -or $prior.testExitCode -ne 0 -or $prior.variant -ne 'appearance' -or
            $prior.workflowRun -ne $expectedRun -or $prior.workflowCommit -ne $env:PREVIEW_SOURCE_COMMIT -or
            $prior.patchSha256 -ne $env:PREVIEW_PATCH_SHA256 -or $prior.sdkVersion -ne $sdk) {
            throw 'The downloaded artifact does not match the pinned passing source run.'
        }
        [xml] $trx = Get-Content (Join-Path $ValidatedResultsRoot 'trx/tests.trx') -Raw
        $ns = [Xml.XmlNamespaceManager]::new($trx.NameTable)
        $ns.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
        $summary = $trx.SelectSingleNode('/t:TestRun/t:ResultSummary', $ns)
        $counters = $summary.SelectSingleNode('t:Counters', $ns)
        $tests = @($trx.SelectNodes('/t:TestRun/t:Results/t:UnitTestResult', $ns))
        if ($summary.outcome -ne 'Completed' -or [int]$counters.total -ne 2938 -or
            [int]$counters.passed -ne 2938 -or [int]$counters.executed -ne 2938 -or
            $tests.Count -ne 2938 -or @($tests | Where-Object outcome -ne 'Passed').Count -ne 0) {
            throw 'The pinned Options appearance artifact must have all 2938 tests passing.'
        }
        $previewRecord.sourceRun = $expectedRun
        Copy-Item -LiteralPath (Join-Path $ValidatedResultsRoot 'result.json') -Destination (Join-Path $results 'source-validation.json')
    } else {
        # Upstream's Build target publishes and cleans its own intermediates.
        Invoke-Checked $msbuild @('mRemoteNG/mRemoteNG.csproj','/restore','/t:Build',
            '/p:Configuration=Release Self-Contained','/p:Platform=x64','/p:RuntimeIdentifier=win-x64',
            '/p:SelfContained=true','/p:PublishReadyToRun=false','/p:MSBuildEnableWorkloadResolver=false',
            "/p:PublishDir=$PublishRoot/",'/verbosity:minimal','/nologo') (Join-Path $results 'portable-publish.log')
    }
    foreach ($required in @('mRemoteNG.exe','mRemoteNG.dll','Themes/Catppuccin Mocha Comfortable.vstheme','Icons/mRemoteNG.ico')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PublishRoot $required))) { throw "Portable output is missing $required" }
    }
    $previewRecord.portablePublished = $true
    @'
Portable appearance preview: extract this entire artifact into a NEW writable folder.
Run mRemoteNG.exe. Select Catppuccin Mocha Comfortable in Options > Themes and
restart once so native Windows controls start in the matching dark mode.
This is an unsigned local test build, not a maintainer-signed release. The app was
compiled with upstream's PORTABLE configuration; use this separate folder and an
empty test connection list. Your installed program was not replaced.
This artifact is retained once the app publishes successfully, even if later
screenshot capture fails. Check the workflow and comparison report separately;
an available download does not establish that the screenshot checks passed.
If device policy blocks the build, keep that policy in place. Live RDP still
needs a build permitted by your device policy. No private inventory is bundled.
'@ | Set-Content (Join-Path $PublishRoot 'START-HERE.txt') -Encoding utf8
    'PORTABLE_PREVIEW_READY=true' | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8
    $previewRecord.stage = 'snapshot-host-build'
    $hostProject = Join-Path $PSScriptRoot 'preview-host/AppearancePreview.csproj'
    $hostBuild = Join-Path $env:RUNNER_TEMP 'appearance-host-build'
    # The app-local hostfxr from the portable app wins over a framework-dependent
    # helper's global runtime search. Publish the helper self-contained too so its
    # runtimeconfig agrees with the runtime files copied beside it.
    Invoke-Checked $msbuild @($hostProject,'/restore','/t:Publish','/p:Configuration=Release','/p:Platform=x64',
        '/p:SelfContained=true','/p:RuntimeIdentifier=win-x64','/p:PublishReadyToRun=false',
        '/p:MSBuildEnableWorkloadResolver=false',"/p:PreviewAppDirectory=$PublishRoot", "/p:PublishDir=$hostBuild/",'/verbosity:minimal','/nologo') (Join-Path $results 'snapshot-host-build.log')
    $hostConfig = Get-Content -LiteralPath (Join-Path $hostBuild 'AppearancePreview.runtimeconfig.json') -Raw | ConvertFrom-Json
    if ($hostConfig.runtimeOptions.framework -or $hostConfig.runtimeOptions.frameworks -or
        -not $hostConfig.runtimeOptions.includedFrameworks) { throw 'Screenshot helper must be self-contained.' }
    foreach ($required in @('AppearancePreview.exe','AppearancePreview.dll','hostfxr.dll','hostpolicy.dll','coreclr.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $hostBuild $required))) { throw "Screenshot helper runtime is missing $required" }
    }
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
            $process.Refresh()
            "Process $($process.Id); responding: $($process.Responding); window: $($process.MainWindowTitle)" |
                Set-Content (Join-Path $variantOutput 'process-state.txt') -Encoding utf8
            Copy-FixtureLogs $hostDirectory $variantOutput
            Stop-Process -Id $process.Id -Force
            throw "Screenshot process timed out for $variant; see its logs."
        }
        Copy-FixtureLogs $hostDirectory $variantOutput
        if ($process.ExitCode -ne 0) { throw "Screenshot process failed for $variant with exit $($process.ExitCode)." }
        if (@(Get-ChildItem -LiteralPath $variantOutput -Filter *.png).Count -ne 3) { throw "Expected three real-app snapshots for $variant." }
        $previewRecord.screenshots += $variant
    }
    $previewRecord.completed = $true
    $previewRecord.stage = 'finished'
}
catch { $previewRecord.error = $_.Exception.Message; throw }
finally {
    $previewRecord | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $results 'preview-result.json') -Encoding utf8
    Pop-Location
}
