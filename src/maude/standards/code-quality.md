---
title: Code Quality Standard
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-29
status: MANDATORY
---

# Code Quality Standard

## Purpose

Engineering principles for writing maintainable, auditable code across all Maude
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

## Examples

**Minimum complexity:**
- Bad: Adding a `--verbose`, `--format`, and `--output` flag to a script that only needs to do one thing.
- Good: A script that does the one thing. Add flags when a second use case demands them.

**Duplication over abstraction:**
- Bad: `class BaseProcessor` with 12 subclasses when you have 2 similar functions.
- Good: Two similar functions. Refactor when the third one arrives and the pattern is clear.

## Enforcement

Enforced through code review. These principles cannot be mechanically detected
(no hook can identify premature abstraction). Reviewers SHOULD flag violations.
Compliance is verified during review and maintained through team discipline.
