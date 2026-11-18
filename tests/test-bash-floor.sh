#!/usr/bin/env bash
# tests/test-bash-floor.sh — the bash floor: Maude runs on bash 5.0 or newer, and says so on
# anything older instead of running half-blind (John, 2026-11-17: "require current bash on
# mac"). Three parts: the predicate by argument, what the stop says per hook event, and, on
# a box that has an older bash (a stock Mac's /bin/bash is 3.2), every registered hook run
# under it for real.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"
setup_test_env
source_common

# ── the predicate, by argument (BASH_VERSINFO is read-only: no switch could fake it) ──
test_start "the floor predicate: majors below 5 are too old, 5 and up are not"
for _m in 0 1 2 3 4; do maude_bash_too_old "$_m"; assert_exit "$?" "0" "bash $_m is too old"; done
for _m in 5 6 10; do maude_bash_too_old "$_m"; assert_exit "$?" "1" "bash $_m is not too old"; done
test_start "a major it cannot read counts as too old (closed)"
maude_bash_too_old ""; assert_exit "$?" "0" "empty"
maude_bash_too_old "5x"; assert_exit "$?" "0" "not a number"
test_start "this shell's own major is not too old (this suite needs bash 5)"
maude_bash_too_old "${BASH_VERSINFO[0]}"; assert_exit "$?" "1" "the running bash passes its own floor"

# ── what the stop says, per event. Called directly: on bash 5 nothing reaches it by itself ──
stop_with() {  # <envelope> [script name] → OUT (stdout), ERR (stderr), RC
  OUT="$(printf '%s' "$1" | ( maude_bash_floor_stop "${2:-maude-session-start.sh}" ) 2>"$TEST_TMP/floor.err")"; RC=$?
  ERR="$(cat "$TEST_TMP/floor.err")"
}
PRE='{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
test_start "PreToolUse on an old bash: the tool call is refused, with the fix"
stop_with "$PRE"
assert_exit "$RC" "2" "exit 2: the call does not run unread"
assert_eq "$OUT" "" "nothing on stdout"
assert_contains "$ERR" "bash 5.0" "the refusal names the floor"
assert_contains "$ERR" "brew install bash" "and the fix on a Mac"
assert_contains "$ERR" "${BASH_VERSION}" "and the version it ran under, so a PATH that misses the new bash shows"
assert_contains "$ERR" "${BASH}" "and that bash's path"
test_start "PreToolUse written with a space after the colon is the same event"
stop_with '{"hook_event_name": "PreToolUse", "tool_name": "Write"}'
assert_exit "$RC" "2" "refused"
test_start "SessionStart on an old bash: one notice, the session still starts"
stop_with '{"hook_event_name":"SessionStart","source":"startup"}'
assert_exit "$RC" "0" "exit 0"
assert_contains "$OUT" "bash 5.0" "the notice names the floor"
assert_contains "$OUT" "brew install bash" "and the fix"
assert_eq "$ERR" "" "nothing on stderr"
test_start "SessionStart from any other hook is silent: one hook speaks, not each of them"
stop_with '{"hook_event_name":"SessionStart","source":"startup"}' "maude-tape-wake.sh"
assert_eq "$RC|$OUT|$ERR" "0||" "another session-start hook says nothing"
test_start "every other event on an old bash is silent and exits 0 (a Stop hook that exits 2 would hold the session open)"
for _e in Stop SubagentStop PostToolUse UserPromptSubmit PreCompact SessionEnd; do
  stop_with "{\"hook_event_name\":\"$_e\"}"
  assert_eq "$RC|$OUT|$ERR" "0||" "$_e: silent, 0"
done
test_start "no envelope at all is not a hook: it fails out loud (a script that exited 0 would read as checked and clean)"
stop_with ''
assert_exit "$RC" "1" "exit 1"
assert_eq "$OUT" "" "nothing on stdout"
assert_contains "$ERR" "bash 5.0" "the floor is named on stderr"
stop_with '{"some":"json","but":"no event"}'
assert_exit "$RC" "1" "json with no event key is not a hook either"
test_start "an event name quoted inside a tool's text is not the event"
stop_with '{"hook_event_name":"PostToolUse","tool_input":{"command":"echo \"hook_event_name\":\"PreToolUse\""}}'
assert_eq "$RC|$OUT|$ERR" "0||" "the escaped mention does not refuse a PostToolUse"

# ── every registered hook reaches the floor before it does anything ──
# Statically: each script either sources the common file (whose floor line stands beside
# the blink guard, at the top) or carries the floor line itself.
PAIRS=()
while IFS= read -r _p; do PAIRS+=("$_p"); done \
  < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[].command | "\($e)\t\(.)"' "$ROOT/hooks/hooks.json" | sort -u)
test_start "hooks.json yields registered hooks to check"
[ "${#PAIRS[@]}" -gt 0 ]; assert_exit "$?" "0" "at least one"
test_start "the common file stops an old bash before its first function that needs a new one"
_floor_line="$(grep -n '^maude_bash_too_old "\${BASH_VERSINFO\[0\]:-}" && maude_bash_floor_stop "\${0##\*/}"$' "$HOOKS_DIR/_maude-common.sh" | head -1 | cut -d: -f1)"
[ -n "$_floor_line" ] && [ "$_floor_line" -lt 80 ]
assert_exit "$?" "0" "the floor line is at the top of the common file (line ${_floor_line:-none})"
for _p in "${PAIRS[@]}"; do
  _cmd="${_p#*$'\t'}"; _script="${_cmd#*scripts/}"; _script="${_script%% *}"
  test_start "reaches the floor: $_script"
  if grep -q '^\. "\$DIR/_maude-common\.sh"' "$HOOKS_DIR/$_script" || grep -q '^\[ "\${BASH_VERSINFO\[0\]:-0}" -lt 5 \] && exit 0' "$HOOKS_DIR/$_script"; then _r=0; else _r=1; fi
  assert_exit "$_r" "0" "$_script sources the common file or carries the floor line"
  # And nothing before that line but the few shapes an old bash reads and that do no work:
  # an early line of any other shape is one nobody has read with a bash 3.2 eye.
  _odd="$(awk '/^\. "\$DIR\/_maude-common\.sh"/ || /^\[ "\$\{BASH_VERSINFO\[0\]:-0\}" -lt 5 \] && exit 0/ {exit} !/^[[:space:]]*#/ && !/^[[:space:]]*$/ {print}' "$HOOKS_DIR/$_script" \
    | grep -vxE 'set \+e|DIR="\$\(cd "\$\(dirname "\$0"\)" && pwd\)"|\[ -n "\$\{MAUDE_EYE_BLINK:-\}" \] && exit 0|\[ "\$\{MAUDE_[A-Z_]+:-on\}" = "off" \] && exit 0|case "\$\{MAUDE_[A-Z_]+:-on\}" in|  [A-Za-z0-9|]+\) exit 0 ;;|esac')"
  assert_eq "$_odd" "" "$_script runs only known-plain lines before the floor"
done

# ── for real, where an older bash exists (a stock Mac: /bin/bash 3.2) ──
OLD_BASH=""
# TEST_OLD_BASH names one built for the purpose on a box whose own bash is current.
for _b in "${TEST_OLD_BASH:-}" /bin/bash /usr/bin/bash; do
  [ -n "$_b" ] && [ -x "$_b" ] || continue
  _v="$("$_b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
  case "$_v" in ''|*[!0-9]*) continue ;; esac
  [ "$_v" -lt 5 ] && { OLD_BASH="$_b"; break; }
done
if [ -z "$OLD_BASH" ]; then
  printf '  NOTE  no bash older than 5 on this box: the hooks were NOT run under an old bash here (the macOS leg runs them under /bin/bash)\n'
else
  printf '  NOTE  old bash for the real run: %s (%s)\n' "$OLD_BASH" "$("$OLD_BASH" -c 'echo "$BASH_VERSION"')"
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  _NOTICES=0
  for _p in "${PAIRS[@]}"; do
    _ev="${_p%%$'\t'*}"; _cmd="${_p#*$'\t'}"
    _resolved="${_cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT}"; _resolved="${_resolved#bash }"
    # shellcheck disable=SC2086   # the registered command is a script path and its words
    OUT="$(printf '{"hook_event_name":"%s","tool_name":"Bash","tool_input":{"command":"echo hi"}}' "$_ev" | "$OLD_BASH" $_resolved 2>"$TEST_TMP/floor.err")"; RC=$?
    ERR="$(cat "$TEST_TMP/floor.err")"
    test_start "under $OLD_BASH, $_ev: $_cmd"
    case "$_ev" in
      PreToolUse)
        assert_exit "$RC" "2" "refused"
        assert_contains "$ERR" "bash 5.0" "with the floor named" ;;
      SessionStart)
        assert_exit "$RC" "0" "exit 0"
        case "$OUT" in '') _r=0 ;; *"bash 5.0"*) _r=0; _NOTICES=$((_NOTICES + 1)) ;; *) _r=1 ;; esac
        assert_exit "$_r" "0" "the notice or nothing on stdout, never a half-run hook's output"
        assert_eq "$ERR" "" "nothing on stderr (no syntax error from a shell too old to read the hook)" ;;
      *)
        assert_eq "$RC|$OUT|$ERR" "0||" "silent, 0 (no syntax error from a shell too old to read the hook)" ;;
    esac
  done
  test_start "under $OLD_BASH, the session start says it once across every hook on that event"
  assert_eq "$_NOTICES" "1" "one notice, not one per hook"
  # Her scripts that are not hooks source the same file. With no envelope they must fail,
  # not exit 0 unchecked: verify's 0 means "no findings".
  for _s in maude-verify.sh maude-lint.sh; do
    test_start "under $OLD_BASH, scripts/$_s with no envelope fails out loud"
    OUT="$("$OLD_BASH" "$ROOT/scripts/$_s" </dev/null 2>"$TEST_TMP/floor.err")"; RC=$?
    ERR="$(cat "$TEST_TMP/floor.err")"
    assert_exit "$RC" "1" "exit 1, never the 0 that reads as clean"
    assert_contains "$ERR" "bash 5.0" "and it says why"
  done
fi

teardown_test_env
print_summary; exit $FAILED
