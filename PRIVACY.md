<!-- Version: 0.24.0 -->
<!-- Created: 2026-07-17 -->
<!-- Revised: 2026-07-22 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Privacy Policy — Maude for Claude

The short version: **everything stays in your house.** Maude contacts no
remote host, sends zero telemetry, and has zero external dependencies. There
is no server, no account, no analytics, and nothing that phones home. This
document exists so you don't have to take that on faith — every claim below
is verifiable in this repository's source, and this policy was corrected once
(2026-07-17) when an independent review found its first draft overstated;
the diff is in the history.

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
has ever recorded. There is no copy anywhere else. (One opt-in exception,
off by default: the `MAUDE_REROLL=on` chore moves your own aging
`.remember/today-*.md` notes into `.remember/archive/` — your files, moved
not copied, inside your project.)

## What Maude transmits

Nothing to any remote host. No requests to any server, no DNS lookups, no
update checks, no crash reports. Stated precisely rather than rounded: at
session start she probes a few **loopback-only** ports (`127.0.0.1` —
redis/qdrant/neo4j-shaped local dev services) to detect what's running in
your own house; no name resolution, no payload, nothing beyond your machine
(`hooks/scripts/maude-probe-tier1.sh` — read it), and `MAUDE_PROBE=off`
turns it off entirely — no sockets, no cache. Beyond that, the plugin
surface is bash and python3-stdlib scripts operating on local files. There
is no dedicated CI gate asserting "no network client" — the claim is
verifiable by inspection: no HTTP library is imported anywhere and the repo
carries no dependency manifest to smuggle one in.

## Model calls

Two features (the periodic "eye" review and the missed-save chore) invoke
**your own** `claude` CLI locally — `claude -p --model haiku --safe-mode
--no-session-persistence --tools ""` — on your account, under your existing
agreement with Anthropic. Maude never sends data to any endpoint of her own;
she has none. Kill switches: `MAUDE_EYE=off`, `MAUDE_CHORES=off`,
`MAUDE_PROBE=off` (the loopback liveness probe).

## What the author receives

Nothing. No usage data, no identifiers, no counts. The author learns about
your use of Maude only if you open a GitHub issue.

## Changes

This policy changes only via commits to this repository — the history is the
changelog. If a future feature ever needed to transmit anything, it would be
off by default, disclosed here first, and gated behind your explicit opt-in.
