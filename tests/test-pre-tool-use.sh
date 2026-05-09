#!/usr/bin/env bash
# Tests for hooks/scripts/maude-pre-tool-use.sh — pre-Write/Edit checks.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

PRE="$HOOKS_DIR/maude-pre-tool-use.sh"

run_pre() {
  local fp="$1"
  ERR="$(make_edit_tool_input "$fp" | bash "$PRE" 2>&1 >/dev/null)"
  RC=$?
}

# Pre-seed care.json + a CLAUDE.md Read in trace so the CLAUDE.md-unread
# whisper doesn't fire across the watch-list and registry tests below.
# (Real $HOME/.claude/CLAUDE.md exists in the sandbox; without seeding,
# every Edit would draw the unread warning and mask other assertions.)
printf '{"claudemd_warned":"%s"}\n' "$(date +%Y-%m-%d)" > "$(care_path)"

# Always exits 0
test_start "pre-tool exits 0 with no map"
run_pre "$TEST_TMP/foo.txt"
assert_exit "$RC" "0" "exit"

# House-map watch list
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map
## Watch list
- CLAUDE.md
- secrets.yaml
EOF

test_start "pre-tool warns on watch-list path"
run_pre "$TEST_TMP/.claude/CLAUDE.md"
assert_contains "$ERR" "watch list" "watch warning"

test_start "pre-tool silent on non-watched path"
run_pre "$TEST_TMP/random/file.py"
assert_eq "$ERR" "" "no warning"

# Registry file class
test_start "pre-tool warns on settings.json"
run_pre "$HOME/.claude/settings.json"
assert_contains "$ERR" "registry file" "registry warning"

test_start "pre-tool warns on installed_plugins.json"
run_pre "$HOME/.claude/installed_plugins.json"
assert_contains "$ERR" "registry file" "registry warning"

# CLAUDE.md unread check
# Need a CLAUDE.md to exist somewhere AND no Read of any CLAUDE.md in trace today.
mkdir -p "$TEST_TMP/.claude"
cat > "$TEST_TMP/CLAUDE.md" <<'EOF'
# CLAUDE.md
EOF
: > "$(trace_path)"
: > "$(care_path)"
printf '{}\n' > "$(care_path)"

test_start "pre-tool warns CLAUDE.md unread when none Read today"
run_pre "$TEST_TMP/some-other-file.py"
assert_contains "$ERR" "CLAUDE.md has not been Read" "claudemd warning"

test_start "pre-tool stamps care.json after CLAUDE.md warning"
warned="$(read_care '.claudemd_warned')"
assert_eq "$warned" "$(date +%Y-%m-%d)" "stamped today"

test_start "pre-tool does NOT re-fire CLAUDE.md warning same day"
run_pre "$TEST_TMP/another-file.py"
assert_not_contains "$ERR" "CLAUDE.md has not been Read" "cooldown holds"

# Reset and seed trace with a Read of CLAUDE.md
printf '{}\n' > "$(care_path)"
jq -nc --arg ts "2026-05-08T12:00:00Z" \
  '{ts:$ts, kind:"tool", tool:"Read", target:"/some/CLAUDE.md"}' \
  > "$(trace_path)"

test_start "pre-tool silent on CLAUDE.md when one was Read this session"
run_pre "$TEST_TMP/some-file.py"
assert_not_contains "$ERR" "CLAUDE.md has not been Read" "silent after Read"

# No file_path in input
test_start "pre-tool exits cleanly with no target"
ERR="$(printf '{}' | bash "$PRE" 2>&1 >/dev/null)"
RC=$?
assert_exit "$RC" "0" "no target exit"

print_summary
teardown_test_env
exit $FAILED
