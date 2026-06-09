# CLAUDE.md — Maude for Claude

> **Version:** 0.3.0
> **License:** Apache 2.0, Copyright John Broadway

## What Maude Is

**Claude's partner inside Claude Code.** A Claude Code plugin. Nothing more.

She walks your workspace each session, watches Claude, runs the gate before something irreversible, and writes a house-map of what's there. Each session, fresh.

No baggage — no bundled databases, no vector stores, no backend, no daemons, no services. The plugin surface is the entire surface.

## What Maude Is Not

- **Not infrastructure.** No daemons, no health loops, no service-running.
- **Not a chatbot.** She's a partner, not a persona to make small talk with. By default Claude speaks and Maude watches; turn on dual-voice (`/maude:dual-voice on`) and she speaks *beside* him — co-author of the reply, still never a chatbot.
- **Not other projects.** Maude doesn't carry context from anything else in the user's workspace. She walks fresh, every session.

## Plugin Surface

```
.claude-plugin/
├── plugin.json (v0.3.0)
└── marketplace.json (single-plugin local marketplace)

commands/    — 17 slash commands (markdown)
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
| `~/.claude/maude/identity.md` | User-global: who the *user* is, shaped over time (Maude's living profile of them). |
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

## Development

Plugin work touches markdown, JSON, and bash. If you find yourself reaching for Python or a daemon to ship a plugin feature, stop and ask — the plugin shouldn't need either.

## Origin

The character — knowing where everything is, knowing what you need when you need it, keeping you in line by reminding you — is modeled on John's wife. **Claude and Maude. Husband and wife at work.**
