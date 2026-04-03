---
title: Testing Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Testing Standard

## Purpose

Consistent test patterns across all Maude projects. Tests verify real behavior,
run fast, and produce reliable results. Every project with logic worth testing
has tests that a new contributor can run and understand immediately.

## Rules

1. **Framework.** All Python projects MUST use `pytest` as the test runner.
   Async tests MUST use `pytest-asyncio` with `asyncio_mode = "auto"` in
   `pyproject.toml`.

2. **Fakes over mocks.** Tests MUST prefer purpose-built fakes that simulate
   real behavior over `unittest.mock.patch` wiring. A fake that returns
   deterministic output tests your logic. A mock that returns whatever you
   told it to proves nothing.

3. **State isolation.** Tests MUST NOT leak state between test cases. Shared
   resources (rate limiters, caches, connection pools) MUST be reset in
   fixtures or teardown. Leaking state causes flaky failures.

4. **Timestamps.** Time-sensitive tests MUST use relative offsets (`timedelta`,
   `time.monotonic`) or time-freezing libraries. Hardcoded dates MUST NOT
   appear in assertions.

5. **Test file layout.** Test files MUST be named `test_{module}.py` inside a
   `tests/` directory at the project root. Shared fixtures MUST live in
   `tests/conftest.py` and MUST NOT be duplicated across test files.

6. **Coverage.** Every function with meaningful logic MUST have at least one
   happy-path test. Edge cases and error paths SHOULD be tested for functions
   with complex branching.

7. **No boilerplate tests.** Generated code, dataclass definitions, and trivial
   pass-through wrappers SHOULD NOT have dedicated tests.

8. **Integration test pattern.** End-to-end tests MUST follow:
   call function → verify result structure → verify side effects (logs, DB
   writes, audit entries).

## Examples

### Fakes over mocks

```python
# Good — fake returns deterministic output, tests real logic
@pytest.fixture
def executor():
    fake = FakeExecutor()
    fake.register("restic snapshots --json", '[{"id": "abc123"}]')
    return fake

async def test_backup_status(executor):
    result = await backup_status(executor=executor)
    assert result["snapshots"][0]["id"] == "abc123"
```

```python
# Bad — mock wiring proves nothing about your logic
from unittest.mock import patch, AsyncMock

@patch("asyncssh.connect", new_callable=AsyncMock)
async def test_backup_status(mock_connect):
    mock_connect.return_value.run.return_value.stdout = '{"id": "abc123"}'
    ...
# This tests that you called the mock correctly, not that your code works.
```

### State isolation

```python
# tests/conftest.py — reset shared state between tests
@pytest.fixture(autouse=True)
def reset_shared_state():
    yield
    rate_limiter.reset()
    cache.clear()
```

### Integration test with side effect verification

```python
async def test_disk_usage_audited(service, audit_log):
    result = await service.call("disk_usage")
    assert "total_gb" in result

    entries = audit_log.entries_for("disk_usage")
    assert len(entries) == 1
    assert entries[0]["success"] is True
```

## Enforcement

- **CI pipeline:** `pytest` runs on every push. Failures block merge.
- **Pre-commit:** Projects SHOULD include a pytest pre-commit hook for fast feedback.
- **Code review:** Reviewers MUST reject mock-heavy tests for operations that
  have purpose-built fakes, and verify that new logic includes at least one test.
- **Constitutional basis:** The Constitution establishes code quality and
  accountability; this standard implements them for test practices.
