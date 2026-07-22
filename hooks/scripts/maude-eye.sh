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

case "$CMD" in
  tick)
    INPUT="$(cat 2>/dev/null)"
    TRANSCRIPT=""
    if command -v jq >/dev/null 2>&1; then
      TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
    fi
    COUNT=0; LAST=0
    if [ -f "$STATE" ]; then
      COUNT="$(sed -n 1p "$STATE" 2>/dev/null)"; LAST="$(sed -n 2p "$STATE" 2>/dev/null)"
      case "$COUNT" in ''|*[!0-9]*) COUNT=0;; esac
      case "$LAST"  in ''|*[!0-9]*) LAST=0;;  esac
    fi
    COUNT=$((COUNT + 1))
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
        printf '0\n%s\n' "$NOW" > "$STATE" 2>/dev/null
        nohup bash "$DIR/maude-eye-blink.sh" "$TRANSCRIPT" >/dev/null 2>&1 &
        disown 2>/dev/null
      else
        printf '%s\n%s\n' "$COUNT" "$LAST" > "$STATE" 2>/dev/null
      fi
    else
      printf '%s\n%s\n' "$COUNT" "$LAST" > "$STATE" 2>/dev/null
    fi
    ;;
  whisper)
    if [ -s "$WHISPER_FILE" ]; then
      # Freshness by write-time (the blink's mv stamps it): a whisper is
      # advisory and asynchronous — one generated many calls ago must not
      # wear a fresh voice (issue #35). Weight the gate over the whisper.
      # stat failure -> BORN=0 -> treated as fresh (fail-open to the old
      # behavior; a false print beats a silent swallow of a live catch).
      TTL="${MAUDE_EYE_WHISPER_TTL:-300}"
      BORN="$(maude_mtime "$WHISPER_FILE")"
      NOW="$(date +%s)"
      if [ "$BORN" -gt 0 ] && [ $((NOW - BORN)) -gt "$TTL" ]; then
        # Content-free receipt: the trace is metadata-only by design.
        maude_log_trace "eye" "stale whisper dropped (aged $((NOW - BORN))s > ttl ${TTL}s)"
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
