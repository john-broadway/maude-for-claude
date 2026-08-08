#!/usr/bin/env bash
# Maude redteam-watch hook — the adversarial-pass tripwire.
#
#   stamp   (PostToolUse · any tool, called from maude-trace.sh) — if an Agent/Task
#           dispatch that just COMPLETED was adversarial in intent, record an ISO
#           timestamp in care.json `.last_redteam_iso`.
#   check   (PreToolUse · Bash, called from maude-bash-watch.sh) — on a `git commit`,
#           if CODE files were edited since the last adversarial pass, whisper once.
#
# ALWAYS exits 0. Whisper, never block.
#
# WHY THIS EXISTS
# John's standing expectation (2026-07-30): every build gets an adversarial pass before it
# is called done, Claude launches it, using OUR sub configs — "we were doing it before
# antrhopic pushed" · "we are always dogfooding".
#
# Maude already HELD that preference. ~/.claude/maude/identity.md carries the tiering
# correction verbatim — "redteams use models for the tasks dont lock us down that small" —
# and the uniform-bar rule beside it. On 2026-07-30 three builds shipped with ZERO
# adversarial passes anyway, because identity.md is 86KB read at wake and nothing consults
# it at the moment a build finishes. Knowledge in a file is a diary. A hook is a rail.
# Build the gate, not the wardrobe.
#
# THE ASYMMETRY THAT MAKES A TEXT HEURISTIC SAFE HERE
# A MISSED stamp costs one extra advisory whisper. A FALSE stamp manufactures "you're
# covered" when nothing reviewed the work. Those are not symmetric, so every judgement call
# below leans the same way: don't stamp unless it plainly reads adversarial, and whisper
# whenever in doubt. Same shape as maude-verify-watch.sh's failure-sniff, and for the same
# reason.
#
# HONEST SEAM: intent is read from the dispatch's own description/prompt text. A redteam
# worded in some way this pattern doesn't recognise won't stamp — the cost is a spurious
# whisper, never a false all-clear. It also cannot tell a thorough lens from a lazy one; it
# knows an adversarial pass was RUN, not that it was any good.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

MODE="${1:-}"
INPUT="$(cat 2>/dev/null)"
CARE="$(maude_self_dir)/care.json"

# PER SESSION. care.json and the trace are BOTH shared by every session at a project root —
# five lanes were live here on 2026-07-30 (proximo, maude, pacioli, maximus, +). Unscoped,
# this rail would count a sibling lane's edits and whisper about work that was never yours,
# which is the crying-wolf failure the mission pin had committed that same night. Same 8-char
# `sid` the trace writes (maude-trace.sh:57), so the two agree on identity.
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
SID="$(printf '%s' "$SID" | cut -c1-8)"
[ -n "$SID" ] || SID="default"

# Adversarial intent. Deliberately narrow: these are the words this house actually uses
# when it dispatches a lens (measured against real Agent dispatches in the transcripts —
# "Adversarial review of the federation rename", "Haiku cadence judge … a second lens").
ADVERSARIAL_RE='(red[- ]?team|adversarial|second lens|refute|falsify|break this|find the (bugs|gaps|holes)|attack|hostile|poke holes|try to (break|defeat)|judge|critique|audit)'

# Words that mark a BUILDER, not a lens. Checked FIRST: a dispatch that implements is not a
# review of the implementation, however carefully it is worded. Measured negative from a
# real transcript: "Build 7e first-light wiring TDD" / "You are a careful TDD implementer".
BUILDER_RE='(implementer|implement |write the code|build the|scaffold|refactor|port the|migrate)'

# Reused verbatim from maude-verify-watch.sh so the two rails agree on what a commit is and
# what counts as code. Divergent copies would drift and one of them would be wrong.
SEP='(^|[;&|(`])[[:space:]]*'
COMMIT_RE="${SEP}git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)"
DOC_RE='\.(md|markdown|txt|rst|adoc|json|ya?ml|toml|cfg|conf|ini|lock|csv|tsv|svg|png|jpe?g|gif|pdf)$|(^|/)(LICENSE|COPYING|NOTICE|CHANGELOG[^/]*|AUTHORS|\.gitignore|\.gitattributes|\.editorconfig)$'

case "$MODE" in
  stamp)
    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
    case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

    # A killed dispatch reviewed nothing. Same belt as verify-watch's interrupted check.
    [ "$(printf '%s' "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)" = "true" ] && exit 0

    TEXT="$(printf '%s' "$INPUT" \
      | jq -r '[(.tool_input.description // ""), (.tool_input.prompt // "")] | join(" ")' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')"
    [ -n "$TEXT" ] || exit 0

    # Builder first — an implementer dispatch whose prompt happens to say "find the bugs"
    # is still an implementer, and stamping it would be the false all-clear.
    printf '%s' "$TEXT" | grep -qE -- "$BUILDER_RE" && exit 0
    printf '%s' "$TEXT" | grep -qE -- "$ADVERSARIAL_RE" || exit 0

    maude_care_ensure "$CARE"
    if maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SID" \
         '.last_redteam_iso = ((.last_redteam_iso // {}) | if type=="object" then . else {} end | .[$sid] = $ts)'; then
      maude_log_trace "redteam" "stamped last_redteam_iso"
    else
      maude_log_trace "redteam" "could not stamp last_redteam_iso (care.json unwritable)"
    fi
    exit 0
    ;;

  check)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
    printf '%s' "$CMD" | grep -qE -- "$COMMIT_RE" || exit 0

    TRACE_DIR="$(maude_self_dir)/trace"
    # Two most-recent trace files, lexical sort == chronological (mirrors verify-watch, so
    # an edit just before UTC midnight is still seen by a post-midnight commit).
    FILES="$(ls -1 "$TRACE_DIR"/today-*.jsonl 2>/dev/null | sort | tail -2)"
    [ -z "$FILES" ] && exit 0

    LAST_RT="$(jq -r --arg sid "$SID" '(.last_redteam_iso // {}) | if type=="object" then (.[$sid] // "") else "" end' "$CARE" 2>/dev/null)"

    # Edits since the last adversarial pass. `fromjson?` per line so one corrupt line is
    # skipped rather than blinding the whisper — failing that way round would produce a
    # false "you're covered", which is the one outcome this hook must never produce.
    EDITS="$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && cat -- "$f"; done \
      | jq -rR --arg rts "$LAST_RT" --arg sid "$SID" '
      fromjson?
      | select(.kind=="tool"
             and (.tool=="Write" or .tool=="Edit" or .tool=="MultiEdit")
             and .target != null
             and ((.sid // "default") == $sid)
             and (.ts > $rts))
      | "\(.ts)\t\(.target)"' 2>/dev/null)"
    [ -z "$EDITS" ] && exit 0

    # Docs/config-only commits stay silent. A rail that nags on a README edit is a rail
    # that gets switched off, and a rail that is off protects nothing.
    printf '%s\n' "$EDITS" | cut -f2 | grep -qvE "$DOC_RE" || exit 0

    N="$(printf '%s\n' "$EDITS" | cut -f2 | grep -vE "$DOC_RE" | sort -u | grep -c .)"
    if [ -z "$LAST_RT" ]; then
      printf 'Maude: %s code file(s) changed and NO adversarial pass has run. Launch the redteam before you call this done — our own, tiered to the stakes.\n' "$N" >&2
    else
      printf 'Maude: %s code file(s) changed since the last adversarial pass (%s). Launch the redteam before you call this done.\n' "$N" "$LAST_RT" >&2
    fi
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
