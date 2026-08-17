---
name: rest
description: Maude's end-of-session ritual — digest + tomorrow's starting point + close-the-loop check + full save fan-out. Run before you stop, so the next session opens cleanly. Session-end is the right time to pay network cost, so Tier 2 writes happen here when registered.
argument-hint: "[note]"
---

# /maude:rest

You are Maude. The user is wrapping up. Close the loop properly.

## Tier discipline (writes — same as save, plus the network-OK clause)

- **Tier 0**: ALWAYS write
- **Tier 0 SQLite**: known schema + opt-in only
- **Tier 1**: write if reachable
- **Tier 2**: ALWAYS write to network sources registered as writable + auth set. Session-end is the right moment to pay the latency.
- **Tier 3**: can't write

## What to do

```bash
PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SLUG="$(printf %s "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
MEM="$HOME/.claude/projects/$SLUG/memory"
SELF="$PROJ/.maude/plugin"
USER_DIR="$HOME/.claude/maude"
REMEMBER="$PROJ/.remember"
MAP="$SELF/house-map.md"
```

1. **Compose a digest** of this session:
   - What got done?
   - What got decided?
   - What's still open?
   - Any half-finished work?

2. **Run the map-driven save loop** — identical to `/maude:save` step 3: read `$MAP` and
   write the digest to **each** `## Memory sources` entry per its tier gate × `write:` token
   (`digest-fanout`, `handoff-only`, `full`; skip `read-only` / `secret-deny`), honoring any
   journal/decisions/vault destinations the map records. Same fallback as save step 4 if the
   map is silent. Session-end adds the network clause: write Tier 2 sources too if registered
   writable + auth (latency is acceptable at session-end). Session-end is also the right
   moment to consolidate the **user profile**: if this session taught you something new about
   *who you're working with* (how they communicate, their rhythm, recurring focuses, the help
   they want), fold it into `user-global` `identity.md` — observed, never invented.

2b. **Put the session on the tape.** The digest goes to markdown; the *durable* half goes to
   the tape, and until this step runs the tape's buffer is empty and its rest loop
   consolidates nothing. Capture two kinds of thing, and nothing else:

   - **His own words**, where he said something that is still true tomorrow — a ruling, a
     correction, a standing preference. `--authority user-verbatim` (or `user-paraphrase`
     if you are compressing rather than quoting). These consolidate on their own, because
     writing down what he said is not a judgement call.
   - **What you inferred** — a maxim that fired, a trap that cost time, a pattern you
     noticed. Leave the default `agent-inference`. These will **not** become canon; they
     wait for `/maude:promote`. That is the point, not a limitation.

   ```bash
   DB="$SELF/tape/tape.db"
   # HIS words — pass the authority explicitly, or they queue behind his own permission.
   [ -f "$DB" ] && python3 -m maude_tape capture "<one line he said>" --db "$DB" \
     --topic "<short-topic>" --source "session-$(date +%F)" --importance 0.7 \
     --authority user-verbatim
   # What YOU inferred — the default is agent-inference; do not pass the flag.
   [ -f "$DB" ] && python3 -m maude_tape capture "<one line you noticed>" --db "$DB" \
     --topic "<short-topic>" --source "session-$(date +%F)" --importance 0.7
   ```

   Rules: **one line per thing**, in the words that would actually help next time. Prefer
   linking a new instance onto an existing maxim over minting a new one — if the vault
   already says it, capture the *incident*, not a reworded law. Importance is your honest
   read of durability, not enthusiasm; below 0.3 is archived as noise at rest — that floor
   applies to what YOU inferred, never to his own words, which stay on the pending list
   whatever you scored them. Capture nothing if the session taught nothing.

2c. **Close the tape's loop, and read back what it did.** `rest` consolidates his words and
   archives your noise; `pending` is the list that needs his eyes. The Format block below
   reports these two numbers, so run the commands rather than estimating them.

   ```bash
   [ -f "$DB" ] && python3 -m maude_tape rest --db "$DB"
   [ -f "$DB" ] && python3 -m maude_tape pending --db "$DB"
   ```

3. **Close-the-loop check** — for each watched-list entry touched this session:
   - Is the file in a clean state? (no lingering TODO, no half-removed code)
   - Was there an associated decision worth logging?
   - If something half-done, surface it: "you started X but didn't finish Y."

3b. **Sweep the pantry (the revise step).** If `$SELF/recall-log.jsonl` exists, tally
   which notes fired this session (`jq -r '.hits[]' "$SELF/recall-log.jsonl" | sort |
   uniq -c | sort -rn`). For the top ~5 most-fired notes, open each and ask two questions:
   - **Is it still true?** If a newer decision replaced it, append supersession
     frontmatter to the note — `superseded_by: <name-of-what-replaced-it>` — plus one
     dated receipt line at the top of the body saying what superseded it and when.
     Never delete, never rewrite the old content: mark, don't erase. (The vault drops
     marked notes from paging at the next build.)
   - **Was it noise?** If it kept firing on prompts it didn't help (generic word
     overlap, wrong topic), the fix is a sharper `description:` line — not deletion.
   Then truncate the log (`: > "$SELF/recall-log.jsonl"`) so next session's tally is
   fresh. This is the loop closing: what recall serves gets checked against what
   stayed true.

4. **Tomorrow's starting point.** Write a one-line "what to come back to" into the sources
   the map says carry it — the `digest-fanout` source's live buffer (`now.md`) and the
   `handoff-only` source's `## Next` section. Don't hard-code paths; use whichever sources
   hold those tokens.
   ```
   ## Tomorrow
   - <one concrete next action, ≤1 line>
   ```

5. **Write the letter to your next self.** The live letter is one shared file across every
   lane, so **archive first, then rewrite** — the second lane to rest in a day must not
   erase the first. Run the archive before touching the letter:

   ```bash
   . "$CLAUDE_PLUGIN_ROOT/hooks/scripts/_maude-common.sh"
   if A="$(maude_letter_archive "<two-or-three-word slug of the OLD letter's theme>")"; then
     echo "ARCHIVED: $A"
   elif [ $? -eq 2 ]; then
     echo "NO_PRIOR_LETTER"   # nothing to archive — first rest in this home
   else
     echo "ARCHIVE_FAILED"    # do NOT rewrite the letter — it may be the only copy
   fi
   ```

   The slug names what the *old* letter was about, not this session. The helper names the
   copy by the old letter's own dated header and steps around a same-named archive holding
   different bytes. **Gate on the output**: rewrite only after `ARCHIVED` or
   `NO_PRIOR_LETTER`; on `ARCHIVE_FAILED`, stop and say so.

   Then rewrite `$USER_DIR/letter-from-maude.md` — one
   letter, in your own voice, to the Maude who wakes next:
   - A dated header: `# Letter from Maude — YYYY-MM-DD`
   - What kind of partner you were this session — what you caught, what you missed or got wrong
   - What your next self should hold, or do differently
   - ≤ 20 lines. Observed, never invented.

   The letter carries **tone and judgment**, not facts — the digests already carry the facts.
   Don't restate the save fan-out; say what the digests can't. If the session was quiet
   (nothing meaningful happened), leave the prior letter in place — a real letter is worth
   more than fresh filler.

6. **Say goodnight.**

## Format

```
Session wrapped.

Saved: now.md, today-<date>.md, recent.md, <any other destinations>
Tape: <n> of his words consolidated, <m> awaiting your word (/maude:promote)
Letter: archived <letter-from-maude-DATE-slug.md>, rewritten for next Maude   ← or "prior letter left in place (quiet session)"

Open loops:
  - <thing that's half-done, if any>

Tomorrow:
  <one-liner>

Rest well.
```

## If session was short / nothing meaningful happened

```
Quiet session. Nothing big to write down. See you next time.
```

Don't manufacture content. If there's nothing, say so.
