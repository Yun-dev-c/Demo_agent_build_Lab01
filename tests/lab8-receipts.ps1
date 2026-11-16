#Requires -Version 7.5
# Run from the repository root.
$ErrorActionPreference = 'Stop'
$project = 'fleet-lab8-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$composeArgs = @('--profile', 'lab7', '-f', 'compose.yaml', '-f', 'tests/lab4.compose.yaml', '-p', $project)
$oldPassword = $env:MSSQL_SA_PASSWORD
$env:MSSQL_SA_PASSWORD = 'Lab8!' + [guid]::NewGuid().ToString('N')

function Invoke-Compose {
    docker compose @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "Compose failed: $($args -join ' ')" }
}

function Wait-For($description, [scriptblock]$check) {
    foreach ($attempt in 1..45) {
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

try {
    Write-Host "Isolated Compose project $project"
    Invoke-Compose up --wait kafka mssql
    Invoke-Compose run --build --rm migrations
    foreach ($topic in @('robot.commands', 'robot.events')) {
        Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic $topic --partitions 1 --replication-factor 1
    }
    Invoke-Compose up --build --wait api bridge simulator
    $baseUrl = "http://$(Invoke-Compose port api 8080)/api/messages"
    Wait-For 'both ROS topic pairs' {
        $commands = Invoke-Compose exec -T bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/commands --verbose --no-daemon'
        $receipts = Invoke-Compose exec -T bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/receipts --verbose --no-daemon'
        return ($commands -match 'Node name: robotics_fleet_bridge') -and
            ($commands -match 'Node name: robotics_fleet_simulator') -and
            ($receipts -match 'Node name: robotics_fleet_bridge') -and
            ($receipts -match 'Node name: robotics_fleet_simulator')
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

    Invoke-Compose stop mssql
    Send-Receipt $id $receipt.receivedAt
    Send-Receipt $unknown $receipt.receivedAt
    Wait-For 'consumer halt on SQL outage' {
        return [bool](Invoke-Compose logs --no-color api | Select-String 'Receipt consumer halted at .*@3')
    }
    Assert-Group 3 5 2
    Write-Host 'PASS SQL failure left the failed and subsequent offsets uncommitted'

    Invoke-Compose up --wait mssql
    Invoke-Compose restart api
    Assert-Group 5 5 0
    Write-Host 'PASS restart processed both outstanding receipts'

    Send-Receipt $id $receipt.receivedAt $unknown
    Wait-For 'consumer halt on key mismatch' {
        return [bool](Invoke-Compose logs --no-color api | Select-String 'Receipt consumer halted at .*@5')
    }
    Assert-Group 5 6 1
    Write-Host 'PASS invalid key halted the consumer without committing'
}
finally {
    try { Invoke-Compose down }
    finally { $env:MSSQL_SA_PASSWORD = $oldPassword }
}
