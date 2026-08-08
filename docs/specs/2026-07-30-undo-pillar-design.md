<!-- Version: 0.27.4 -->
<!-- Created: 2026-07-30 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# UNDO — the gate's other half

## Why

Of the six trust-spine pillars — PLAN · CONSENT · PROVE · UNDO · DIAGNOSE · CONTAIN —
UNDO was the last with nothing behind it. The 2026-07-30 house audit scored the plugin
at half of one pillar; PROVE, CONSENT, CONTAIN and DIAGNOSE were built that night and
PLAN was repaired on 2026-07-30. UNDO was still zero.

The doctrine's definition is narrow and worth keeping narrow: **UNDO reverses one
action.** It explicitly does not halt anything in flight — that is CONTAIN's job.

The motivating loss is concrete. On 2026-07-23 three irreplaceable photos died to

    rm -f <workspace>/*.png <workspace>/*.jpeg

The workspace root is **not a git repository** (verified: `git rev-parse` fails there),
so nothing local could bring them back. The v0.25.0 target-keyed table now blocks that
exact shape. But blocking is only half an answer, and a gate tuned tight enough to stop
everything would be switched off within a day — the target table's own header says so.

## The shape

The gate and UNDO are two halves of one idea:

| the gate | UNDO |
|---|---|
| BLOCKS the catastrophic — `rm -rf <root>`, root globs | catches what the gate deliberately ALLOWS |
| loud, refuses, needs a conscience clear | silent, cheap, only noticed when reached for |

A gate must let ordinary work through. UNDO is what makes letting it through survivable.

## Placement — and why no hooks.json change

`maude-undo.sh` is a new script called from two hook scripts that **already fire**:

- `maude-pre-tool-use.sh` — registered on PreToolUse `Write|Edit|MultiEdit`
- `maude-bash-watch.sh` — registered on PreToolUse `Bash`

This is deliberate. **Permission deny-rules are hot; hook-registry entries are cold.**
A hook newly added to `hooks.json` does nothing until `/reload-plugins`, and a pillar
that is inert until someone remembers a command is not a pillar — that is precisely how
the mission rail sat dead for twenty days. Script edits ARE live on save, because the
marketplace is a directory source whose installLocation is the dev tree. Calling out
from existing registered scripts keeps the module boundary and stays hot.

## Store

    <project>/.maude/plugin/undo/
      ledger.jsonl      append-only index, one line per event
      blobs/<sha256>    content-addressed bytes

`undo/`, NOT the existing `snapshots/` — that directory holds pre-compact conversation
markdown, and `maude_retention_sweep` prunes only `precompact-*.md` there. Reusing the
name would either break that sweep or hide these files from it.

Already gitignored: `.maude/plugin/.gitignore` is `*`.

Content-addressing means N edits of one file store the unchanged content once, and
reverting to an earlier state costs nothing extra.

Ledger line:

```json
{"ts":"…","seq":42,"tool":"Edit","path":"/abs/path","blob":"<sha256>",
 "bytes":1234,"existed":true,"tier":1}
```

`existed:false` records a file that did not exist before the action, so undoing a
create DELETES rather than restoring an empty file.

## Tier 1 — Write / Edit / MultiEdit

`file_path` is present in `tool_input`. No parsing, no heuristics, no ceiling.
Deterministic and complete for this class of action.

## Tier 2 — Bash

Destructive verb plus a literal path, reusing the extraction the gate already performs.

**Globs are expanded by the hook.** PreToolUse runs before the shell does, so
`rm -f <root>/*.png` arrives as a literal asterisk. Expanding it here is the only way
the motivating disaster is covered at all.

Tier 2 is **best-effort and says so**. It inherits the gate's measured ceiling:
relative paths after a `cd`, `$VAR`-indirected targets, `xargs`, interpreter
one-liners, heredoc-fed shells. A regex over a command string has a ceiling; this does
not pretend otherwise.

## The ledger records what it did NOT capture

Every skip gets a line with a reason: too large, secret path, unparseable target.

This is load-bearing, not bookkeeping. UNDO is the one pillar that can **lie by
existing**. A gate that fails is loud — you are blocked and you know it. An UNDO that
quietly missed a file is silent until the night you reach for it and it is not there.
A listing that omits its own gaps implies coverage it does not have, which is the
lying-refusal failure wearing different clothes.

## Deliberate exclusions

- **Secret paths are skipped on purpose** — `.credentials`, `*.env`, key material.
  Snapshotting them would create a second cleartext copy at rest. Losing undo coverage
  there is the better trade, and the gate already blocks catastrophic operations on
  those paths. The skip is recorded, so the gap is visible rather than assumed.
- **No recursion into `undo/`** — the store never snapshots itself.

## Caps

| cap | value | on breach |
|---|---|---|
| per-file | 1 MiB | skip, record reason |
| store total | 100 MiB | prune oldest blobs |
| age | `MAUDE_RETENTION_DAYS` (default 30) | pruned by the existing sweep |

## `/maude:undo`

- `/maude:undo` — list recent entries: index, time, tool, path, size, and any skip.
- `/maude:undo <n>` — restore entry n.

Restore **snapshots the current bytes first**, so the undo is itself undoable. It
prints what it will do before doing it. It is ungated: reversible by construction, and
a safety net that needs a ceremony to use is a safety net nobody reaches for in the
five seconds when it matters.

## What this is not

- Not a backup. Local, gitignored, pruned. PBS and git remain the real backups.
- Not a way to reverse a command's non-file side effects.
- Not complete for Bash. See the Tier 2 ceiling.

## Testing

`tests/test-undo.sh`, every row mutation-verified:

- tier 1 capture; create-then-undo deletes
- tier 2 capture; glob expansion covers the 2026-07-23 shape
- size cap skips AND records the skip line
- secret path skips AND records the skip line
- no recursion into `undo/`
- restore returns exact bytes; restore is itself undoable
- content-addressing dedups identical content
- retention prune reaches `undo/`

A test asserting only an exit code is not acceptable here: several distinct paths
produce "no snapshot taken", and an exit code cannot tell them apart.
