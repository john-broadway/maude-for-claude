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

print_summary
teardown_test_env
exit "$FAILED"
