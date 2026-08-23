<!-- Version: 0.30.0 -->
<!-- Created: 2026-06-18 CDT -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Mission-Hold Rail — design

> **Historical design doc (2026-06-18).** Captures the design *as planned*; kept for the
> reasoning, not as current reference. Command names and counts here (e.g. "17 → ~5 + 4 cut",
> `check-setup`, `dual-voice`) reflect the plan at that moment — the shipped surface is **9
> commands** (see the README / SKILL for the current list). Rots in place by design.

## The one rule (the problem)

Claude loses the **established mission** within a few turns — intermittently, both *after
wake* (the session's objective fades) and *mid-session* (a fresh objective fades). Wanders
"out to left field." This is the #1 partnership failure John named, and the same shape that
talked a prior session off its correct simple plan.

## Principle

Maude's only honest job: move a chosen rule from the **probabilistic** column (text in
memory the model *might* weight) to the **deterministic** column (code that *fires* at the
moment). A rule that has to be *called* is a rail with the auto-fire ripped out. So: rails,
not commands.

**The go-state is the hinge.** The instant Claude flips from *thinking* to *doing* is when
the mission is both most concrete and most at risk. That one observable event does the work
— no human types or untypes a pin.

## The rail — one pin, three touches, self-clearing

**Store.** A `.mission` field in the existing `care.json`, written through the existing
`maude_care_set` atomic helper. Throwaway, session-scoped. No new file, no new write path.

```
.mission = { text: "<one line>", set_by: "plan|todo", set_at: <epoch> }
```

1. **Capture** *(mission-level, automatic, sticky).* A hook reads the payload of the two
   tools where the objective already exists as structured data:
   - `ExitPlanMode` → the plan text.
   - `TodoWrite` / `TaskCreate` → the task list (first/active item).
   Only these mission-level events set/replace the pin — so it stays the *through-line*,
   not "the last little thing I touched."
2. **Hold** *(every turn).* `maude-user-prompt-submit.sh` injects `MISSION: <text>` on every
   `UserPromptSubmit`. The anti-fade — fixes "even after wake," because a re-injected line
   can't scroll out of view.
3. **Verify** *(every action-flip — the catch).* When Claude touches `Write`/`Edit`/`Bash`
   after a read-only/talking stretch (the trace sees the flip), a whisper fires — modeled on
   the existing `maude-verify-watch.sh`: *"this action — still `<mission>`, or did you
   wander?"* If no pin is set, it flips to *"no mission set — what are you doing, and is it
   where we started?"* Once per flip (cooldown), never blocks.

**Self-clear.** `SessionStart` wipes `.mission` (NOT `Stop` — it fires every turn and would
erase the pin mid-session); the next mission-level event replaces it. John never types, never
untypes. The transitions maintain it.

## Honest seams (no overselling)

- Detecting the flip is **deterministic** (the `ExitPlanMode`/`TodoWrite` tools; the
  read-only→mutate flip from the trace).
- *Auto*-capturing the mission **text** only works from the plan/todo payloads. A bare
  action-flip with no pin falls back to forcing a one-line declaration — event-reminded,
  not "Claude-remembers-to," but reliable, not ironclad.
- The verify **judgment** is Claude's; the hook supplies the timing + the pinned mission.
  The power is forced adjacency at the right moment.
- **No drift-detector / no trace-complexity scoring / no LLM-judge.** Rejected on purpose —
  it wouldn't catch a pure-prose drift and it re-enacts the over-engineering this fixes.

## Out of scope / non-goals

No Python, no daemon (Maude locked decision #4). No new files beyond the `care.json` field.
No semantic comparison of action-vs-mission in bash.

## Tests (TDD — extends `tests/` harness)

- capture: `ExitPlanMode` payload → pin set.
- capture: `TodoWrite` payload → pin set (first/active task).
- sticky: a `Write`/`Edit` does **not** overwrite the pin.
- hold: `user-prompt-submit` injects `MISSION:` line when a pin exists; silent when none.
- verify: action-flip after a talk stretch whispers once; cooldown holds for the rest.
- fallback: action-flip with no pin → the "what are you doing?" whisper.
- clear: `SessionStart` wipes `.mission`.

## Build order

1. `care.json` `.mission` field + helper read/write (reuse `maude_care_set`).
2. Hold injection in `maude-user-prompt-submit.sh`.
3. Capture hook(s) on `ExitPlanMode` + `TodoWrite`.
4. Verify whisper on the action-flip (trace-read, verify-watch pattern).
5. Clear on `SessionStart` (not `Stop` — it fires every turn).

---

## Winter weight (companion trim — the same principle, applied to Maude herself)

17 commands → **~5 commands + silent rails + 4 cut.** Order: **rail first, cuts second** (a
rail that fires is the proof; cutting is the easy part once nothing depends on it).

**Becomes a rail** (retire the command): `wake` (SessionStart), `found` (SessionStart if
stale), `save`/`rest` (Stop + PreCompact), `check-on-me` (care cadence),
`check-on-claude`+`notice` (UserPromptSubmit/PostToolUse), `remind-me` cheap (topic-match
injection), `weekly` (SessionStart cadence).

**Stays a command** (deliberate, has a consequence): `conscience` (the gate's valve),
`teach` (deliberate input), `verify` (readiness gate), `sweep` (deep audit),
`remind-me --deep` (expensive recall).

**Cut** (ceremony / duplicate / obsolete): `brief` (dup of the wake rail), `where-is`
(answered by asking + the house-map), `check-setup` (folds into `sweep`), `dual-voice`
(obsolete under "voiced on signal" — the rail that catches is what speaks).
