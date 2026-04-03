<!-- Version: 1.0 -->
<!-- Created: 2026-03-28 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Security Policy

## Security Principles

Maude takes security seriously. Every Room has a kill switch. Every action has an audit trail. Every credential has a scope and an expiration. These aren't features — they're constitutional requirements.

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, please use [GitHub's private vulnerability reporting](https://github.com/john-broadway/maude-for-claude/security/advisories/new) or email via the address on [the maintainer's GitHub profile](https://github.com/john-broadway). Include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if you have one)

We will acknowledge receipt within 48 hours and provide a timeline for resolution.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |

## Security Architecture

Maude includes built-in security patterns:

- **Kill Switch** — Per-room read-only flag. One call stops all writes.
- **`@requires_confirm`** — Destructive operations require explicit consent.
- **`@rate_limited`** — Prevents rapid-fire mutations.
- **`@audit_logged`** — Every tool call recorded to PostgreSQL + stdout.
- **ACL Engine** — Role-based access control with glob pattern matching.
- **Credential Isolation** — No shared credentials across trust boundaries.

## What We Consider In Scope

- Authentication/authorization bypasses
- Injection vulnerabilities in tool inputs
- Credential exposure in logs, outputs, or error messages
- Kill switch bypass
- Audit trail tampering
- Cross-room unauthorized access

## What Is Out of Scope

- Vulnerabilities in dependencies (report upstream)
- Denial of service against local services
- Social engineering

---

*Rules exist for a reason. Every standard came from a real incident.*
