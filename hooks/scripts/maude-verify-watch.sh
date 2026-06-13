#!/usr/bin/env bash
# Maude verify-watch hook — closes the assert-without-verify gap.
#
# The existing gate hard-blocks irreversible *actions*. Nothing caught a confident
# *claim* committed without checking — Claude's #1 documented failure mode. This
# hook is that tripwire.
#
# Two modes (dispatched by $1, mirroring maude-trace.sh):
#
#   stamp   (PostToolUse · Bash) — if the command that just ran was a verify
#           (test / lint / typecheck / smoke) AND it exited 0, record an ISO
#           timestamp in care.json `.last_verify_iso`. A failed run, or one whose
#           exit code the runtime doesn't surface, is NOT stamped. Silent. Never blocks.
#
#   commit  (PreToolUse · Bash) — if the command is `git commit`, look at the two
#           most recent trace files (today + the one before, so a session that
#           crosses UTC midnight isn't blind) for file edits made *since* the last
#           verify. If at least one such edit was a CODE file (docs/config-only
#           commits are suppressed), whisper one line. Once per edit-batch.
#
# Design notes / v1 limits:
#   * Quote-stripped before matching (like gate/bash-watch) so a commit message
#     or `echo` that merely NAMES a tool can't be mistaken for running it.
#   * Verify tokens must sit at COMMAND position (line start / after a shell
#     separator / after a known run-wrapper) — so `pip install pytest`,
#     `cat pytest.ini`, `which tsc` do NOT count as a verify.
#   * Timestamps are compared as ISO-8601 UTC strings (lexical == chronological),
#     so there is NO `date -d` dependency — portable to macOS/BSD.
#   * A verify is stamped only on a CONFIRMED exit 0 (the Bash tool_response's
#     `exit_code`). If the exit code isn't surfaced, the run is treated as
#     unproven and not stamped — the failure direction is fail-loud (an extra
#     advisory whisper), never a false "you're covered".
#   * Custom/unknown test runners (project-specific names) won't be recognized and
#     will produce a (one-per-batch) advisory whisper — inherent to static matching.
#
# Privacy: writes ONLY timestamps to care.json. Never persists command or output
# content to disk (consistent with maude-trace.sh's metadata-only rule).
#
# Always exits 0. Requires jq; silently inert without it (the SessionStart notice
# already tells the user the hooks are degraded when jq is missing).

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v jq >/dev/null 2>&1 || exit 0

MODE="${1:-}"
INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
[ -z "$CMD" ] && exit 0
# Strip paired quotes first (same as gate/bash-watch): a commit message or echo
# that merely names a test tool must not be read as running one.
CMD="$(maude_strip_quotes "$CMD")"

# --- pattern building blocks ------------------------------------------------
# Command position: line start, after a shell separator, optionally after a run-
# wrapper (env/sudo/time/nice/xvfb-run, a VAR= assignment, uv|poetry|pipenv|pdm
# run, npx, pnpm exec|dlx, bunx).
SEP='(^|[;&|]|&&|\|\|)[[:space:]]*'
WRAP='((env|sudo|time|nice|xvfb-run)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(uv|poetry|pipenv|pdm)[[:space:]]+run[[:space:]]+|npx[[:space:]]+|pnpm[[:space:]]+(exec|dlx)[[:space:]]+|bunx[[:space:]]+)*'
# Recognized test/lint/typecheck runners (each at command position via SEP+WRAP).
RUNNER='(pytest|py\.test|tox|nox|bats|phpunit|rspec|jest|vitest|mocha|ctest|mypy|pyright|tsc|flake8|pylint|eslint|cargo[[:space:]]+(test|check|clippy)|go[[:space:]]+test|gradlew?[[:space:]]+(test|check)|mvn[[:space:]]+(test|verify)|dotnet[[:space:]]+test|bazel[[:space:]]+test|rake[[:space:]]+(spec|test)|mix[[:space:]]+test|ruff[[:space:]]+check|black[[:space:]]+--check|pre-commit[[:space:]]+run|python[0-9.]*[[:space:]]+(-m[[:space:]]+(pytest|unittest)|manage\.py[[:space:]]+test)|(npm|yarn|pnpm|bun)[[:space:]]+(run[[:space:]]+)?(test|lint|typecheck|check)|make[[:space:]]+(test|check|lint|verify))'
# smoke/verify/run-tests scripts invoked at command position (bash/sh/./). The
# "run" prefix on run-tests and the distinctiveness of smoke/verify keep this from
# matching incidental names like "latest.sh".
SCRIPT='(bash[[:space:]]+|sh[[:space:]]+|\./)([^[:space:]]*(smoke|verify)[[:alnum:]_.-]*|[^[:space:]]*run[_-]?tests?)\.(sh|bash)'
VERIFY_RE="${SEP}${WRAP}(${RUNNER}|${SCRIPT})"

# `git commit` at command position (post quote-strip).
COMMIT_RE="${SEP}git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)"

# A target path that is docs/config (not code) — used to suppress noise on
# docs-only commits. Anything NOT matching this is treated as code (safe default).
DOC_RE='\.(md|markdown|txt|rst|adoc|json|ya?ml|toml|cfg|conf|ini|lock|csv|tsv|svg|png|jpe?g|gif|pdf)$|(^|/)(LICENSE|COPYING|NOTICE|CHANGELOG[^/]*|AUTHORS|\.gitignore|\.gitattributes|\.editorconfig)$'

maude_ensure_self_dir
CARE="$(maude_self_dir)/care.json"
[ -s "$CARE" ] || printf '{}\n' > "$CARE" 2>/dev/null
jq -e . "$CARE" >/dev/null 2>&1 || printf '{}\n' > "$CARE" 2>/dev/null

# Atomic same-filesystem merge into care.json (mktemp in CARE's own dir so the
# rename is a true atomic rename, not a cross-fs cp; rm the temp on any failure).
care_set() {
  local tmp
  tmp="$(mktemp "$(dirname "$CARE")/.care.XXXXXX" 2>/dev/null)" || return 0
  if jq "$@" "$CARE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CARE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

case "$MODE" in
  stamp)
    printf '%s' "$CMD" | grep -qE -- "$VERIFY_RE" || exit 0
    # Count only a CONFIRMED pass. The Bash tool_response carries `exit_code`
    # when available; require it to be 0. A failed run, or one whose exit code the
    # runtime doesn't surface, is NOT stamped — worst case is an extra advisory
    # whisper (fail-loud), never a false "you're covered".
    EXIT="$(printf '%s' "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // .tool_response.code // .tool_response.returncode // ""' 2>/dev/null)"
    [ "$EXIT" = "0" ] || exit 0
    care_set --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_verify_iso = $ts'
    maude_log_trace "verify" "stamped last_verify_iso"
    ;;

  commit)
    printf '%s' "$CMD" | grep -qE -- "$COMMIT_RE" || exit 0

    TRACE_DIR="$(maude_self_dir)/trace"
    # Two most-recent trace files (today + the prior day) so an edit made before
    # UTC midnight is still seen by a post-midnight commit. No date arithmetic.
    FILES="$(ls -1 "$TRACE_DIR"/today-*.jsonl 2>/dev/null | sort | tail -2)"
    [ -z "$FILES" ] && exit 0

    LAST_VERIFY_ISO="$(jq -r '.last_verify_iso // ""' "$CARE" 2>/dev/null)"

    # Edits since the last verify: "ts<TAB>target" lines (ISO ts string compare).
    EDITS="$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && cat -- "$f"; done \
      | jq -r --arg vts "$LAST_VERIFY_ISO" '
      select(.kind=="tool"
             and (.tool=="Write" or .tool=="Edit" or .tool=="MultiEdit")
             and .target != null
             and (.ts > $vts))
      | "\(.ts)\t\(.target)"' 2>/dev/null)"
    [ -z "$EDITS" ] && exit 0   # nothing edited since the last verify

    # Suppress docs/config-only commits: only whisper if at least one edited file
    # is code (a line NOT matching DOC_RE).
    printf '%s\n' "$EDITS" | cut -f2 | grep -qvE "$DOC_RE" || exit 0

    LAST_EDIT_ISO="$(printf '%s\n' "$EDITS" | cut -f1 | sort | tail -1)"
    WARNED_FOR="$(jq -r '.verify_warned_for // ""' "$CARE" 2>/dev/null)"

    if [ "$WARNED_FOR" != "$LAST_EDIT_ISO" ]; then
      printf 'Maude: files changed since the last verify — did you check this, or are you asserting it?\n' >&2
      care_set --arg e "$LAST_EDIT_ISO" '.verify_warned_for = $e'
      maude_log_trace "verify" "commit-without-verify whisper"
    fi
    ;;

  *)
    exit 0
    ;;
esac

exit 0
