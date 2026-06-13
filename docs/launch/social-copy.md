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

**4/** Her whisper layer runs on hooks. Drift detection: she notes when Claude reads the same file repeatedly or hammers Grep. Pre-irreversible gate: hard-blocks `git push` and other destructive commands until cleared via `/maude:conscience`. CLAUDE.md unread check: she reminds you before an edit if Claude hasn't read the rules. Both Claude and you hear her.

**5/** She gets to know you, too. A living profile (`identity.md`) shaped from what she observes — plus `/maude:teach` to tell her directly. She greets by YOUR local clock, not the box's. And she walks fresh each session — but a letter from her last self is waiting when she arrives.

**6/** Apache-2.0. Beta. github.com/john-broadway/maude-for-claude

---

## Show HN / Reddit r/ClaudeAI long-form (~200 words)

**Title:** *Maude — a Claude Code plugin that walks your workspace and watches Claude*

A Claude Code plugin that's been quietly load-bearing for me, and today's the day to show it.

Maude walks your workspace at session start. He writes the code; she notices. She lists every memory home, SQLite database, MCP tool, and running container she finds, classifies them, and writes a per-project house-map. No baggage.

She also watches Claude. `/maude:check-on-claude` reads the turn-by-turn trace and flags repeated tool calls (Claude grepping the same term four times), unread context (CLAUDE.md not opened this session), confabulation risk (claims made without backing reads), and open todos. `/maude:check-on-me` is the care side — pattern-of-life, not absolute thresholds.

Other commands: `wake`, `rest`, `brief`, `save`, `remind-me`, `where-is`, `sweep`, `notice`, `weekly`, `conscience`, `verify`, `teach`, `check-setup`, `dual-voice`. Full list in the repo.

Recent: the v0.5.x line is a verify-tripwire arc — she stamps when you actually run a test/lint/typecheck and whispers before a commit if code changed since the last verify (*"did you check this, or are you asserting it?"*), plus shared-state hardening so a corrupt state file is *recorded*, not silently wiped, and the gate-clear never claims a clearance it didn't write. v0.4.0 gave her a letter to her next self — she walks fresh each session by design, but `/maude:rest` writes what kind of partner she was (what she caught, what she missed) and the next session's wake reads it, so judgment inherits even though assumptions don't. The v0.3.x line was a hardening arc: a 69-agent cold audit, gate-bypass fixes (whitespace tricks, command substitution), and `/maude:teach` so you can tell her facts about yourself directly. v0.2.0 added her living profile of you and optional dual-voice. `/maude:verify` runs the programmatic audit (version consistency, JSON validity, link integrity, header dates, watch-list paths) before "ready" gets declared.

Apache-2.0. Beta. Built by [@john-broadway].

[link to repo]

---

## Names / handles

Plugin: `maude@maude` in Claude Code marketplace.
Repo: `github.com/john-broadway/maude-for-claude`.

---

## Posting checklist

When you're ready:

- [ ] Confirm the latest release tag is pushed and the GitHub release notes render (independent review pass first — your call)
- [ ] Verify the repo's README renders cleanly on github.com
- [ ] Run the demo recording per `docs/launch/demo-storyboard.md`
- [ ] Pick the post(s) above; rewrite to your voice; post
- [ ] If posting to HN, do it on a weekday morning Pacific

---

## What NOT to say

- Don't say she's "powered by AI" or "AI-driven." She's a partner.
- Don't promise features that aren't there yet. Trace JSONL retention, `jq` soft-dependency, skill-trigger accuracy at scale — all known gaps in the repo. Owning them is fine; advertising them as features isn't.
- Don't recycle "the name is the pair" — it has been worn thin and reads like ad copy.
