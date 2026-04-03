---
title: Dependency Management Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Dependency Management Standard

## Purpose

Consistent, secure dependency management across all Maude Python projects.
`pyproject.toml` is the single source of truth for project metadata and
dependencies. This standard eliminates dependency confusion, version conflicts,
and environment pollution.

## Rules

### Dependency Definition

1. `pyproject.toml` MUST be the sole dependency definition file. Projects MUST
   NOT use `requirements.txt`, `setup.py`, or `setup.cfg` for dependency
   specification.

2. All projects MUST declare `requires-python = ">=3.10"`.

3. Dependencies MUST pin the major version and allow minor/patch updates:
   `fastmcp>=2.14.0,<3`. Projects MUST NOT pin exact versions (`==`) unless a
   specific version is required to work around a known bug, in which case a
   comment MUST explain why.

4. Projects MUST NOT use lockfiles. Maude leans toward latest compatible versions
   and validates through testing, not pinning.

### Shared Libraries

5. Internal shared libraries MUST be installed in editable mode during
   development: `pip install -e <path>`.

6. Shared libraries SHOULD use extras for optional feature sets (e.g.,
   `library[llm]`, `library[cache]`). Services SHOULD declare only the extras
   they actually use.

7. Production deploys install shared libraries from source via deployment
   scripts. Individual services MUST NOT bundle shared libraries.

### Virtual Environments

8. All Python work MUST use virtual environments. System-wide `pip install` is
   NEVER permitted.

9. Development venvs MUST live at `.venv/` in the project root.

10. `.venv/` MUST be listed in `.gitignore`. Virtual environments MUST NOT be
    committed.

### Updates and Security

11. Security updates SHOULD be applied promptly: bump version, run tests,
    deploy. Do NOT blindly update all dependencies at once.

12. When updating a dependency, the changelog SHOULD be reviewed for breaking
    changes before bumping.

13. Transitive dependency conflicts MUST be resolved by adjusting direct
    dependency bounds, not by pinning transitive dependencies.

### Project Self-Install

14. During development, the project itself MUST be installed in editable mode:
    `pip install -e .` from the project root. This ensures entry points,
    package metadata, and imports work correctly.

## Examples

### Good: pyproject.toml dependency section

```toml
[project]
name = "lab-service"
version = "1.4.0"
requires-python = ">=3.10"

dependencies = [
    "asyncpg>=0.30.0,<1",
    "fastmcp>=2.14.0,<3",
    "uvicorn>=0.34.0,<1",
    "pydantic>=2.10.0,<3",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0,<9",
    "pytest-asyncio>=0.25.0,<1",
    "ruff>=0.9.0,<1",
]
```

### Bad: Exact pinning without justification

```toml
# DON'T — locks out security patches
dependencies = [
    "fastmcp==2.14.0",
    "pydantic==2.10.3",
]
```

### Bad: requirements.txt

```
# DON'T — use pyproject.toml instead
fastmcp==2.14.0
asyncpg==0.30.0
```

### Development setup

```bash
cd ~/projects/lab-service
python3 -m venv .venv
source .venv/bin/activate
pip install -e .  # install project in editable mode
pip install -e .[dev]  # include dev dependencies
```

## Enforcement

- **Code review:** PRs adding `requirements.txt` or `setup.py` are rejected.
- **CI:** Build step runs `pip install -e .[dev]` to verify dependency
  resolution succeeds.
- **Audit:** Periodic `pip audit` runs against production environments to flag
  known CVEs.
- **Constitutional basis:** The Constitution establishes safety and
  accountability; this standard implements them for dependency management.
