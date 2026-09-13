#!/usr/bin/env bash
# Discover and run all tests/test-*.sh. Print PASS/FAIL per test.
# Exit 0 if all pass, 1 if any fail.

set +e
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

OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/maude-run.XXXXXX")"
# Every file's temp lands under here: tests/lib.sh puts its own root beneath TMPDIR and
# sweeps that root at exit, so after a file returns this dir must be empty. Anything left
# is a leak, and a leak is a failure. The sweep in lib.sh is the fix; this keeps it fixed.
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/maude-suite.XXXXXX")"   # a template: macOS mktemp ignores TMPDIR without one
export TMPDIR="$SUITE_TMP"
trap 'rm -f "$OUT_TMP"; rm -rf "$SUITE_TMP"' EXIT

for t in test-*.sh; do
  TOTAL=$((TOTAL + 1))
  bash "$t" > "$OUT_TMP" 2>&1; rc=$?
  # Exit status is not the only signal. A file that ends without `exit "$FAILED"`
  # returns 0 whatever its assertions said (four did, 147 assertions unenforced,
  # found by the 11th lens on v0.30.1). Read the summary line too: a file that
  # says "N failed" with N > 0 is a failure however it exited. Files that print
  # no summary keep reporting through their exit status alone.
  nfail=0
  summary="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$OUT_TMP" | tail -1)"
  if [ -n "$summary" ]; then nfail="${summary#* passed, }"; nfail="${nfail%% failed}"; fi
  left="$(find "$SUITE_TMP" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  if [ "$rc" -eq 0 ] && [ "${nfail:-0}" -eq 0 ] && [ "$left" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    # The file's own count rides on the PASS line, and its NOTE lines — what it could not
    # assert here (a locale not installed, a binary not present) — come through. Swallowed
    # with the rest of a passing file's output, a suite whose pins had silently stopped
    # running reported nothing but "61/61" (the 31st lens, IMPORTANT-2).
    if [ -n "$summary" ]; then _sum="$summary"
    elif grep -qE '[0-9]+ passed, [0-9]+ failed' "$OUT_TMP"; then _sum="summary unreadable; enforced by exit status"
    else _sum="no summary line; enforced by exit status"; fi
    printf 'PASS  %s  (%s)\n' "$t" "$_sum"
    grep -E '^[[:space:]]*NOTE ' "$OUT_TMP"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$t")
    printf 'FAIL  %s  (exit %s, %s failed by its own count, %s left in TMPDIR)\n' "$t" "$rc" "${nfail:-0}" "$left"
    sed 's/^/  /' "$OUT_TMP"
    if [ "$left" -gt 0 ]; then
      # Name what was left, a few levels deep: a count says a file leaked, the tree
      # says which fixture or worker made it. Then start the next file clean, so a
      # leak is charged to the file that made it.
      printf '  left behind:\n'
      find "$SUITE_TMP" -mindepth 1 -maxdepth 4 | head -40 | while IFS= read -r _p; do printf '    TMPDIR%s\n' "${_p#"$SUITE_TMP"}"; done
      find "$SUITE_TMP" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
  fi
done

printf '\n%d/%d test files passed' "$PASSED" "$TOTAL"
if [ "$FAILED" -gt 0 ]; then
  printf ' (%d failed: %s)\n' "$FAILED" "${FAILED_NAMES[*]}"
  exit 1
fi
printf '\n'
exit 0
