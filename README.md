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

Expect SQL Server to return `1`, Kafka to report a leader on the single-node quorum, and the API to return HTTP `404` for the unmapped root path. Use the same internal bootstrap address with `kafka-topics.sh --list` to check the broker's topic metadata.

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

## Week 1 / Lab 4 — HTTP API and Kafka producer

The API inserts a `Pending` row and publishes a command to `robot.commands` through `kafka:29092`. The producer uses `acks=all` and a five-second delivery timeout. A confirmed delivery returns `201 Created` with `Location`. The broker can create the topic on first publication. Use the idempotent create command below to provision it explicitly before testing.

```powershell
docker compose run --build --rm migrations
docker compose up --build --wait api mssql kafka
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic robot.commands --partitions 1 --replication-factor 1
$body = @{ content = 'Hello ROS 2' } | ConvertTo-Json
$message = Invoke-RestMethod http://127.0.0.1:8080/api/messages -Method Post -ContentType application/json -Body $body
Invoke-RestMethod "http://127.0.0.1:8080/api/messages/$($message.messageId)"
docker compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 --topic robot.commands --from-beginning --timeout-ms 10000 --property print.key=true
```

Compare the returned `messageId` with the Kafka key and the JSON `messageId`. The consumer prints the topic history and exits after its idle timeout. A broker acknowledgement confirms Kafka delivery. Simulator receipt requires the later return flow.

SQL Server and Kafka writes are separate. If the SQL insert succeeds and Kafka delivery cannot be confirmed, POST returns `503` and the row stays `Pending`. Kafka may already contain the command if its acknowledgement was lost. A repeated POST creates a new command and UUID.

Run the HTTP, SQL Server, and Kafka checks from the repository root with PowerShell 7.5 or later. The script uses a disposable Compose project with an automatically assigned API port and saves credential-free evidence under `TestResults` before removing its test resources.

```powershell
pwsh -NoProfile -File ./tests/lab4-http.ps1
```

## Week 2 / Lab 6 — Kafka to ROS 2

The Bridge image uses the public `ros:jazzy-ros-base-noble` image with Python 3.12. Start the local stack and apply the existing migration.

```powershell
docker compose up --build --wait api mssql kafka
docker compose run --build --rm migrations
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic robot.commands --partitions 1 --replication-factor 1
docker compose up --build --wait bridge
```

In a second terminal, start the ROS 2 subscriber and leave it running. The CLI inherits the Bridge container's ROS environment and network.

```powershell
docker compose exec bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic echo --full-length /demo/commands example_interfaces/msg/String'
```

Verify the publisher and subscriber appear before sending the command. Volatile durability means a late subscriber can miss earlier commands.

```powershell
docker compose exec bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/commands --verbose'
$body = @{ content = 'Lab 6 acceptance' } | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:8080/api/messages -Method Post -ContentType application/json -Body $body
docker compose logs --tail 20 bridge
docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group robotics-fleet-bridge
```

Match the HTTP `messageId` to the JSON in the subscriber's `data` and the Bridge log. The publisher uses Reliable, Volatile, Keep Last, and depth 10. The group's committed offset should be at least the logged record offset plus one. The commit records the local `publish()` handoff. Subscriber output provides separate evidence of receipt. A publish or commit error stops the Bridge so a later offset cannot skip the failed command. A publish followed by an unconfirmed commit can lead to duplicate delivery on restart.

Stop the subscriber with Ctrl+C and stop the Bridge with `docker compose stop bridge`.
