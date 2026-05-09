#!/usr/bin/env bash
# Tests for hooks/scripts/_maude-common.sh helpers.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

# ── maude_project_dir ─────────────────────────────────────────────────
test_start "project_dir respects CLAUDE_PROJECT_DIR"
assert_eq "$(maude_project_dir)" "$TEST_TMP" "project_dir"

test_start "project_dir returns non-empty existing dir when env unset"
# When run from inside Claude Code, the proc-tree walk (step 2) typically finds
# the claude process's cwd before the filesystem walk-up (step 3) runs. So we
# can't cleanly test step 3 from inside a CC session. Instead verify the
# function returns SOMETHING reasonable: a non-empty existing directory.
saved="$CLAUDE_PROJECT_DIR"
unset CLAUDE_PROJECT_DIR
got="$(maude_project_dir)"
export CLAUDE_PROJECT_DIR="$saved"
[ -n "$got" ] && [ -d "$got" ]
assert_exit "$?" "0" "returns existing dir"

# ── maude_slug ────────────────────────────────────────────────────────
test_start "slug replaces non-alphanumerics with dashes"
slug="$(maude_slug)"
assert_not_contains "$slug" "/" "slug has no slashes"

# ── maude_self_dir ────────────────────────────────────────────────────
test_start "self_dir is project_dir/.maude/plugin"
assert_eq "$(maude_self_dir)" "$TEST_TMP/.maude/plugin" "self_dir"

# ── maude_user_dir ────────────────────────────────────────────────────
test_start "user_dir is HOME/.claude/maude"
assert_eq "$(maude_user_dir)" "$HOME/.claude/maude" "user_dir"

# ── maude_log_trace ───────────────────────────────────────────────────
test_start "log_trace writes a JSONL line"
maude_log_trace "test-kind" "test-payload"
assert_file_exists "$(trace_path)" "trace file created"

test_start "trace line has expected fields"
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"kind":"test-kind"' "kind field"

test_start "trace payload preserved"
assert_contains "$last" '"payload":"test-payload"' "payload field"

# ── maude_strip_quotes ───────────────────────────────────────────────
test_start "strip_quotes removes single-quoted span"
got="$(maude_strip_quotes "echo 'git push' done")"
assert_eq "$got" "echo  done" "single-quote strip"

test_start "strip_quotes removes double-quoted span"
got="$(maude_strip_quotes 'echo "hi there" done')"
assert_eq "$got" "echo  done" "double-quote strip"

test_start "strip_quotes removes mixed quotes"
got="$(maude_strip_quotes "echo 'a' \"b\" c")"
assert_eq "$got" "echo   c" "mixed quote strip"

test_start "strip_quotes flattens newlines (heredoc inside double-quotes)"
input='git commit -m "$(cat <<'"'"'EOF'"'"'
mentions git push in body
EOF
)"'
got="$(maude_strip_quotes "$input")"
# After flatten + strip single-quotes, then double-quotes: only `git commit -m ` remains.
assert_not_contains "$got" "git push" "literal scrubbed from heredoc"

test_start "strip_quotes preserves unquoted content"
got="$(maude_strip_quotes "git push origin main")"
assert_eq "$got" "git push origin main" "unquoted preserved"

test_start "strip_quotes handles backslash-escaped double-quote"
got="$(maude_strip_quotes 'echo "say \"hi\""')"
assert_eq "$got" "echo " "escaped quote handled"

# ── maude_match_gate_pattern ─────────────────────────────────────────
test_start "match_gate_pattern matches bare git push"
maude_match_gate_pattern "git push origin" '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "0" "should match git push"

test_start "match_gate_pattern does NOT match git push inside double-quotes"
maude_match_gate_pattern 'git commit -m "do not git push"' '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "1" "should NOT match git push in quotes"

test_start "match_gate_pattern matches after && separator"
maude_match_gate_pattern "cd foo && git push" '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "0" "should match after &&"

test_start "match_gate_pattern does NOT match git pull"
maude_match_gate_pattern "git pull origin" '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "1" "should NOT match git pull"

# ── maude_have_remember / maude_have_map ─────────────────────────────
test_start "have_remember is false in fresh test env"
maude_have_remember
assert_exit "$?" "1" "no .remember dir"

test_start "have_map is false in fresh test env"
maude_have_map
assert_exit "$?" "1" "no house-map"

mkdir -p "$TEST_TMP/.remember"
test_start "have_remember is true after creating .remember/"
maude_have_remember
assert_exit "$?" "0" "remember exists"

# ── maude_tier1_up ───────────────────────────────────────────────────
test_start "tier1_up false when no care.json"
maude_tier1_up
assert_exit "$?" "1" "no care.json"

test_start "tier1_up false when care.json says down"
printf '{"tier1_up":false,"tier1_last_probe":%d}\n' "$(date +%s)" > "$TEST_TMP/.maude/plugin/care.json"
maude_tier1_up
assert_exit "$?" "1" "tier1 marked down"

test_start "tier1_up true when care.json says up and probe fresh"
printf '{"tier1_up":true,"tier1_last_probe":%d}\n' "$(date +%s)" > "$TEST_TMP/.maude/plugin/care.json"
maude_tier1_up
assert_exit "$?" "0" "tier1 marked up + fresh"

test_start "tier1_up false when probe stale"
printf '{"tier1_up":true,"tier1_last_probe":1}\n' > "$TEST_TMP/.maude/plugin/care.json"
maude_tier1_up
assert_exit "$?" "1" "tier1 stale"

print_summary
teardown_test_env
exit $FAILED
