[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][string] $ResultsRoot,
    [Parameter(Mandatory)][ValidateSet('baseline', 'tree', 'panel')][string] $Variant,
    [Parameter(Mandatory)][string] $SdkVersion
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$ResultsRoot = [IO.Path]::GetFullPath($ResultsRoot)
New-Item -ItemType Directory -Force -Path $ResultsRoot | Out-Null
$record = [ordered]@{
    variant = $Variant
    baseCommit = $env:BASE_COMMIT
    workflowCommit = $env:GITHUB_SHA
    workflowRun = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    sdkVersion = $SdkVersion
    runnerImage = "$env:ImageOS $env:ImageVersion"
    configuration = 'Debug'
    platform = 'x64'
    t4Version = '3.0.0'
    patchSha256 = $null
    stage = 'prepare'
    testExitCode = $null
    completed = $false
    error = $null
}

function Invoke-Logged {
    param([string] $File, [string[]] $Arguments, [string] $LogName)
    & $File @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $ResultsRoot $LogName) | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$File failed with exit code $LASTEXITCODE; see $LogName." }
}

$failed = $false
Push-Location $SourceRoot
try {
    $actualCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $env:BASE_COMMIT) {
        throw 'Source checkout does not match the pinned upstream commit.'
    }
    $status = & git status --porcelain
    if ($LASTEXITCODE -ne 0 -or $status) { throw 'Expected a clean source checkout.' }

    $patchName = switch ($Variant) {
        tree { '01-themed-tree-lines.patch' }
        panel { '02-rdp-connecting-panel.patch' }
    }
    if ($patchName) {
        $patchPath = Join-Path $PSScriptRoot "patches/$patchName"
        $record.patchSha256 = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
        Invoke-Logged git @('apply', '--check', $patchPath) 'patch-check.log'
        Invoke-Logged git @('apply', $patchPath) 'patch-apply.log'
    }
    Invoke-Logged git @('diff', '--stat') 'source-diff-stat.log'
    Invoke-Logged git @('diff', '--binary') 'applied-source.diff'

    # Pin the selected SDK so preinstalled newer SDKs cannot silently take over.
    if ($SdkVersion -notmatch '^10\.0\.\d+$') { throw "Unexpected SDK version: $SdkVersion" }
    if (Test-Path global.json) { throw 'Review the existing upstream global.json before replacing it.' }
    @{ sdk = @{ version = $SdkVersion; rollForward = 'disable' }; test = @{ runner = 'VSTest' } } |
        ConvertTo-Json -Depth 4 | Set-Content global.json -Encoding utf8
    Copy-Item global.json (Join-Path $ResultsRoot 'global.json')
    Invoke-Logged dotnet @('--info') 'dotnet-info.log'

    $msbuild = (Get-Command msbuild -ErrorAction Stop).Source
    $record['msbuildPath'] = $msbuild
    Invoke-Logged $msbuild @('-version', '-nologo') 'msbuild-version.log'
    $dotnetRoot = Split-Path (Get-Command dotnet -ErrorAction Stop).Source -Parent
    $env:DOTNET_ROOT = $dotnetRoot
    $env:DOTNET_MSBUILD_SDK_RESOLVER_CLI_DIR = $dotnetRoot
    $env:MSBuildSDKsPath = Join-Path $dotnetRoot "sdk/$SdkVersion/Sdks"
    if (-not (Test-Path $env:MSBuildSDKsPath)) { throw 'Selected MSBuild SDK path does not exist.' }

    # Follow upstream's template generation, using a pinned tool version.
    $record.stage = 'template'
    $toolPath = Join-Path $env:RUNNER_TEMP 'ui-validation-t4'
    Invoke-Logged dotnet @('tool', 'install', 'dotnet-t4', '--version', $record.t4Version,
        '--tool-path', $toolPath) 't4-install.log'
    $template = Join-Path $SourceRoot 'mRemoteNG/Properties/AssemblyInfo.tt'
    $interop = Join-Path $SourceRoot 'mRemoteNG/libs/Microsoft.VisualStudio.Interop.dll'
    Invoke-Logged (Join-Path $toolPath 't4.exe') @($template, '-P', 'platformType=x64', "-r:$interop") 't4.log'

    # Full Visual Studio MSBuild is needed for the app's COM references.
    # Build the app first: the test project references its generated interop DLL.
    $record.stage = 'build-app'
    Invoke-Logged $msbuild @('mRemoteNG/mRemoteNG.csproj', '/restore', '/t:Build',
        '/p:Configuration=Debug', '/p:Platform=x64', '/p:MSBuildEnableWorkloadResolver=false',
        '/nologo', '/verbosity:minimal', "/bl:$(Join-Path $ResultsRoot 'app-build.binlog')") 'app-build.log'
    $record.stage = 'build-tests'
    Invoke-Logged $msbuild @('mRemoteNGTests/mRemoteNGTests.csproj', '/restore', '/t:Build',
        '/p:Configuration=Debug', '/p:Platform=x64', '/p:MSBuildEnableWorkloadResolver=false',
        '/nologo', '/verbosity:minimal', "/bl:$(Join-Path $ResultsRoot 'test-build.binlog')") 'test-build.log'

    $testAssembly = Join-Path $SourceRoot 'mRemoteNGTests/bin/x64/Debug/mRemoteNGTests.dll'
    if (-not (Test-Path $testAssembly)) { throw "Test assembly not found at $testAssembly" }
    $record.stage = 'test'
    # Run the actual upstream test assembly, without filtering or changing tests.
    # A hung test aborts the run as a failure; it is never treated as a pass.
    & dotnet test $testAssembly --logger 'trx;LogFileName=tests.trx' `
        --results-directory (Join-Path $ResultsRoot 'trx') `
        --blame-hang-timeout 5m --blame-hang-dump-type none `
        --diag (Join-Path $ResultsRoot 'vstest.log') 2>&1 |
        Tee-Object -FilePath (Join-Path $ResultsRoot 'tests.log') | Out-Host
    $record.testExitCode = $LASTEXITCODE
    if ($record.testExitCode -ne 0) { throw "Full test suite returned exit code $($record.testExitCode)." }
    if (-not (Test-Path (Join-Path $ResultsRoot 'trx/tests.trx'))) { throw 'No TRX result was produced.' }
    $record.completed = $true
    $record.stage = 'finished'
}
catch {
    $failed = $true
    $record.error = $_.Exception.Message
    Write-Host "::error::$($record.error)"
}
finally {
    $record | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ResultsRoot 'result.json') -Encoding utf8
    Pop-Location
}
if ($failed) { exit 1 }
