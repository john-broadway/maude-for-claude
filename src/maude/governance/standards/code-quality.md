---
title: Code Quality Standard
type: standard
version: 1.2.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-04-01
status: MANDATORY
---

# Code Quality Standard

## Purpose

Engineering principles for writing maintainable, auditable code across all organization
projects. Implements code quality principles originally in Art. VII, demoted to
Federal Standard by Amendment A2 on 2026-03-15. The principles are unchanged —
the authority level is corrected.

## Rules

### 1. Minimum Complexity

MUST NOT add configuration, flags, or features that are not needed yet.

- SHOULD solve the problem in front of you. Do not design for hypothetical
  future requirements.

### 2. Explicit Over Implicit

No magic. No hidden behavior.

- If it matters, it is visible in the code.
- Implicit behavior is a liability — it cannot be audited, debugged,
  or trusted.

### 3. Validate at Boundaries, Trust Internals

Input from users, external systems, and configuration is validated.
Internal function calls between trusted components are not wrapped in
defensive error handling.

- System boundaries are where trust changes. Validate there.
- Internal code trusts the guarantees of the components it calls.

### 4. Dead Code Is Removed

Unused variables, commented-out blocks, and unreachable branches MUST be
deleted.

- If it is not serving a purpose, it is not in the codebase.
- Dead code is not a safety net — it is noise that obscures intent.

### 5. Duplication Over Premature Abstraction

MUST NOT generalize until the pattern has proven itself.

- Three similar lines are better than the wrong abstraction.
- Duplication is cheaper than the wrong abstraction. Consolidate
  when the pattern is clear, not before.

### 6. NULL-Safe Data Access

Data from PostgreSQL (or any external system) MAY contain NULL values for
columns that exist. `dict.get("key", default)` returns the default only
when the key is *missing* — a key present with value `None` returns `None`.

- **Integers and strings:** MUST use `(row.get("key") or default)` where
  NULL is possible. Safe because `0 or 0` is `0` and `"" or ""` is `""`.
- **Booleans:** MUST NOT use `or` — it coalesces `False` to the default.
  Use `val if val is not None else default` or keep `dict.get("key", default)`
  with explicit None-check upstream.
- MUST NOT assume `dict.get("key", 0)` protects against NULL. It does not.

## Examples

**Minimum complexity:**
- Bad: Adding a `--verbose`, `--format`, and `--output` flag to a script that only needs to do one thing.
- Good: A script that does the one thing. Add flags when a second use case demands them.

**Duplication over abstraction:**
- Bad: `class BaseProcessor` with 12 subclasses when you have 2 similar functions.
- Good: Two similar functions. Refactor when the third one arrives and the pattern is clear.

**NULL-safe data access (integers/strings):**
- Bad: `if row.get("failed", 0) > 0:` — crashes with `TypeError` when PG returns NULL.
- Good: `if (row.get("failed") or 0) > 0:` — coalesces NULL to 0.
- Bad: `row.get("summary", "")[:120]` — crashes with `TypeError` when summary is NULL.
- Good: `(row.get("summary") or "")[:120]` — coalesces NULL to empty string.

**NULL-safe data access (booleans — `or` is WRONG):**
- Bad: `(config.get("enabled") or True)` — `False` becomes `True`. Silent logic inversion.
- Bad: `(config.get("default_allow") or True)` — ACL bypass when allow is explicitly False.
- Good: `config.get("enabled", False)` with NULL-check at the data boundary, or:
- Good: `val if (val := config.get("enabled")) is not None else True`

## Enforcement

Enforced through code review and `null-safe-get.sh` hook (PostToolUse).
Reviewers MUST flag `or True`/`or False` patterns on external data.
Compliance is verified during review and maintained through team discipline.
