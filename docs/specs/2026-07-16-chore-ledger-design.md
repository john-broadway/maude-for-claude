# The chore ledger — Maude's hands (design)

> Date: 2026-07-16 · Status: DRAFT for John's review
> Origin: John's pennies→whole-home arc ("she completes you… she will use your
> remember if you don't… offload it but make sure it gets done"), grounded in the
> verified 1914–1950s research (`docs/research/2026-07-16-homemaker-operations-1914-1950s.md`).

## Era anchor (governs this design and all copy)

Maude draws from the **1914–1950s operations-professional era** — the Extension
Service's home demonstration agents, Christine Frederick's *Household
Engineering* (1919), the flexible-scheduling doctrine of the era's own guidance
literature. Never the fabricated late-60s/70s submissive framing. Copy cites
government sources and official prints only; John's metaphors (shelves, coupons,
the fireplace re-roll) are **his spec-language**, presented as such, not as
claimed history.

## What this is

Until now Maude senses and warns (hooks, gates, the wake brief). The chore
ledger gives her **hands**: the housekeeping that gets lost when nobody types
the command — the save, the shelf pass, the noticing of new method — happens
because she does it, or it appears on the wake brief as undone. **It gets done,
or it's named as undone — never silently missed.**

Her hands are **her own model's runs**: background one-shot blinks
(`claude -p --model ${MAUDE_EYE_MODEL:-haiku}`, the existing eye pattern) or
pure script — never the main session's model, never inside Claude's context.
*With* him present, not *in* him present.

## The spine

**Ledger** — `chores.json` in her closet (`.maude/plugin/`, gitignored). Per
chore: `last_detect`, `due`, `last_run`, `status`
(`done|undone|failed|dispatched`), `note`, `output` (pointer into closet), and
a **cost stamp** (`runtime_s`, `model`, `tokens` when a blink) — the
anti-invisible-labor rule: the era's documented failure was 52–55 unseen
hours/week; every doer reports its own load, so the brief can say what it cost.

**Runner** — `scripts/maude-chores.sh`, three verbs:

| verb | what | caller |
|---|---|---|
| `detect` | run every detector (pure bash, ms), mark `due` | any hook, safe always |
| `dispatch` | for each due chore: `nohup` the doer, per-chore `flock`, stamp `dispatched` | Stop hook |
| `run <chore>` | the doer itself; `trap` guarantees a crash stamps `failed` + reason | dispatch / stage B timer |

**Heartbeat, staged (John's ruling: C — both, session-borne first):**
- **Stage A (this build):** Stop hook → `detect` + `dispatch` (mess is cleaned
  when the session breathes out). SessionStart → `detect` only; the wake brief
  reads the ledger: *"while you were away: save written (haiku, 41s); undone:
  shelf pass (blink failed)."*
- **Stage B (later, John's go):** a systemd timer calls the same runner —
  the heartbeat changes, not one job. Stage B's mature shape is the
  **small-business layer**: cost stamps accumulate into a household budget
  (spend per chore / model / week) she plans against.

**House rules in the spine:** doers never delete — verbatim-move only; all
output passes the existing redaction helper; write boundary holds (closet +
`remember.md`, nothing else, unless a chore's license says otherwise — C1's
does by the remember plugin's own design; C2's re-roll carries an **explicit
widening** John granted 2026-07-16, see C2); **every doer pins its model in the
job definition** — no chore ever inherits the session model (rule earned
2026-07-16, 4th tier-models strike).

## Trust model — flow by default, rigid where complex (John's law)

Not every chore pays a probation period. **Where the pattern is already known,
it flows naturally from day one. Rigid is the deliberate tool for the genuinely
complex, until we know they've got it.** Graduation is judgment reading the
ledger's history — never an automatic counter. The historical arc is the
design arc: rigid trained the nation on new method (1914 canning schools);
rhythm is what the trained home earned (the 1950s home as small business).

| chore | trust at ship | why |
|---|---|---|
| C1 save | **flows** | every part proven in the house already |
| C2 clip + stage | **flows** | read-only; cannot lose a line |
| C2 re-roll | **rigid until known** | files move; starts verbatim-move, tight bounds |
| C3 new-method watch | **flows** | pure read + diff |
| C4 detector | **flows** | report-only |
| C4 md-improve doer | **rigid until known** (stage B) | model judgment over living docs |

## The chores (v1)

### C1 — the save nobody typed (headline)

- **Detector:** `maude_uncaptured_prompts` (existing) ≥ threshold (default 6).
- **Doer (haiku blink):** Stop hook passes `transcript_path`; the blink reads
  the transcript tail and writes the handoff digest (done / decided / open —
  the `/remember` shape). Output: (1) `remember.md` — her one licensed write in
  `.remember/`; (2) closet copy + ledger stamp.
- **Edges:** digest passes redaction before disk. Blink fails → `failed` on the
  ledger, wake brief leads with it. Never rewrites human/plugin content — if
  `remember.md` is fresher than the anchor, append under a dated `## Maude`
  heading, never replace.

### C2 — the shelves and the coupon-cut

The whole-home freshness lifecycle (today's paper → reading shelf → fireplace
pile), over the aging piles she can see (`.remember/` dailies, auto-memory
dailies, aging scratch). Two halves, two trust levels:

- **Clip + stage (flows):** identify pile candidates; before anything is staged
  for re-roll, grep content for live markers (🔴, OPEN, NEXT, TODO, unresolved)
  not represented in a durable file → clip to `coupons.md` in the closet,
  surfaced at wake. Report the staged re-roll list. Read-only.
- **Re-roll (rigid until known):** move aged, covered, coupon-clipped dailies
  **verbatim** into archive (the house compaction discipline — file, never
  burn). v1 bounds: her own closet + `.remember/` dailies only — note this widens
  her old handoff-only license in `.remember/`, granted explicitly by John
  2026-07-16 (*"she will use your remember if you don't… she will also compact
  for you if its time"*); `now.md`/`archive.md`/`logs/`/`tmp/` stay untouched,
  and auto-memory stays report-only until we know. Demotion v1 = simple thresholds (calendar as
  dial); **rhythm demotion (coverage/flow — "it waits for a save, not a
  calendar") is the known pattern and the intended resting state** — v1's
  rigidity is scoped to the *moving of files*, not to pretending the calendar
  is doctrine.

### C3 — the extension agent (new method into the home)

Snapshot the installed plugin/skill/command roster at wake in the closet; diff
against last; brief line: *"new since you last looked: X"*. Pure script. This is
the verified institutional core of the era — delivery of new method into the
home — not a nice-to-have.

### C4 — CLAUDE.md freshness (detector only, v1)

Flag drift: stale header dates, heavy churn around an untouched CLAUDE.md.
Report to brief. The md-improve **doer** (a blink or `claude-md-improver` run)
is stage-B, rigid until known.

## Wake-brief loop (closes every chore)

One line in the brief, always: chores done (with cost), chores undone/failed
(with reason), coupons clipped, new method arrived. The ledger makes the labor
visible — the direct anti-mechanism to the era's documented invisibility.

## Testing

Per-chore bats/pytest in the existing 32-file fleet style: detector triggers at
threshold; dispatch backgrounds + flocks (no double-fire); crashed doer stamps
`failed`; C1 append-never-replace race; C2 clip finds a planted 🔴 in an aged
daily; C2 re-roll preserves every line verbatim (diff empty across
move); model pin present in every doer (grep test — the 4th-strike fence);
redaction applied to blink output (planted marker never lands).

## Out of scope (named, not drifted into)

Stage B daemon/timer; the budget layer; auto-memory re-roll; C4's doer;
rhythm-demotion's graduation call (John's judgment when the ledger shows it);
any persona/voice work — this is hooks, scripts, and a ledger.
