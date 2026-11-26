# Discovery probes capture native output separately from strict acceptance Compose operations.
function Invoke-RosDiscoveryCommand([string[]]$Arguments, [int]$TimeoutMilliseconds) {
    $start = [Diagnostics.ProcessStartInfo]::new('docker')
    $start.UseShellExecute = $false
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = !$process.WaitForExit([math]::Max(1, $TimeoutMilliseconds))
        if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
            TimedOut = $timedOut
        }
    }
    finally { $process.Dispose() }
}

function Protect-RosDiagnostic([string]$Text) {
    foreach ($value in @($env:MSSQL_SA_PASSWORD)) {
        if ($value) { $Text = $Text.Replace($value, '[REDACTED]') }
    }
    $Text = [regex]::Replace($Text, '(?is)("content"\s*:\s*)"(?:\\.|[^"\\])*"', '$1"[REDACTED]"')
    $Text = [regex]::Replace($Text, '(?im)^.*"content"\s*:.*$', '[PAYLOAD REDACTED]')
    $Text = [regex]::Replace($Text, '(?im)(authorization\s*[=:]\s*)[^\r\n]+', '$1[REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)((?:password|token|secret|authorization)\s*[=:]\s*)\S+', '$1[REDACTED]')
    return $Text.Substring(0, [math]::Min($Text.Length, 16000))
}

function Wait-Ros2Discovery {
    param(
        [string[]]$ComposeArguments,
        [string]$EvidencePath,
        [ValidateRange(1, 100)][int]$Attempts = 45,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [ValidateRange(1, 30)][int]$ProbeTimeoutSeconds = 10,
        [ValidateRange(0, 10000)][int]$DelayMilliseconds = 1000
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    New-Item -ItemType Directory -Path (Split-Path $EvidencePath -Parent) -Force | Out-Null
    function Save-Probe($kind, $target, $result) {
        [ordered]@{
            observedAt = [datetimeoffset]::UtcNow.ToString('o')
            attempt = $attempt
            elapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
            kind = $kind
            target = $target
            exitCode = $result.ExitCode
            timedOut = $result.TimedOut
            stdout = Protect-RosDiagnostic $result.Stdout
            stderr = Protect-RosDiagnostic $result.Stderr
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $EvidencePath
    }
    try {
        foreach ($attempt in 1..$Attempts) {
            $remaining = $TimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { break }
            $status = Invoke-RosDiscoveryCommand (@('compose') + $ComposeArguments +
                @('ps', '--all', '--format', 'json', 'bridge', 'simulator')) ([math]::Min(5000, $remaining))
            Save-Probe 'container-status' 'bridge,simulator' $status
            if ($status.TimedOut -or $status.ExitCode -ne 0) { throw 'ROS discovery container-status command failed.' }
            # Compose versions emit either a JSON array or newline-delimited JSON objects.
            $containers = @($status.Stdout -split '\r?\n' | Where-Object { $_.Trim() } |
                ForEach-Object { $_ | ConvertFrom-Json })
            foreach ($service in @('bridge', 'simulator')) {
                $container = @($containers | Where-Object Service -eq $service)
                if ($container.Count -ne 1 -or $container[0].State -ne 'running' -or $container[0].Health -eq 'unhealthy') {
                    throw "ROS discovery requires a running $service container."
                }
            }
            $complete = $true
            foreach ($topic in @('/demo/commands', '/demo/receipts')) {
                $remaining = $TimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds
                if ($remaining -le 0) { $complete = $false; break }
                $probe = Invoke-RosDiscoveryCommand (@('compose') + $ComposeArguments +
                    @('exec', '-T', 'bridge', 'timeout', '--kill-after=1s', "${ProbeTimeoutSeconds}s", 'bash', '-lc',
                      "source /opt/ros/jazzy/setup.bash && ros2 topic info $topic --verbose --no-daemon")) `
                    ([math]::Min(($ProbeTimeoutSeconds + 2) * 1000, $remaining))
                Save-Probe 'topic-info' $topic $probe
                $unknownTopic = ($probe.Stdout + $probe.Stderr).Trim() -ceq "Unknown topic '$topic'"
                if ($probe.TimedOut -or $probe.ExitCode -eq 124 -or ($probe.ExitCode -eq 1 -and $unknownTopic)) {
                    $complete = $false
                    continue
                }
                if ($probe.ExitCode -ne 0) { throw "ROS discovery CLI failed for $topic. See sanitized probe evidence." }
                if ($probe.Stdout -notmatch 'Node name: robotics_fleet_bridge\b' -or
                    $probe.Stdout -notmatch 'Node name: robotics_fleet_simulator\b') {
                    $complete = $false
                }
            }
            Write-Host "ROS discovery attempt=$attempt elapsed=$([math]::Round($clock.Elapsed.TotalSeconds, 2))s complete=$complete"
            if ($complete) { return }
            $remaining = $TimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([math]::Min($DelayMilliseconds, $remaining)) }
        }
        throw "ROS discovery exhausted its budget of $Attempts attempts and $TimeoutSeconds seconds."
    }
    catch {
        # Capture diagnostics before the caller's finally block tears down this project.
        foreach ($command in @(
            @('ps', '--all', '--format', 'json', 'bridge', 'simulator'),
            @('logs', '--no-color', '--tail', '60', 'bridge', 'simulator')
        )) {
            try {
                $diagnostic = Invoke-RosDiscoveryCommand (@('compose') + $ComposeArguments + $command) 5000
                Save-Probe 'terminal-diagnostic' ($command -join ' ') $diagnostic
            }
            catch { Write-Warning 'A terminal ROS diagnostic command could not be captured.' }
        }
        throw
    }
}
