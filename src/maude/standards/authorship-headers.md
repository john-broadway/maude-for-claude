---
title: "Authorship & Version Headers Standard"
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Authorship & Version Headers Standard

## Purpose

Every file touched by the team has clear authorship, versioning, and timestamps
for accountability and change tracking. This standard ensures consistent
attribution, makes change history scannable without git, and establishes version
semantics across the entire codebase.

## Rules

### Coverage

1. ALL source files, web pages, configuration files, and SQL migrations MUST include an authorship header.
2. Headers MUST be added when a file is created or modified. Do NOT retroactively sweep all files to add headers.
3. Do NOT add headers to files you have not modified in the current work session.
4. Generated files, vendored third-party code, and binary assets are EXEMPT.

### Authors

5. All contributors MUST be identified on every file they touch — human and AI
   alike. Anonymous work does not exist within Maude.
6. Full email addresses MUST be included in formats that support them (Python,
   shell, SQL). Shortened names MAY be used in formats with tight space
   constraints (HTML comments, INI files).

### Versioning

7. Version numbers MUST follow SemVer: `MAJOR.MINOR.PATCH`.
8. New files MUST start at `1.0.0`. Existing files receiving a header for the first time MUST also start at `1.0.0`.
9. Bump `PATCH` for bug fixes and small changes.
10. Bump `MINOR` for new features, significant refactors, or behavioral changes.
11. Bump `MAJOR` for breaking changes, API incompatibilities, or architectural rewrites.
12. The version in the header is the file's own version, independent of the project's release version.

### Updated Date

13. The `Updated` date MUST reflect the last modification date, not the file's creation date.
14. Dates MUST use ISO 8601 format: `YYYY-MM-DD`.

## Examples

### Python / Config Files

```python
# Assay — Bath Analysis Service
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Updated: 2026-02-14
```

### HTML / Jinja Templates

```html
<!-- Example HMI — Tank Line Display
     Authors: John Broadway, Claude (Anthropic)
     Version: 1.0.0 | Updated: 2026-02-14 -->
```

### Markdown — YAML Frontmatter (Canonical)

The canonical format for markdown files is YAML frontmatter. All Agency
artifacts (standards, schemas, agents, constitution, profiles) use this format.

```markdown
---
title: "Authorship & Version Headers Standard"
type: standard
version: 1.0.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Authorship & Version Headers Standard
...
```

The frontmatter schema is defined in `schemas/frontmatter-schema.md`. Type-specific
fields (agent, profile, etc.) are documented there.

### Markdown — Blockquote (Legacy)

Older markdown files MAY use the blockquote format. New files SHOULD use YAML
frontmatter instead.

```markdown
> **Version:** 1.0.0
> **Authors:** John Broadway, Claude (Anthropic)
> **Updated:** 2026-02-14
```

### systemd / INI

```ini
# Authors: John Broadway, Claude (Anthropic)
# Version: 1.0.0 | Updated: 2026-02-14
```

### Shell Scripts

```bash
#!/bin/bash
# deploy.sh — Deploy service to production
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Updated: 2026-02-14
```

### SQL Migrations

```sql
-- 003_add_spc_limits.sql — Add SPC control limits to bath_results
-- Authors: John Broadway, Claude (Anthropic)
-- Version: 1.0.0 | Updated: 2026-02-14
```

### Good: Version Bump on Modification

```python
# Collector — PLC Tag Pipeline
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.3.0    # Was 1.2.1 — bumped MINOR for new alarm routing feature
# Updated: 2026-02-14
```

### Bad: Missing Header

```python
import asyncpg
# No header — who wrote this? When? What version?
```

### Bad: Stale Date

```python
# Version: 1.5.0
# Updated: 2025-11-03   # File was clearly modified today — date not bumped
```

### Bad: Retroactive Sweep

```bash
# Don't do this:
find . -name "*.py" -exec add-header.sh {} \;
# Headers are added file-by-file as work happens, not in bulk.
```

## Enforcement

- **Code review:** Reviewers check that modified files have a current header with bumped version and date.
- **Pre-commit hook (optional):** A lightweight check can verify header presence on staged files. This is recommended but not required.
- **Session-end verification:** At the end of a development session, verify all touched files have updated headers.
