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
```

1. **Compose a digest** of this session:
   - What got done?
   - What got decided?
   - What's still open?
   - Any half-finished work?

2. **Run the full save flow** (same logic as `/maude:save`):
   - Anthropic auto-memory: `$MEM/now.md`, `$MEM/today-$(date +%Y-%m-%d).md`, `$MEM/recent.md` (if `$MEM` exists)
   - **remember.md handoff** (if `[ -d "$REMEMBER" ]`): write the digest to `$REMEMBER/remember.md` in remember's handoff format (`## State` / `## Next` / `## Context`, ≤20 lines)
   - Other house-map destinations (journal, decisions, vaults)
   - Cross-project state (`$USER_DIR/patterns.md`, `$USER_DIR/projects.json`)

3. **Close-the-loop check** — for each watched-list entry touched this session:
   - Is the file in a clean state? (no lingering TODO, no half-removed code)
   - Was there an associated decision worth logging?
   - If something half-done, surface it: "you started X but didn't finish Y."

4. **Tomorrow's starting point.** Write a one-line "what to come back to" — in `$MEM/now.md` AND in `$REMEMBER/remember.md`'s `## Next` section:
   ```
   ## Tomorrow
   - <one concrete next action, ≤1 line>
   ```

5. **Say goodnight.**

## Format

```
Session wrapped.

Saved: now.md, today-<date>.md, recent.md, <any other destinations>

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
