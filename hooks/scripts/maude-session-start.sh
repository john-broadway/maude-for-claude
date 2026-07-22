#!/usr/bin/env bash
# Maude session-start hook — degradative brief across every reachable memory source.
# Reads: Anthropic auto-memory, .remember/, user-global home, house-map.
# Never blocks startup. Each missing tier is silently skipped.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
USER_DIR="$(maude_user_dir)"
REMEMBER="$PROJ/.remember"
MAP="$(maude_map_path)"

# ── Once-per-session housekeeping ────────────────────────────────────────────
# SessionStart is the once-per-start hook (it fires at each start/resume/clear/
# compact, not per turn), so it's the natural chokepoint for:
#   1. Pruning append-only artifacts (trace JSONL, pre-compact snapshots) past
#      the retention window — they grew unbounded before.
#   2. A single jq-missing notice. Without jq the irreversible-command gate is
#      fail-OPEN (silently disabled), and drift-watch / tier-1 / watch-list
#      nudges are off too. This is a SAFETY notice, not cosmetic — so it must
#      fire even when there's no memory to brief (i.e. before the early-exit).
maude_retention_sweep
if ! command -v jq >/dev/null 2>&1; then
  printf 'Maude: jq not found — the irreversible-command gate is OFF this session (fail-open), and drift-watch, tier-1, and watch-list nudges are disabled. Install jq to restore them.\n' >&2
fi
case "${MAUDE_RUN_GOVERNOR:-on}" in
  off|OFF|0|false|no|NO)
    printf 'Maude: run-governor is OFF this session (MAUDE_RUN_GOVERNOR=%s) — no run-length checkpoints or pauses.\n' "$MAUDE_RUN_GOVERNOR" >&2
    ;;
esac

# Collect signals across every available tier — degradative, each independent.
NOW_LINE=""
REMEMBER_HANDOFF=""
PATTERN_HINT=""
LETTER_LINE=""
HAS_MAP=""
TOPIC_COUNT=0

# Tier 1: Anthropic auto-memory live buffer
if [ -f "$MEM/now.md" ]; then
  NOW_LINE="$(grep -m1 -E '^## [0-9]{2}:[0-9]{2}' "$MEM/now.md" | head -c 200)"
  [ -z "$NOW_LINE" ] && NOW_LINE="$(head -1 "$MEM/now.md" | head -c 200)"
fi

# Tier 1b: the remember plugin's live buffer ($REMEMBER/now.md) — updated continuously,
# so usually FRESHER than the Anthropic now.md (which can lag an hour+). Surface its
# NEWEST entry as "where you left off", so the wake path reads CURRENT state instead of a
# lagging source while the fresh capture sits unread. (The continuity gap the live
# dogfood exposed: session-start was reading the stale buffer and an empty handoff while
# this file held the freshest summary.) Entries are oldest-first; newest is at the bottom.
# SCOPE: under an umbrella root (one shared .remember/ across projects), the newest entry
# is workspace-WIDE — it may name a different project than the current focus. Intended:
# one session spans the whole workspace, so "the latest thing done anywhere" is where you
# left off. In a single-project .remember/, it's naturally that project's latest.
LEFTOFF_LINE=""
LEFTOFF_SRC="workspace-wide"
if [ -s "$REMEMBER/now.md" ]; then
  LEFTOFF_LINE="$(grep -A1 -E '^## [0-9]{2}:[0-9]{2}' "$REMEMBER/now.md" 2>/dev/null \
    | grep -vE '^## |^--$|^[[:space:]]*$' | tail -1 | head -c 200)"
  # The session tie (the fleet fix): under concurrent sessions the newest entry
  # may be a NEIGHBOR session's work, so the line declares its source instead of
  # masquerading as this session's state. Entry headers are "## HH:MM | label";
  # the label is the writer's branch field (a fleet can set REMEMBER_BRANCH per
  # session to put its session name here). "unknown"/absent → workspace-wide.
  LEFTOFF_HDR="$(grep -E '^## [0-9]{2}:[0-9]{2}' "$REMEMBER/now.md" 2>/dev/null | tail -1)"
  case "$LEFTOFF_HDR" in
    *"|"*)
      LEFTOFF_SRC="$(printf '%s' "$LEFTOFF_HDR" | sed -E 's/^[^|]*\|[[:space:]]*//; s/[[:space:]]*$//' | head -c 40)"
      case "$LEFTOFF_SRC" in ''|unknown) LEFTOFF_SRC="workspace-wide" ;; esac
      ;;
  esac
fi

# Tier 2: remember plugin's handoff file (the dense, intentional signal from last session)
if [ -s "$REMEMBER/remember.md" ]; then
  REMEMBER_HANDOFF="$(grep -m1 -A1 '^## Next' "$REMEMBER/remember.md" 2>/dev/null | tail -1 | head -c 200)"
  [ -z "$REMEMBER_HANDOFF" ] && REMEMBER_HANDOFF="$(head -3 "$REMEMBER/remember.md" | tail -1 | head -c 200)"
fi

# Tier 3: cross-project patterns (her own home base) — one scar per wake, rotating.
# Day-of-year cycles through the entry HEADINGS: every pattern gets airtime and none
# pins forever (the old basename-grep locked onto any entry whose BODY contained the
# project name — e.g. a path — and truncated it mid-sentence into what read like a
# live alert). A ## heading is a complete dated sentence; history stays history.
if [ -s "$USER_DIR/patterns.md" ]; then
  PATTERN_HINT="$(awk -v day="$(date +%j | sed 's/^0*//')" '
    /^## / { h[n++] = substr($0, 4) }
    END { if (n > 0) print h[day % n] }
  ' "$USER_DIR/patterns.md" 2>/dev/null | head -c 200)"
fi

# Tier 3b: her letter to her next self (written at /maude:rest — read-only here,
# like every hook). First non-header, non-blank line is the essence; the wake/brief
# commands read the whole letter.
LETTER_LINE=""
if [ -s "$USER_DIR/letter-from-maude.md" ]; then
  LETTER_LINE="$(grep -m1 -v -E '^#|^[[:space:]]*$' "$USER_DIR/letter-from-maude.md" 2>/dev/null | head -c 160)"
fi

# Tier 4: house-map status
[ -f "$MAP" ] && HAS_MAP="✓"

# Tier 5: simple count of memory files in Anthropic dir
[ -d "$MEM" ] && TOPIC_COUNT="$(find "$MEM" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')"

# She ALWAYS greets — her once-per-session voice is a RAIL, not a condition. Even on
# a pristine project (no memory, no map) her name lands, with a /maude:found nudge.
# (Previously an early-exit-on-nothing stayed silent here; removed so the greeting can
# never be skipped — the guaranteed once-per-session presence the plugin promises.)

# Compose brief — terse, one stanza per signal that fired.
# Greet by the user's local clock when the timezone is known (house-map);
# stay time-neutral otherwise — never assert a time-of-day from the box clock.
# Maude's one JOHN-facing line: what she caught since he last looked. Watermark-based
# (last_digest_iso in care.json) so it never re-prints across SessionStart's resume/
# clear/compact re-fires. Computed before the brief so the catch leads the stanza.
DIGEST_LINE="$(maude_digest_line)"

# Continuity guard: warn at the top if the last save is stale vs real trace activity —
# the closing loop so a forgotten /maude:rest degrades continuity loudly, not silently.
CONTINUITY_LINE="$(maude_continuity_guard)"

# Cushion line (issue #36): render the last flip's stamp — count + age, one line.
# No re-scan at wake (the flip walks every repo; too heavy for session-start);
# absent stamp = the nudge, so the ritual can't quietly reapply its own problem
# ("nobody checks the places nobody sweeps") to itself.
CUSHION_LINE=""
CUSHION_STAMP="$(maude_self_dir)/cushions-last"
if [ -f "$CUSHION_STAMP" ]; then
  read -r C_EPOCH C_COUNT < "$CUSHION_STAMP" 2>/dev/null
  # Both fields must be non-empty and numeric — the ':' probe catches a missing
  # field (leading/trailing colon) that bare concatenation would let slip.
  case "${C_EPOCH}:${C_COUNT}" in
    *[!0-9:]*|:*|*:) : ;;  # malformed stamp → say nothing rather than something wrong
    *)
      C_AGE_D=$(( ( $(date +%s) - C_EPOCH ) / 86400 ))
      if [ "$C_AGE_D" -lt 1 ]; then C_WHEN="today"; else C_WHEN="${C_AGE_D}d ago"; fi
      C_PL="s"; [ "$C_COUNT" = "1" ] && C_PL=""
      CUSHION_LINE="Cushions: $C_COUNT value candidate$C_PL — last flipped $C_WHEN." ;;
  esac
else
  CUSHION_LINE="Cushions: never flipped — /maude:cushions when you have a minute."
fi

GREETING="$(maude_greeting)"
{
  [ -n "$GREETING" ] && printf '%s ' "$GREETING"
  printf 'Maude here.'
  [ -n "$HAS_MAP" ] && printf ' (house-map ✓)'
  printf '\n'
  [ -n "$DIGEST_LINE" ] && printf '  %s\n' "$DIGEST_LINE"
  [ -n "$CONTINUITY_LINE" ] && printf '  %s\n' "$CONTINUITY_LINE"
  [ -n "$LEFTOFF_LINE" ] && printf '  Where you left off (%s): %s\n' "$LEFTOFF_SRC" "$LEFTOFF_LINE"
  [ -n "$REMEMBER_HANDOFF" ] && printf '  Last handoff (.remember): %s\n' "$REMEMBER_HANDOFF"
  [ -n "$NOW_LINE" ]          && printf '  Anthropic now: %s\n' "$NOW_LINE"
  [ -n "$PATTERN_HINT" ]      && printf '  Cross-project pattern: %s\n' "$PATTERN_HINT"
  [ -n "$LETTER_LINE" ]       && printf '  Letter from my last self: %s\n' "$LETTER_LINE"
  [ "$TOPIC_COUNT" -gt 0 ]    && printf '  %s memory file(s) on hand.\n' "$TOPIC_COUNT"
  [ -n "$CUSHION_LINE" ]      && printf '  %s\n' "$CUSHION_LINE"
  [ -z "$HAS_MAP" ] && printf '  No house-map yet — run /maude:found.\n'
} 2>/dev/null

# Chore brief — the ledger makes the labor visible (one line, silent when idle).
CHORES="$DIR/../../scripts/maude-chores.sh"
if [ -f "$CHORES" ]; then
  bash "$CHORES" detect >/dev/null 2>&1
  CHORE_LINE="$(bash "$CHORES" brief 2>/dev/null)"
  [ -n "$CHORE_LINE" ] && printf '  %s\n' "$CHORE_LINE"
fi

exit 0
