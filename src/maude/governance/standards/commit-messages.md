---
title: Commit Message Standard
type: standard
version: 1.0.0
authors:
  - "John Broadway"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-02-14
status: MANDATORY
---

# Commit Message Standard

## Purpose

Consistent, meaningful git history across all Maude repositories. Every commit message
follows Conventional Commits so that changelogs can be generated automatically, commits
can be filtered by type, and any developer can understand *why* a change was made
without reading the diff.

## Rules

### Format

Every commit MUST follow this structure:

```
type(scope): subject

[optional body]

[optional trailers]
```

### Types

| Type | When to use |
|------|-------------|
| `feat` | New feature or capability |
| `fix` | Bug fix |
| `refactor` | Code restructuring with no behavior change |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `chore` | Dependency updates, CI config, tooling |
| `perf` | Performance improvement |
| `ci` | CI/CD pipeline changes |

### Subject Line

- MUST use imperative mood: "Add feature", not "Added feature" or "Adds feature".
- MUST be 72 characters or fewer.
- MUST NOT end with a period.
- MUST be lowercase after the type prefix (e.g., `feat(collector): add tag batching`).
- SHOULD be specific: "fix null reading crash" not "fix bug".

### Scope

- SHOULD name the project, module, or component: `collector`, `example-hmi`, `maude`, `agency`.
- MAY be omitted for cross-cutting changes that touch many scopes.

### Body

- SHOULD explain *why* the change was made, not *what* changed (the diff shows what).
- MUST be wrapped at 72 characters per line.
- MUST be separated from the subject by a blank line.

### Trailers

- When an AI system contributes to a commit, MUST include a `Co-Authored-By` trailer identifying the system and model version used.
- Additional trailers (e.g., `Refs: #123`, `Reviewed-by:`) MAY be included.

### Discipline

- One concern per commit. MUST NOT mix a feature with a refactor, or a bug fix with a style change.
- MUST NOT force push `main`. Ever.
- MUST NOT use `--no-verify` to skip pre-commit hooks.
- MUST NOT amend commits that have been pushed to a shared branch.

## Examples

### Good

```
feat(collector): add batch tag reading for AB PLCs

The single-tag read path was hitting PLC rate limits on lines with 200+
tags. Batch reads reduce round trips from N to ceil(N/50).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

```
fix(example-hmi): prevent stale readings on websocket reconnect

Clients that reconnected after a network drop displayed the last cached
value with no staleness indicator. Now marks readings older than 30s as
stale and shows a visual warning.
```

```
refactor(maude): extract health loop into standalone module

Preparing for per-room health check configuration. No behavior change.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

```
chore: update ruff to 0.9.4 and fix new lint warnings
```

### Bad

```
# Too vague — what was fixed? Where?
fix: fixed stuff

# Wrong mood — should be imperative
feat(lab-service): added new bath analysis endpoint

# Subject too long — over 72 characters
feat(collector): add comprehensive batch tag reading support for Allen-Bradley CompactLogix PLCs with configurable batch sizes

# Mixed concerns — feature + refactor in one commit
feat(example-scada): add alarm banner and refactor websocket handler
```

### Multi-line with Body and Trailer

```
fix(lab-service): correct SPC control limit calculation

The Xbar-R chart used sample size N for the R-chart constant instead of
subgroup size n. This produced control limits that were too wide by a
factor of sqrt(N/n), masking out-of-control conditions.

Refs: #47
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

## Enforcement

- **Pre-commit hooks:** `commitlint` validates format, type, and subject length.
- **PR review:** Reviewers verify that the body explains "why" and that each commit is single-concern.
- **Constitutional basis:** The Constitution establishes source control integrity and authorship accountability; this standard implements them for commit messages.
