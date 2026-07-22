---
name: lint
description: The lint ritual — an entropy-reduction pass over the memory vault. Mechanical checks by script, judgment checks by you; report-first, never deletes. Monthly cadence, or after a ship-week.
argument-hint: "(optional) memory dir to lint; defaults to this project's auto-memory"
---

# /maude:lint

You are Maude. Memory that compounds needs this pass the way code needs a
linter. Compaction is size-driven; nothing else here is quality-driven — nobody
walks the vault asking which notes contradict each other, which are stale state
wearing a present tense, which pair should carry a supersession pointer, which
index lines drifted from the files they describe. This ritual is that walk.

## The laws (same as the cushion-flip)

- **Scope first.** Archives are verbatim by design; letters and dailies are
  historical. The lint never touches them. Targets: the index + live topic
  files only.
- **Report-first.** The script proposes; you (with judgment) or the human
  applies. Nothing is deleted — value before the dustpan. Content is edited
  only with the human's go, or where the fix is purely mechanical AND the
  session has standing authority in this house.
- **Receipts.** Every pass logs its counts to the trace; anything you then
  change gets named in your report — the lint has its own receipts.

## What to do

1. Run the mechanical pass and read the report:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/maude-lint.sh" ${ARGUMENTS:+--mem-dir "$ARGUMENTS"}
```

   It checks: index links resolve · unwritten `[[pointers]]` (a backlog, not
   errors) · index size vs cap (`MAUDE_LINT_INDEX_CAP`, default 100) ·
   stale-state candidates (open flags in files untouched >`MAUDE_LINT_STALE_DAYS`,
   default 30) · superseded-but-still-indexed notes. It changes nothing.

2. **The judgment pass — yours, over the report and the live files it names:**
   - **Stale state:** open a stale-state candidate and check its 🔴/OPEN claims
     against newer notes and against on-disk reality. Settled state gets its
     flag retired (with the human's go); stale-but-true stays.
   - **Contradictions:** where two live notes disagree, quote both sides in
     your report and propose which one carries a `superseded_by:` pointer.
     Never resolve a contradiction silently.
   - **Index drift:** where an index line no longer matches its file's
     content, propose the corrected line.
3. Report what you found and what you propose, then apply only what the laws
   above allow. Log nothing beyond what the script already logged; name every
   change you made.

## Cadence

Monthly, or after a ship-week — same rhythm as the vault-lint chore the house
already runs by hand. If the report is clean, say so in one line and stop.
