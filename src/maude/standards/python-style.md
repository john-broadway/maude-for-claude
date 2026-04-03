---
title: Python Style Standard
type: standard
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Python Style Standard

## Purpose

Unified Python coding conventions across all Maude projects. Every Python file in every
repository follows these rules so that any developer (human or AI) can read, modify,
and review code without guessing at local conventions.

## Rules

### Type Hints

- All function signatures MUST include type hints for parameters and return values.
- MUST use Python 3.10+ union syntax: `X | None`, not `Optional[X]`.
- MUST use lowercase generics: `list[str]`, `dict[str, Any]`, `tuple[int, ...]`.
- SHOULD avoid `Any` except at true serialization boundaries (JSON parsing, dynamic config).

### Async I/O

- All I/O operations (database queries, HTTP calls, file reads in production services) MUST be `async`.
- Synchronous I/O is acceptable in CLI scripts, one-shot migration tools, and test fixtures.
- MUST NOT mix `asyncio.run()` inside already-running event loops.

### Paths

- MUST use `pathlib.Path` for all filesystem operations.
- MUST NOT use `os.path.join`, `os.path.exists`, or `os.makedirs`.

### Simplicity

- Explicit over implicit. No metaclasses, no descriptor magic, no `__init_subclass__` tricks unless solving a real problem.
- Three similar lines of code is better than a premature abstraction. Do not DRY until the pattern has proven itself.
- Delete unused code. No `_unused` variables, no commented-out blocks, no `# TODO: remove`.
- Minimum complexity: do not add configuration, flags, or features that are not needed yet.

### Error Handling

- MUST validate at system boundaries: user input, external API responses, config file parsing.
- MUST NOT wrap internal function calls in try/except. Trust internal code.
- MUST NOT handle impossible scenarios (e.g., catching `TypeError` on a statically typed call).
- SHOULD let exceptions propagate to the boundary where they can be handled meaningfully.

### Imports

- MUST order imports: stdlib, then third-party, then local, with a blank line between each group.
- MUST NOT use wildcard imports (`from module import *`).
- SHOULD prefer explicit imports over module-level imports for clarity.

### Comments and Docstrings

- Do not add docstrings to code you did not change. Docstrings on new public APIs are fine.
- Only add inline comments where the logic is not self-evident from the code.
- MUST NOT leave `# noqa` without specifying the rule being suppressed.

## Examples

### Type Hints

```python
# Good
def fetch_readings(tank_id: int, limit: int = 100) -> list[dict[str, Any]]:
    ...

def find_user(name: str) -> User | None:
    ...

# Bad — legacy syntax
from typing import Optional, List, Dict
def fetch_readings(tank_id: int, limit: int = 100) -> List[Dict[str, Any]]:
    ...

def find_user(name: str) -> Optional[User]:
    ...
```

### Error Handling

```python
# Good — validate at the boundary (API endpoint)
async def create_batch(request: Request) -> Response:
    body = await request.json()
    if "tank_id" not in body:
        return Response(status=400, text="tank_id required")
    await service.create_batch(body["tank_id"])
    return Response(status=201)

# Bad — defensive wrapping deep inside trusted code
def calculate_concentration(reading: Reading) -> float:
    try:
        return reading.value / reading.volume
    except ZeroDivisionError:
        return 0.0  # volume is never zero — this hides bugs
```

### Import Ordering

```python
# Good
import asyncio
from pathlib import Path

import httpx
from sqlalchemy.ext.asyncio import AsyncSession

from collector.models import TagReading
from collector.config import settings
```

### Async Patterns

```python
# Good — async for production I/O
async def read_config(path: Path) -> dict[str, Any]:
    async with aiofiles.open(path) as f:
        return yaml.safe_load(await f.read())

# Acceptable — sync in a CLI script
def read_config(path: Path) -> dict[str, Any]:
    return yaml.safe_load(path.read_text())
```

## Enforcement

- **Linting:** `ruff` with Maude config in `pyproject.toml`. Runs in pre-commit hooks.
- **Code review:** Reviewers check for boundary-only error handling, correct type hint syntax, and async I/O usage.
- **Constitutional basis:** The Constitution establishes Code Quality principles; this standard implements them for Python.
