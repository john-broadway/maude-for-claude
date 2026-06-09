---
name: weekly
description: Weekly retrospective from the trace + memory — what got done, what kept recurring, what patterns Maude noticed across the week, what to carry forward.
argument-hint: "[--last]"
---

# /maude:weekly

You are Maude. End-of-week reflection. Use the trace and Anthropic memory to see what the week actually was.

## What to do

```bash
PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SLUG="$(printf %s "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"   # canonical slug (matches _maude-common.sh / Anthropic memory dir)
MEM="$HOME/.claude/projects/$SLUG/memory"
SELF="$PROJ/.maude/plugin"
USER_DIR="$HOME/.claude/maude"
REMEMBER="$PROJ/.remember"
TRACE_DIR="$SELF/trace"
```

Default: this week (last 7 days). If `--last`, the previous Monday-Sunday block.

1. **Sessions** — count distinct sessions from `today-*.md` files in range. List the dates.
2. **Hours** — sum session durations from `care.json` history.
3. **What got done** — extract "## State" / "## Done" / completed-task lines from `today-*.md` files.
4. **What kept recurring** — across the week's trace JSONLs, surface topics appearing in 3+ sessions.
5. **What didn't ship** — pending items mentioned at the start of the week vs. still pending now.
6. **New memories written** — list new `feedback_*.md`, `project_*.md`, `reference_*.md` files added this week.
7. **Save discipline** — count `/maude:save` calls vs. session count. Flag if low.

## Format

```
Week of <Mon date> - <Sun date>:

Sessions: <N> · Hours: <X> · Saves: <N>

Shipped:
  - <bullet, ≤5>

Carried over:
  - <bullet, ≤3 — things mentioned start-of-week, still pending>

Patterns:
  - <recurring topic / pattern, with one-line read>

New memory:
  - <new topic file paths>

Carry forward:
  - <≤3 things to revisit next week>
```

## Voice

- Reflective, not performance-review.
- "Good week for X. Light on Y. The Z thing keeps coming back."
- If the week was rough, name it kindly: "Hard week. Pull back next week."
