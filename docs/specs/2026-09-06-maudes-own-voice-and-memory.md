# Maude's own voice and memory, held to her own laws

John, 2026-09-03 03:59Z: "have you applied the laws to maude." John, 2026-09-06 14:52Z:
"the last thing i remember asking you over 4 sessions ago was have we applied the laws to
maude not just added them to her."

The honest answer on 09-06 was: added. The rulebooks shipped, the rail whispered on other
people's schemas, the spec named the laws the rail's own whispers were built to, and nobody
had pointed the rail or a lens at Maude herself. Her schema linter read zero over her own
tables because it could not see them; her UI rail classified `app.css` and was silent on
`maude-gate.sh`; no lens had ever been handed her 89 speaking lines or her four stores with
the laws as its brief. This document exists because, on 2026-09-06, two lenses were, and
the rail was pointed at her. It names only what a lens saw honoured or what this wave
fixed with a red-first control. Nothing here is named on a path that was never drawn.

Reports (off-tree, the author's scratch): `.scratch/maude-laws-applied-2026-09-06/ux-lens.md` (7 defects, 5 notes, 11
honoured) and `memory-lens.md` (11 defects, 6 notes, 24 honoured), both opus, both
read-only on her, both closing with "not applied, and here is what would make it true."

## UX laws

Her user interface is a whisper line on stderr, a refusal, and a command's `## Format`.
The rail now classifies all three as UI surfaces (a script that prints to the person's
stderr; a command file with a Format section), so a session that edits them touches
`ui` and owes this section. The laws her surfaces hold to, by name, and where:

- **Doherty Threshold** and **Flow**: every per-turn hook answers well inside four
  hundred milliseconds (lens H1, measured). The wake brief lands again: the retention
  sweep was 33 s on the dev box and ran before the brief, so the harness killed the hook
  at 10 s at every session start for weeks; it is one jq pass now and runs after the brief
  is printed and billed. A hook that says nothing until it is done past the threshold is
  the SessionStart chain at 668 ms (lens N3), filed, not fixed.
- **Postel's Law**: forty-four malformed-input runs, forty-four clean exits (lens H2).
- **Von Restorff Effect**, **Law of Similarity**, **Law of Prägnanz**: a red refusal now
  opens with `Maude [RED]:`; a yellow one keeps `Maude:`. Before, the only discriminator
  was a file name in a parenthetical (lens D3). The credential warning remains the one
  surface that deliberately breaks shape (lens H3).
- **Mental Model**, **Jakob's Law**: the token behaves exactly as its sentence says (lens
  H4); a red refusal no longer tells the person to run the yellow self-clear (lens D2),
  and the red script's paste line runs the red script (lens D1).
- **Zeigarnik Effect**, **Goal-Gradient Effect**, **Paradox of the Active User**: every
  yellow refusal names a typeable next action (lens H7); every red refusal now names
  whose hand it is and the command that shows the line to paste; a pass on a live token
  is spoken, so a spent token leaves a trace on screen (lens N4).
- **Serial Position Effect**, **Working Memory**, **Peak-End Rule**: the wake reads the
  tail of every append-only file and dates what it read (the handoff's age, the map's
  walk date); before, it presented a three-week-old handoff as "Last" beside a fresh
  line with nothing to tell them apart (lens D4). The undo listing is newest first and
  bounded to ten, with `restore last` for the common case (lens D7). The `## Format`
  sections of `commands/*.md` are the one place the laws were visibly held all along
  (lens H5): three named chunks, one or two things prioritised, "don't dump."
- **Occam's Razor**, **Cognitive Load**: the empty-state wake brief is four lines and
  every non-greeting line is an action (lens H9).
- **Mental Model**, **Zeigarnik Effect**, **Goal-Gradient Effect** (after the 23rd lens,
  2026-09-06, each with a red-first control): a pass on a token says when the token is
  spent (when the command runs, not when the gate lets it through), and a token another
  session holds, or one the gate could not record, is refused in those words rather
  than "go get a token"; a lens launched in the background is a PENDING stamp until the
  agent stops, the commit whisper says a lens is pending, and the wake names one that
  never reported; a MEMORY.md written past Claude Code's load limit is told its size,
  the limit, and the action, at the write.
- **Tesler's Law**: the sentence every red refusal ends with lives in one function; the
  touch a surface records lives in one function; the lock every hook's shared state
  file needs lives in one function. Not yet: scripts/maude-chores.sh keeps two locks of
  its own (a ledger lock with its own race test, and a try-lock held for a doer's
  lifetime, a different shape); folding the first is filed (the 23rd lens, MINOR-3).
- **Chunking**, **Miller's Law**, **Law of Proximity**, **Law of Common Region**: NOT yet
  honoured on one prompt. Up to five identically prefixed `Maude:` lines can land on one
  UserPromptSubmit, one of them a credential compromise, none grouped, none ordered by
  consequence (lens D5). The fix shape is an aggregator that emits one bounded block; it
  is a new mechanism and waits for John's word.
- **Hick's Law**, **Choice Overload**: `/maude:rules ux` prints thirty undifferentiated
  choices while carrying the family that would chunk them (lens N1); filed.
- Not applicable to a stderr surface, said so by the lens: Fitts's Law, Law of Uniform
  Connectedness, Cognitive Bias, Parkinson's Law.

## Laws of memory

Her memory is the tape (canon, events, voice, rejections), the vault mirror, the state
file, and the user-global files. The laws it holds to, and the debts, by name:

- **The log first**, **Cache invalidation**: the state file is written under a lock and
  read back before the write is reported; a gate token is read and consumed in one locked
  step (lens DEFECT-4, fixed). The pre-compact hook appends a dated handoff and reads its
  stamp back before claiming it, where it truncated a 31-handoff file before (DEFECT-3,
  fixed). The letter archive already archived before overwrite and read the copy back
  (lens, honoured).
- **A window is not a history**, **Recency and primacy**: the wake reads the newest
  handoff and the newest buffer entry and says their age; the snapshot keeps the last 200
  lines and its header says "last N of M" (DEFECT-1, DEFECT-2, fixed). The house-map tick
  carries the map's walk date and age instead of asserting a currency the file never
  claimed (DEFECT-10, fixed).
- **Supersede, never erase**: canon retires by pointer, the buffer archives by status,
  nothing in the package deletes a row (lens, honoured); the one erasure path was the
  pre-compact handoff and it is closed.
- **Promotion is his**, **Reconstruction and impurity**: an inference never
  auto-consolidates (lens, honoured). The label that gates auto-promotion was typed by
  the agent, and 141 of 152 consolidated rows reached canon on it with no pointer to the
  utterance (DEFECT-8); the fix is a pointer into the voice table for a verbatim capture,
  and a verbatim capture the tape cannot point at waits for his hand. See the tape commit.
- **Jost and Ribot**, **Governed consolidation**, **Remember the decision**: canon had no
  time and promotion threw the event's time away (DEFECT-7); canon carries `ts` now and the
  wake prints it. What is not yet honoured: no consistency check before consolidation, so
  five current rows can share one topic with nothing marking the later ruling (N-6).
- **Working memory is small**, **Cue overload**, **Locality**: NOT honoured. The wake plays
  every current canon row, 161 of them, 17.8 KB, and the three cue-driven recall engines
  have no production caller (DEFECT-5). John's own words for the tape are "nothing cut,"
  and paging canon at the prompt would cut it; the lens's shape (page canon through
  recall_relevant the way the vault pages markdown) is his call, not a fix.
- **Little's law**, **The five-minute rule**, **Bélády**: the buffer held 317 rows, the
  oldest 19.6 days, and the forget floor of 0.3 was unreachable against a distribution
  whose minimum is 0.4 (DEFECT-6). The pending list is now ordered his words first, newest
  first, so the five verbatim lines stuck among 312 inferences lead it; the thresholds were
  assumed, not measured, and cutting them is his.
- **The index is not the content**: the vault stored every note body twice, in `notes`
  and again inside a plain FTS table, 35.8 MB for 16.5 MB of markdown, and `notes.body`
  had no reader (DEFECT-9); the FTS table is external-content now and the body is stored
  once. The vault's `description` is still content, the note's first line when no
  description exists (lens, noted).
- **Cache invalidation** at the pager: the mirror served a body 849 s behind the file on
  disk with no signal (DEFECT-11); a hit whose file is newer than its index row is marked
  stale at the prompt.

## Normal forms

The linter sees her own tables since `36beeee` (an internal-tree sha): a document column named `json`, an
embedding stored as text, a link list, and a `superseded_by` integer with no REFERENCES
are the four asks her live schemas raise, each answered in the rules-rail design's
section 8a, and her two schema files are a test control. Canon gains a `ts` column by
the same in-place migration `embedding` used; a Codd 10 constraint on `superseded_by`
would need the table rebuilt on every adopter's tape and stays a stated debt.

## What would make "applied" a true sentence

Everything above that says "fixed" has a red-first control in the tree. Everything that
says "filed", "not yet honoured", or "his" is open by name: the whisper aggregator (D5), the
wake that plays the whole store (DEFECT-5, his "nothing cut"), the consolidation
consistency check (N-6), the thresholds (DEFECT-6), `/maude:rules ux` chunking (N1), and
the SessionStart chain's 668 ms (N3). A lens on the next tip is what says whether the
fixed ones hold; this document says only what was looked at.
