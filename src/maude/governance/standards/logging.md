---
title: Logging Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Logging Standard

## Purpose

Consistent, structured logging across all Maude services for operational
observability. Logs are useful for debugging, alerting, and compliance — without
leaking secrets or drowning operators in noise.

## Rules

1. **Two logging channels.** Every service MUST maintain both:
   - **Application logs** — operational events to stdout or a log aggregation
     pipeline. Records lifecycle events, errors, and operational state.
   - **Audit logs** — structured records of every significant operation. Records
     what was done, by whom, with what inputs, and whether it succeeded.

2. **No print statements.** Application code MUST NOT use `print()` for
   operational output. Use `logging.getLogger(__name__)` instead.

3. **Log levels.** All services MUST follow these level definitions:

   | Level | Meaning | Example |
   |-------|---------|---------|
   | DEBUG | Development tracing, verbose | `Parsed 47 tags from PLC response` |
   | INFO | Normal operations | `Scheduled health check completed, status=healthy` |
   | WARNING | Degraded but functional | `PLC response latency 4.2s (threshold 3.0s)` |
   | ERROR | Action needed | `Connection to InfluxDB lost, retrying in 30s` |
   | CRITICAL | Service down or data loss risk | `Cannot reach PostgreSQL after 5 retries, shutting down` |

   Production log level SHOULD be INFO. DEBUG MUST NOT be enabled in production
   without explicit operator action.

4. **What to log:**
   - Operations and their outcomes
   - Service lifecycle events (started, stopped, config loaded)
   - Scheduled task execution and results
   - Errors with enough context to diagnose (operation name, input summary, error type)
   - Configuration changes and reloads
   - Connection state changes (connected, reconnected, lost)

5. **What NOT to log:**
   - Credentials, tokens, API keys, or database passwords
   - PII: Social Security numbers, personal email addresses, home addresses
   - Full request/response bodies (log summaries or record counts instead)
   - Health check successes at high frequency (one log per 10+ checks is sufficient)
   - Routine metric scrapes or heartbeats

6. **Structured format.** Application logs SHOULD use key=value pairs for fields
   that log queries will filter on:
   ```
   tool=disk_usage duration_ms=42 status=ok total_gb=450
   ```

7. **Audit completeness.** Every significant operation MUST produce an audit
   record. Audit middleware handles this automatically where available; custom
   operations MUST NOT bypass the audit pipeline.

## Examples

### Good INFO log entry

```python
logger.info(
    "Scheduled collection completed count=%d duration_ms=%d plc=%s",
    tag_count, elapsed_ms, plc_name
)
# Output: INFO Scheduled collection completed count=128 duration_ms=340 plc=plating-main
```

### Good ERROR log entry with context

```python
logger.error(
    "Operation failed op=%s error=%s input_summary=%s",
    "backup_status", "ConnectionRefused", "host=localhost"
)
# Output: ERROR Operation failed op=backup_status error=ConnectionRefused input_summary=host=localhost
```

### Bad log entry — credential leak

```python
# BAD: leaks the database password into logs
logger.info("Connecting to database with URL %s", database_url)
# Output: INFO Connecting to database with URL postgresql://user:s3cret@localhost/myapp

# GOOD: log the host only
logger.info("Connecting to database host=%s db=%s", db_host, db_name)
```

### Bad log entry — missing context

```python
# BAD: useless without knowing which operation or what was attempted
logger.error("Something went wrong")

# GOOD: includes operation, error class, and actionable detail
logger.error("Operation failed op=%s error=%s retry_in=%ds", op_name, type(e).__name__, backoff)
```

## Enforcement

- **Code review:** Reviewers MUST reject `print()` in application code,
  credential logging, and PII exposure. New operations MUST flow through the
  audit pipeline.
- **Alert rules:** Alerts SHOULD fire on ERROR-level log spikes and on any
  CRITICAL-level entry.
- **Constitutional basis:** The Constitution establishes credential governance
  and authorship accountability; this standard implements them for operational
  logging.
