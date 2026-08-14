#!/usr/bin/env bash
# Maude voice-capture hook (UserPromptSubmit) — silently appends the prompt John just
# typed into the voice corpus (tape.db `voice` table), for later profile derivation
# (the capture half of the voice feature; `harvest` is the backfill half).
#
# CONTRACT — an OBSERVER, never a gate:
#   - Prints NOTHING to stdout on success. stdout on a UserPromptSubmit hook is
#     injected into Claude's context, so silence is the whole point: capture must
#     be free — unnoticed until she has something to cue on. The python's stdout is
#     therefore always discarded here, regardless of what it prints.
#   - On ANY failure (no python3, no jq, no db, malformed stdin, the CLI itself
#     failing for any reason at all) this
#     exits 0 silently. A broken capture must never block John's prompt.
#   - Fast: parse + invoke, nothing else. No filtering/dedup/secret-scan logic
#     lives here — that's voice.py's job (cmd_capture), the one place that owns
#     it for both the harvest and the hook ingest paths.
#
# Prompt parsing copies the sibling UserPromptSubmit hooks EXACTLY (see
# maude-secret-scan.sh, maude-page.sh): `jq -r '.prompt // .message // ""'` off
# the hook's stdin JSON envelope.
#
# DB path + PYTHONPATH resolution copy the OTHER `python3 -m maude_tape` callers
# (maude-tape-wake.sh / maude-tape-rest.sh) rather than maude-page.sh's
# maude_vault convention — same module, same resolution, same fallback for a
# CLAUDE_PLUGIN_ROOT-less context (tests, `!` bash runs).
set +e

# The kill switch, same idiom as MAUDE_EYE/MAUDE_PROBE/MAUDE_CHORES: capture is the
# most sensitive organ in the house (your words, verbatim), so it is also the easiest
# to turn off.
[ "${MAUDE_VOICE:-on}" = "off" ] && exit 0

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v python3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DB="$(maude_project_dir)/.maude/plugin/tape/tape.db"
[ -f "$DB" ] || exit 0

INPUT="$(cat 2>/dev/null)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // .message // ""' 2>/dev/null)"
[ -z "$PROMPT" ] && exit 0

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"

VC_ARGS=(--db "$DB" --source hook --register chat)
[ -n "$SID" ] && VC_ARGS+=(--session "$SID")

printf '%s' "$PROMPT" | PYTHONPATH="${CLAUDE_PLUGIN_ROOT:-$DIR/../..}" \
  python3 -m maude_tape voice-capture "${VC_ARGS[@]}" >/dev/null 2>/dev/null

exit 0
