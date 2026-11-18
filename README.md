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

## Week 2 / Lab 7 — Simulator receipt

With the local environment configured, start the existing services and provision the two topics before starting the Bridge and simulator.

```powershell
docker compose up --build --wait api mssql kafka
docker compose run --build --rm migrations
foreach ($topic in @('robot.commands', 'robot.events')) {
    docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic $topic --partitions 1 --replication-factor 1
}
docker compose --profile lab7 up --build --wait bridge simulator
docker compose exec bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/commands --verbose && ros2 topic info /demo/receipts --verbose'
```

Wait until both topics show a publisher and a subscriber. To observe the receipt directly, start the following command in a separate terminal before posting.

```powershell
docker compose exec bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic echo --full-length /demo/receipts example_interfaces/msg/String'
```

```powershell
$body = @{ content = 'Lab 7 receipt verification' } | ConvertTo-Json
$message = Invoke-RestMethod http://127.0.0.1:8080/api/messages -Method Post -ContentType application/json -Body $body
$message
docker compose logs --tail 20 bridge simulator
docker compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:29092 --topic robot.events --from-beginning --timeout-ms 10000 --property print.key=true
```

Match the HTTP `messageId` to the simulator receipt, the Kafka key and JSON value, and the Bridge delivery log. The event uses `RECEIVED`, source `ros2-simulator`, and the simulator's UTC `receivedAt`. SQL status stays `Pending` until the Lab 8 consumer persists a receipt.

Malformed ROS input is logged and ignored. The Bridge logs enqueue and delivery failures with the message ID. An expired receipt can be lost during a broker outage, and an uncertain acknowledgement can leave its Kafka outcome unknown. The command offset still records the earlier ROS publish handoff.

## Week 2 / Lab 8 — Persist simulator receipts

Start Kafka and MSSQL, apply the migration, and provision both topics before starting the API, Bridge, and simulator.

```powershell
docker compose up --wait kafka mssql
docker compose run --build --rm migrations
foreach ($topic in @('robot.commands', 'robot.events')) {
    docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:29092 --create --if-not-exists --topic $topic --partitions 1 --replication-factor 1
}
docker compose --profile lab7 up --build --wait api bridge simulator
docker compose exec bridge bash -lc 'source /opt/ros/jazzy/setup.bash && ros2 topic info /demo/commands --verbose && ros2 topic info /demo/receipts --verbose'
```

After DDS discovers both topic pairs, submit a command and poll its status.

```powershell
$baseUrl = 'http://127.0.0.1:8080/api/messages'
$body = @{ content = 'Lab 8 receipt verification' } | ConvertTo-Json
$message = Invoke-RestMethod $baseUrl -Method Post -ContentType application/json -Body $body
foreach ($attempt in 1..20) {
    $result = Invoke-RestMethod "$baseUrl/$($message.messageId)"
    if ($result.status -eq 'Acknowledged') { break }
    Start-Sleep -Seconds 1
}
$result
docker compose logs --tail 30 api bridge simulator
docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group robotics-fleet-receipts
```

The API hosts the `robotics-fleet-receipts` consumer. It starts at the earliest available offset when the group has none and commits explicitly after a successful SQL update, a confirmed duplicate, or a confirmed unmatched receipt. If SQL processing or offset commit fails, the consumer halts while HTTP remains available. Malformed records also halt the consumer with the offset uncommitted pending an approved disposition. Resolve the failure before restarting the API. A successful SQL write followed by an unconfirmed commit can cause redelivery. The conditional update preserves the first receipt timestamp.

Run the isolated acceptance suite with PowerShell 7.5 or later. It exercises the round trip, duplicates, unmatched receipts, a SQL outage and recovery, and a mismatched Kafka key. Its Compose volumes are retained.

```powershell
pwsh -NoProfile -File ./tests/lab8-receipts.ps1
```

## Lab 9 — Liveness and readiness

| URL | Meaning |
| --- | --- |
| `http://127.0.0.1:8080/health/live` | The HTTP process can respond. |
| `http://127.0.0.1:8080/health/ready` | MSSQL accepts a connection and the receipt consumer is operational. |

Both endpoints return plain text. A healthy probe returns HTTP `200` with `Healthy`. An unhealthy readiness probe returns HTTP `503` with `Unhealthy`. The SQL connection probe has a two-second timeout. The consumer reports Kafka statistics every two seconds. Readiness requires an active partition assignment, a connected broker, and statistics observed within ten seconds. An idle topic still produces these statistics.

Run the isolated failure checks from the repository root. The script retains its Docker volumes.

```powershell
pwsh -NoProfile -File ./tests/lab8-receipts.ps1 -CheckHealth
```

To see the liveness and readiness split manually on your development stack, provision both Kafka topics and start the services as shown in Lab 8. Allow the consumer to join its group, and keep receipt traffic idle for this exercise.

```powershell
curl.exe -i http://127.0.0.1:8080/health/live
curl.exe -i http://127.0.0.1:8080/health/ready
docker compose stop mssql
curl.exe -i http://127.0.0.1:8080/health/live
curl.exe -i http://127.0.0.1:8080/health/ready
docker compose up --wait mssql
curl.exe -i http://127.0.0.1:8080/health/ready
```

SQL restoration recovers readiness if the worker stayed operational. If a receipt encountered a SQL error, the worker halts and readiness stays unhealthy. Check `docker compose logs --tail 50 api`, resolve the failure, and run `docker compose restart api` to resume at the outstanding offset. A malformed receipt remains pending a disposition decision and will halt the worker again after restart.

The HTTP probes expose readiness separately from Docker container status. The API runtime image has neither curl nor wget, so the probes run from the host without adding an in-container dependency. Docker Compose health status alone provides no automatic restart or application recovery. Readiness reflects recent consumer observations and SQL connectivity. It can take a few seconds to reflect a broker disconnect. Kafka lag, simulator availability, and receipt delivery are outside the readiness check.

## Lab 10 — Metrics and dashboard

The API publishes OpenTelemetry metrics from `System.Diagnostics.Metrics`. Prometheus scrapes the API and Kafka exporter every five seconds over the Compose network. Grafana loads its Prometheus datasource and Robotics Fleet Operations dashboard from the files under `monitoring/grafana`. Prometheus and Grafana store data in named Docker volumes.

Run the Lab 8 startup commands first, then start monitoring.

```powershell
docker compose --profile monitoring up -d prometheus grafana kafka-exporter
```

| Local URL | Use |
| --- | --- |
| http://127.0.0.1:8080/metrics | API exposition text |
| http://127.0.0.1:9090/targets | Prometheus target status |
| http://127.0.0.1:3000/d/robotics-fleet | Provisioned dashboard with anonymous Viewer access |
| http://127.0.0.1:8080/health/ready | Actual readiness |

The published ports bind to loopback. The Kafka exporter uses the existing internal plaintext broker listener at `kafka:29092` with topic and group filters. Its metrics port is internal.

| Exported metric | Meaning |
| --- | --- |
| `robotics_receipts_processed_total` | Committed receipts by `outcome` with values `acknowledged`, `duplicate`, and `unmatched`. |
| `robotics_receipts_failures_total` | Terminal processing failures by stage under `reason` with values `invalid_receipt`, `database_error`, `kafka_commit_error`, and `unexpected_error`. |
| `robotics_receipt_processing_duration_seconds_bucket`, `_sum`, `_count` | Histogram for successful receipts. Elapsed monotonic time spans validation, SQL persistence or lookup, and Kafka offset commit. Kafka polling and failed attempts are outside this measurement. |
| `robotics_consumer_last_success_timestamp_seconds` | Unix timestamp of the latest successful commit in this process. Zero means no success since startup. |
| `kafka_consumergroup_lag` | Per-partition Kafka log-end offset minus the group's committed offset. The dashboard excludes negative values used for unknown lag. |
| `up{job="robotics-api"}` | Availability of the API metrics scrape. Readiness comes from the separate HTTP endpoint and has no dashboard panel. |

```promql
sum(rate(robotics_receipts_processed_total[5m]))
sum by (outcome) (increase(robotics_receipts_processed_total[5m]))
sum by (reason) (increase(robotics_receipts_failures_total[5m]))
histogram_quantile(0.95, sum by (le) (rate(robotics_receipt_processing_duration_seconds_bucket[5m])))
time() - (robotics_consumer_last_success_timestamp_seconds > 0)
sum(kafka_consumergroup_lag{consumergroup="robotics-fleet-receipts",topic="robot.events"} >= 0)
up{job="robotics-api"}
```

Use the isolated test to inject an MSSQL outage, queue receipts, verify backlog growth, restore MSSQL, and restart the API. The same test injects a mismatched key to exercise validation failure. The script preserves volumes. On the development stack, inspect the group directly if the exporter is unavailable.

```powershell
pwsh -NoProfile -File ./tests/lab8-receipts.ps1 -CheckHealth -CheckMonitoring
docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group robotics-fleet-receipts
```

See Lab 9 for manual SQL fault recovery. The ASP.NET Core Prometheus exporter is pinned to a prerelease. Application counters and the last-success gauge reset with the API process. Label series appear when first recorded, and rates and P95 need multiple scrapes and recent observations. Lag depends on broker reachability and an existing committed group offset.

## Lab 11 — Alerting and incident response

Start the existing Lab 8 stack, then run `docker compose --profile monitoring up -d prometheus grafana kafka-exporter alertmanager`. Prometheus evaluates rules every five seconds. View rules at [Prometheus Alerts](http://127.0.0.1:9090/alerts) and active alert groups at [Alertmanager](http://127.0.0.1:9093). Alertmanager groups by service, waits five seconds for the initial group, checks group changes every ten seconds, and repeats eligible notifications every four hours. The local receiver keeps alerts available in the UI and API without sending external notifications.

Run these checks to distinguish an HTTP process outage, a readiness failure, and a broken scrape path.

```powershell
docker compose ps
curl.exe -i http://127.0.0.1:8080/health/live
curl.exe -i http://127.0.0.1:8080/health/ready
curl.exe -i http://127.0.0.1:8080/metrics
Invoke-RestMethod http://127.0.0.1:9090/api/v1/targets
Invoke-RestMethod http://127.0.0.1:9090/api/v1/alerts
Invoke-RestMethod http://127.0.0.1:9093/api/v2/alerts/groups
```

### RoboticsApiMetricsDown

**Critical.** The API scrape reports `up == 0` for 30 seconds. The API may be stopped or the metrics route or Compose network may be unreachable. Check the Prometheus target's last error and compare it with the direct HTTP checks above. Use `docker compose logs --tail 50 api prometheus` to investigate. Start a stopped API with `docker compose up -d api` or fix the route or network if HTTP otherwise responds. Verify that `/metrics` returns 200, the target returns to UP, and the alert clears. This alert measures the scrape path.

### RoboticsReceiptLagHigh

**Warning.** At least one `robot.events` partition has positive lag for the `robotics-fleet-receipts` group for 60 seconds while the exporter is reachable. Slow SQL, a halted consumer, or a burst of receipts can cause it. Compare Kafka's committed and log-end offsets and inspect the consumer logs.

```powershell
docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:29092 --describe --group robotics-fleet-receipts
docker compose logs --tail 50 api mssql kafka-exporter
```

Restore dependencies and restart a halted worker after resolving the error. Verify that the committed offset advances, lag returns to zero, and Prometheus clears the alert. Lag measures Kafka backlog and can be zero when the return path produces no receipts.

### RoboticsReceiptConsumerUnavailable

**Critical.** The API exposes its existing consumer health decision as `robotics_receipt_consumer_available` with values 1 and 0. An observed 0 for 15 seconds with a successful scrape triggers the alert. Starting, stopped, faulted, disconnected, unassigned, and stale-statistics states all report 0. Check `/health/live`, `/health/ready`, `docker compose logs --tail 50 api`, and the Kafka group command above. If SQL faulted the worker, restore SQL first with `docker compose up --wait mssql`, then `docker compose restart api`. For malformed receipts, obtain an approved disposition before restarting because the same record will be read again. Verify the gauge returns to 1, readiness returns 200 with SQL available, and the group resumes. Readiness can also fail independently because SQL is unavailable.

### RoboticsTelemetryMissing

**Warning.** A missing API target or missing consumer gauge on a successful scrape, or an absent/unreachable Kafka exporter or missing usable lag on a successful exporter scrape, persists for 60 seconds. Check the alert's `signal` label, Prometheus target errors, and `docker compose logs --tail 50 prometheus kafka-exporter`. Restore the target or exporter with `docker compose --profile monitoring up -d prometheus kafka-exporter` and verify the expected series returns and the alert clears. A new group has no committed offset before its first receipt, so lag is unknown until that commit. Verify the group directly with the Kafka CLI. A stopped Prometheus cannot evaluate any of these rules.

Run the isolated failure and recovery exercise. It records raw alert snapshots, timestamps, offsets, and HTTP outcomes in `TestResults` and preserves Docker volumes.

```powershell
pwsh -NoProfile -File ./tests/lab8-receipts.ps1 -CheckAlerting
```

## Lab 12 — API scrape SLO and error budget

The [Robotics API Scrape SLO dashboard](http://127.0.0.1:3000/d/robotics-api-scrape-slo) is provisioned alongside the operations dashboard. Start the monitoring profile as shown in Lab 11. The objective is 99% successful Prometheus scrapes of the API's `/metrics` endpoint over a rolling seven days, with a 1% error budget. A successful scrape says Prometheus could collect metrics at that moment. User requests and receipt processing have separate signals.

### PromQL

The dashboard uses these expressions. All percentages are represented as fractions in Prometheus.

```promql
# Latest scrape result. The -1 sentinel means the target is missing.
up{job="robotics-api"} or on() vector(-1)

# Observed coverage and its status. 120960 is seven days at one scrape per five seconds.
(count_over_time(up{job="robotics-api"}[7d]) and on(job, instance) up{job="robotics-api"}) / 120960
((count_over_time(up{job="robotics-api"}[7d]) and on(job, instance) up{job="robotics-api"}) >= bool 120960) or on() vector(-1)

# SLO target.
vector(0.99)

# Observed rolling SLI, also used as a range query for history.
(avg_over_time(up{job="robotics-api"}[7d]) and on(job, instance) up{job="robotics-api"})

# Observed budget consumed and remaining.
(1 - (avg_over_time(up{job="robotics-api"}[7d]) and on(job, instance) up{job="robotics-api"})) / 0.01
1 - (1 - (avg_over_time(up{job="robotics-api"}[7d]) and on(job, instance) up{job="robotics-api"})) / 0.01
```

An observed `up=0` counts as a failure. A missing sample contributes neither success nor failure and lowers coverage. The target match prevents old samples alone from producing a current SLI for a missing target. Coverage status shows **Insufficient history** until the expected count is reached. Until then, the observed ratio and budget are provisional, even if every recorded scrape succeeded. If the target or data is absent, the status is **Unknown** and there is no ratio or budget value. A Prometheus outage prevents live queries. After recovery, the missing collection period reduces coverage. Coverage is a sample-count estimate for this single-target, fixed-interval Compose setup. Short scheduling shifts near the window boundary can affect it. If the scrape interval changes, update the expected count. Budget consumption can exceed 100% and remaining budget can go below zero.

### Verify degradation and recovery

Use the isolated suite to provision both dashboards, check the exact dashboard PromQL, exercise a scrape outage, and rerun Lab 8–11 checks. It preserves volumes and saves evidence under `TestResults`.

```powershell
pwsh -NoProfile -File ./tests/lab8-receipts.ps1 -CheckSlo
```

For a manual exercise on a disposable development stack, open the SLO dashboard and wait for successful scrapes. Stop only the API and allow Prometheus to record several failed scrapes. Leave Prometheus running so the outage is observed.

```powershell
docker compose stop api
Start-Sleep -Seconds 15
docker compose up -d api
```

During the stop, scrape status changes to **Scrape failed**, observed success drops, and observed budget consumption rises. After restart, wait for **Scrape succeeded**. The rolling ratio and budget retain the recorded failures until they age out of the window.

## Lab 13 — Command submission traces

A trace groups the timed operations for a command submission. Each span records one operation and its parent. ASP.NET Core reads the incoming W3C `traceparent` header and creates the server span for `POST /api/messages`. The `RoboticsFleet.Api.Commands` ActivitySource adds two child spans in sequence, `INSERT Messages` and `publish robot.commands`. Both use the same trace ID and refer to the HTTP span as their parent.

The `robotics-api` tracing provider exports spans over OTLP HTTP to `http://jaeger:4318/v1/traces` inside Compose. Jaeger receives, stores and displays traces. The `monitoring` profile starts Jaeger and publishes its UI at `http://127.0.0.1:16686`. Set `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` to an empty value in the Compose `.env` to disable export when running without Jaeger. The existing Prometheus metrics remain available independently.

Run the isolated acceptance suite to verify successful and failed traces and rerun Labs 8–12. It saves raw Jaeger records under `TestResults` and preserves named Docker volumes.

```powershell
pwsh -NoProfile -File ./tests/lab8-receipts.ps1 -CheckTracing
```

On a running development stack with the database migrated, start the API and Jaeger, then submit a command with a known trace ID.

```powershell
docker compose --profile monitoring up -d --build api jaeger
$traceId = [guid]::NewGuid().ToString('N')
$parentId = [guid]::NewGuid().ToString('N').Substring(0, 16)
Invoke-WebRequest http://127.0.0.1:8080/api/messages -Method Post `
    -ContentType application/json -Body '{"content":"Lab 13 trace verification"}' `
    -Headers @{ traceparent = "00-$traceId-$parentId-01" }
"http://127.0.0.1:16686/trace/$traceId"
```

Allow a few seconds for batching before opening the printed URL. You can also search for service `robotics-api` in Jaeger. In a disposable stack, stop Kafka with `docker compose stop kafka`, rerun the request with fresh trace and parent IDs, and include `-SkipHttpErrorCheck` on `Invoke-WebRequest` to inspect the 503 response. Expand `publish robot.commands` in Jaeger to inspect its Error status and `exception.type` event. The SQL span should show that persistence completed. Restore the broker with `docker compose up --wait kafka`. The failed publication can leave a Pending row, as in the existing command flow.

Traces use in-memory Jaeger storage and disappear when Jaeger restarts. The application spans include operation names, outcomes and exception types. Payloads, SQL connection details, exception messages and stack traces are excluded. The trace ends at the producer delivery result. Kafka consumers, Python Bridge, ROS2 and receipt processing have no trace propagation in this lab.
