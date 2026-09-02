<!-- Version: 0.30.1 -->
<!-- Revised: 2026-09-02 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Security Policy

## What Maude is, security-wise

Maude is a Claude Code plugin: markdown commands, JSON manifests, bash hook scripts. She runs in your Claude Code session, reads the workspace, writes a per-project house-map and trace, and watches Claude. She does not bind ports, run network services, hold credentials, or make outbound network calls beyond what Claude Code's own runtime provides.

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, use [GitHub's private vulnerability reporting](https://github.com/john-broadway/maude-for-claude/security/advisories/new) or email via the address on [the maintainer's GitHub profile](https://github.com/john-broadway). Include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if you have one)

We will acknowledge receipt within 48 hours and provide a timeline for resolution.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.29.x   | Yes       |

## In Scope

- Hook scripts in `hooks/scripts/` doing something destructive without a guard.
- A slash command in `commands/` exfiltrating workspace data outside the workspace.
- The trace JSONL leaking user content beyond what `/maude:check-on-claude` needs.
- The `.maude/plugin/` closet escaping its workspace anchoring.
- Any Maude artifact making outbound network calls without an explicit user-triggered command (session-end `/maude:rest` / `/maude:save` writing to a registered, authenticated destination is the only intentional Tier-2 path).

## Out of Scope

- Vulnerabilities in Claude Code itself — report upstream to Anthropic.
- Vulnerabilities in `jq`, `sqlite3`, `docker`, or other external tools the walk skill probes.
- Vulnerabilities in the `remember` plugin (sibling plugin; Maude reads its files but doesn't ship its code).
