# Robotics Fleet Operations Platform Communication Contract v1.0

**Status — Partially approved.** The approved contract choices are the HTTP routes, UUID v4, Kafka keys and payloads, ROS 2 String message type and initial QoS, `Pending` and `Acknowledged` states, and the C# hosted background consumer and its receipt offset rules. Other design choices remain proposed.

Source documents are [AGENTS.md](../AGENTS.md), [Architecture v1.1](architecture_v1.1.md), [Requirements v1.0](requirements_v1.0.md), and [Codex Handoff](robotics_fleet_codex_handoff.md).

## 1. HTTP API — Approved routes, proposed request and response details

### POST `/api/messages`

Accept an `application/json` object with a required `content` string containing at least one non-whitespace character. The API generates `messageId` and preserves the submitted content.

```json
{
  "content": "Hello ROS 2"
}
```

Return `201 Created` after the MSSQL insert and a successful Kafka producer acknowledgement for `robot.commands`. Include `Location: /api/messages/550e8400-e29b-41d4-a716-446655440000`. The body describes the initial record and may still show `Pending` if the receipt is already being processed. Use GET to read the current state. [HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.2)

```json
{
  "messageId": "550e8400-e29b-41d4-a716-446655440000",
  "content": "Hello ROS 2",
  "status": "Pending",
  "createdAt": "2026-11-10T02:00:00Z",
  "receivedAt": null
}
```

### GET `/api/messages/{messageId}`

Return `200 OK` with the current MSSQL record in the same shape as the POST response. `receivedAt` is null while the record is `Pending`. The following example shows the record after the C# consumer persists the simulator receipt.

```json
{
  "messageId": "550e8400-e29b-41d4-a716-446655440000",
  "content": "Hello ROS 2",
  "status": "Acknowledged",
  "createdAt": "2026-11-10T02:00:00Z",
  "receivedAt": "2026-11-10T02:00:02Z"
}
```

### HTTP status codes

| Code | Applies to | Condition |
| --- | --- | --- |
| `201 Created` | POST | Record persisted and Kafka acknowledged the command publication. |
| `200 OK` | GET | Matching record found, regardless of its receipt status. |
| `400 Bad Request` | POST, GET | Malformed JSON, missing or invalid `content`, or a `messageId` path value outside the approved format. |
| `404 Not Found` | GET | The ID is well formed and no matching record exists. |
| `415 Unsupported Media Type` | POST | A request with a body uses an unsupported content type. |
| `503 Service Unavailable` | POST, GET | A required dependency is temporarily unavailable. GET requires MSSQL. POST requires MSSQL and Kafka. |
| `500 Internal Server Error` | POST, GET | Unexpected server failure. |

## 2. Kafka — Approved payloads and key

Use one API-generated UUID v4 per command. Serialize `messageId` as lowercase, hyphenated UUID text (`8-4-4-4-12`) across HTTP, Kafka, and ROS 2. On both Kafka topics, the record key is the UTF-8 encoding of that same text, with no JSON quotes. The UTF-8 JSON record value also carries `messageId`. The key aids correlation and partition selection within a topic. Matching keys carry no ordering guarantee across topics. Timestamps are UTC RFC 3339 strings ending in `Z`. [Apache Kafka producer configuration](https://kafka.apache.org/42/configuration/producer-configs/)

### `robot.commands`

The C# API produces this record and the Python Bridge consumes it. `createdAt` is the API creation timestamp stored in MSSQL.

```json
{
  "messageId": "550e8400-e29b-41d4-a716-446655440000",
  "type": "PING",
  "content": "Hello ROS 2",
  "createdAt": "2026-11-10T02:00:00Z"
}
```

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["messageId", "type", "content", "createdAt"],
  "properties": {
    "messageId": {"type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},
    "type": {"const": "PING"},
    "content": {"type": "string", "pattern": "\\S"},
    "createdAt": {"type": "string", "format": "date-time", "pattern": "Z$"}
  }
}
```

### `robot.events`

The Python Bridge produces this record and the C# background consumer consumes it. `receivedAt` is when the simulator received the command. The Bridge preserves that timestamp.

```json
{
  "messageId": "550e8400-e29b-41d4-a716-446655440000",
  "type": "RECEIVED",
  "source": "ros2-simulator",
  "receivedAt": "2026-11-10T02:00:02Z"
}
```

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["messageId", "type", "source", "receivedAt"],
  "properties": {
    "messageId": {"type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},
    "type": {"const": "RECEIVED"},
    "source": {"const": "ros2-simulator"},
    "receivedAt": {"type": "string", "format": "date-time", "pattern": "Z$"}
  }
}
```

These schema examples describe the payloads for review and local tests.

## 3. ROS 2 — Approved topics, message type, and initial QoS

Use `example_interfaces/msg/String` for both topics in the demo. Its `data` field contains one serialized JSON object. Reuse the Kafka payload shapes so the Bridge can preserve fields through each translation. [ROS 2 Jazzy String interface](https://github.com/ros2/example_interfaces/blob/jazzy/msg/String.msg)

| Topic | Publisher → Subscriber | JSON object inside `data` |
| --- | --- | --- |
| `/demo/commands` | Python Bridge → ROS 2 Jazzy simulator | `messageId`, `type` (`PING`), `content`, `createdAt` |
| `/demo/receipts` | ROS 2 Jazzy simulator → Python Bridge | `messageId`, `type` (`RECEIVED`), `source` (`ros2-simulator`), `receivedAt` |

**Initial QoS.** Use matching reliable, volatile, keep-last depth 10 profiles for both topic pairs. Start subscribers and verify discovery before sending a demo command. [ROS 2 Jazzy QoS settings](https://github.com/ros2/ros2_documentation/blob/jazzy/source/Concepts/Intermediate/About-Quality-of-Service-Settings.rst)

## 4. Message Flow

The component sequence, correlation, status names, and C# consumer offset rules are approved. API partial-failure handling remains proposed.

1. The API assigns `messageId` and inserts a `Pending` record in MSSQL. It then publishes the command to `robot.commands` with the same ID in the key and payload.
2. The Bridge reads the command and publishes it on `/demo/commands`. When the simulator receives the command, it emits a `/demo/receipts` message with the same ID and its receipt timestamp.
3. The Bridge forwards the receipt to `robot.events`. The C# consumer matches the MSSQL record by `messageId` and persists `Acknowledged` and `receivedAt`. GET reads that record.

| Signal | What it establishes |
| --- | --- |
| Kafka producer ACK | The broker acknowledged the publication according to producer settings. This is evidence about the Kafka write. |
| ROS 2 receipt | The simulator received the command and emitted an application-level response. DDS QoS governs transport. |
| GET returns `Acknowledged` | The C# consumer persisted the simulator receipt for the matching MSSQL record. |

### Kafka offset commit

The Python Bridge commits the `robot.commands` offset after ROS 2 `publish()` returns successfully. This commit records completion of the local publisher handoff. The ROS 2 subscriber may still have yet to receive or process the message. Verify end-to-end success by observing the simulator receipt and confirming that MSSQL contains `Acknowledged` for the same `messageId`.

### C# consumer offset rules

The hosted C# consumer applies these rules to receipt records on `robot.events`. The [approved receipt handling](data_model_v1.0.md#4-receipt-handling--approved) defines the MSSQL outcomes.

| Receipt outcome | Offset rule |
| --- | --- |
| MSSQL update succeeds | Commit the offset after MSSQL persists the `Pending` → `Acknowledged` transition and receipt timestamp. |
| Duplicate receipt | Commit after confirming the matching record is already `Acknowledged`. Preserve the first persisted receipt timestamp. |
| Unmatched receipt | Commit after confirming the ID is absent and logging a `Warning` with the `messageId`. Leave the table untouched. |
| MSSQL update fails | Leave the offset uncommitted and surface the failure. Do not advance the partition's committed offset past the failed record. A failed lookup cannot confirm a duplicate or an unmatched receipt. |

### Known limitation — MSSQL insert and Kafka publish

If the MSSQL insert succeeds but Kafka publication fails or its outcome is unknown, the API may return an error and the row may remain `Pending`. When the publish outcome is unknown, Kafka may already contain the command even though the API returned an error. `Pending` means no receipt has been persisted. Transactional outbox, advanced retries, and exactly-once delivery are outside the MVP.

**Proposed partial-failure handling.** Return an error and log the `messageId` and failed step. Repeating POST creates a new command and a new ID.

### Verification after implementation

- **Week 1.** POST one command and capture `messageId` from the response. Compare the MSSQL row with a `robot.commands` consumer record, including its key. Both must correspond to that request.
- **Week 2.** Run `ros2 topic echo /demo/commands` and `ros2 topic echo /demo/receipts` before sending the command. Compare their `data` payloads and the `robot.events` consumer output with the POST ID. Query the response `Location` and confirm `Acknowledged` and the same `receivedAt` stored in MSSQL.

## 5. Open Decisions

| Decision | Options and trade-offs | Proposed minimum viable choice |
| --- | --- | --- |
| HTTP response and validation rules | `201` describes creation of a queryable record. `202` emphasizes asynchronous processing and still needs a clear status lookup. | Use `201` with `Location`. Confirm the validation and error rules before implementation. |
| Consumer processing mechanics | Sequential processing simplifies tracking which records can be committed. A completed operation can still be redelivered if its offset commit fails. | Process sequentially per partition and surface a failed Bridge handoff before advancing that partition. Follow the documented [Bridge commit point](#kafka-offset-commit) and [C# consumer offset rules](#c-consumer-offset-rules). [Apache Kafka consumer configuration](https://kafka.apache.org/42/configuration/consumer-configs/#enable.auto.commit) |

PLC, physical hardware, navigation, and fleet scheduling are outside the contract scope. Advanced retries, transactional outbox, exactly-once delivery, and complex idempotency are outside the MVP contract.
