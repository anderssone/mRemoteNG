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
$lines.Add('Repeated display names are compared as groups: every result is retained, and group counts and outcomes must be reviewed together. TRX does not always distinguish individual custom-named NUnit cases.')
$lines.Add('')
$lines.Add('| Variant | Build/run | Total | Passed | Failed | Other / unexecuted |')
$lines.Add('| --- | --- | ---: | ---: | ---: | ---: |')

foreach ($variant in @('baseline', 'tree', 'panel')) {
    $folder = Join-Path $ArtifactsRoot "validation-$variant"
    $row = [ordered]@{
        variant = $variant; status = 'INCOMPLETE'; total = 0; passed = 0; failed = 0; other = 0
        tests = @(); issues = @(); record = $null; repeatedNameGroups = 0
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
        $nameCounts = @{}
        $row.tests = @(foreach ($test in $trx.SelectNodes('/t:TestRun/t:Results/t:UnitTestResult', $ns)) {
            if (-not $definitions.ContainsKey($test.testId)) { throw 'TRX has an unknown test definition.' }
            # NUnit SetName can reuse a name across methods and data cases. Keep
            # every result; compare repeated names by multiplicity and outcomes.
            # Execution order and generated IDs are not cross-run identities.
            $key = "$($definitions[$test.testId])|$($test.testName)"
            $nameCounts[$key] = 1 + [int] $nameCounts[$key]
            [pscustomobject]@{ key = $key; outcome = [string] $test.outcome }
        })
        $row.repeatedNameGroups = @($nameCounts.Values | Where-Object { $_ -gt 1 }).Count
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

function Get-OutcomeGroups {
    param([object[]] $Tests)
    $groups = @{}
    foreach ($test in $Tests) {
        if (-not $groups.ContainsKey($test.key)) {
            $groups[$test.key] = @{ total = 0; passed = 0; failed = 0; outcomes = @{} }
        }
        $group = $groups[$test.key]
        $group.total++
        if ($test.outcome -eq 'Passed') { $group.passed++ }
        if ($test.outcome -eq 'Failed') { $group.failed++ }
        $group.outcomes[$test.outcome] = 1 + [int] $group.outcomes[$test.outcome]
    }
    return $groups
}

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
            $old = Get-OutcomeGroups $baseline.tests
            $new = Get-OutcomeGroups $candidate.tests
            $allKeys = @(@($old.Keys) + @($new.Keys) | Sort-Object -Unique)
            foreach ($key in $allKeys) {
                $before = $old[$key]
                $after = $new[$key]
                $oldTotal = [int] $before.total
                $newTotal = [int] $after.total
                $oldFailed = [int] $before.failed
                $newFailed = [int] $after.failed
                $oldPassed = [int] $before.passed
                $newPassed = [int] $after.passed
                if ($newFailed -gt $oldFailed) {
                    $comparison.newlyFailing += "$key (failed: $oldFailed -> $newFailed)"
                }
                if ($oldPassed -gt $newPassed) {
                    $comparison.newlyNotPassing += "$key (passed: $oldPassed -> $newPassed)"
                }
                if ($oldTotal -gt $newTotal) {
                    $comparison.missing += "$key (results: $oldTotal -> $newTotal)"
                }
                if ($newTotal -gt $oldTotal) {
                    $comparison.added += "$key (results: $oldTotal -> $newTotal)"
                }
                if ($oldFailed -gt $newFailed -and $newPassed -gt $oldPassed) {
                    $comparison.resolvedFailures += "$key (failed: $oldFailed -> $newFailed)"
                }
            }
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
    $lines.Insert(7 + $index, "| $($row.variant) | $($row.status) | $($row.total) | $($row.passed) | $($row.failed) | $($row.other) |")
}

$lines.Add('')
$lines.Add('## Evidence and remaining checks')
foreach ($row in $rows) {
    $lines.Add('')
    $lines.Add("$($row.variant): final status **$($row.status)**")
    $lines.Add("- Repeated-name groups: $($row.repeatedNameGroups); every result occurrence is counted.")
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
