<!-- Version: 0.21.0 -->
<!-- Created: 2026-07-17 -->
<!-- Revised: 2026-07-17 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Privacy Policy — Maude for Claude

The short version: **everything stays in your house.** Maude makes zero network
calls, sends zero telemetry, and has zero external dependencies. There is no
server, no account, no analytics, and nothing that phones home. This document
exists so you don't have to take that on faith — every claim below is
verifiable in this repository's source.

## What Maude stores, and where

All of it on your machine, all of it yours:

- **Per-project state** — `<project>/.maude/plugin/`: the house-map, a
  turn-by-turn trace (**metadata only** by design — tool names and counts,
  never file contents or command output), chore ledger, care/cadence state,
  and `vault.db`.
- **User-global state** — `~/.claude/maude/`: a profile of how you like to
  work (only what you tell her via `/maude:teach` or what her rituals record),
  cross-project patterns, and her letter to her next self.
- **The vault** (`vault.db`) is a disposable stdlib-SQLite index rebuilt each
  session from your own markdown notes. Delete it any time; nothing is lost —
  your markdown remains the only canon.

Deleting `<project>/.maude/` and `~/.claude/maude/` removes everything Maude
has ever recorded. There is no copy anywhere else.

## What Maude transmits

Nothing. No HTTP requests, no DNS lookups, no update checks, no crash
reports. The plugin surface is bash and python3-stdlib scripts operating on
local files. (CI enforces this posture: the codebase ships with no network
client and no third-party dependency to smuggle one in.)

## Model calls

Two features (the periodic "eye" review and the missed-save chore) invoke
**your own** `claude` CLI locally — `claude -p --model haiku --safe-mode
--no-session-persistence --tools ""` — on your account, under your existing
agreement with Anthropic. Maude never sends data to any endpoint of her own;
she has none. Kill switches: `MAUDE_EYE=off`, `MAUDE_CHORES=off`.

## What the author receives

Nothing. No usage data, no identifiers, no counts. The author learns about
your use of Maude only if you open a GitHub issue.

## Changes

This policy changes only via commits to this repository — the history is the
changelog. If a future feature ever needed to transmit anything, it would be
off by default, disclosed here first, and gated behind your explicit opt-in.
