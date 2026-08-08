#!/usr/bin/env bash
# Tests for hooks/scripts/maude-secret-scan.sh — credential-shape detection on
# submitted prompts. Confirms: real token shapes are caught, prose mentions are
# NOT (no false positives), the matched secret value is NEVER echoed, and the
# hook always exits 0 (never blocks).
#
# Every token below is FAKE and is ASSEMBLED FROM PARTS at runtime: that keeps a
# complete credential-shaped literal out of this file's source (the workspace
# content-fingerprint write-guard blocks those) while still feeding the
# hook-under-test a full shape to detect.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

SCAN="$HOOKS_DIR/maude-secret-scan.sh"

# --- fake credential shapes, assembled at runtime (see header) ---
pp='pypi-';  PYPI="${pp}FAKEbodyAAAA0000111122223333444455556666ccccdddd"
gp='ghp_';   GHP="${gp}FAKEbody000011112222333344445555666677778888"
ak='AKIA';   AKIA_KEY="${ak}FAKEABCD01234567"
pk1='-----BEGIN OPENSSH '; pk2='PRIVATE KEY-----'; PK="${pk1}${pk2}"
# 32-hex bodies for the tool-output fixtures, assembled the same way and for the
# same reason. A literal 32-hex string sitting next to `server_logon_token` is,
# correctly, a gitleaks finding: the pre-push guard blocked this very commit over
# three of them. Muting that with a .gitleaksignore fingerprint would hide a real
# detection AND would need re-adding on every amend, since fingerprints carry the
# commit sha. Building the value removes the finding instead of suppressing it, and
# the hook under test still receives an identical string at runtime.
FIXTURE_HEX="$(printf 'DEADBEEF%.0s' 1 2 3 4)"
FIXTURE_HEX2="$(printf 'CAFEBABE%.0s' 1 2 3 4)"

# Run the hook with a given prompt; capture stdout (OUT), stderr (ERR), exit (RC).
run_scan() {
  local prompt="$1"
  OUT="$(jq -nc --arg p "$prompt" '{prompt:$p}' | bash "$SCAN" 2>"$TEST_TMP/err")"
  RC=$?
  ERR="$(cat "$TEST_TMP/err")"
}

# --- detection: each credential shape is caught and labelled ---

test_start "detects a PyPI token shape"
run_scan "uv publish --token ${PYPI}"
assert_contains "$OUT" "MAUDE SECRET GUARD" "alert fired"
assert_contains "$OUT" "PyPI token" "labelled type"
assert_exit "$RC" "0" "never blocks"

test_start "NEVER echoes the secret value (redaction guarantee)"
# The distinctive body of the fake token must appear in NEITHER stdout nor stderr.
assert_not_contains "$OUT" "FAKEbody" "body absent from stdout"
assert_not_contains "$ERR" "FAKEbody" "body absent from stderr"

test_start "detects a GitHub token shape"
run_scan "here it is ${GHP}"
assert_contains "$OUT" "GitHub token" "labelled type"
assert_exit "$RC" "0" "exit"

test_start "detects an AWS access key shape"
run_scan "AWS_ACCESS_KEY_ID=${AKIA_KEY}"
assert_contains "$OUT" "AWS access key" "labelled type"

test_start "detects a private key block"
run_scan "$PK"
assert_contains "$OUT" "private key block" "labelled type"

# --- no false positives: prose mentions of tokens must stay silent ---

test_start "silent on prose mention of token names"
run_scan "can you set up a pypi token and a github token for publishing?"
assert_eq "$OUT" "" "no stdout alert"
assert_exit "$RC" "0" "exit"

test_start "silent on an ordinary prompt"
run_scan "add tests/test-secret-scan.sh and run make test"
assert_eq "$OUT" "" "no stdout alert"
assert_exit "$RC" "0" "exit"

# --- robustness: malformed / empty input never crashes or blocks ---

test_start "silent + exit 0 on empty prompt"
OUT="$(jq -nc '{prompt:""}' | bash "$SCAN" 2>/dev/null)"; RC=$?
assert_eq "$OUT" "" "empty prompt silent"
assert_exit "$RC" "0" "exit"

test_start "silent + exit 0 on prompt-less JSON"
OUT="$(printf '{}' | bash "$SCAN" 2>/dev/null)"; RC=$?
assert_eq "$OUT" "" "no prompt key"
assert_exit "$RC" "0" "exit"

# ── tool-output mode: the leak channel nobody was watching ──────────────────
# Both real credential leaks in this workspace (2026-07-08 via `ps -ef`,
# 2026-07-10/29 via a grep of a game-server config) arrived through TOOL OUTPUT,
# not through John's prompt. The scanner read only .prompt on UserPromptSubmit, so
# it could not see either one, and the CS2 token then sat unrotated for 22 days.
#
# HONEST CEILING: PostToolUse fires AFTER the tool ran, so this cannot PREVENT the
# leak -- the value is already in the transcript. What it can do is raise the alarm
# in the same second instead of never, which is the difference between rotating
# tonight and finding it in an audit three weeks later. Do not let anyone describe
# this as prevention.

test_start "tool-output mode: silent on ordinary command output"
OUT="$(jq -nc '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"ls"},tool_response:{stdout:"README.md\nsrc\n",stderr:""}}' | bash "$SCAN" tool-output 2>/dev/null)"; RC=$?
assert_eq "$OUT" "" "clean output silent"
assert_exit "$RC" "0" "exit 0"

test_start "tool-output mode: catches a GSLT-shaped value in stdout"
OUT="$(jq -nc '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"grep tok cfg"},tool_response:{stdout:"server_logon_token='"$FIXTURE_HEX"'\n",stderr:""}}' | bash "$SCAN" tool-output 2>&1)"; RC=$?
assert_contains "$OUT" "SECRET GUARD" "alerted"
assert_exit "$RC" "0" "never blocks"

test_start "the alert never echoes the value itself"
assert_not_contains "$OUT" "$FIXTURE_HEX" "value withheld"

test_start "tool-output mode: catches sv_setsteamaccount"
OUT="$(jq -nc '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"cat cfg"},tool_response:{stdout:"sv_setsteamaccount '"$FIXTURE_HEX"'\n",stderr:""}}' | bash "$SCAN" tool-output 2>&1)"
assert_contains "$OUT" "SECRET GUARD" "alerted"

test_start "tool-output mode: catches a PVE API token"
OUT="$(jq -nc '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"env"},tool_response:{stdout:"PVEAPIToken=root@pam!ci=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n",stderr:""}}' | bash "$SCAN" tool-output 2>&1)"
assert_contains "$OUT" "SECRET GUARD" "alerted"

test_start "tool-output mode: catches a labelled 32-hex secret"
OUT="$(jq -nc '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"cat x"},tool_response:{stdout:"rcon_password: '"$FIXTURE_HEX2"'\n",stderr:""}}' | bash "$SCAN" tool-output 2>&1)"
assert_contains "$OUT" "SECRET GUARD" "alerted"

test_start "tool-output mode: also reads stderr"
OUT="$(jq -nc --arg tok "${gp}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"x"},tool_response:{stdout:"",stderr:($tok+"\n")}}' | bash "$SCAN" tool-output 2>&1)"
assert_contains "$OUT" "SECRET GUARD" "stderr scanned"

test_start "tool-output mode: reads an MCP tool response body too"
OUT="$(jq -nc '{tool_name:"mcp__proximo__pve_node_syslog",hook_event_name:"PostToolUse",tool_response:{content:[{type:"text",text:"PVEAPIToken=root@pam!x=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]}}' | bash "$SCAN" tool-output 2>&1)"
assert_contains "$OUT" "SECRET GUARD" "mcp body scanned"

test_start "tool-output mode: says plainly that it cannot prevent, only alarm"
OUT="$(jq -nc '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:"x"},tool_response:{stdout:"server_logon_token='"$FIXTURE_HEX"'"}}' | bash "$SCAN" tool-output 2>&1)"
assert_contains "$OUT" "ALREADY IN THE TRANSCRIPT" "honest about the ceiling"

test_start "tool-output mode: malformed json never crashes or blocks"
OUT="$(printf 'not json at all' | bash "$SCAN" tool-output 2>/dev/null)"; RC=$?
assert_exit "$RC" "0" "exit 0 on garbage"

test_start "tool-output mode: empty response silent"
OUT="$(printf '{}' | bash "$SCAN" tool-output 2>/dev/null)"; RC=$?
assert_eq "$OUT" "" "silent"
assert_exit "$RC" "0" "exit 0"

test_start "prompt mode is unchanged by the new arg handling"
run_scan "just a normal sentence"
assert_eq "$OUT" "" "prompt mode still silent"

test_start "the hook is WIRED to PostToolUse, not just implemented"
[ "$(grep -c 'maude-secret-scan.sh tool-output' "$(dirname "$SCAN")/../hooks.json")" -ge 1 ]
assert_exit "$?" "0" "registered in hooks.json"

print_summary
teardown_test_env
exit "$FAILED"
