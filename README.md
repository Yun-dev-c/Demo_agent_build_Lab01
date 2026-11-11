# Robotics Fleet Operations Platform

## Week 1 / Lab 1

Use Docker Desktop in Linux-container mode with Docker Compose. Compose builds the ASP.NET Core skeleton with the official .NET 10 LTS SDK image. The Windows host can use the stack without a local .NET SDK.

From the repository root in PowerShell, copy `.env.example` to `.env` on first setup and set `MSSQL_SA_PASSWORD` to a strong local password. Use a single-quoted value in `.env` if the password contains `$`. Keep `.env` local and retain the original SQL password when reusing its data volume.

```powershell
Copy-Item .env.example .env
# Set MSSQL_SA_PASSWORD in .env before continuing.
docker compose config --quiet
docker compose up --build --wait
docker compose ps
```

### Local connections

Services share the Compose default network (`robotics-fleet_default`). Service names resolve on that network. Published ports bind to the host loopback address.

| Service | Windows host | Compose network |
| --- | --- | --- |
| ASP.NET Core | `http://127.0.0.1:8080` | `http://api:8080` |
| SQL Server | `127.0.0.1,1433` | `mssql,1433` |
| Kafka | `127.0.0.1:9092` | `kafka:29092` |

Kafka advertises a different address for each client network. The KRaft controller listener at `kafka:9093` stays inside Compose. SQL Server persists to `mssql-data` at `/var/opt/mssql`. Kafka persists log and KRaft metadata to `kafka-data` at `/var/lib/kafka/data`.

### Check the lab

```powershell
docker compose exec kafka /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server kafka:29092 describe --status
curl.exe -i http://127.0.0.1:8080/
docker compose exec mssql sh
```

In the SQL Server container shell, run the query and return to PowerShell.

```sh
SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -Q 'SELECT 1 AS Ready'
exit
```

Expect SQL Server to return `1`, Kafka to report a leader on the single-node quorum, and the API to return HTTP `404` because the skeleton has no routes. For a Kafka exercise, use the same internal bootstrap address with `kafka-topics.sh --list` to check the broker's topic metadata.

Stop and remove the containers with `docker compose down`. The named data volumes persist across `down` and subsequent `up` runs.

## Week 1 / Lab 2 — EF Core and SQL Server

The API and migration tool connect to `mssql,1433` on the Compose network and use the local `RoboticsFleet` database. Compose passes the password from the ignored `.env` file. The migration tool uses the development `sa` login and trusts the local SQL Server certificate.

Apply the migration explicitly from PowerShell. The tool waits for SQL Server to be healthy. Starting the API alone performs no migration.

```powershell
docker compose run --build --rm migrations
```

For a quick schema check, enter the SQL Server container with `docker compose exec mssql sh` and run:

```sh
SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d RoboticsFleet -Q "EXEC sys.sp_help N'dbo.Messages'; SELECT MigrationId, ProductVersion FROM dbo.__EFMigrationsHistory;"
exit
```

The initial migration creates `dbo.Messages`. EF Core tracks it in `dbo.__EFMigrationsHistory`.

Roll back to the empty migration state only on a disposable database or after backing up the data. This drops `dbo.Messages` and its rows. Reapplying recreates an empty table.

```powershell
docker compose run --build --rm migrations 0
docker compose run --build --rm migrations
```

## Week 1 / Lab 3 — HTTP API

For local SQL-only testing, set `LAB3_SQL_ONLY_POST=true` in `.env`, apply the migration, and start the API. A successful test POST returns `200 OK`, a `Location` header, and `X-Lab-Mode: sql-only`. It saves a `Pending` row and returns its fields. With the flag off, a valid POST returns `503` before writing because command publication is unavailable. GET uses MSSQL in either mode.

```powershell
docker compose run --build --rm migrations
docker compose up --build --wait api mssql
$body = @{ content = 'Hello ROS 2' } | ConvertTo-Json
$message = Invoke-RestMethod http://127.0.0.1:8080/api/messages -Method Post -ContentType application/json -Body $body
Invoke-RestMethod "http://127.0.0.1:8080/api/messages/$($message.messageId)"
```

Lab 4 will remove the SQL-only flag and response. After the insert, the API will publish the command to `robot.commands` using the saved `messageId`. A successful broker acknowledgement will enable the contract's `201 Created` response with `Location`. If publication fails or its outcome is unknown, the persisted row may remain `Pending` and the API returns an error.

Run the automated HTTP and MSSQL checks from the repository root with PowerShell 7.5 or later. Keep host ports `8080` and `1433` free. The script uses a disposable Compose project and database volume, tests a real SQL Server outage, and removes its test resources afterward.

```powershell
pwsh -NoProfile -File ./tests/lab3-http.ps1
```
