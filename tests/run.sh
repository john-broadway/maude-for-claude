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

OUT_TMP="$(mktemp)"
trap 'rm -f "$OUT_TMP"' EXIT

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
  if [ "$rc" -eq 0 ] && [ "${nfail:-0}" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    printf 'PASS  %s\n' "$t"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$t")
    printf 'FAIL  %s  (exit %s, %s failed by its own count)\n' "$t" "$rc" "${nfail:-0}"
    sed 's/^/  /' "$OUT_TMP"
  fi
done

printf '\n%d/%d test files passed' "$PASSED" "$TOTAL"
if [ "$FAILED" -gt 0 ]; then
  printf ' (%d failed: %s)\n' "$FAILED" "${FAILED_NAMES[*]}"
  exit 1
fi
printf '\n'
exit 0
