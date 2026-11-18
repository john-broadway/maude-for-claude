#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced: run_gate sets ERR/RC and the parts read CR/WRAP; lint does not follow the source
# Shared by the tests/test-gate*.sh files that were one file until 2026-11-16 (it took five
# minutes alone; split so the suite can run its files side by side). Sourced after lib.sh's
# setup_test_env. Holds only what more than one part needs.

GATE="$HOOKS_DIR/maude-gate.sh"

# Run the gate against a synthetic command. Captures exit + stderr.
# Sets $RC and $ERR.
run_gate() {
  local cmd="$1"
  ERR="$(make_bash_tool_input "$cmd" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}
# A gate row that fails says what the gate SAID. Until 2026-11-17 a red row gave only the
# exit status ("expected exit=0 got=2"), and when the public macOS leg refused a control
# on the merge of v0.38.0 nobody could tell which key had refused it, the clock's or
# another. lib.sh's assert_exit is kept under another name and wrapped: on a mismatch the
# label carries the first of the gate's own words from the last run_gate.
# Once only: sourced a second time, the copy would be of the wrapper and call itself.
declare -F _lib_assert_exit >/dev/null || eval "$(declare -f assert_exit | sed '1s/^assert_exit /_lib_assert_exit /')"
assert_exit() {
  if [ "$1" != "$2" ] && [ -n "${ERR:-}" ]; then
    _lib_assert_exit "$1" "$2" "${3:-exit} [the gate said: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-300)]"
  else
    _lib_assert_exit "$@"
  fi
}
# A reservation's identity is the exact CALL: the session and the cksum of its tool_input
# bytes, computed the way the gate computes it. Seeds a reservation by hand:
#   seed_reserved <token-file> <key> <sid> <age-seconds> <command>
# Exactly as maude_call_fp hashes: keys SORTED, and NO trailing newline (jq prints one;
# the lib's command substitution drops it, so a seeded fp must drop it too).
# … and the tool NAME with them (lens 6): the same bytes under another tool are another call.
fp_of() { printf '%s' "$(make_bash_tool_input "$1" | jq -Sc '{n: (.tool_name // ""), i: (.tool_input // {})}')" | cksum | awk '{print $1}'; }
seed_reserved() {
  printf '{"gate_cleared":{"%s":{"until":%d,"reserved":{"sid":"%s","at":%d,"fp":"%s","head":"%.60s","v":3}}}}\n' \
    "$2" $(($(date +%s) + 600)) "$3" $(($(date +%s) - $4)) "$(fp_of "$5")" "$5" > "$1"
}


# The red clear script's path as the backstop tests spell it (the red-backstop and
# lens-fold parts both use it).
CR='/x/hooks/scripts/maude-clear-red.sh'

# A wrapped amend, used by both wrapping parts.
WRAP="bash -c 'git commit -m m --amend'"
