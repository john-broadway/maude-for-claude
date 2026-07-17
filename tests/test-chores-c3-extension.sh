#!/usr/bin/env bash
# tests/test-chores-c3-extension.sh — roster diff: seed, arrival, silence.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
CH="$SCRIPTS_DIR/maude-chores.sh"
LEDGER="$TEST_TMP/.maude/plugin/chores.json"
CACHE="$TEST_TMP/plugin-cache"
# A real cached plugin carries its manifest; a bare dir is a transient.
seat_plugin() { mkdir -p "$1/.claude-plugin"; printf '{}\n' > "$1/.claude-plugin/plugin.json"; }
seat_plugin "$CACHE/mk/alpha/1.0.0"; seat_plugin "$CACHE/mk/beta/0.5.0"
export MAUDE_PLUGIN_CACHE="$CACHE"

test_start "first run seeds silently (not due after seed)"
bash "$CH" run c3-extension >/dev/null 2>&1
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "false" "seed then not due"

test_start "new plugin arrival makes c3 due"
seat_plugin "$CACHE/mk/gamma/2.0.0"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "true" "new arrival makes c3 due"

test_start "run notes the arrival by name"
bash "$CH" run c3-extension >/dev/null 2>&1
assert_contains "$(jq -r '.["c3-extension"].note' "$LEDGER")" "gamma" "run notes the arrival"

test_start "version bump is an arrival too"
seat_plugin "$CACHE/mk/alpha/1.1.0"; rm -rf "$CACHE/mk/alpha/1.0.0"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "true" "version bump detected"

test_start "installer transients never enter the roster (issue #34)"
bash "$CH" run c3-extension >/dev/null 2>&1   # settle the roster
mkdir -p "$CACHE/temp_git_1783663093402_j14cs1/.git/objects" \
         "$CACHE/temp_subdir_1784262339427_175csd/skills/install-mfw"
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "false" "transient dirs are not arrivals"

test_start "a manifest-less dir at plugin depth is not a plugin"
mkdir -p "$CACHE/mk/half-extracted/9.9.9"    # no .claude-plugin/plugin.json
bash "$CH" detect >/dev/null 2>&1
assert_eq "$(jq -r '.["c3-extension"].due' "$LEDGER")" "false" "manifest-less dir is not an arrival"

teardown_test_env
exit "$FAILED"
