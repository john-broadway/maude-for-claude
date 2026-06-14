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
cd "$MAUDE_ROOT" || exit 1

test_start "watch-list parser ignores a trailing inline description"
printf '%s' "$OUT_P" | grep -q "Watch-list path missing: sub/realfile.md"
assert_exit "$?" "1" "no false missing-path finding for sub/realfile.md"

rm -rf "$PMAP"

# ── Version-header sync: a stale <!-- Version: --> header is a finding ─
# The release convention bumps EVERY markdown version header to the canonical
# plugin.json version; v0.4.0 missed seven (including the README's own) and
# nothing caught it. This pins the check that now does.
HSYNC="$(mktemp -d)"
mkdir -p "$HSYNC/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HSYNC/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\ncurrent file\n' > "$HSYNC/current.md"
printf '<!-- Version: 1.0.0 -->\nstale file\n' > "$HSYNC/stale.md"
OUT_H="$(bash "$VERIFY" "$HSYNC" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify flags a markdown version header behind plugin.json"
assert_contains "$OUT_H" "STALE HEADER" "stale header finding present"

test_start "stale-header finding names the file and both versions"
assert_contains "$OUT_H" "stale.md says Version: 1.0.0 (expected 2.0.0)" "specific finding"

test_start "a header matching the canonical version is not flagged"
printf '%s' "$OUT_H" | grep -q "current.md says"
assert_exit "$?" "1" "no finding for the in-sync header"

rm -rf "$HSYNC"

# ── Failing case: a broken plugin.json must produce a finding ────────
TMP_PLUGIN="$(mktemp -d)"
mkdir -p "$TMP_PLUGIN/.claude-plugin"
cat > "$TMP_PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{ this is not valid JSON
EOF
bash "$VERIFY" "$TMP_PLUGIN" >/dev/null 2>&1
RC_B=$?
cd "$MAUDE_ROOT" || exit 1

test_start "verify exits non-zero on broken plugin.json"
[ "$RC_B" -ne 0 ]
assert_exit "$?" "0" "non-zero exit"

rm -rf "$TMP_PLUGIN"

print_summary
exit $FAILED
