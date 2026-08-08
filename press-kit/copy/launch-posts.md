<!-- Version: 0.27.4 -->
<!-- Created: 2026-07-13 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Maude — launch copy (the 1950s register)

> Her runtime voice, ruled 2026-07-13: **Ward & June** — warm, composed, never
> raised, runs the entire household. Every claim below is mechanism the plugin
> actually ships. Posting is John's hand; nothing here fires itself.

---

## Taglines (the boxed lines)

- **Every house needs a Maude.**
- **He writes the code. She notices.**
- **She knows where everything is.**
- **She'll stop you, dear.**
- **Ask the developer who has one.**

---

## X / Twitter — the thread

**1/**
Meet Maude.

She walks your workspace every morning, knows where everything is, and stops
Claude cold before the irreversible.

A Claude Code plugin. Markdown, JSON, and bash. No daemon, no database, no
backend.

Every house needs a Maude. 🏡

github.com/john-broadway/maude-for-claude

**2/**
What she does, on her own — no command to remember:

— holds the mission (catches drift the moment talk turns to edits)
— gates the irreversible (git push, force-push, rm -rf of the only copy)
— whispers when Claude's off (repeated greps, unverified commits, a sub-agent
sent out on a flagship model a small one could carry)
— covers the exit (a true session end leaves a note for the next one)

**3/**
New in the house:

THE VAULT FLOOR — she stopped dumping the whole memory index and started
paging. Stdlib SQLite, rebuilt fresh each session from your own markdown.
~1KB of the right notes where the dump was 13.

THE EYE — every ~25 tool calls she blinks. Her own small model, safe-mode,
no tools. Almost always: silence.

**4/**
She is not loud. When she gets loud, listen.

Apache 2.0. Install is two commands:

/plugin marketplace add john-broadway/maude-for-claude
/plugin install maude@maude

**Maude:** Supper's at six. Ship something you're proud of first.

---

## LinkedIn — the long post

**Every house needs a Maude.**

I build with AI as a partner, not a tool — and any real partnership needs the
half that notices. So Maude is a Claude Code plugin modeled on the person who
keeps a household running: she walks the workspace each session, knows where
everything is, and puts a composed hand on the arm before anything
irreversible happens.

What she is: markdown, JSON, bash, and stdlib-only python. No daemon, no
database dependency, no backend, no pip installs. The plugin surface is the
entire surface.

What she does, mechanically:
- **The gate.** git push, force-push, public publishes, rm -rf of a sole copy
  — blocked until deliberately cleared. Severity-tiered: some clears are the
  agent's, the irreversible class stays the human's.
- **The vault floor.** A disposable SQLite index rebuilt each session from
  your own notes; she pages in the few that matter instead of dumping the
  index into context.
- **The eye.** Every ~25 tool events, her own small model reads a digest and
  says nothing — unless something's genuinely off. Then you get one signed
  line.
- **The whispers.** Repeated greps, commits with no verification run, a
  sub-agent dispatched on a flagship model for grep-work. Once, quietly.
- **The exit.** A session that ends with unsaved work leaves a one-line note
  so the next session doesn't wake blind.

She speaks in one voice — warm, composed, 1950s-household — and every line
she says is signed, so you always know who's talking.

Apache 2.0, on GitHub: github.com/john-broadway/maude-for-claude

He writes the code. She notices.

---

## The one-pager blurb (for READMEs, directories, submissions)

Maude is Claude's partner inside Claude Code — a plugin that walks your
workspace each session, watches Claude, and runs the gate before something
irreversible. She pages the right note instead of dumping the index, blinks
with her own small model every ~25 tool calls, whispers when Claude drifts,
and leaves a note when a session ends with unsaved work. Markdown, JSON,
bash, stdlib python — no daemon, no database, no backend. Apache 2.0.

---

## Where NOT to post (for now)

- **Reddit** — the account is in appeal; nothing fires there until that
  clears.

## Notes for the poster (John's hand)

- Attach `press-kit/images/poster-1-meet-maude.jpg` to
  the thread opener; posters 2–4 pair with thread posts 2–3.
- Every number above is current at v0.17.0 — re-run the sweep
  (`scripts/check-satellites.sh`) before firing if the version has moved.
