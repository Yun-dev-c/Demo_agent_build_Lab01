#Requires -Version 7.5
# Run from the repository root with Docker Desktop running.
$ErrorActionPreference = 'Stop'
$project = 'fleet-lab4-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$composeFiles = @('-f', 'compose.yaml', '-f', 'tests/lab4.compose.yaml')
$resultsDirectory = Join-Path (Get-Location) 'TestResults'
New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
$evidencePath = Join-Path $resultsDirectory "$project.log"
$originalPassword = $env:MSSQL_SA_PASSWORD
$env:MSSQL_SA_PASSWORD = 'Lab4!;' + [guid]::NewGuid().ToString('N')

function Write-Evidence([string]$line) {
    Add-Content -LiteralPath $evidencePath -Value $line -Encoding utf8
    Write-Host $line
}

function Invoke-Compose {
    docker compose @composeFiles -p $project @args
    if ($LASTEXITCODE -ne 0) { throw "Compose failed: $($args -join ' ')" }
}

function Invoke-Sql([string]$statement) {
    $statement | docker compose @composeFiles -p $project exec -T mssql sh -c 'export SQLCMDPASSWORD=$MSSQL_SA_PASSWORD; exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d RoboticsFleet'
    if ($LASTEXITCODE -ne 0) { throw 'SQL assertion failed.' }
}

function Assert-Status($response, [int]$expected, [string]$case) {
    if ($response.StatusCode -ne $expected) {
        throw "$case expected HTTP $expected, received $($response.StatusCode)"
    }
    Write-Evidence "PASS $case (HTTP $expected)"
}

function Send-Post([string]$body, [string]$contentType = 'application/json') {
    Invoke-WebRequest -Uri $baseUrl -Method Post -ContentType $contentType -Body $body -SkipHttpErrorCheck -TimeoutSec 45
}

function Send-Get([string]$id) {
    Invoke-WebRequest -Uri "$baseUrl/$id" -SkipHttpErrorCheck -TimeoutSec 45
}

try {
    Write-Evidence "Lab 4 integration test ($project)"
    Invoke-Compose up --build --wait api mssql kafka
    $apiAddress = Invoke-Compose port api 8080
    $baseUrl = "http://$apiAddress/api/messages"
    Invoke-Compose run --build --rm migrations
    foreach ($attempt in 1..2) {
        Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic robot.commands --partitions 1 --replication-factor 1
    }
    Write-Evidence 'PASS robot.commands topic creation is repeatable'

    $valid = '{"content":"  Lab 4 SQL and Kafka marker  "}'
    $created = Send-Post $valid
    Assert-Status $created 201 'POST with Kafka acknowledgement'
    $message = $created.Content | ConvertFrom-Json -DateKind String
    $id = $message.messageId
    if ($id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' -or
        $message.content -cne '  Lab 4 SQL and Kafka marker  ' -or $message.status -cne 'Pending' -or
        $message.createdAt -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$' -or
        $null -ne $message.receivedAt -or
        ($message.PSObject.Properties.Name -join ',') -cne 'messageId,content,status,createdAt,receivedAt' -or
        ($created.Headers.Location -join '') -cne "/api/messages/$id") {
        throw 'POST response fields, formats, or Location differ.'
    }
    Invoke-Sql "IF NOT EXISTS (SELECT 1 FROM dbo.Messages WHERE MessageId = '$id' AND Status = 0 AND ReceivedAt IS NULL AND DATALENGTH(Content) = DATALENGTH(N'  Lab 4 SQL and Kafka marker  ') AND Content = N'  Lab 4 SQL and Kafka marker  ' AND CreatedAt = CAST('$($message.createdAt)' AS datetimeoffset(7)) AND DATEPART(TZOFFSET, CreatedAt) = 0) THROW 51000, 'Missing Pending row', 1;"
    Write-Evidence "PASS MSSQL Pending row and POST share messageId $id and createdAt $($message.createdAt)"

    $record = Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 --topic robot.commands --from-beginning --max-messages 1 --timeout-ms 15000 --property print.key=true
    $key, $value = $record -csplit "`t", 2
    $command = $value | ConvertFrom-Json -DateKind String
    if ($key -cne $id -or $command.messageId -cne $id -or $command.type -cne 'PING' -or
        $command.content -cne $message.content -or $command.createdAt -cne $message.createdAt -or
        ($command.PSObject.Properties.Name -join ',') -cne 'messageId,type,content,createdAt') {
        throw 'Kafka record does not match the persisted command and POST response.'
    }
    Write-Evidence "PASS robot.commands key=$key value=$value"

    $found = Send-Get $id
    Assert-Status $found 200 'GET by persisted UUID'
    if ($found.Content -cne $created.Content) { throw 'GET did not return the persisted POST fields.' }

    foreach ($invalid in @('', '{}', 'null', '[]', '{"content":null}', '{"content":42}', '{"content":""}', '{"content":" \t\n"}', '{"content":')) {
        Assert-Status (Send-Post $invalid) 400 "Invalid body [$invalid]"
    }
    Assert-Status (Send-Post $valid 'text/plain') 415 'Unsupported media type'
    Assert-Status (Send-Post $valid 'application/problem+json') 415 'Unsupported JSON media type'
    Assert-Status (Send-Get 'bad-id') 400 'Malformed message ID'
    Assert-Status (Send-Get $id.ToUpperInvariant()) 400 'Noncanonical message ID'
    Assert-Status (Send-Get '550e8400-e29b-11d4-a716-446655440000') 400 'Non-v4 message ID'
    Assert-Status (Send-Get '550e8400-e29b-41d4-0716-446655440000') 400 'Invalid UUID variant'
    Assert-Status (Send-Get ([guid]::NewGuid().ToString())) 404 'Missing message'
    Invoke-Sql "IF (SELECT COUNT(*) FROM dbo.Messages) <> 1 THROW 51000, 'Unexpected row count after validation', 1; UPDATE dbo.Messages SET Status = 1, ReceivedAt = '2026-11-10T02:00:02.1234567+00:00' WHERE MessageId = '$id';"
    $acknowledged = Send-Get $id
    Assert-Status $acknowledged 200 'GET acknowledged message'
    $receipt = $acknowledged.Content | ConvertFrom-Json -DateKind String
    if ($receipt.status -cne 'Acknowledged' -or $receipt.receivedAt -cne '2026-11-10T02:00:02.1234567Z') {
        throw 'Receipt status or UTC timestamp differs.'
    }

    Invoke-Compose stop mssql
    Assert-Status (Send-Get $id) 503 'GET with MSSQL stopped'
    Assert-Status (Send-Post $valid) 503 'POST with MSSQL stopped'
    $offsets = Invoke-Compose exec -T kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:29092 --topic robot.commands
    if ($offsets -cne 'robot.commands:0:1') { throw 'Kafka received an unexpected record.' }
    Write-Evidence 'PASS Invalid requests and the SQL outage produced no additional command'

    Invoke-Compose up --wait mssql
    Invoke-Compose stop kafka
    $unavailable = Send-Post '{"content":"Lab 4 Kafka outage marker"}'
    Assert-Status $unavailable 503 'POST with Kafka stopped'
    if ($unavailable.Headers.ContainsKey('Location')) { throw 'Unconfirmed POST returned Location.' }
    Invoke-Sql "IF (SELECT COUNT(*) FROM dbo.Messages WHERE Content = N'Lab 4 Kafka outage marker' AND Status = 0 AND ReceivedAt IS NULL) <> 1 THROW 51000, 'Kafka failure should leave one Pending row', 1;"
    Write-Evidence 'PASS Kafka outage left one Pending row and returned no Location'
    Assert-Status (Send-Get $id) 200 'GET with Kafka stopped'

    Invoke-Compose run --rm migrations 0
    Assert-Status (Send-Get $id) 500 'Unexpected database schema failure'
    Write-Evidence 'Lab 4 integration checks passed.'
}
catch {
    Write-Evidence 'FAIL Lab 4 integration checks. See console output for details.'
    docker compose @composeFiles -p $project logs --tail 80 api
    throw
}
finally {
    try { Invoke-Compose down --volumes }
    finally {
        $env:MSSQL_SA_PASSWORD = $originalPassword
        Write-Host "Test evidence: $evidencePath"
    }
}
