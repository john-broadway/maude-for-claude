#!/usr/bin/env bash
# Maude's eye — tick (PostToolUse counter -> background blink) + whisper (one-shot pickup).
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

[ "${MAUDE_EYE:-on}" = "off" ] && exit 0

CMD="${1:-}"
SELF="$(maude_self_dir)"
mkdir -p "$SELF" 2>/dev/null
STATE="$SELF/eye-state"
WHISPER_FILE="$SELF/eye-whisper.txt"

# The tick's read-modify-write of eye-state, run under a lock: every tool call in every
# subagent ticks this file, and unlocked, 60 parallel ticks landed 4 (the lens, 2026-09-14).
# Everything the tick needs is decided in here; nothing is read back after it returns.
# Measured under the 60-way race: worst tick 728 ms against the hook's 5 s budget.
# Residual, accepted: on a box without flock(1) the mkdir fallback's dead-holder floor is
# 30 s, so a tick killed mid-lock wedges the next ~6 ticks (each times out at 5 s), then
# heals; flock releases on kill in 2 ms.
_eye_tick() {
    # eye-state: line 1 = ticks since the last blink (the burst), line 2 = when it blinked,
    # line 3 = ticks ever (monotonic; the whisper's age is measured against it).
    COUNT=0; LAST=0; TOTAL=0
    if [ -f "$STATE" ]; then
      COUNT="$(sed -n 1p "$STATE" 2>/dev/null)"; LAST="$(sed -n 2p "$STATE" 2>/dev/null)"; TOTAL="$(sed -n 3p "$STATE" 2>/dev/null)"
      case "$COUNT" in ''|*[!0-9]*) COUNT=0;; esac
      case "$LAST"  in ''|*[!0-9]*) LAST=0;;  esac
      case "$TOTAL" in ''|*[!0-9]*) TOTAL=0;; esac
    fi
    COUNT=$((COUNT + 1)); TOTAL=$((TOTAL + 1))
    NOW="$(date +%s)"
    EVERY="${MAUDE_EYE_EVERY:-25}"
    MIN="${MAUDE_EYE_MIN_INTERVAL:-180}"
    LOCK="$SELF/.eye-blink.lock"
    if [ "$COUNT" -ge "$EVERY" ] && [ $((NOW - LAST)) -ge "$MIN" ] \
       && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      # Reclaim a stale lock: the worker that created it died (killed,
      # crashed) before its own EXIT trap could rmdir it. Age is judged off
      # the lock dir's own mtime, not any counter, so a slow-but-alive worker
      # is never mistaken for dead.
      if [ -d "$LOCK" ]; then
        LOCK_MTIME="$(maude_mtime "$LOCK" "$NOW")"
        if [ $((NOW - LOCK_MTIME)) -ge 120 ]; then
          rmdir "$LOCK" 2>/dev/null
        fi
      fi
      # Atomic claim: mkdir either succeeds exactly once — this tick spawns —
      # or fails because a concurrent tick already won it. Without this, N
      # concurrent ticks that all read the same pre-reset counter each judged
      # the threshold met and each spawned its own blink.
      if mkdir "$LOCK" 2>/dev/null; then
        printf '0\n%s\n%s\n' "$NOW" "$TOTAL" > "$STATE" 2>/dev/null
        # The whisper this blink may produce is born at this tick.
        printf '%s' "$TOTAL" > "$SELF/eye-whisper.born" 2>/dev/null
        # 9>&-: the blink must not inherit the lock's fd, or it would hold the tick
        # lock for as long as it runs.
        nohup bash "$DIR/maude-eye-blink.sh" "$TRANSCRIPT" >/dev/null 2>&1 9>&- &
        disown 2>/dev/null
      else
        printf '%s\n%s\n%s\n' "$COUNT" "$LAST" "$TOTAL" > "$STATE" 2>/dev/null
      fi
    else
      printf '%s\n%s\n%s\n' "$COUNT" "$LAST" "$TOTAL" > "$STATE" 2>/dev/null
    fi
}

case "$CMD" in
  tick)
    INPUT="$(cat 2>/dev/null)"
    TRANSCRIPT=""
    if command -v jq >/dev/null 2>&1; then
      TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
    fi
    maude_locked "$SELF/.eye-state.lock" _eye_tick
    ;;
  whisper)
    if [ -s "$WHISPER_FILE" ]; then
      # Freshness is measured in TOOL CALLS since the whisper was born, not in seconds:
      # a whisper is advisory and asynchronous, and one generated many calls ago must
      # not wear a fresh voice (issue #35) — but pickup only happens at the next human
      # prompt, and a wall-clock TTL shorter than the human's turn cadence dropped every
      # whisper while the work had not moved at all (0 of 10 delivered, 2026-09-14).
      # Either measure missing -> treated as fresh (fail-open; a false print beats a
      # silent swallow of a live catch). Residual, accepted: an eye-state reset that
      # leaves eye-whisper.born behind reads born > total, i.e. fresh, until the total
      # climbs back past it; the next blink rewrites born. MAUDE_EYE_WHISPER_TTL (seconds) stays as an
      # opt-in wall-clock ceiling for a site that wants one; default off.
      TTL_A="${MAUDE_EYE_WHISPER_TTL_ACTIONS:-40}"
      TTL="${MAUDE_EYE_WHISPER_TTL:-0}"
      TOTAL="$(sed -n 3p "$STATE" 2>/dev/null)"; BORN_T="$(cat "$SELF/eye-whisper.born" 2>/dev/null)"
      case "$TOTAL"  in ''|*[!0-9]*) TOTAL=0;;  esac
      case "$BORN_T" in ''|*[!0-9]*) BORN_T=0;; esac
      BORN="$(maude_mtime "$WHISPER_FILE")"
      NOW="$(date +%s)"
      STALE=""
      if [ "$BORN_T" -gt 0 ] && [ $((TOTAL - BORN_T)) -gt "$TTL_A" ]; then
        STALE="aged $((TOTAL - BORN_T)) tool calls > ttl ${TTL_A}"
      elif [ "$TTL" -gt 0 ] 2>/dev/null && [ "$BORN" -gt 0 ] && [ $((NOW - BORN)) -gt "$TTL" ]; then
        STALE="aged $((NOW - BORN))s > ttl ${TTL}s"
      fi
      if [ -n "$STALE" ]; then
        # Content-free receipt: the trace is metadata-only by design.
        maude_log_trace "eye" "stale whisper dropped ($STALE)"
      else
        W="$(head -c 400 "$WHISPER_FILE" | tr '\n' ' ')"
        printf '**Maude:** %s\n' "$W"
        # #49: a shown whisper is injected context — log its bill.
        maude_log_spend "eye-whisper" "$(printf '%s' "$W" | wc -c | tr -d ' ')"
      fi
      : > "$WHISPER_FILE" 2>/dev/null
    fi
    ;;
esac
exit 0
