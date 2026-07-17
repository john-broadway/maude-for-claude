#!/usr/bin/env bash
# Recursion-guard completeness: EVERY hook registered in hooks/hooks.json must
# be inert (no output, exit 0) when invoked under MAUDE_EYE_BLINK=1. This
# closes the whole class of bug, not just the one instance found
# (maude-secret-scan.sh was the sole registered hook that didn't source
# _maude-common.sh and so didn't inherit its guard) — any future hook that
# forgets to source the common file, or forgets its own inline guard, fails
# this test instead of silently re-entering during a blink.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

setup_test_env
export CLAUDE_PLUGIN_ROOT="$ROOT"

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq required for this test — skipping (see test-nojq.sh for the no-jq path)\n' >&2
  print_summary
  teardown_test_env
  exit 0
fi

# Every distinct "command" registered anywhere in hooks.json — each script,
# with each argument shape it's actually invoked with (e.g. `maude-mission.sh
# clear|hold|verify|capture` are 4 separate invocations of one script).
# bash-3 compatible (macOS): no mapfile
COMMANDS=()
while IFS= read -r _c; do COMMANDS+=("$_c"); done \
  < <(jq -r '[.hooks[][].hooks[].command] | .[]' "$ROOT/hooks/hooks.json" | sort -u)

test_start "hooks.json yields registered commands to check"
[ "${#COMMANDS[@]}" -gt 0 ]
assert_eq "$?" "0" "hooks.json yields registered commands to check"

for cmd in "${COMMANDS[@]}"; do
  resolved="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT}"
  OUT="$(MAUDE_EYE_BLINK=1 bash -c "$resolved" < /dev/null 2>&1)"
  RC=$?
  test_start "silent under blink: $cmd"
  assert_eq "$OUT" "" "silent under blink: $cmd"
  test_start "exit 0 under blink: $cmd"
  assert_eq "$RC" "0" "exit 0 under blink: $cmd"
done

teardown_test_env
print_summary; exit $FAILED
