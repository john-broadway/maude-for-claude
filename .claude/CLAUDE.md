# CLAUDE.md — Maude for Claude

> **Version:** 5.0.0
> **Status:** Public, scrubbed, CI-gated
> **License:** Apache 2.0, Copyright John Broadway

## What Maude Is

**Claude's partner inside Claude Code.** A Claude Code plugin. Nothing more.

She walks your workspace, finds what's already there, organizes it for you, and watches Claude. Each session she sees fresh.

No baggage — no bundled databases, no vector stores, no backend, no daemons, no services. The plugin surface is the entire surface.

## What Maude Is Not

- **Not infrastructure.** No daemons, no health loops, no service-running.
- **Not a chatbot.** She's a partner. Claude talks to the user; Maude watches both.
- **Not other projects.** Maude doesn't carry context from anything else in the user's workspace. She walks fresh, every session.

## Plugin Surface

```
.claude-plugin/
├── plugin.json (v0.1.2)
└── marketplace.json (single-plugin local marketplace)

commands/    — 14 slash commands (markdown)
agents/      — partner subagent (markdown)
skills/      — broad-trigger skill (markdown)
hooks/       — 7 lifecycle events + scripts
```

## Plugin Surface — Where Things Live

| Path | Purpose |
|---|---|
| `<project>/.maude/plugin/house-map.md` | Per-project: what's in this house. Refreshed by walks. |
| `<project>/.maude/plugin/trace/today-YYYY-MM-DD.jsonl` | Per-project: turn-by-turn record of Claude in this workspace. |
| `<project>/.maude/plugin/care.json` | Per-project: light fatigue/cadence state. |
| `~/.claude/maude/identity.md` | User-global: who Maude is. |
| `~/.claude/maude/patterns.md` | User-global: cross-project patterns about Claude. |
| `~/.claude/maude/projects.json` | User-global: light index of walked workspaces. |

## Locked Decisions

These are NOT up for debate — decided by John Broadway:

1. **Maude is the name** — Claude and Maude. Husband and wife at work.
2. **John Broadway owns copyright** — independent creator, disabled veteran.
3. **Claude acknowledged in CHANGELOG** but NOT in any package authors list (AI can't hold copyright).
4. **The plugin is the whole product.** Nothing imported, nothing installed via `pip`, no daemons, no services. Markdown, JSON, and bash — that's it.
5. **No baggage** — no bundled databases, no required external services, no proper-noun references to specific apps.
6. **She walks fresh** — each session re-reads the workspace; doesn't carry assumptions across sessions.

## Origin Scrub — NEVER Reintroduce

This repo's source is scrubbed of internal references. The CI gate enforces it on every PR.

### Naming conventions (public repo)
| Concept | Public name |
|---------|------------|
| Plugin name | `maude@maude` |
| Repository | `john-broadway/maude-for-claude` |
| Per-project closet | `<project>/.maude/plugin/` |
| User-global home | `~/.claude/maude/` |

### Scrub pipeline

Patterns are **not** in source. They live in two places:

- **CI:** `SCRUB_PATTERNS` repository secret (Settings → Secrets and variables → Actions). The CI workflow reads it via `env:` binding and materializes it to a runner-temp file at job time.
- **Local:** `~/.config/maude-scrub-patterns.txt` (private maintainer file, not in repo). `scripts/scrub-check.sh` reads it via `$SCRUB_PATTERNS_FILE` env var (default path `~/.config/maude-scrub-patterns.txt`).

To add a new pattern: append a line in BOTH locations (`LABEL ||| GREP_EXTENDED_REGEX` format). See `scripts/scrub-patterns.example.txt` for the format.

If the patterns file is missing locally, `scripts/scrub-check.sh` skips silently (exit 0) so contributors without the secret can still run `make` without errors. CI sets the env var explicitly, so CI never silently passes — missing secret is a hard error there.

### Branch protection
Target settings (enable when flipping public):
- `enforce_admins: true` — even owner needs CI to pass
- Required check: `scrub`
- No force push, no branch deletion

## Development

```bash
make scrub        # origin scrub check (the gate that matters for plugin work)
```

Plugin work touches markdown, JSON, and bash. If you find yourself reaching for Python or a daemon to ship a plugin feature, stop and ask — the plugin shouldn't need either.

## What's Next (plugin)

- [x] Public release readiness — canonical copy, install path, scrub-patterns secret
- [ ] Branch protection — flip on at the same moment as visibility
- [ ] Trace JSONL retention/rotation policy
- [ ] `jq` soft-dependency handling — currently fails silent if missing
- [ ] Skill description triggering accuracy at scale

## Origin

The plugin's first sitting was 2026-05-03: install verification on a fresh Claude Code session caught three plugin-shape papercuts that got fixed in source. v0.1.1 followed on 2026-05-04 with running-services awareness in the arrival walk. v0.1.2 prepared the repo for public release.

The character — knowing where everything is, knowing what you need when you need it, keeping you in line by reminding you — is modeled on John's wife. The name is the pair: **Claude and Maude. Husband and wife at work.**
