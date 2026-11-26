#Requires -Version 7.5
# Deterministic probe tests. No Docker resources are created or modified.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ros2-discovery.ps1')
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $native = Invoke-RosDiscoveryCommand @('--version') 5000
    if ($native.ExitCode -ne 0 -or $native.Stdout -notmatch 'Docker version' -or $native.TimedOut) {
        throw 'Native discovery command capture failed'
    }
    Write-Host 'PASS native Docker CLI stdout and exit-code capture'
}
$results = Join-Path (Split-Path $PSScriptRoot -Parent) 'TestResults/ros2-discovery-checks'
New-Item -ItemType Directory -Path $results -Force | Out-Null
$originalPassword = $env:MSSQL_SA_PASSWORD
$env:MSSQL_SA_PASSWORD = 'probe-test-secret'
$fixture = @{}

function Invoke-RosDiscoveryCommand([string[]]$Arguments, [int]$TimeoutMilliseconds) {
    $result = [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = ''; TimedOut = $false }
    if ($Arguments -contains 'ps') {
        $fixture.StatusCalls++
        $state = if ($fixture.Scenario -eq 'bridge unavailable') { 'exited' } else { 'running' }
        $simulator = if ($fixture.Scenario -eq 'simulator unavailable') { 'exited' } else { 'running' }
        $result.Stdout = @(@{ Service = 'bridge'; State = $state }, @{ Service = 'simulator'; State = $simulator }) |
            ConvertTo-Json -Compress
    }
    elseif ($Arguments -contains 'logs') {
        $result.Stdout = "Password=$env:MSSQL_SA_PASSWORD`n{""content"":""private payload""}"
    }
    else {
        $fixture.ProbeCalls++
        $topic = if ($Arguments[-1] -match '/demo/commands') { '/demo/commands' } else { '/demo/receipts' }
        $result.Stdout = "Node name: robotics_fleet_bridge`nNode name: robotics_fleet_simulator"
        if ($fixture.Scenario -in @('never discovered', 'deadline exhausted') -or
            ($fixture.Scenario -eq 'initially unavailable' -and $fixture.StatusCalls -eq 1)) {
            $result.ExitCode = 1
            $result.Stdout = ''
            $result.Stderr = "Unknown topic '$topic'"
        }
        if ($fixture.Scenario -eq 'incomplete endpoints') { $result.Stdout = 'Node name: robotics_fleet_bridge' }
        if ($fixture.Scenario -eq 'CLI failure') {
            $result.ExitCode = 127
            $result.Stderr = 'bash: ros2: command not found'
        }
        if ($fixture.Scenario -eq 'probe timeout') { $result.ExitCode = 124; $result.TimedOut = $true }
    }
    return $result
}

try {
    foreach ($scenario in @('immediate success', 'initially unavailable', 'never discovered',
        'incomplete endpoints', 'bridge unavailable', 'simulator unavailable', 'CLI failure', 'probe timeout')) {
        $fixture = @{ Scenario = $scenario; ProbeCalls = 0; StatusCalls = 0 }
        $evidence = Join-Path $results ($scenario.Replace(' ', '-') + '.jsonl')
        Set-Content -LiteralPath $evidence -Value ''
        $failed = $false
        try {
            Wait-Ros2Discovery -ComposeArguments @('-p', 'probe-fixture') -EvidencePath $evidence `
                -Attempts 2 -TimeoutSeconds 5 -DelayMilliseconds 0
        }
        catch { $failed = $true }
        $shouldPass = $scenario -in @('immediate success', 'initially unavailable')
        if ($failed -eq $shouldPass) { throw "Unexpected outcome for $scenario" }
        $records = @(Get-Content $evidence | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $probes = @($records | Where-Object kind -eq 'topic-info')
        if ($shouldPass) {
            $expectedAttempts = if ($scenario -eq 'immediate success') { 1 } else { 2 }
            if ($probes.Count -ne $expectedAttempts * 2) { throw 'Both topics were not probed each attempt' }
        }
        else {
            if (@($records | Where-Object kind -eq 'terminal-diagnostic').Count -ne 2) {
                throw "Missing pre-cleanup diagnostics for $scenario"
            }
            if ($scenario -like '*unavailable' -and $fixture.ProbeCalls -ne 0) { throw 'Unavailable container should fail before CLI' }
            if ($scenario -eq 'CLI failure' -and $fixture.ProbeCalls -ne 1) { throw 'Permanent CLI error was retried' }
            if ($scenario -in @('never discovered', 'probe timeout', 'incomplete endpoints') -and $probes.Count -ne 4) {
                throw 'Transient discovery did not exhaust the bounded retry count'
            }
        }
        $raw = Get-Content $evidence -Raw
        if ($raw.Contains('probe-test-secret') -or $raw.Contains('private payload')) { throw 'Diagnostic redaction failed' }
        if (@($records | Where-Object { $null -eq $_.exitCode -or $null -eq $_.elapsedSeconds -or $null -eq $_.attempt }).Count) {
            throw 'Probe metadata missing'
        }
        Write-Host "PASS $scenario with sanitized stdout/stderr, exit codes and timing"
    }

    $fixture = @{ Scenario = 'deadline exhausted'; ProbeCalls = 0; StatusCalls = 0 }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $failed = $false
    try {
        Wait-Ros2Discovery -ComposeArguments @('-p', 'probe-fixture') `
            -EvidencePath (Join-Path $results 'deadline-exhausted.jsonl') -Attempts 45 -TimeoutSeconds 1
    }
    catch { $failed = $true }
    if (!$failed -or $fixture.ProbeCalls -ne 2 -or $timer.Elapsed.TotalSeconds -gt 5) {
        throw 'Wall-clock discovery budget was not enforced'
    }
    Write-Host 'PASS wall-clock budget stops discovery before the retry-count limit'
}
finally { $env:MSSQL_SA_PASSWORD = $originalPassword }

# Verify the acceptance wrapper attributes discovery failure to its own checkpoint.
$fixtureTests = Join-Path $results 'checkpoint-fixture/tests'
New-Item -ItemType Directory -Path $fixtureTests -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'lab14-acceptance.ps1') (Join-Path $fixtureTests 'lab14-acceptance.ps1')
Set-Content (Join-Path $fixtureTests 'lab8-receipts.ps1') @'
param([switch]$CheckTracing, [scriptblock]$OnCheckpoint)
& $OnCheckpoint 'Starting' 'fleet-lab8-check-1234abcd'
& $OnCheckpoint 'Isolated stack and migrations' 'fleet-lab8-check-1234abcd'
& $OnCheckpoint 'Monitoring and dashboard provisioning' 'fleet-lab8-check-1234abcd'
try { throw 'Controlled ROS2 discovery failure' }
finally { & $OnCheckpoint 'Isolated cleanup preserving volumes' 'fleet-lab8-check-1234abcd' }
'@
pwsh -NoProfile -File (Join-Path $fixtureTests 'lab14-acceptance.ps1')
if ($LASTEXITCODE -eq 0) { throw 'Discovery failure incorrectly returned success' }
$report = Get-Content (Join-Path $results 'checkpoint-fixture/TestResults/lab14/summary.json') -Raw | ConvertFrom-Json
if ($report.checks.Count -ne 13 -or ($report.checks | Where-Object status -eq 'FAIL').name -ne 'ROS2 topic endpoint discovery' -or
    ($report.checks | Where-Object name -eq 'Idle consumer and SQL availability health checks').status -ne 'SKIP') {
    throw 'Discovery checkpoint attribution is incorrect'
}
Write-Host 'PASS discovery failure returns nonzero and marks ROS2 FAIL with SQL health SKIP'
exit 0
