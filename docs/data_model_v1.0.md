# Robotics Fleet Operations Platform Data Model v1.0

**Status — Approved MSSQL storage and receipt rules.** The MVP uses one `Messages` table. The approved choices and receipt behavior are recorded below.

Source documents are [AGENTS.md](../AGENTS.md), [Architecture v1.1](architecture_v1.1.md), [Requirements v1.0](requirements_v1.0.md), [Communication Contract v1.0](communication_contract_v1.0.md), and [Codex Handoff](robotics_fleet_codex_handoff.md).

## 1. Table and EF Core mapping

**Proposed EF Core mapping.** Map one EF Core `Message` entity to `dbo.Messages`. Each row represents one submitted command and its current receipt state.

| SQL column | SQL Server type | Nullable | EF Core property and CLR type | Meaning |
| --- | --- | --- | --- | --- |
| `MessageId` | `uniqueidentifier` | No | `MessageId` · `Guid` | Primary key. The API supplies the UUID v4 before insertion. Disable EF Core key generation for this property and omit a database key default. |
| `Content` | `nvarchar(max)` | No | `Content` · `string` | Original Unicode command text. The column adds no MVP-specific length cap to the communication contract. |
| `Status` | `tinyint` | No | `Status` · `MessageStatus` enum backed by `byte` | Explicit mapping of `0` to `Pending` and `1` to `Acknowledged`. HTTP continues to use the contract's status names. |
| `CreatedAt` | `datetimeoffset(7)` | No | `CreatedAt` · `DateTimeOffset` | API-generated creation time, stored with offset `+00:00`. Use the same instant for the Kafka command. |
| `ReceivedAt` | `datetimeoffset(7)` | Yes | `ReceivedAt` · `DateTimeOffset?` | Simulator receipt time from `robot.events`, stored with offset `+00:00`. Null until a receipt is persisted. |

The API and consumer supply the values. Normalize timestamps to UTC before writing and serialize wire timestamps with `Z` as required by the contract. The SQL types and numeric status mapping are internal. HTTP, Kafka, and ROS 2 keep their existing formats. [SQL Server `uniqueidentifier`](https://learn.microsoft.com/en-us/sql/t-sql/data-types/uniqueidentifier-transact-sql) · [SQL Server `datetimeoffset`](https://learn.microsoft.com/en-us/sql/t-sql/data-types/datetimeoffset-transact-sql) · [EF Core value generation](https://learn.microsoft.com/en-us/ef/core/providers/sql-server/value-generation) · [EF Core value conversions](https://learn.microsoft.com/en-us/ef/core/modeling/value-conversions)

## 2. Keys, indexes, and integrity

- **Primary key.** Use the clustered `PK_Messages` on `MessageId`. Its unique index supports both receipt updates and status lookups. Random UUID v4 inserts can fragment the index as the table grows. No secondary indexes are needed for the MVP access paths. [EF Core SQL Server indexes](https://learn.microsoft.com/en-us/ef/core/providers/sql-server/indexes)
- **Database CHECK constraints.** One check allows only `Pending` with a null `ReceivedAt` or `Acknowledged` with a non-null `ReceivedAt`. A second check requires a zero UTC offset for `CreatedAt` and any non-null `ReceivedAt`. The API and simulator supply times from separate clocks, so the database does not enforce ordering between the two timestamps.
- **Table boundary.** The model contains no Task, Step, Outbox, or Audit tables. The command type and receipt source remain Kafka payload fields. Advanced retries and exactly-once delivery remain outside the MVP.

## 3. Data operations

| Operation | Database behavior |
| --- | --- |
| Create a message | The API inserts `MessageId`, `Content`, `Pending`, and `CreatedAt`, with `ReceivedAt` null. After the insert commits, the API publishes the corresponding command to `robot.commands`. A failed or uncertain publish can leave the row `Pending`, and Kafka may already contain the command when the outcome is uncertain. |
| Receive a simulator receipt | The C# hosted background consumer reads a valid `RECEIVED` event from `robot.events`. Match by `MessageId` and apply one conditional update to a `Pending` row. Set `Status` to `Acknowledged` and `ReceivedAt` to the simulator timestamp together. Preserve `Content` and `CreatedAt`. |
| Query status | For `GET /api/messages/{messageId}`, read the row by primary key. Use the stored ID, content, status, and timestamps to populate the existing response shape. Report a missing row through the contract's proposed `404` response. |

## 4. Receipt handling — Approved

The only receipt transition is `Pending` → `Acknowledged`, applied with one atomic update filtered by `MessageId` and `Pending`. Keep the first successfully persisted receipt timestamp even if duplicate deliveries overlap. If the update affects zero rows, look up the ID. An `Acknowledged` row confirms a duplicate and requires no write. A missing row is an unmatched receipt. Log a `Warning` with the ID and leave the table untouched. Surface database errors separately from zero-row results. See the [C# consumer offset rules](communication_contract_v1.0.md#c-consumer-offset-rules) for the resulting commit behavior. [EF Core conditional updates and affected row counts](https://learn.microsoft.com/en-us/ef/core/saving/execute-insert-update-delete#concurrency-control-and-rows-affected)

## 5. Verification after implementation

| Case | Expected evidence from a SQL query, API response, or integration test |
| --- | --- |
| One submitted command | Before receipt processing, the row for the ID read from `robot.commands` contains the original content, `Pending`, a UTC `CreatedAt`, and null `ReceivedAt`. |
| One valid simulator receipt | For the same ID, one existing row becomes `Acknowledged`. Its `ReceivedAt` matches the receipt instant, and GET returns that persisted state. |
| Duplicate or unmatched receipt | A duplicate with a different timestamp leaves the first persisted value intact. An unknown ID creates no row and produces a `Warning` containing the ID. |

## 6. Approved design decisions

| Decision | Approved MVP choice |
| --- | --- |
| Primary key | Use a clustered primary key on the API-generated UUID v4 stored as `uniqueidentifier`. |
| Content storage | Use `nvarchar(max)` to preserve Unicode without introducing a new contract limit. A bounded column would require an agreed API limit. |
| Status storage | Use `tinyint` with `0` for `Pending` and `1` for `Acknowledged`. |
| Timestamp storage | Use `datetimeoffset(7)` at `+00:00` for `CreatedAt` and any non-null `ReceivedAt`. |
| Database CHECK constraints | Enforce the allowed status and receipt timestamp combinations and UTC offsets described in [Keys, indexes, and integrity](#2-keys-indexes-and-integrity). |
