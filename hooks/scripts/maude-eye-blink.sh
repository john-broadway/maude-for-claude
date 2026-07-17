#!/usr/bin/env bash
# The eye's blink: digest -> her model -> silence or one whisper. Never blocks, never fails.
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

TRANSCRIPT="${1:-}"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

SELF="$(maude_self_dir)"
mkdir -p "$SELF" 2>/dev/null

# Release the spawn lock (see maude-eye.sh tick) whenever this worker exits,
# by any path — normal completion, an early `exit 0`, or a signal. A worker
# that never releases its lock would starve every future blink; tick's
# stale-lock reclaim (120s) is the second line of defense if this trap itself
# can't fire (e.g. SIGKILL).
trap 'rmdir "$SELF/.eye-blink.lock" 2>/dev/null' EXIT

# 1) the window: transcript tail
DIGEST="$(PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -c "
import sys
from maude_eye import digest
print(digest.build_digest(sys.argv[1]))" "$TRANSCRIPT" 2>/dev/null)"
[ -n "$DIGEST" ] || exit 0

# 2) the mission pin (best effort). The pin lives at .mission.text (an object
# with text/set_by/set_at — see maude-mission.sh `capture`), NOT a bare .mission
# string.
MISSION=""
if command -v jq >/dev/null 2>&1 && [ -f "$SELF/care.json" ]; then
  MISSION="$(jq -r '.mission.text // empty' "$SELF/care.json" 2>/dev/null | head -c 300)"
fi

# 3) her memory feeding her eye (best effort)
NOTES=""
if [ -f "$SELF/vault.db" ]; then
  NOTES="$(printf '%s' "$DIGEST" | tail -c 800 | \
    PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -m maude_vault page \
      --db "$SELF/vault.db" --k 3 2>/dev/null | head -c 1200)"
fi

# 4) the runner: override -> claude -> dark
RUNNER=""
if [ -n "${MAUDE_EYE_RUNNER_OVERRIDE:-}" ] && [ -x "${MAUDE_EYE_RUNNER_OVERRIDE}" ]; then
  RUNNER="$MAUDE_EYE_RUNNER_OVERRIDE"
elif command -v claude >/dev/null 2>&1; then
  RUNNER="claude"
fi
[ -n "$RUNNER" ] || exit 0

# Wall-clock bound: a hung runner must never block the caller or outlive the
# session it was spawned from. No `timeout` binary -> dark is safer than an
# orphaned blink that lives on unbounded (env-overridable for tests).
command -v timeout >/dev/null 2>&1 || exit 0
BLINK_TIMEOUT="${MAUDE_EYE_TIMEOUT:-30}"

PROMPT="You are Maude's eye — a quiet observer watching Claude (an AI coding agent) work.
You see a digest of recent activity, the pinned mission, and notes from memory.
Look ONLY for these signals: churn (same call repeated without progress), drift
(work no longer serves the pinned mission), assert-without-verify (claiming state
without a fresh look), care (the human seems to be running into the ground).
Almost always there is NO signal — silence is your default and your discipline.
Reply with ONLY one JSON object, nothing else:
{\"signal\": false}
or
{\"signal\": true, \"kind\": \"churn|drift|assert-without-verify|care\", \"whisper\": \"<one plain sentence, max 25 words, addressed to Claude>\"}

PINNED MISSION: ${MISSION:-<none pinned>}

MEMORY NOTES:
${NOTES:-<none>}

RECENT ACTIVITY (oldest first):
$DIGEST"

if [ "$RUNNER" = "claude" ]; then
  # --safe-mode: disables CLAUDE.md/skills/plugins/hooks/MCP auto-discovery —
  # without it, every blink silently sends the user's private CLAUDE.md
  # (global + project) to the model. --no-session-persistence: this call must
  # not leave a resumable transcript (containing the digest) on disk.
  # --tools "": the eye only classifies text; it never needs tool access.
  RAW="$(printf '%s' "$PROMPT" | MAUDE_EYE_BLINK=1 timeout "$BLINK_TIMEOUT" \
    claude -p --model "${MAUDE_EYE_MODEL:-haiku}" --safe-mode --no-session-persistence --tools "" 2>/dev/null | head -c 2000)"
else
  RAW="$(printf '%s' "$PROMPT" | MAUDE_EYE_BLINK=1 timeout "$BLINK_TIMEOUT" "$RUNNER" 2>/dev/null | head -c 2000)"
fi
[ -n "$RAW" ] || exit 0

WHISPER="$(PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -c "
import sys
from maude_eye import verdict
print(verdict.whisper_from(sys.stdin.read()))" <<<"$RAW" 2>/dev/null)"
[ -n "$WHISPER" ] || exit 0

TMP="$SELF/.eye-whisper.tmp.$$"
printf '%s\n' "$WHISPER" > "$TMP" 2>/dev/null && mv -f "$TMP" "$SELF/eye-whisper.txt" 2>/dev/null
exit 0
