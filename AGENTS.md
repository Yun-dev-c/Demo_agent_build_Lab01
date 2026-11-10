
AGENTS.md — Robotics Fleet Operations Platform
Mission
Build a four-week, portfolio-quality end-to-end integration demo using C# ASP.NET Core, Microsoft SQL Server, Apache Kafka, Python, and ROS2 Jazzy. Prioritize a correct, demonstrable message flow over extra features.

Source of truth
Read architecture_v1.1.md and robotics_fleet_codex_handoff.md before planning or changing implementation.
Treat the approved architecture and scope in those files as authoritative. If they conflict, describe the conflict and ask for a decision rather than guessing.
Record detailed requirements, communication contracts, data model, deployment design, roadmap, and progress in docs/ as they are approved. Do not silently supersede approved decisions.
Approved architecture
C# ASP.NET Core API accepts commands and stores records in local Microsoft SQL Server.
C# publishes commands to Kafka topic robot.commands.
Python ROS2 Bridge consumes commands and publishes ROS2 messages.
ROS2 Jazzy simulator subscribes and publishes a simple receipt/status message; no real robot movement or fleet-management logic.
Python Bridge publishes resulting events to Kafka topic robot.events.
C# consumer receives events and updates SQL Server.
Docker Compose supports local execution; GitHub Actions, GHCR, Kubernetes, Prometheus, and Grafana are planned project components.
Scope and constraints
Keep the project a minimal but working end-to-end demonstration.
No PLC integration, physical hardware dependency, navigation, scheduling, or robot control logic.
Use local/containerized SQL Server as the baseline. Azure SQL is optional, not required.
Do not introduce RabbitMQ alongside Kafka or add unrelated infrastructure.
Defer advanced retry policies, transactional outbox, complex idempotency, high availability, and other reliability extensions until explicitly approved.
Preserve basic diagnostics and meaningful test coverage; never hide failures.
Keep source code on the Windows host if desired; run application services in Linux containers. Do not require WSL-based source storage or Dev Containers.
Working agreement
Inspect repository state and read relevant specifications before modifying files.
Propose the smallest next milestone with acceptance criteria and wait for approval when scope or architecture changes are involved.
Implement only the approved milestone; prefer simple, maintainable solutions.
Run applicable checks and tests. Distinguish executed tests from unverified assumptions.
Report changed files, commands run, outcomes, unresolved issues, and next steps.
Update docs/progress.md when it exists and a milestone is validated.
Recommend a Git commit at a validated milestone; do not commit or push without user approval.
If blocked or repeated fixes fail, stop and report evidence instead of looping indefinitely.
Engineering standards
Do not commit credentials, tokens, private keys, or populated .env files.
Prefer documented, reproducible Docker-based setup and pinned dependencies where practical.
Keep API, Kafka event, and ROS2 message contracts explicit and consistent.
Distinguish transport delivery from application-level receipt/processing confirmation.
Do not claim a container, build, test, or deployment succeeded without actual execution evidence.
Keep documentation concise and updated alongside relevant changes.
AI-assisted development
AI may draft most boilerplate and implementation code.
The user owns architecture decisions, acceptance, and troubleshooting conclusions.
Explain unfamiliar integration boundaries and provide verifiable test commands.
For unfamiliar core technologies, include a minimal hands-on exercise that demonstrates the essential behavior.
