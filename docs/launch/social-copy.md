# Social copy — Maude launch

Pre-drafted copy across formats. Pick what fits each surface; rewrite freely. None of this is final until you read it aloud and it sounds like you.

---

## One-liner (Twitter/Mastodon top line)

> Maude is Claude's partner inside Claude Code. She walks your workspace, finds what's already there, and notices what Claude doesn't. Beta v0.1.1. Apache-2.0.
> [link to repo]

## One-paragraph (HN comment, blog teaser, README hero)

> A Claude Code plugin that walks your workspace on session start, lists every memory home and SQLite db and running service it finds, classifies them, and writes a per-project house-map. She watches Claude too — flags repeated tool calls, unread context, confabulation risk. No baggage. Beta v0.1.1. Apache-2.0.
> [link to repo]

## Thread (Twitter / Mastodon long-form, ~6 posts)

**1/** Most agent frameworks help LLMs answer questions. I wanted a partner that watched mine.

Maude walks your workspace at session start. Lists what's there: memory homes, SQLite databases, MCP tools, running containers and what they're bound to. Writes a house-map. Notices what I don't.

**2/** She's a Claude Code plugin. Zero dependencies; no baggage. No bundled database, no vector store, no backend. She finds what you already have and works with it.

**3/** Some of what's in her surface:

- `/maude:found` — the arrival walk
- `/maude:wake` / `/maude:rest` — start/end-of-session rituals
- `/maude:check-on-claude` — reads the trace, flags repeated calls, missed CLAUDE.md, confabulation risk
- `/maude:check-on-me` — care side, pattern-of-life
- `/maude:conscience` — pre-irreversible-action gate

**4/** v0.1.1 added running-services awareness to the arrival walk. She lists running containers and reconciles their bind mounts against the workspace, classifying each as `[OK]` / `[GHOST]` / `[ORPHAN]`. Filesystem-only walks miss this category of state; she doesn't.

**5/** Apache-2.0. Beta. github.com/john-broadway/maude-for-claude

The name is the pair. *Claude and Maude.*

---

## Show HN / Reddit r/ClaudeAI long-form (~200 words)

**Title:** *Maude — a Claude Code plugin that walks your workspace and watches Claude*

A Claude Code plugin that's been quietly load-bearing for me, and today's the day to show it.

Maude walks your workspace at session start. She lists every memory home, SQLite database, MCP tool, and running container she finds, classifies them, and writes a per-project house-map. No baggage — she finds what's already there and works with it.

She also watches Claude. `/maude:check-on-claude` reads the turn-by-turn trace and flags repeated tool calls (Claude grepping the same term four times), unread context (CLAUDE.md not opened this session), confabulation risk (claims made without backing reads), and open todos. `/maude:check-on-me` is the care side — pattern-of-life, not absolute thresholds.

Other commands: `wake`, `rest`, `brief`, `save`, `remind-me`, `where-is`, `sweep`, `notice`, `weekly`, `conscience`, `check-setup`. Full list in the repo.

v0.1.1 added running-services awareness to the arrival walk: running containers, bind-mount reconciliation against the filesystem, `[OK]` / `[GHOST]` / `[ORPHAN]` classification. No new dependencies; graceful degrade.

Apache-2.0. Beta. Built by [@john-broadway].

[link to repo]

---

## Names / handles

Plugin: `maude@maude` in Claude Code marketplace.
Repo: `github.com/john-broadway/maude-for-claude`.

The name is the pair. **Claude and Maude.**

---

## Posting checklist

When you're ready:

- [ ] Push commits + `v0.1.2` tag to GitHub (3-team rule — your call)
- [ ] Verify the repo's README renders cleanly on github.com
- [ ] Run the demo recording per `docs/launch/demo-storyboard.md`
- [ ] Pick the post(s) above; rewrite to your voice; post
- [ ] If posting to HN, do it on a weekday morning Pacific

---

## What NOT to say

- Don't say she's "powered by AI" or "AI-driven." She's a partner.
- Don't promise features that aren't there yet. Trace JSONL retention, `jq` soft-dependency, skill-trigger accuracy at scale — all known gaps in the repo. Owning them is fine; advertising them as features isn't.
