#!/usr/bin/env bash
# Tests for scripts/maude-verify.sh — the project audit.
# Runs the script against the maude repo itself and asserts 0 findings.

set +e
. "$(dirname "$0")/lib.sh"

VERIFY="$SCRIPTS_DIR/maude-verify.sh"

# Run from the maude project root so verify finds its own plugin.json etc.
cd "$MAUDE_ROOT"

OUT="$(bash "$VERIFY" 2>&1)"
RC=$?

test_start "verify is executable"
[ -x "$VERIFY" ] || [ -r "$VERIFY" ]
assert_exit "$?" "0" "readable"

test_start "verify exits 0 on the maude repo (0 findings)"
assert_exit "$RC" "0" "exit"

test_start "verify output ends with 'N findings' summary"
last_line="$(printf '%s' "$OUT" | tail -1)"
assert_contains "$last_line" "findings" "summary line"

test_start "verify output mentions 0 findings"
assert_contains "$OUT" "0 findings" "zero findings"

# Synthetic failing case: mutate a file to introduce a finding
TMP_PLUGIN="/tmp/maude-fake-plugin-$$"
mkdir -p "$TMP_PLUGIN/.claude-plugin"
cat > "$TMP_PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{ this is not valid JSON
EOF
cd "$TMP_PLUGIN"
OUT="$(bash "$VERIFY" 2>&1)"
RC=$?
cd "$MAUDE_ROOT"

test_start "verify exits non-zero on broken plugin.json"
[ "$RC" -ne 0 ]
assert_exit "$?" "0" "non-zero exit"

rm -rf "$TMP_PLUGIN"

print_summary
exit $FAILED
