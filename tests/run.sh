#!/usr/bin/env bash
# Discover and run all tests/test-*.sh. Print PASS/FAIL per test.
# Exit 0 if all pass, 1 if any fail.
#
# -j N (or MAUDE_TEST_JOBS=N): run up to N files side by side (default 1: one at a time,
# streamed, exactly as before). Files named in tests/serial.list run afterwards, one at a
# time, with nothing beside them: the ones that bound wall time or went red under load.
# Results are printed in file order either way, and each file has its own TMPDIR, so a
# leak is charged to the file that made it.

set +e
JOBS="${MAUDE_TEST_JOBS:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -j*) JOBS="${1#-j}"; shift ;;
    *) printf 'run.sh: unknown argument %s (usage: run.sh [-j N])\n' "$1" >&2; exit 2 ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*|0) printf 'run.sh: -j takes a positive whole number, got "%s"\n' "$JOBS" >&2; exit 2 ;; esac
cd "$(dirname "$0")" || exit 1

# Loud guard: most assertions read state via jq-backed helpers (read_care,
# count_trace_lines) that return null/0 when jq is absent — which would make
# those assertions PASS falsely. Warn so a jq-less run isn't mistaken for green.
if ! command -v jq >/dev/null 2>&1; then
  printf '!! WARNING: jq not found — coverage is DEGRADED; jq-backed assertions may pass falsely.\n' >&2
  printf '!!          Install jq for a trustworthy run. (test-nojq.sh covers the no-jq paths.)\n' >&2
fi

TOTAL=0
PASSED=0
FAILED=0
FAILED_NAMES=()

_tmp_base="${TMPDIR:-/tmp}"; _tmp_base="${_tmp_base%/}"; [ -n "$_tmp_base" ] || _tmp_base=/   # macOS TMPDIR ends in a slash
OUT_TMP="$(mktemp "${_tmp_base}/maude-run.XXXXXX")"
# Every file's temp lands under here: tests/lib.sh puts its own root beneath TMPDIR and
# sweeps that root at exit, so after a file returns this dir must be empty. Anything left
# is a leak, and a leak is a failure. The sweep in lib.sh is the fix; this keeps it fixed.
SUITE_TMP="$(mktemp -d "${_tmp_base}/maude-suite.XXXXXX")"   # a template: macOS mktemp ignores TMPDIR without one
export TMPDIR="$SUITE_TMP"
# The pool's outputs: its own private dir, never a path guessable from another's name.
OUTS="$(mktemp -d "${_tmp_base}/maude-out.XXXXXX")"
trap 'rm -f "$OUT_TMP"; rm -rf "$SUITE_TMP" "$OUTS"' EXIT

# judge <test> <its output file> <its exit status> <its TMPDIR> [leftover count]: read the
# verdict, print the PASS or FAIL line, and sweep anything the file left behind so a leak is
# charged to it. The pool passes the count it took when the file exited: counted later, a
# leak a background child tidied in the meantime would read as clean.
judge() {
  local t="$1" out="$2" rc="$3" tdir="$4" nfail summary left _sum
  # Exit status is not the only signal. A file that ends without `exit "$FAILED"`
  # returns 0 whatever its assertions said (four did, 147 assertions unenforced,
  # found by the 11th lens on v0.30.1). Read the summary line too: a file that
  # says "N failed" with N > 0 is a failure however it exited. Files that print
  # no summary keep reporting through their exit status alone.
  nfail=0
  summary="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$out" | tail -1)"
  if [ -n "$summary" ]; then nfail="${summary#* passed, }"; nfail="${nfail%% failed}"; fi
  # The larger of the count taken at exit and a fresh one: a child that tidies after the file
  # exits is caught by the first, one that writes after it by the second (the delta lens on
  # bb6aa1c).
  left="$(find "$tdir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ -n "${5:-}" ] && [ "$5" -gt "$left" ] 2>/dev/null && left="$5"
  if [ "$rc" -eq 0 ] && [ "${nfail:-0}" -eq 0 ] && [ "$left" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    # The file's own count rides on the PASS line, and its NOTE lines — what it could not
    # assert here (a locale not installed, a binary not present) — come through. Swallowed
    # with the rest of a passing file's output, a suite whose pins had silently stopped
    # running reported nothing but "61/61" (the 31st lens, IMPORTANT-2).
    if [ -n "$summary" ]; then _sum="$summary"
    elif grep -qE '[0-9]+ passed, [0-9]+ failed' "$out"; then _sum="summary unreadable; enforced by exit status"
    else _sum="no summary line; enforced by exit status"; fi
    printf 'PASS  %s  (%s)\n' "$t" "$_sum"
    grep -E '^[[:space:]]*NOTE ' "$out"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$t")
    printf 'FAIL  %s  (exit %s, %s failed by its own count, %s left in TMPDIR)\n' "$t" "$rc" "${nfail:-0}" "$left"
    sed 's/^/  /' "$out"
    if [ "$left" -gt 0 ]; then
      # Name what was left, a few levels deep: a count says a file leaked, the tree
      # says which fixture or worker made it. Then start the next file clean, so a
      # leak is charged to the file that made it.
      printf '  left behind:\n'
      find "$tdir" -mindepth 1 -maxdepth 4 | head -40 | while IFS= read -r _p; do printf '    TMPDIR%s\n' "${_p#"$tdir"}"; done
      find "$tdir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
  fi
}

if [ "$JOBS" -gt 1 ]; then
  SERIAL=" "
  if [ -f serial.list ]; then
    while IFS= read -r _l; do
      _l="${_l%%#*}"                              # a reason may follow the name
      _l="${_l%"${_l##*[![:space:]]}"}"           # trailing blanks
      _l="${_l#"${_l%%[![:space:]]*}"}"           # leading blanks
      [ -n "$_l" ] || continue
      SERIAL="$SERIAL$_l "
    done < serial.list
  fi
  FILES=(test-*.sh)
  # start <test> <n>: run one file in the background, its own TMPDIR, its output and exit
  # status kept for judging in file order afterwards.
  start() {
    mkdir -p "$SUITE_TMP/f.$2"
    ( TMPDIR="$SUITE_TMP/f.$2" bash "$1" < /dev/null > "$OUTS/$2.out" 2>&1; echo "$?" > "$OUTS/$2.rc"
      find "$SUITE_TMP/f.$2" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ' > "$OUTS/$2.left" ) &
  }
  n=0
  for t in "${FILES[@]}"; do
    case "$SERIAL" in *" $t "*) n=$((n + 1)); continue ;; esac
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.1; done
    start "$t" "$n"
    n=$((n + 1))
  done
  wait
  n=0
  for t in "${FILES[@]}"; do
    case "$SERIAL" in *" $t "*) start "$t" "$n"; wait ;; esac
    n=$((n + 1))
  done
  n=0
  for t in "${FILES[@]}"; do
    TOTAL=$((TOTAL + 1))
    judge "$t" "$OUTS/$n.out" "$(cat "$OUTS/$n.rc" 2>/dev/null || echo 1)" "$SUITE_TMP/f.$n" \
      "$(cat "$OUTS/$n.left" 2>/dev/null || echo 1)"
    n=$((n + 1))
  done
else
for t in test-*.sh; do
  TOTAL=$((TOTAL + 1))
  # stdin pinned shut: a hook under test that reads its JSON from stdin (`[ -t 0 ] || cat`)
  # waited forever on a stdin that never closed, and the release gate sat a day on
  # test-eye-hooks.sh with nothing red (2026-10-12). A gate that never returns is a stamp.
  bash "$t" < /dev/null > "$OUT_TMP" 2>&1; rc=$?
  judge "$t" "$OUT_TMP" "$rc" "$SUITE_TMP"
done
fi

printf '\n%d/%d test files passed' "$PASSED" "$TOTAL"
if [ "$FAILED" -gt 0 ]; then
  printf ' (%d failed: %s)\n' "$FAILED" "${FAILED_NAMES[*]}"
  exit 1
fi
printf '\n'
exit 0
