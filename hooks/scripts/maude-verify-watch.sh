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
#           (test / lint / typecheck / smoke) that ran to COMPLETION with no visible
#           failure, record an ISO timestamp in care.json `.last_verify_iso`. The
#           Bash tool_response carries no exit code, so completion + clean output is
#           the pass signal (see the stamp case). Silent. Never blocks.
#
#   commit  (PreToolUse · Bash) — if the command is `git commit`, look at the two
#           most recent trace files (so an edit made just before UTC midnight is
#           still seen by a post-midnight commit) for file edits made *since* the
#           last verify. If at least one such edit was a CODE file (docs/config-only
#           commits are suppressed), whisper one line. Once per edit-batch.
#
# Design notes / v1 limits:
#   * Quote-stripped before matching (like gate/bash-watch) so a commit message
#     that merely NAMES a tool in a quoted string can't be mistaken for running it.
#     (An UNQUOTED mention like `echo pytest` is stopped separately by the
#     command-position anchoring below — `echo` is not a run-wrapper.)
#   * Verify tokens must sit at COMMAND position (line start / after a shell
#     separator / after a known run-wrapper) — so `pip install pytest`,
#     `cat pytest.ini`, `which tsc` do NOT count as a verify.
#   * Timestamps are compared as ISO-8601 UTC strings (lexical == chronological),
#     so there is NO `date -d` dependency — portable to macOS/BSD.
#   * The Bash tool_response surfaces NO exit code — only {stdout, stderr,
#     interrupted}. So the pass signal is belt-and-suspenders: stamp a run that ran
#     to COMPLETION (not interrupted) AND whose output shows no failure signature
#     (FAIL_RE). Both checks err fail-loud — a miss is an extra advisory whisper,
#     never a false "you're covered". (A failing run whose output we don't recognise
#     still stamps; that residual gap is inherent without an exit code.)
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
# wrapper (e.g. env/sudo/time/nice/xvfb-run, a VAR= assignment, a `<tool> run`
# form, npx/pnpm/bunx). The WRAP regex below is the authoritative list.
SEP='(^|[;&|]|&&|\|\|)[[:space:]]*'
WRAP='((env|sudo|time|nice|xvfb-run)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(uv|poetry|pipenv|pdm)[[:space:]]+run[[:space:]]+|bundle[[:space:]]+exec[[:space:]]+|npx[[:space:]]+|pnpm[[:space:]]+(exec|dlx)[[:space:]]+|bunx[[:space:]]+)*'
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

# High-confidence FAILURE signatures in a verify's OUTPUT (the "suspenders" — see
# the stamp case). Deliberately conservative: match only an unambiguous failure so a
# clean pass still stamps. Both count forms require a NON-ZERO count (a "0" is a pass,
# never matched), covering the two conventions runners use:
#   count-before — "1 failed" / "1 failing" / "1 failure" / "2 errors"  (pytest, jest,
#                  mocha, rspec, mix, …)
#   count-after  — "Failed: 3" / "Failures: 2" / "Errors: 1"            (dotnet/MSTest,
#                  JUnit/surefire, …)
# Plus literal markers runners print only on failure. Any miss is fail-loud (an extra
# whisper), never a false pass.
FAIL_RE='[1-9][0-9]*[[:space:]]+(failed|failing|failures?|errors?)|([Ff]ailed|[Ff]ailures?|[Ee]rrors?):[[:space:]]*[1-9]|FAILED|--- FAIL|Traceback \(most recent call last\)|panicked at|npm ERR!|AssertionError|BUILD FAILURE|BUILD FAILED'

maude_ensure_self_dir
CARE="$(maude_self_dir)/care.json"
# Valid JSON base for the merge below; a corrupt file is reseeded AND traced
# (shared helper — see maude_care_ensure; replaces the old silent wipe, R2).
maude_care_ensure "$CARE"

case "$MODE" in
  stamp)
    printf '%s' "$CMD" | grep -qE -- "$VERIFY_RE" || exit 0
    # The Bash tool_response surfaces {stdout, stderr, interrupted} — there is NO
    # exit code (verified against the runtime), so "did it pass?" isn't directly
    # knowable. Belt-and-suspenders, both erring fail-loud:
    #   belt       — only stamp a run that ran to COMPLETION (interrupted != true).
    #   suspenders — and whose output shows no high-confidence FAILURE signature.
    # A failure-sniff can only ever SUPPRESS a stamp (→ an extra advisory whisper),
    # never manufacture a false "you're covered" — that asymmetry is what makes a
    # best-effort output signal safe to layer on. Output is scanned IN MEMORY only
    # and never written to disk (the privacy invariant).
    [ "$(printf '%s' "$INPUT" | jq -r '.tool_response.interrupted // false' 2>/dev/null)" = "true" ] && exit 0
    OUT="$(printf '%s' "$INPUT" | jq -r '[.tool_response.stdout // "", .tool_response.stderr // ""] | join("\n")' 2>/dev/null)"
    printf '%s' "$OUT" | grep -qE -- "$FAIL_RE" && exit 0
    # maude_care_set reports its own success; don't claim a stamp the write dropped.
    if maude_care_set "$CARE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_verify_iso = $ts'; then
      maude_log_trace "verify" "stamped last_verify_iso"
    else
      maude_log_trace "verify" "could not stamp last_verify_iso (care.json unwritable)"
    fi
    ;;

  commit)
    printf '%s' "$CMD" | grep -qE -- "$COMMIT_RE" || exit 0

    TRACE_DIR="$(maude_self_dir)/trace"
    # The two most-recent trace files (so an edit made just before UTC midnight is
    # still seen by a post-midnight commit). Lexical filename sort == chronological;
    # no date arithmetic. After an idle gap these are the two most recent ACTIVE
    # days, not strictly yesterday/today — still correct (edits since the last
    # verify are matched by their own ts, not by the filename).
    FILES="$(ls -1 "$TRACE_DIR"/today-*.jsonl 2>/dev/null | sort | tail -2)"
    [ -z "$FILES" ] && exit 0

    LAST_VERIFY_ISO="$(jq -r '.last_verify_iso // ""' "$CARE" 2>/dev/null)"

    # Edits since the last verify: "ts<TAB>target" lines (ISO ts string compare).
    # Parse per-line with `fromjson?` (-R reads raw lines): a half-flushed or corrupt
    # JSONL line is SKIPPED, not fatal. A single bad line must never abort the stream
    # and silently blind the whisper — that would fail the WRONG way (a false "you're
    # covered" instead of the fail-loud extra whisper this hook promises).
    EDITS="$(printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && cat -- "$f"; done \
      | jq -rR --arg vts "$LAST_VERIFY_ISO" '
      fromjson?
      | select(.kind=="tool"
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
      maude_care_set "$CARE" --arg e "$LAST_EDIT_ISO" '.verify_warned_for = $e'
      maude_log_trace "verify" "commit-without-verify whisper"
    fi
    ;;

  *)
    exit 0
    ;;
esac

exit 0
