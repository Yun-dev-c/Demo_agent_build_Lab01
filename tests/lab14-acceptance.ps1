#Requires -Version 7.5
# The reused suite requires PowerShell 7.5 for its existing JSON parsing options.
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$startedAt = [datetimeoffset]::UtcNow
$runId = $startedAt.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$resultsRoot = Join-Path $repository 'TestResults/lab14'
$runDirectory = Join-Path $resultsRoot $runId
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$state = @{
    StartedAt = $startedAt
    Project = $null
    Checks = [System.Collections.Generic.List[object]]::new()
}
$expected = @(
    'Isolated stack and migrations'
    'Monitoring and dashboard provisioning'
    'Idle consumer and SQL availability health checks'
    'Command receipt round trip and successful trace'
    'Duplicate unmatched receipts and metrics'
    'API scrape alert and SLO degradation recovery'
    'Kafka outage health and failed trace'
    'SQL outage and uncommitted receipt offsets'
    'SQL recovery consumer restart and final receipt state'
    'Consumer alerts and missing exporter recovery'
    'Malformed receipt health and offset protection'
    'Isolated cleanup preserving volumes'
)
$onCheckpoint = {
    param([string]$name, [string]$project)
    $state.Project = $project
    if ($name -eq 'Starting') { return }
    $now = [datetimeoffset]::UtcNow
    $state.Checks.Add([ordered]@{
        name = $name
        status = 'PASS'
        startedAt = $state.StartedAt.ToString('o')
        endedAt = $now.ToString('o')
        durationSeconds = [math]::Round(($now - $state.StartedAt).TotalSeconds, 3)
        diagnostics = $null
    })
    $state.StartedAt = $now
}.GetNewClosure()
$failure = $null
$exitCode = 1
Push-Location $repository
try {
    # Reuse the full suite once. Its finally block owns cleanup of its unique Compose project.
    & (Join-Path $PSScriptRoot 'lab8-receipts.ps1') -CheckTracing -OnCheckpoint $onCheckpoint
    $missing = @($expected | Where-Object { $_ -notin $state.Checks.name })
    if ($missing.Count -gt 0) { throw 'The suite returned without all required checkpoints.' }
    $exitCode = 0
}
catch {
    # Persist source locations, not exception bodies that could contain HTTP payloads or credentials.
    $failure = 'Acceptance stopped with {0} at {1}, line {2}. Inspect the console output and saved evidence.' -f
        $_.Exception.GetType().FullName,
        [IO.Path]::GetFileName($_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber
    Write-Host $failure -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    Pop-Location
}
$endedAt = [datetimeoffset]::UtcNow
$missing = @($expected | Where-Object { $_ -notin $state.Checks.name })
foreach ($name in $missing) {
    $isFailure = $name -eq $missing[0]
    $state.Checks.Add([ordered]@{
        name = $name
        status = if ($isFailure) { 'FAIL' } else { 'SKIP' }
        startedAt = if ($isFailure) { $state.StartedAt.ToString('o') } else { $null }
        endedAt = if ($isFailure) { $endedAt.ToString('o') } else { $null }
        durationSeconds = if ($isFailure) { [math]::Round(($endedAt - $state.StartedAt).TotalSeconds, 3) } else { 0 }
        diagnostics = if ($isFailure) { $failure } else { 'Earlier failure prevented execution.' }
    })
}
$evidence = @()
if ($state.Project) {
    $evidence = @(Get-ChildItem -LiteralPath (Join-Path $repository 'TestResults') -File |
        Where-Object { $_.Name.StartsWith($state.Project + '-', [StringComparison]::Ordinal) } |
        ForEach-Object { $_.FullName })
}
$summary = [ordered]@{
    name = 'Lab 14 complete system acceptance and recovery'
    status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    runId = $runId
    composeProject = $state.Project
    startedAt = $startedAt.ToString('o')
    endedAt = $endedAt.ToString('o')
    durationSeconds = [math]::Round(($endedAt - $startedAt).TotalSeconds, 3)
    diagnostics = $failure
    evidencePaths = $evidence
    checks = $state.Checks.ToArray()
}
$json = $summary | ConvertTo-Json -Depth 10
$report = [System.Collections.Generic.List[string]]::new()
$report.Add('# Lab 14 acceptance results')
$report.Add('')
$report.Add("Overall **$($summary.status)**. Run ``$runId``. Compose project ``$($state.Project)``.")
$report.Add('')
$report.Add("UTC start $($summary.startedAt). UTC end $($summary.endedAt). Duration $($summary.durationSeconds) seconds.")
$report.Add('')
$report.Add('Durations measure intervals between completed checkpoints. Cleanup can pass after a failed check. SKIP indicates checks prevented by an earlier failure.')
$report.Add('')
$report.Add('| Test | Result | Start UTC | End UTC | Seconds | Diagnostics |')
$report.Add('|---|---|---|---|---:|---|')
foreach ($check in $state.Checks) {
    $report.Add("| $($check.name) | $($check.status) | $($check.startedAt) | $($check.endedAt) | $($check.durationSeconds) | $($check.diagnostics) |")
}
$report.Add('')
$report.Add('Evidence files')
$report.Add('')
foreach ($path in $evidence) { $report.Add("- ``$path``") }
if ($failure) { $report.Add(''); $report.Add($failure) }
foreach ($directory in @($runDirectory, $resultsRoot)) {
    Set-Content -LiteralPath (Join-Path $directory 'summary.json') -Value $json -Encoding utf8
    Set-Content -LiteralPath (Join-Path $directory 'report.md') -Value $report -Encoding utf8
}
Write-Host "Lab 14 $($summary.status). Report saved to $runDirectory"
exit $exitCode
