[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ArtifactsRoot,
    [Parameter(Mandatory)][string] $OutputRoot
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$rows = @()
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# UI contribution validation')
$lines.Add('')
$lines.Add('All runs use the same pinned upstream revision. Existing failures remain failures; comparison does not waive the test checklist.')
$lines.Add('')
$lines.Add('| Variant | Build/run | Total | Passed | Failed | Other / unexecuted |')
$lines.Add('| --- | --- | ---: | ---: | ---: | ---: |')

foreach ($variant in @('baseline', 'tree', 'panel')) {
    $folder = Join-Path $ArtifactsRoot "validation-$variant"
    $row = [ordered]@{
        variant = $variant; status = 'INCOMPLETE'; total = 0; passed = 0; failed = 0; other = 0
        tests = @(); issues = @(); record = $null
    }
    try {
        $row.record = Get-Content (Join-Path $folder 'result.json') -Raw | ConvertFrom-Json
        if ($row.record.variant -ne $variant) { throw 'Result belongs to a different variant.' }
        $trxPath = Join-Path $folder 'trx/tests.trx'
        if (-not (Test-Path $trxPath)) {
            throw "No completed TRX file. Stage: $($row.record.stage). $($row.record.error)"
        }
        [xml] $trx = Get-Content $trxPath -Raw
        $ns = [Xml.XmlNamespaceManager]::new($trx.NameTable)
        $ns.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
        $summary = $trx.SelectSingleNode('/t:TestRun/t:ResultSummary', $ns)
        $counters = $summary.SelectSingleNode('t:Counters', $ns)
        if ($null -eq $counters) { throw 'TRX has no result counters.' }
        $row.total = [int] $counters.total
        $row.passed = [int] $counters.passed
        $row.failed = [int] $counters.failed
        $row.other = $row.total - $row.passed - $row.failed
        $definitions = @{}
        foreach ($definition in $trx.SelectNodes('/t:TestRun/t:TestDefinitions/t:UnitTest', $ns)) {
            $method = $definition.SelectSingleNode('t:TestMethod', $ns)
            $definitions[$definition.id] = "$($method.className)|$($method.name)"
        }
        $seen = @{}
        $row.tests = @(foreach ($test in $trx.SelectNodes('/t:TestRun/t:Results/t:UnitTestResult', $ns)) {
            if (-not $definitions.ContainsKey($test.testId)) { throw 'TRX has an unknown test definition.' }
            # Test IDs change between runs. Compare class, method and case name instead.
            $key = "$($definitions[$test.testId])|$($test.testName)"
            if ($seen.ContainsKey($key)) { throw "Duplicate test identity in TRX: $key" }
            $seen[$key] = $true
            [pscustomobject]@{ key = $key; outcome = [string] $test.outcome }
        })
        if ($row.tests.Count -ne $row.total -or $row.total -lt 1) {
            throw 'TRX result count is empty or inconsistent with its counters.'
        }
        $actualPassed = @($row.tests | Where-Object outcome -eq 'Passed').Count
        $actualFailed = @($row.tests | Where-Object outcome -eq 'Failed').Count
        if ($actualPassed -ne $row.passed -or $actualFailed -ne $row.failed) {
            throw 'TRX outcomes disagree with its summary counters.'
        }
        $row.status = 'FAIL'
        if ($row.record.completed -and $row.record.testExitCode -eq 0 -and
            $summary.outcome -eq 'Completed' -and $row.passed -eq $row.total -and
            [int] $counters.executed -eq $row.total) {
            $row.status = 'PASS'
        } else {
            $row.issues += "Run not fully passing. TRX outcome: $($summary.outcome). $($row.record.error)"
        }
        if ($variant -eq 'panel') {
            $panelTests = @($row.tests | Where-Object { $_.key -like '*RdpConnectingPanelTests|*' })
            if ($panelTests.Count -ne 9 -or @($panelTests | Where-Object outcome -ne 'Passed').Count -gt 0) {
                $row.status = 'FAIL'
                $row.issues += 'Expected all nine new RdpConnectingPanelTests to be discovered and pass.'
            }
        }
    }
    catch {
        $row.status = 'INCOMPLETE'
        $row.issues += $_.Exception.Message
    }
    $rows += [pscustomobject] $row
}

$baseline = $rows | Where-Object variant -eq 'baseline'
$comparisons = @()
foreach ($candidate in @($rows | Where-Object variant -ne 'baseline')) {
    $lines.Add('')
    $lines.Add("## $($candidate.variant) compared with baseline")
    $comparison = [ordered]@{ variant = $candidate.variant; comparable = $false; newlyFailing = @(); newlyNotPassing = @(); missing = @(); added = @(); resolvedFailures = @() }
    if ($baseline.tests.Count -gt 0 -and $candidate.tests.Count -gt 0 -and
        $baseline.status -ne 'INCOMPLETE' -and $candidate.status -ne 'INCOMPLETE') {
        # Different SDKs, source revisions or runner images cannot establish a controlled comparison.
        $sameEnvironment = $true
        foreach ($field in @('baseCommit', 'sdkVersion', 'runnerImage', 'configuration', 'platform', 't4Version', 'workflowCommit')) {
            if (-not $baseline.record.$field -or $baseline.record.$field -ne $candidate.record.$field) {
                $sameEnvironment = $false
                $candidate.issues += "Comparison environment mismatch: $field."
            }
        }
        if ($sameEnvironment) {
            $comparison.comparable = $true
            $old = @{}; $new = @{}
            foreach ($test in $baseline.tests) { $old[$test.key] = $test.outcome }
            foreach ($test in $candidate.tests) { $new[$test.key] = $test.outcome }
            $comparison.newlyFailing = @($new.Keys | Where-Object { $new[$_] -eq 'Failed' -and $old[$_] -ne 'Failed' } | Sort-Object)
            $comparison.newlyNotPassing = @($new.Keys | Where-Object { $old[$_] -eq 'Passed' -and $new[$_] -ne 'Passed' } | Sort-Object)
            $comparison.missing = @($old.Keys | Where-Object { -not $new.ContainsKey($_) } | Sort-Object)
            $comparison.added = @($new.Keys | Where-Object { -not $old.ContainsKey($_) } | Sort-Object)
            $comparison.resolvedFailures = @($old.Keys | Where-Object { $old[$_] -eq 'Failed' -and $new[$_] -eq 'Passed' } | Sort-Object)
            foreach ($field in @('newlyFailing', 'newlyNotPassing', 'missing', 'added', 'resolvedFailures')) {
                $lines.Add("${field}: $($comparison[$field].Count)")
                foreach ($key in $comparison[$field]) { $lines.Add("- $key") }
                $lines.Add('')
            }
            if ($comparison.missing.Count -gt 0) {
                $candidate.status = 'FAIL'
                $candidate.issues += 'Baseline test cases disappeared from the candidate run.'
            }
        }
    }
    if (-not $comparison.comparable) {
        $lines.Add('Cannot establish a complete, controlled baseline comparison. Review the build/test logs.')
        if ($candidate.status -eq 'PASS') { $candidate.status = 'INCOMPLETE' }
    }
    $comparisons += [pscustomobject] $comparison
}

for ($index = 0; $index -lt $rows.Count; $index++) {
    $row = $rows[$index]
    $lines.Insert(6 + $index, "| $($row.variant) | $($row.status) | $($row.total) | $($row.passed) | $($row.failed) | $($row.other) |")
}

$lines.Add('')
$lines.Add('## Evidence and remaining checks')
foreach ($row in $rows) {
    $lines.Add('')
    $lines.Add("$($row.variant): final status **$($row.status)**")
    if ($row.record) {
        $lines.Add("- Upstream: $($row.record.baseCommit); SDK: $($row.record.sdkVersion); image: $($row.record.runnerImage)")
        $lines.Add("- Validation commit: $($row.record.workflowCommit); patch SHA-256: $($row.record.patchSha256)")
    }
    foreach ($issue in $row.issues) { $lines.Add("- $issue") }
}
$lines.Add('')
$lines.Add('Manual checks remain required: dotted tree guides in dark/light/disabled themes; live RDP connect, interactive sign-in, reconnect, resize, disconnect/error and theme switching. Hosted tests do not verify native ActiveX z-order or a real remote session. The installer, ARM64 and release packaging are outside this workflow.')
$lines.Add('')
$lines.Add('This run does not by itself satisfy a checklist item that explicitly requires running tests within Visual Studio. Report the actual GitHub Actions result and ask the maintainer whether that is accepted as equivalent evidence.')
$allPassed = @($rows | Where-Object status -ne 'PASS').Count -eq 0
@{ allAutomatedChecksPassed = $allPassed; runs = $rows; comparisons = $comparisons; manualChecksComplete = $false } |
    ConvertTo-Json -Depth 12 | Set-Content (Join-Path $OutputRoot 'comparison.json') -Encoding utf8
$summaryText = $lines -join "`n"
$summaryText | Set-Content (Join-Path $OutputRoot 'SUMMARY.md') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summaryText -Encoding utf8 }
Write-Host $summaryText
if (-not $allPassed) { exit 1 }
