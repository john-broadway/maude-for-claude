---
title: Database Access Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Database Access Standard

## Purpose

Safe, consistent database access patterns across all Maude services. This standard
prevents SQL injection, connection exhaustion, data cross-contamination, and
unrecoverable schema drift.

## Rules

### Query Safety

1. All queries MUST use parameterized placeholders. NEVER use f-strings,
   `str.format()`, or string concatenation to build SQL.

2. Column and table names that cannot be parameterized MUST be validated
   against an allowlist before interpolation.

### Database Isolation

3. Each database serves a single domain. Services MUST NOT mix data between
   databases or issue cross-database queries.

4. Each service MUST connect to exactly one database. If a service needs data
   from multiple domains, it MUST use separate connections with separate
   credentials.

### Connection Pooling

5. Services MUST use connection pools with bounded sizing. Pools MUST be
   closed gracefully on service shutdown.

6. Services MUST NOT exceed their pool allocation without coordination with
   the database administrator.

### Transactions

7. Write operations spanning multiple statements MUST use explicit
   transactions.

8. Read-only queries SHOULD use bare fetch calls without an explicit
   transaction unless snapshot isolation is required.

### Timestamps

9. All timestamp columns MUST use `TIMESTAMPTZ` and store values in UTC.

10. Conversion to local time MUST happen only at the UI/presentation layer,
    never in the database or service layer.

### Schema Migrations

11. Migrations MUST be numbered SQL files: `001_create_tables.sql`,
    `002_add_column.sql`, etc.

12. Migrations MUST be applied in order and MUST be idempotent where possible
    (`IF NOT EXISTS`, `IF EXISTS`).

13. A database backup MUST be taken before applying any schema migration to
    production.

14. Migrations MUST NOT be modified after they have been applied. Fixes go in
    a new migration file.

## Examples

### Good: Parameterized query

```python
async def get_tank_reading(pool, tank_id: int):
    return await pool.fetchrow(
        "SELECT tank_id, temperature, ph, timestamp "
        "FROM readings WHERE tank_id = $1 "
        "ORDER BY timestamp DESC LIMIT 1",
        tank_id,
    )
```

### Bad: SQL injection risk

```python
# NEVER DO THIS
async def get_tank_reading(pool, tank_id):
    query = f"SELECT * FROM readings WHERE tank_id = {tank_id}"
    return await pool.fetchrow(query)
```

### Transaction pattern

```python
async with pool.acquire() as conn:
    async with conn.transaction():
        await conn.execute(
            "INSERT INTO bath_results (bath_id, analyte, value) VALUES ($1, $2, $3)",
            bath_id, analyte, value,
        )
        await conn.execute(
            "UPDATE baths SET last_sampled = now() WHERE id = $1",
            bath_id,
        )
```

### Migration file (`003_add_spc_limits.sql`)

```sql
-- Add SPC control limits to bath_results
-- Authors: John Broadway, Claude (Anthropic)
-- Version: 1.0.0 | Updated: 2026-02-14

ALTER TABLE bath_results
    ADD COLUMN IF NOT EXISTS ucl DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS lcl DOUBLE PRECISION;
```

## Enforcement

- **Code review:** Every change touching SQL is reviewed for parameterized
  queries and correct pool usage.
- **CI:** Static analysis checks for f-string/format patterns adjacent to
  `execute`/`fetch` calls.
- **Audit logs:** All database operations are logged with caller identity and
  timestamp.
- **Migration tracking:** Applied migrations are recorded in a
  `schema_migrations` table per database.
- **Constitutional basis:** The Constitution establishes data sovereignty and
  domain isolation; this standard implements them for database access.
