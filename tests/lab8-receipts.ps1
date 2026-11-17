#Requires -Version 7.5
# Run from the repository root.
param([switch]$CheckHealth, [switch]$CheckMonitoring, [switch]$CheckAlerting)

$ErrorActionPreference = 'Stop'
if ($CheckAlerting) {
    $CheckMonitoring = $true
    $CheckHealth = $true
}
$project = 'fleet-lab8-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$composeArgs = @('--profile', 'lab7', '-f', 'compose.yaml', '-f', 'tests/lab4.compose.yaml', '-p', $project)
if ($CheckMonitoring) { $composeArgs = @('--profile', 'monitoring') + $composeArgs }
$oldPassword = $env:MSSQL_SA_PASSWORD
$env:MSSQL_SA_PASSWORD = 'Lab8!' + [guid]::NewGuid().ToString('N')
if ($CheckAlerting) {
    New-Item -ItemType Directory -Path TestResults -Force | Out-Null
    $alertEvidence = Join-Path TestResults "$project-alerts.jsonl"
    Write-Host "Alert evidence: $alertEvidence"
}

function Invoke-Compose {
    docker compose @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "Compose failed: $($args -join ' ')" }
}

function Wait-For($description, [scriptblock]$check, [int]$attempts = 45) {
    foreach ($attempt in 1..$attempts) {
        if (& $check) { return }
        Start-Sleep -Seconds 1
    }
    throw "Timed out waiting for $description"
}

function Send-Receipt($id, $timestamp, $key = $id) {
    $value = @{ messageId = $id; type = 'RECEIVED'; source = 'ros2-simulator'; receivedAt = $timestamp } |
        ConvertTo-Json -Compress
    "$key|$value" | docker compose @composeArgs exec -T kafka /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka:29092 --topic robot.events --property parse.key=true --property 'key.separator=|'
    if ($LASTEXITCODE -ne 0) { throw 'Kafka receipt injection failed' }
}

function Assert-Group($offset, $end, $lag) {
    $pattern = "robotics-fleet-receipts\s+robot.events\s+0\s+$offset\s+$end\s+$lag(?:\s|$)"
    Wait-For "receipt group offset $offset and lag $lag" {
        $group = Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group robotics-fleet-receipts
        if ($group -match $pattern) { Write-Host ($group -join [Environment]::NewLine); return $true }
        return $false
    }
}

function Assert-Health($scenario, $readyStatus) {
    Wait-For "$scenario readiness $readyStatus" {
        $ready = Invoke-WebRequest "$apiUrl/health/ready" -SkipHttpErrorCheck -TimeoutSec 6
        return $ready.StatusCode -eq $readyStatus
    }
    $live = Invoke-WebRequest "$apiUrl/health/live" -SkipHttpErrorCheck -TimeoutSec 6
    if ($live.StatusCode -ne 200 -or $live.Content -ne 'Healthy') {
        throw "Liveness failed during $scenario"
    }
    $ready = Invoke-WebRequest "$apiUrl/health/ready" -SkipHttpErrorCheck -TimeoutSec 6
    $expectedBody = if ($readyStatus -eq 200) { 'Healthy' } else { 'Unhealthy' }
    if ($ready.StatusCode -ne $readyStatus -or $ready.Content -ne $expectedBody) {
        throw "Unexpected readiness result during $scenario"
    }
    Write-Host "PASS $scenario live=200 Healthy ready=$readyStatus $expectedBody"
}

function Assert-Metric($expression, [scriptblock]$matchesValue) {
    Wait-For $expression {
        $query = [uri]::EscapeDataString($expression)
        $response = Invoke-RestMethod "$promUrl/api/v1/query?query=$query" -TimeoutSec 5
        foreach ($sample in $response.data.result) {
            $value = $sample.value[1]
            if (& $matchesValue $value) {
                Write-Host "PASS Prometheus $expression = $value"
                return $true
            }
        }
        return $false
    }
}

function Save-AlertEvidence($scenario) {
    $evidence = [ordered]@{
        scenario = $scenario
        observedAt = [datetimeoffset]::UtcNow.ToString('o')
        prometheus = Invoke-RestMethod "$promUrl/api/v1/alerts" -TimeoutSec 5
        alertmanager = @(Invoke-RestMethod "$alertUrl/api/v2/alerts/groups" -TimeoutSec 5)
        kafkaOffsets = @(Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group robotics-fleet-receipts)
        liveHttp = (Invoke-WebRequest "$apiUrl/health/live" -SkipHttpErrorCheck -TimeoutSec 5).StatusCode
        readyHttp = (Invoke-WebRequest "$apiUrl/health/ready" -SkipHttpErrorCheck -TimeoutSec 5).StatusCode
    }
    $evidence | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $alertEvidence
}

function Wait-Alerts([string[]]$names, [switch]$Resolved, [string]$Signal) {
    $mode = if ($Resolved) { 'resolved' } else { 'firing and grouped' }
    function Select-Alerts($alerts) {
        $alerts | Where-Object { $_.labels.alertname -in $names -and (!$Signal -or $_.labels.signal -eq $Signal) }
    }
    Wait-For "$($names -join ', ') $mode" {
        $alerts = (Invoke-RestMethod "$promUrl/api/v1/alerts" -TimeoutSec 5).data.alerts
        $groups = @(Invoke-RestMethod "$alertUrl/api/v2/alerts/groups" -TimeoutSec 5)
        if ($Resolved) {
            return @(Select-Alerts $alerts).Count -eq 0 -and @(Select-Alerts ($groups.alerts)).Count -eq 0
        }
        $firing = @(Select-Alerts ($alerts | Where-Object state -eq 'firing'))
        if (@($firing.labels.alertname | Sort-Object -Unique).Count -ne $names.Count) { return $false }
        foreach ($group in $groups) {
            $received = @(Select-Alerts $group.alerts)
            if ($group.labels.service -eq 'robotics-fleet' -and $group.receiver.name -eq 'local' -and
                $received.Count -eq $names.Count -and @($received.labels.alertname | Sort-Object -Unique).Count -eq $names.Count) {
                return $true
            }
        }
        return $false
    } 100
    Write-Host "PASS alerts $($names -join ', ') $mode"
}

try {
    Write-Host "Isolated Compose project $project"
    Invoke-Compose up --wait kafka mssql
    Invoke-Compose run --build --rm migrations
    foreach ($topic in @('robot.commands', 'robot.events')) {
        Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic $topic --partitions 1 --replication-factor 1
    }
    Invoke-Compose up --build --wait api bridge simulator
    $apiUrl = "http://$(Invoke-Compose port api 8080)"
    $baseUrl = "$apiUrl/api/messages"
    if ($CheckMonitoring) {
        Invoke-Compose up --wait prometheus grafana kafka-exporter
        $promUrl = "http://$(Invoke-Compose port prometheus 9090)"
        $grafanaUrl = "http://$(Invoke-Compose port grafana 3000)"
        if ($CheckAlerting) {
            Invoke-Compose up --wait alertmanager
            $alertUrl = "http://$(Invoke-Compose port alertmanager 9093)"
            Invoke-Compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
            Invoke-Compose exec -T alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
        }
        Assert-Metric 'up{job="robotics-api"}' { param($v) $v -eq '1' }
        Assert-Metric 'up{job="kafka-exporter"}' { param($v) $v -eq '1' }
        Assert-Metric 'kafka_brokers' { param($v) $v -eq '1' }
        Wait-For 'Grafana dashboard and datasource' {
            $dashboard = Invoke-WebRequest "$grafanaUrl/api/dashboards/uid/robotics-fleet" -SkipHttpErrorCheck -TimeoutSec 5
            if ($dashboard.StatusCode -ne 200) { return $false }
            $definition = $dashboard.Content | ConvertFrom-Json
            $proxy = Invoke-WebRequest "$grafanaUrl/api/datasources/proxy/uid/robotics-prometheus/api/v1/query?query=up" -SkipHttpErrorCheck -TimeoutSec 5
            return $definition.meta.provisioned -and $definition.dashboard.panels.Count -eq 7 -and
                $proxy.StatusCode -eq 200 -and ($proxy.Content | ConvertFrom-Json).data.result.Count -ge 2
        }
        Write-Host 'PASS Grafana provisioned dashboard and working Prometheus datasource'
        Assert-Metric 'robotics_consumer_last_success_timestamp_seconds' { param($v) $v -eq '0' }
    }
    Wait-For 'both ROS topic pairs' {
        $commands = Invoke-Compose exec -T bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/commands --verbose --no-daemon'
        $receipts = Invoke-Compose exec -T bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/receipts --verbose --no-daemon'
        return ($commands -match 'Node name: robotics_fleet_bridge') -and
            ($commands -match 'Node name: robotics_fleet_simulator') -and
            ($receipts -match 'Node name: robotics_fleet_bridge') -and
            ($receipts -match 'Node name: robotics_fleet_simulator')
    }
    if ($CheckHealth) {
        Assert-Health 'normal operation' 200
        Start-Sleep -Seconds 12
        Assert-Health 'empty topic beyond statistics expiry' 200
        Invoke-Compose stop mssql
        Assert-Health 'MSSQL unavailable while worker is idle' 503
        Invoke-Compose up --wait mssql
        Assert-Health 'MSSQL restored while worker is still running' 200
    }

    $post = Invoke-WebRequest $baseUrl -Method Post -ContentType application/json -Body '{"content":"Lab 8 receipt verification"}'
    $id = ($post.Content | ConvertFrom-Json).messageId
    if ($post.StatusCode -ne 201 -or !$id) { throw 'POST did not create a message' }
    Write-Host "POST 201 $($post.Content)"
    Assert-Group 1 1 0
    $record = Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 --topic robot.events --from-beginning --max-messages 1 --timeout-ms 15000 --property print.key=true
    $key, $value = $record -split "`t", 2
    $receipt = $value | ConvertFrom-Json -DateKind String
    $getResponse = Invoke-WebRequest "$baseUrl/$id"
    $get = $getResponse.Content | ConvertFrom-Json -DateKind String
    if ($key -cne $id -or $receipt.messageId -cne $id -or $receipt.type -cne 'RECEIVED' -or
        $receipt.source -cne 'ros2-simulator' -or $get.status -cne 'Acknowledged' -or
        [datetimeoffset]$get.receivedAt -ne [datetimeoffset]$receipt.receivedAt) {
        throw 'HTTP response and Kafka receipt differ'
    }
    Write-Host "robot.events $record"
    Write-Host "GET 200 $($get | ConvertTo-Json -Compress)"
    Invoke-Compose logs --no-color bridge simulator api | Select-String -SimpleMatch $id | Out-Host
    Write-Host 'PASS HTTP to ROS to Kafka to SQL and GET'
    if ($CheckMonitoring) {
        $metrics = (Invoke-WebRequest "$apiUrl/metrics").Content
        if ($metrics -notmatch 'robotics_receipts_processed_total' -or
            $metrics -notmatch 'robotics_receipt_processing_duration_seconds_bucket' -or
            $metrics -match [regex]::Escape($id)) { throw 'Unexpected API metric names or labels' }
        Write-Host 'PASS API metrics expose receipt instruments without message IDs'
        Assert-Metric 'robotics_receipts_processed_total{outcome="acknowledged"}' { param($v) $v -eq '1' }
        Assert-Metric 'robotics_consumer_last_success_timestamp_seconds' { param($v) [long]$v -gt 0 }
    }

    $unknown = [guid]::NewGuid().ToString()
    Send-Receipt $id '2026-11-16T00:00:00Z'
    Send-Receipt $unknown '2026-11-16T00:00:01Z'
    Assert-Group 3 3 0
    @"
DECLARE @id uniqueidentifier = '$id';
IF NOT EXISTS (SELECT 1 FROM dbo.Messages WHERE MessageId = @id AND Status = 1 AND ReceivedAt = CAST('$($receipt.receivedAt)' AS datetimeoffset(7))) THROW 51000, 'Stored receipt changed', 1;
IF EXISTS (SELECT 1 FROM dbo.Messages WHERE MessageId = '$unknown') THROW 51000, 'Unmatched receipt inserted a row', 1;
SELECT MessageId, Status, ReceivedAt FROM dbo.Messages WHERE MessageId = @id;
"@ | docker compose @composeArgs exec -T mssql sh -c 'export SQLCMDPASSWORD=$MSSQL_SA_PASSWORD; exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -d RoboticsFleet'
    if ($LASTEXITCODE -ne 0) { throw 'SQL assertions failed' }
    $logs = Invoke-Compose logs --no-color api
    if (!($logs -match "Duplicate receipt for $id") -or !($logs -match "Unmatched receipt for $unknown")) {
        throw 'Receipt outcome logs missing'
    }
    $logs | Select-String "Duplicate receipt for $id|Unmatched receipt for $unknown" | Out-Host
    Write-Host 'PASS duplicate kept first timestamp and unmatched created no row'
    if ($CheckMonitoring) {
        Assert-Metric 'robotics_receipts_processed_total{outcome="duplicate"}' { param($v) $v -eq '1' }
        Assert-Metric 'robotics_receipts_processed_total{outcome="unmatched"}' { param($v) $v -eq '1' }
        Assert-Metric 'histogram_quantile(0.95, sum by (le) (rate(robotics_receipt_processing_duration_seconds_bucket[5m])))' {
            param($v) $v -ne 'NaN' -and [double]$v -gt 0
        }
        $lagQuery = 'kafka_consumergroup_lag{consumergroup="robotics-fleet-receipts",topic="robot.events",partition="0"}'
        Assert-Metric $lagQuery { param($v) $v -eq '0' }
    }
    if ($CheckAlerting) {
        # Wait past the longest hold time with all required series present.
        Start-Sleep -Seconds 65
        $normal = (Invoke-RestMethod "$promUrl/api/v1/alerts").data.alerts
        if ($normal.state -contains 'firing') { throw 'Unexpected firing alerts under normal operation' }
        Save-AlertEvidence 'normal after hold periods'
        Write-Host 'PASS no unexpected alerts under normal operation'

        Invoke-Compose stop api
        Wait-Alerts 'RoboticsApiMetricsDown'
        $httpResult = try {
            (Invoke-WebRequest "$apiUrl/health/live" -SkipHttpErrorCheck -TimeoutSec 3).StatusCode
        } catch {
            'No HTTP response'
        }
        if ($httpResult -ne 'No HTTP response') { throw "Expected stopped API, got HTTP $httpResult" }
        [ordered]@{
            scenario = 'API stopped'
            observedAt = [datetimeoffset]::UtcNow.ToString('o')
            prometheus = Invoke-RestMethod "$promUrl/api/v1/alerts"
            alertmanager = @(Invoke-RestMethod "$alertUrl/api/v2/alerts/groups")
            liveHttp = $httpResult
        } | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $alertEvidence
        Invoke-Compose up --wait api
        $apiUrl = "http://$(Invoke-Compose port api 8080)"
        $baseUrl = "$apiUrl/api/messages"
        Assert-Health 'API restored' 200
        Wait-Alerts 'RoboticsApiMetricsDown' -Resolved
        Save-AlertEvidence 'API scrape recovered'
    }

    if ($CheckHealth) {
        Invoke-Compose stop kafka
        Assert-Health 'Kafka unavailable' 503
        Invoke-Compose up --wait kafka
        Assert-Health 'Kafka restored' 200
    }

    Invoke-Compose stop mssql
    Send-Receipt $id $receipt.receivedAt
    Send-Receipt $unknown $receipt.receivedAt
    Wait-For 'consumer halt on SQL outage' {
        return [bool](Invoke-Compose logs --no-color api | Select-String 'Receipt consumer halted at .*@3')
    }
    Assert-Group 3 5 2
    Write-Host 'PASS SQL failure left the failed and subsequent offsets uncommitted'
    if ($CheckMonitoring) {
        Assert-Metric 'robotics_receipts_failures_total{reason="database_error"}' { param($v) $v -eq '1' }
        if (!$CheckAlerting) {
            Assert-Metric 'sum(robotics_receipts_processed_total)' { param($v) $v -eq '3' }
        }
        Assert-Metric $lagQuery { param($v) $v -eq '2' }
    }

    Invoke-Compose up --wait mssql
    if ($CheckHealth) {
        Assert-Health 'MSSQL restored after worker fault' 503
        $stillResponding = Invoke-WebRequest "$baseUrl/$id"
        if ($stillResponding.StatusCode -ne 200) { throw 'HTTP GET failed after consumer halt' }
        Write-Host 'PASS HTTP message GET returned 200 after consumer halt'
    }
    if ($CheckAlerting) {
        Wait-Alerts @('RoboticsReceiptLagHigh', 'RoboticsReceiptConsumerUnavailable')
        Save-AlertEvidence 'SQL restored but consumer halted and lag sustained'
    }
    Invoke-Compose restart api
    Assert-Group 5 5 0
    Write-Host 'PASS restart processed both outstanding receipts'
    if ($CheckMonitoring) { Assert-Metric $lagQuery { param($v) $v -eq '0' } }
    if ($CheckHealth) {
        $apiUrl = "http://$(Invoke-Compose port api 8080)"
        Assert-Health 'API restarted after SQL failure' 200
    }
    if ($CheckAlerting) {
        Wait-Alerts @('RoboticsReceiptLagHigh', 'RoboticsReceiptConsumerUnavailable') -Resolved
        Save-AlertEvidence 'consumer restarted and lag cleared'
        Invoke-Compose stop kafka-exporter
        Wait-Alerts 'RoboticsTelemetryMissing' -Signal receipt-lag
        Save-AlertEvidence 'Kafka exporter unavailable'
        Invoke-Compose up --wait kafka-exporter
        Wait-Alerts 'RoboticsTelemetryMissing' -Signal receipt-lag -Resolved
        Save-AlertEvidence 'Kafka exporter recovered'
    }

    Send-Receipt $id $receipt.receivedAt $unknown
    Wait-For 'consumer halt on key mismatch' {
        return [bool](Invoke-Compose logs --no-color api | Select-String 'Receipt consumer halted at .*@5')
    }
    Assert-Group 5 6 1
    Write-Host 'PASS invalid key halted the consumer without committing'
    if ($CheckMonitoring) {
        Assert-Metric 'robotics_receipts_failures_total{reason="invalid_receipt"}' { param($v) $v -eq '1' }
    }
    if ($CheckHealth) { Assert-Health 'fatal malformed receipt with healthy dependencies' 503 }
}
finally {
    try { Invoke-Compose down }
    finally { $env:MSSQL_SA_PASSWORD = $oldPassword }
}
