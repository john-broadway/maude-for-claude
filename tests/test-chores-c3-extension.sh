#!/usr/bin/env bash
# tests/test-chores-c3-extension.sh — roster diff: seed, arrival, silence.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
CACHE="$TEST_TMP/plugin-cache"
mkdir -p "$CACHE/mk/alpha/1.0.0" "$CACHE/mk/beta/0.5.0"
export MAUDE_PLUGIN_CACHE="$CACHE"

test_start "first run seeds silently (not due after seed)"
bash "$CH" run c3-extension >/dev/null 2>&1
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "false" "seed then not due"

test_start "new plugin arrival makes c3 due"
mkdir -p "$CACHE/mk/gamma/2.0.0"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "true" "new arrival makes c3 due"

test_start "run notes the arrival by name"
bash "$CH" run c3-extension >/dev/null 2>&1
assert_contains "$(jq -r '.["c3-extension"].note' "$LEDGER")" "gamma" "run notes the arrival"

test_start "version bump is an arrival too"
mkdir -p "$CACHE/mk/alpha/1.1.0"; rm -rf "$CACHE/mk/alpha/1.0.0"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "true" "version bump detected"

teardown_test_env
exit "$FAILED"
