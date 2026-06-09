#!/usr/bin/env bash
# Tests for scripts/maude-verify.sh — the project audit.
#
# HERMETIC: the green case runs against a committed, stable fixture
# (tests/fixtures/clean-project/) — NOT the live repo. The old test cd'd to
# MAUDE_ROOT and asserted 0 findings against whatever transient untracked state
# happened to be present (a dogfooding house-map, just-edited files with stale
# Revised: dates), so it failed locally while passing on a clean CI checkout.

set +e
. "$(dirname "$0")/lib.sh"

VERIFY="$SCRIPTS_DIR/maude-verify.sh"
FIXTURE="$MAUDE_ROOT/tests/fixtures/clean-project"

test_start "verify is executable"
[ -x "$VERIFY" ] || [ -r "$VERIFY" ]
assert_exit "$?" "0" "readable"

# ── Green case: a clean fixture yields zero findings ─────────────────
OUT="$(bash "$VERIFY" "$FIXTURE" 2>&1)"
RC=$?

test_start "verify exits 0 on the clean fixture"
assert_exit "$RC" "0" "exit"

test_start "verify reports 0 findings on the clean fixture"
assert_contains "$OUT" "0 findings" "zero findings"

test_start "verify output ends with an 'N findings' summary"
assert_contains "$(printf '%s' "$OUT" | tail -1)" "findings" "summary line"

# ── Parser: a watch-list entry with a trailing description must NOT be ─
# misread as a missing path (the bug that tripped the dogfooding house-map).
# Use a SLASH-containing path so it reaches verify's path-detection branch
# (`/*|./*|[a-zA-Z0-9._-]*/*` requires a slash) — a bare filename is skipped
# regardless of the parser, which would make this test hollow. With the buggy
# whole-line parser the trailing "(description)" makes the path look missing;
# with the first-field fix it resolves. This goes RED if the fix is reverted.
PMAP="$(mktemp -d)"
mkdir -p "$PMAP/.claude-plugin" "$PMAP/.maude/plugin" "$PMAP/sub"
printf '{"name":"x","version":"9.9.9"}\n' > "$PMAP/.claude-plugin/plugin.json"
printf 'real\n' > "$PMAP/sub/realfile.md"
cat > "$PMAP/.maude/plugin/house-map.md" <<'EOF'
# House map
## Watch list
- sub/realfile.md        (a trailing description must not break path resolution)
## Notes
EOF
OUT_P="$(bash "$VERIFY" "$PMAP" 2>&1)"
cd "$MAUDE_ROOT"

test_start "watch-list parser ignores a trailing inline description"
printf '%s' "$OUT_P" | grep -q "Watch-list path missing: sub/realfile.md"
assert_exit "$?" "1" "no false missing-path finding for sub/realfile.md"

rm -rf "$PMAP"

# ── Failing case: a broken plugin.json must produce a finding ────────
TMP_PLUGIN="$(mktemp -d)"
mkdir -p "$TMP_PLUGIN/.claude-plugin"
cat > "$TMP_PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{ this is not valid JSON
EOF
OUT_B="$(bash "$VERIFY" "$TMP_PLUGIN" 2>&1)"
RC_B=$?
cd "$MAUDE_ROOT"

test_start "verify exits non-zero on broken plugin.json"
[ "$RC_B" -ne 0 ]
assert_exit "$?" "0" "non-zero exit"

rm -rf "$TMP_PLUGIN"

print_summary
exit $FAILED
