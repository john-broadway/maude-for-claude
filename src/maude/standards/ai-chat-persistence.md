---
title: AI Chat + Feedback Persistence
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-29
status: MANDATORY
depends:
  - fab-pattern.md
---

# AI Chat + Feedback Persistence

## Purpose

Every app with the FAB pattern (see `fab-pattern.md`) MUST persist AI chat
conversations and user feedback to **both** PostgreSQL and JSONL flat files.
Implements Art. III Sec. 1 (immutable audit trail) and Art. VI Sec. 3
(transaction integrity).

- **PostgreSQL** — queryable, auditable, immutable append-only tables
- **JSONL** — training data for model fine-tuning via Maude's training pipeline

This dual-write MUST be implemented. Browser sessionStorage is ephemeral and
JSONL-only is not queryable. Both tiers serve distinct purposes.

## Reference Implementation

| App | Commit | Files |
|-----|--------|-------|
| Lab-service | `50be66a` | `sql/migrations/040_ai_chat_feedback.sql`, `src/lab_service/shared/services/chat_log.py` |

## Schema

### `ai_chat_messages` (TimescaleDB hypertable, immutable)

```sql
CREATE TABLE ai_chat_messages (
    time             TIMESTAMPTZ     NOT NULL,
    id               BIGSERIAL,
    user_id          INTEGER         NOT NULL,
    session_id       VARCHAR(100)    NOT NULL,
    role             VARCHAR(20)     NOT NULL CHECK (role IN ('user', 'assistant')),
    message_text     TEXT            NOT NULL,
    context_label    TEXT,
    sources          JSONB           DEFAULT '[]',
    response_time_ms INTEGER
);

SELECT create_hypertable('ai_chat_messages', 'time', if_not_exists => TRUE);

CREATE INDEX idx_ai_chat_user_time    ON ai_chat_messages (user_id, time DESC);
CREATE INDEX idx_ai_chat_session_time ON ai_chat_messages (session_id, time ASC);

REVOKE UPDATE, DELETE ON ai_chat_messages FROM {app_role};
GRANT SELECT, INSERT ON ai_chat_messages TO {app_role};
GRANT USAGE, SELECT ON SEQUENCE ai_chat_messages_id_seq TO {app_role};
```

**Columns:**

| Column | Purpose |
|--------|---------|
| `time` | Hypertable partition key — `datetime.now(UTC)` at insert |
| `session_id` | Groups a Q+A pair — `uuid.uuid4().hex[:16]` per request |
| `role` | `'user'` or `'assistant'` |
| `message_text` | The question (user) or answer (assistant) |
| `context_label` | Page context, e.g. "Bath: Acid Copper", "Sales Order: SO-0042" |
| `sources` | RAG source documents (assistant only) — pass as Python list, never `json.dumps()` |
| `response_time_ms` | vLLM/LLM latency in milliseconds (assistant only) |

### `feedback` (regular table, immutable)

```sql
CREATE TABLE feedback (
    id          BIGSERIAL       PRIMARY KEY,
    user_id     INTEGER         NOT NULL,
    category    TEXT            NOT NULL CHECK (category IN ('idea', 'bug', 'request')),
    message     TEXT            NOT NULL,
    page_url    TEXT,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_feedback_created          ON feedback (created_at DESC);
CREATE INDEX idx_feedback_category_created ON feedback (category, created_at DESC);

REVOKE UPDATE, DELETE ON feedback FROM {app_role};
GRANT SELECT, INSERT ON feedback TO {app_role};
GRANT USAGE, SELECT ON SEQUENCE feedback_id_seq TO {app_role};
```

Replace `{app_role}` with the app's database role (e.g. `lab_service`, `ehs_service`, `erp_service`).

## Service Pattern

Create a `ChatLogService` (or equivalent) that dual-writes to DB and JSONL.

```python
class ChatLogService:
    def __init__(self, db, data_dir: Path = Path("/opt/{app}/data")):
        self._db = db
        self._chat_file = data_dir / "chat.jsonl"
        self._feedback_file = data_dir / "feedback.jsonl"
```

### `log_chat_pair()`

Called via `asyncio.create_task()` (fire-and-forget) after the RAG response.

**DB:** INSERT two rows (user + assistant) in a single statement.

**JSONL:** Append one line in ChatML format:

```json
{
    "messages": [
        {"role": "system", "content": "{app-specific system prompt}"},
        {"role": "user", "content": "{question, with optional context prefix}"},
        {"role": "assistant", "content": "{answer}"}
    ],
    "metadata": {
        "source": "{app}_ai_chat",
        "user_id": 12,
        "display_name": "John Broadway",
        "session_id": "a1b2c3d4e5f67890",
        "context_label": "Bath: Acid Copper",
        "response_time_ms": 1234,
        "sources": [],
        "timestamp": "2026-03-17T07:05:06.816376+00:00"
    }
}
```

This format is compatible with Maude's `export-training-data.py` and fine-tuning
scripts. The `metadata.source` field distinguishes app-origin data in merged
training sets.

### `log_feedback()`

Called with `await` (not fire-and-forget) so the user gets a real error on failure.

**DB:** INSERT one row into `feedback`.

**JSONL:** Append one line:

```json
{
    "time": "2026-03-17T07:05:06+00:00",
    "user": "John Broadway",
    "role": "admin",
    "category": "request",
    "message": "...",
    "page_url": "/dashboard"
}
```

## Route Wiring

### AI Chat Route (`POST /api/ai/ask`)

```python
t0 = time.monotonic()
result = await rag.ask(query)
response_time_ms = int((time.monotonic() - t0) * 1000)

chat_log_svc = getattr(request.app.state, "chat_log_svc", None)
if chat_log_svc is not None:
    session_id = uuid.uuid4().hex[:16]
    asyncio.create_task(chat_log_svc.log_chat_pair(
        user_id=user_id,
        session_id=session_id,
        question=body.question,
        answer=result.get("answer", ""),
        display_name=user.display_name,
        context_label=body.context_label,
        sources=result.get("sources"),
        response_time_ms=response_time_ms,
    ))
```

Key points:
- `session_id` generated server-side per request (links Q+A pair)
- `time.monotonic()` for response timing (not wall clock)
- Fire-and-forget via `asyncio.create_task()` — never block the HTTP response
- Graceful fallback: `getattr(..., None)` so the route works without the service

### Feedback Route (`POST /api/feedback`)

```python
await chat_log_svc.log_feedback(
    user_id=user.user_id,
    category=body.category,
    message=body.message,
    display_name=user.display_name,
    role=user.role,
    page_url=body.page_url,
)
```

Key points:
- `await` (not fire-and-forget) — user expects confirmation
- Frontend must send `page_url: window.location.pathname` in the POST body

## Frontend Changes

Add `page_url` to the feedback POST body:

```javascript
body: JSON.stringify({
    message: text,
    category: fbCategory,
    page_url: window.location.pathname
})
```

### Patience Messages

For long LLM responses, show rotating status text below the thinking dots
every 15 seconds:

```javascript
var patienceMessages = ['Still thinking...', 'Almost there...',
    'Searching docs...', 'Generating answer...'];
var patienceIdx = 0;
var patienceTimer = setInterval(function() {
    // update status text below dots
    patienceIdx++;
}, 15000);
```

Clear the timer in both `.then()` and `.catch()` handlers.

CSS for the status text:

```css
.maude-thinking-status {
    width: 100%;
    font-size: 0.75rem;
    color: var(--text-muted);
    margin-top: 0.25rem;
    animation: maude-fade-in 0.4s ease;
}
```

## JSONL File Locations

Each app writes to its own data directory:

| App | Chat JSONL | Feedback JSONL |
|-----|-----------|----------------|
| Lab-service | `/opt/lab-service/data/chat.jsonl` | `/opt/lab-service/data/feedback.jsonl` |
| EHS-service | `/opt/ehs-service/data/chat.jsonl` | `/opt/ehs-service/data/feedback.jsonl` |
| ERP | `/opt/erp/data/chat.jsonl` | `/opt/erp/data/feedback.jsonl` |

The training pipeline collects from all apps. Each line's `metadata.source`
field identifies the originating app.

## Gotchas

- **asyncpg JSONB:** Pass Python dicts/lists directly — never `json.dumps()` before passing to JSONB params (double-encoding)
- **Immutable tables:** Both tables REVOKE UPDATE/DELETE — use supersede patterns if corrections are needed
- **File permissions:** The app user must have write access to the data directory
- **Frappe apps:** Use `frappe.db.sql()` instead of asyncpg, and `frappe.enqueue()` instead of `asyncio.create_task()` for fire-and-forget

## Maude Training Pipeline Integration

The JSONL files are consumed by:
- `maude/scripts/export-training-data.py` — CLI export tool
- `maude/runtime/training_loop.py` — automated training pipeline
- `maude/runtime/training_export.py` — conversion to ChatML format

The ChatML format (`{"messages": [...]}`) is already the target format, so
no conversion is needed. The training pipeline can `cat` all `chat.jsonl`
files across apps into a single training set.

## Do Not

- MUST NOT store chat in sessionStorage only — it's lost on tab close
- MUST NOT store feedback in JSONL only — it's not queryable
- MUST NOT skip the JSONL write — the training pipeline depends on it
- MUST NOT use `json.dumps()` on JSONB params — asyncpg handles serialization
- MUST NOT block the HTTP response on chat logging — use fire-and-forget
- MUST NOT skip `page_url` in feedback — it's needed for usage analytics
