# Maude — Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)

# Contributing to Maude

Thank you for your interest in contributing. Maude is an autonomous agent framework
for infrastructure operations, built on composable MCP servers with self-healing, memory, and
constitutional governance. Contributions should respect those same principles: explicit over
implicit, minimal complexity, and an unbroken audit trail.

---

## Table of Contents

- [Development Environment Setup](#development-environment-setup)
- [Code Style](#code-style)
- [Running Tests](#running-tests)
- [Pull Request Process](#pull-request-process)
- [Governance Model](#governance-model)
- [Code of Conduct](#code-of-conduct)

---

## Development Environment Setup

**Requirements:** Python 3.10+, git.

```bash
# 1. Fork and clone
git clone https://github.com/your-fork/maude-for-claude.git
cd maude-for-claude

# 2. Install the package with all extras and dev dependencies
pip install -e ".[all,dev]"

# 3. Verify the test suite passes
make test
```

The `[all,dev]` extras install every optional dependency (memory, healing, ssh, web, cache,
training) plus the test and lint tooling. If you are working on a specific subsystem, you can
install only the relevant extras:

```bash
pip install -e ".[memory,dev]"    # Memory tier work
pip install -e ".[healing,dev]"   # Health loop and lifecycle work
pip install -e ".[web,dev]"       # Web UI work
```

### Environment for Integration Tests

Integration tests require live infrastructure (PostgreSQL, Qdrant, Redis). They are skipped by
default. To run them, export the following environment variables before calling `pytest`:

```bash
export MAUDE_PG_HOST=localhost
export MAUDE_QDRANT_HOST=localhost
export MAUDE_REDIS_HOST=localhost
pytest tests/ -v -m integration
```

---

## Code Style

The project uses [ruff](https://docs.astral.sh/ruff/) for both linting and import sorting.

**Settings** (`pyproject.toml`):

| Setting | Value |
|---------|-------|
| `line-length` | 100 |
| `target-version` | `py310` |
| `lint.select` | `E`, `F`, `I`, `W` |

Always run `ruff check` before committing:

```bash
ruff check src/ tests/
```

To auto-fix safe issues:

```bash
ruff check --fix src/ tests/
```

### Authorship Headers

Every new file must carry the authorship header. This is enforced by a pre-commit hook:

```python
# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: YYYY-MM-DD MST
# Authors: John Broadway, Claude (Anthropic)
```

For shell scripts, use `#` comments in the same position at the top of the file.

---

## Running Tests

```bash
# All unit tests
make test

# With coverage report
make test-cov

# Only unit tests (no live infrastructure)
pytest tests/ -v -m "not integration"

# Only integration tests (requires live infra — see above)
pytest tests/ -v -m integration
```

Mark any test that requires live infrastructure (PostgreSQL, Redis, Qdrant, or network access)
with the `@pytest.mark.integration` decorator:

```python
import pytest

@pytest.mark.integration
async def test_store_and_recall_with_postgres():
    ...
```

The test runner uses `asyncio_mode = "auto"` (pytest-asyncio), so async test functions work
without an explicit `@pytest.mark.asyncio` decorator.

### Testing Patterns

- Use `maude.testing` fakes (e.g., `FakeAuditLogger`, `FakeKillSwitch`) instead of
  mocking real infrastructure. See `src/maude/testing.py`.
- Guard decorator order matters: `@mcp.tool()` outermost, then `@audit_logged`, then
  `@requires_confirm`, innermost is the function body.
- Install the local package with `pip install -e .` in tests that exercise entry points, not
  by adding `sys.path` hacks.

---

## Pull Request Process

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b feat/my-feature
   ```

2. **Write tests first.** The project follows test-driven development. New behavior should
   have a failing test before the implementation.

3. **Implement** the feature. Keep changes focused — one concern per PR.

4. **Lint and test:**
   ```bash
   ruff check src/ tests/
   make test
   ```

5. **Commit** with a clear message following the pattern `type: subject`:
   - `feat:` new capability
   - `fix:` bug fix
   - `refactor:` internal restructuring, no behavior change
   - `test:` test additions or corrections
   - `docs:` documentation only

6. **Open a Pull Request** against `main`. The description should include:
   - **What** changed and **why**
   - **How to test** the change
   - Any **breaking changes** and migration path
   - Reference to any related issue (`Closes #123`)

7. At least one maintainer review is required before merge. The reviewer may request changes.
   Address review feedback in new commits (do not force-push a rewrite onto an open PR).

8. **Squash-merge** is preferred for feature branches to keep `main` history clean. The
   maintainer handling the merge will do this.

---

## Incorporating Production Changes

Maude runs in production. When improvements are made on the production system, they can be
incorporated into this open-source repo via manual cherry-pick:

1. **Identify** the commit(s) on the production repo that should be brought over.
2. **Cherry-pick** into a feature branch on this repo:
   ```bash
   git checkout -b sync/feature-name
   git cherry-pick <commit-hash>
   ```
3. **Run the scrub check** to catch any re-introduced internal references:
   ```bash
   make scrub
   ```
   Fix any flagged patterns. Use `bash scripts/scrub-check.sh --fix-hint` for replacement
   suggestions.
4. **Open a PR** against `main`. CI will hard-block if the scrub check fails.
5. **Review and squash-merge** as usual.

The scrub check (`scripts/scrub-check.sh`) detects internal IPs, service names, site codes, old
environment variable prefixes, and other origin-specific references. It runs automatically in CI
on every push and pull request.

---

## Governance Model

Maude ships its own governance framework in `src/maude/governance/`. The governance module defines
how autonomous Room agents operate — what they may and may not do without human approval.

Contributions to the framework should be consistent with these principles:

- **Explicit over implicit.** Mutating operations require `confirm=True` and a `reason`.
- **Audit trail is sacred.** Every state change must be logged; the audit log is append-only.
- **Read before edit.** Understand existing behavior before removing or replacing it.
- **Kill switch.** Any mutating operation must respect the kill switch and refuse when it is
  active.
- **Sovereignty.** Each Room is sovereign in its domain. Cross-room interactions happen only
  through sanctioned MCP interfaces.

If you are proposing a change to the constitutional articles in `src/maude/governance/`,
open an issue first to discuss the amendment. Non-trivial amendments require a stated rationale,
impact analysis, and explicit maintainer approval before a PR is opened.

---

## Code of Conduct

Be respectful, constructive, and collaborative.

- Critique code and ideas, not people.
- Assume good intent. Ask for clarification before assuming malice or incompetence.
- Welcome contributors regardless of experience level.
- Harassment of any kind will not be tolerated.

Violations may be reported to the maintainers. Confirmed violations result in removal from the
project — with a stated reason and a restoration path, consistent with the Bill of Rights that
governs the Rooms themselves.
