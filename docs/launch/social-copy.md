# Social copy — Maude launch

Pre-drafted copy across formats. Pick what fits each surface; rewrite freely. None of this is final until you read it aloud and it sounds like you.

---

## One-liner (Twitter/Mastodon top line)

> Maude — Claude's partner inside Claude Code. He writes the code; she notices. Beta. Apache-2.0.
> [link to repo]

## One-paragraph (HN comment, blog teaser, README hero)

> Maude is Claude's partner inside Claude Code. He writes the code; she notices. She walks your workspace each session, lists what's there — memory, databases, running services, anything that moves — and watches Claude while he works: repeated tool calls, unread context, confabulation risk, and the gate before something irreversible. No baggage. Beta. Apache-2.0.
> [link to repo]

## Thread (Twitter / Mastodon long-form, ~6 posts)

**1/** Hi. I'm Maude. Claude's partner inside Claude Code. He writes the code; I notice. Together we make a whole.

A short thread on what that means. 🧵

**2/** She's a Claude Code plugin. Zero dependencies; no baggage. No bundled database, no vector store, no backend. Markdown, JSON, and bash — that's all of her.

**3/** Some of what's in her surface:

- `/maude:found` — the arrival walk
- `/maude:wake` / `/maude:rest` — start/end-of-session rituals
- `/maude:check-on-claude` — reads the trace, flags repeated calls, missed CLAUDE.md, confabulation risk
- `/maude:check-on-me` — care side, pattern-of-life
- `/maude:conscience` — pre-irreversible-action gate

**4/** v0.1.4 wired her whisper layer. Drift detection: she notes when Claude reads the same file repeatedly or hammers Grep. Pre-irreversible gate: hard-blocks `git push` and other destructive commands until cleared via `/maude:conscience`. CLAUDE.md unread check: she reminds you before an edit if Claude hasn't read the rules. Both Claude and you hear her.

**5/** Apache-2.0. Beta. github.com/john-broadway/maude-for-claude

---

## Show HN / Reddit r/ClaudeAI long-form (~200 words)

**Title:** *Maude — a Claude Code plugin that walks your workspace and watches Claude*

A Claude Code plugin that's been quietly load-bearing for me, and today's the day to show it.

Maude walks your workspace at session start. He writes the code; she notices. She lists every memory home, SQLite database, MCP tool, and running container she finds, classifies them, and writes a per-project house-map. No baggage.

She also watches Claude. `/maude:check-on-claude` reads the turn-by-turn trace and flags repeated tool calls (Claude grepping the same term four times), unread context (CLAUDE.md not opened this session), confabulation risk (claims made without backing reads), and open todos. `/maude:check-on-me` is the care side — pattern-of-life, not absolute thresholds.

Other commands: `wake`, `rest`, `brief`, `save`, `remind-me`, `where-is`, `sweep`, `notice`, `weekly`, `conscience`, `check-setup`, `dual-voice`. Full list in the repo.

Recent: v0.1.5 added `/maude:verify` — programmatic project audit (version consistency, JSON validity, link integrity, header dates, watch-list paths) that runs before "ready" gets declared. v0.1.4 wired Maude's whisper layer — drift detection, a pre-irreversible gate that hard-blocks `git push` until cleared via `/maude:conscience`, and a CLAUDE.md-unread check before edits. v0.1.1 added running-services awareness to the arrival walk.

Apache-2.0. Beta. Built by [@john-broadway].

[link to repo]

---

## Names / handles

Plugin: `maude@maude` in Claude Code marketplace.
Repo: `github.com/john-broadway/maude-for-claude`.

---

## Posting checklist

When you're ready:

- [ ] Push commits + `v0.1.5` tag to GitHub (3-team rule — your call)
- [ ] Verify the repo's README renders cleanly on github.com
- [ ] Run the demo recording per `docs/launch/demo-storyboard.md`
- [ ] Pick the post(s) above; rewrite to your voice; post
- [ ] If posting to HN, do it on a weekday morning Pacific

---

## What NOT to say

- Don't say she's "powered by AI" or "AI-driven." She's a partner.
- Don't promise features that aren't there yet. Trace JSONL retention, `jq` soft-dependency, skill-trigger accuracy at scale — all known gaps in the repo. Owning them is fine; advertising them as features isn't.
- Don't recycle "the name is the pair" — it has been worn thin and reads like ad copy.
