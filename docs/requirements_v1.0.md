# Robotics Fleet Operations Platform Requirements v1.0

Baseline documents are [AGENTS.md](../AGENTS.md), [Architecture v1.1](architecture_v1.1.md), and [Codex Handoff](robotics_fleet_codex_handoff.md). The milestone table incorporates the approved Week 1 and Week 3 acceptance criteria.

## 1. Project Goal

Deliver a reproducible, software-only integration demo in four weeks. A user submits a text command to a C# ASP.NET Core API and queries the same record after a ROS 2 Jazzy simulator acknowledges receipt. Local Microsoft SQL Server (MSSQL) stores application state, Apache Kafka carries commands and receipts between the C# application and the Python ROS 2 Bridge, and DDS carries messages between ROS 2 nodes.

## 2. Functional Requirements

| ID | Requirement |
| --- | --- |
| FR-01 | The API must validate a text command submitted over HTTP, assign a `messageId`, and persist the ID, payload, initial status, and timestamps in local MSSQL through EF Core. Use migrations to create the schema. |
| FR-02 | After persisting the request, the API must publish the corresponding command with the same `messageId` to Kafka topic `robot.commands`. |
| FR-03 | The Python Bridge must consume `robot.commands` and publish the command with its `messageId` to ROS 2 topic `/demo/commands`. |
| FR-04 | The ROS 2 Jazzy simulator must subscribe to `/demo/commands` and publish a receipt with the same `messageId` to `/demo/receipts` after receiving the command. |
| FR-05 | The Bridge must consume the ROS 2 receipt and publish the corresponding event with the same `messageId` to Kafka topic `robot.events`. |
| FR-06 | The C# background consumer must consume `robot.events` and update the matching MSSQL record with its receipt status and timestamp. The API must support querying by `messageId` and return the persisted ID, payload, status, and relevant timestamps. |

The final receipt status represents application-level receipt by the simulator. A Kafka producer acknowledgement or DDS delivery alone is insufficient evidence of that receipt.

## 3. Non-Functional Requirements

- **Reproducibility.** Use Docker Compose for local integration, Linux containers for application services, local MSSQL, and a single local Kafka broker in KRaft mode. Developers may keep source code on the Windows host.
- **Diagnostics.** Provide basic health checks, structured logs that make failures visible and identify the `messageId` where relevant, and basic Prometheus metrics with a Grafana dashboard.
- **Verification.** Maintain meaningful automated tests and document how to verify the message flow through API responses, database queries, topic output, logs, or test results. Distinguish transport delivery from simulated receipt in the evidence.
- **Delivery.** Use GitHub Actions for automated tests and builds, publish images to GHCR, and deploy selected services to local Kubernetes after the Docker Compose round trip is verified.
- **Secrets and dependencies.** Keep credentials, tokens, private keys, and populated `.env` files out of Git. Pin dependencies where practical.

## 4. In Scope / Out of Scope

**In scope**

- The C# API and background consumer, local MSSQL, Kafka, the Python Bridge, and ROS 2 Jazzy receipt simulation.
- Docker Compose for local integration, GitHub Actions and GHCR for delivery, selected services on local Kubernetes, and basic monitoring with Prometheus and Grafana.
- Automated tests, a README, an architecture diagram, and a repeatable demo walkthrough.

**Out of scope for the MVP**

- PLC integration, physical hardware, robot control or movement, navigation, SLAM, Gazebo, fleet orchestration or scheduling, and a custom web frontend.
- RabbitMQ, Kafka Connect, Schema Registry, multi-broker Kafka or high availability, service mesh, and required cloud services. Azure SQL remains an optional future evaluation.
- Exactly-once guarantees, advanced retries, transactional outbox, complex idempotency, and other reliability extensions. Review these at the end of the project and require explicit approval before implementation.

## 5. Must Have / Should Have

**Must Have**

- The full correlated command and receipt flow in FR-01 through FR-06, runnable locally with Docker Compose.
- The delivery, health, metrics, and documentation evidence in the four-week milestone table.
- A repeatable demo that distinguishes broker delivery from simulator receipt.

**Should Have**

- A persistent volume for containerized local MSSQL where host compatibility and resources permit.
- Automated deployment smoke checks when time and the configured deployment environment permit. The Week 3 deployment, health, and metrics checks are required regardless of how they are run.

## 6. Four-Week Milestones and Acceptance Criteria

| Week | Milestone | Acceptance evidence |
| --- | --- | --- |
| 1 | C# API, MSSQL, and Kafka baseline | Submit one HTTP request and capture its `messageId`. A SQL query or integration test must show the persisted record for that ID, and Kafka consumer output must show a command on `robot.commands` with the same ID from the same request. |
| 2 | Python Bridge and ROS 2 Jazzy round trip | Run the integrated flow locally with Docker Compose. For one `messageId`, show the command on `/demo/commands` and the receipt on `/demo/receipts` through topic output or correlated logs. Show the same ID on `robot.events` and verify the final receipt status in MSSQL and through the API. |
| 3 | CI, image publishing, Kubernetes, and monitoring | Show a successful GitHub Actions run with automated test and build results, and verify the published image tag or digest in GHCR. Use Kubernetes rollout and workload output to confirm the selected services are deployed. Show a successful health check and verify that Prometheus can query a service metric and Grafana displays basic metrics. |
| 4 | Integration tests and repeatable demo | From a clean local setup, follow the README and walkthrough to reproduce the Week 2 flow. Capture the passing end-to-end test or the API, topic, and database evidence from the run. Include an architecture diagram that matches the demonstrated flow. Record any proposed reliability work for scope review. |

## 7. Open Decisions

- Finalize HTTP routes, request and response schemas, status codes, Kafka payloads, the `messageId` representation, and the ROS 2 message type. The handoff examples are proposals for the detailed communication contract.
- Finalize the MSSQL table schema and status and timestamp definitions, including the names of the initial and receipt states.
- Decide whether the C# event consumer runs as a hosted background service or a separate process. Define Kafka offset commit behavior and document how duplicate receipts and partial failures affect the demo.
- Validate DDS discovery and networking in the local Docker/WSL environment. Use that evidence to select the Kubernetes services and decide where the Bridge and simulator run.
- Choose the CI environment, local Kubernetes deployment mechanism, and environment-specific secret injection. Define the health endpoints and basic metrics to verify in Week 3.
- At the final scope review, decide whether to approve any timeout, advanced retry, outbox, complex idempotency, or other reliability work. Consider Azure SQL only if eligibility, networking, and cost are verified.
