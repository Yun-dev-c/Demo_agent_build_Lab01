#Requires -Version 7.5
# Run from the repository root with Docker Desktop running.
$ErrorActionPreference = 'Stop'
$project = 'fleet-lab3-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$baseUrl = 'http://127.0.0.1:8080/api/messages'
$originalPassword = $env:MSSQL_SA_PASSWORD
$originalLabMode = $env:LAB3_SQL_ONLY_POST
$env:MSSQL_SA_PASSWORD = 'Lab3!;' + [guid]::NewGuid().ToString('N')

function Invoke-Compose {
    docker compose -p $project @args
    if ($LASTEXITCODE -ne 0) { throw "Compose failed: $($args -join ' ')" }
}

function Invoke-Sql([string]$statement) {
    $statement | docker compose -p $project exec -T mssql sh -c 'export SQLCMDPASSWORD=$MSSQL_SA_PASSWORD; exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d RoboticsFleet'
    if ($LASTEXITCODE -ne 0) { throw 'SQL assertion failed.' }
}

function Assert-Status($response, [int]$expected, [string]$case) {
    if ($response.StatusCode -ne $expected) {
        throw "$case expected HTTP $expected, received $($response.StatusCode)"
    }
    Write-Host "PASS $case (HTTP $expected)"
}

function Send-Post([string]$body, [string]$contentType = 'application/json') {
    Invoke-WebRequest -Uri $baseUrl -Method Post -ContentType $contentType -Body $body -SkipHttpErrorCheck -TimeoutSec 45
}

function Send-Get([string]$id) {
    Invoke-WebRequest -Uri "$baseUrl/$id" -SkipHttpErrorCheck -TimeoutSec 45
}

try {
    $env:LAB3_SQL_ONLY_POST = 'false'
    Invoke-Compose up --build --wait api mssql
    Invoke-Compose run --build --rm migrations

    $valid = '{"content":"  Lab 3 SQL marker  "}'
    Assert-Status (Send-Post $valid) 503 'Normal mode requires Kafka publication'
    Invoke-Sql "IF EXISTS (SELECT 1 FROM dbo.Messages) THROW 51000, 'Normal mode unexpectedly inserted a message', 1;"

    $env:LAB3_SQL_ONLY_POST = 'true'
    Invoke-Compose up --wait --force-recreate --no-deps api
    $created = Send-Post $valid
    Assert-Status $created 200 'SQL-only POST'
    $message = $created.Content | ConvertFrom-Json -DateKind String
    $id = $message.messageId
    if ($id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' -or
        $message.content -cne '  Lab 3 SQL marker  ' -or $message.status -cne 'Pending' -or
        $message.createdAt -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$' -or
        $null -ne $message.receivedAt -or
        ($message.PSObject.Properties.Name -join ',') -cne 'messageId,content,status,createdAt,receivedAt' -or
        ($created.Headers['X-Lab-Mode'] -join '') -cne 'sql-only' -or
        ($created.Headers.Location -join '') -cne "/api/messages/$id") {
        throw 'POST response fields, formats, or Lab 3 headers differ.'
    }
    Invoke-Sql "IF NOT EXISTS (SELECT 1 FROM dbo.Messages WHERE MessageId = '$id' AND Status = 0 AND ReceivedAt IS NULL AND DATALENGTH(Content) = DATALENGTH(N'  Lab 3 SQL marker  ') AND Content = N'  Lab 3 SQL marker  ' AND DATEPART(TZOFFSET, CreatedAt) = 0) THROW 51000, 'Missing Pending row', 1;"
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

    Invoke-Compose up --wait mssql
    Invoke-Compose run --rm migrations 0
    Assert-Status (Send-Get $id) 500 'Unexpected database schema failure'
    Write-Host 'Lab 3 integration checks passed.'
}
catch {
    docker compose -p $project logs --tail 80 api
    throw
}
finally {
    try { Invoke-Compose down --volumes }
    finally {
        $env:MSSQL_SA_PASSWORD = $originalPassword
        $env:LAB3_SQL_ONLY_POST = $originalLabMode
    }
}
