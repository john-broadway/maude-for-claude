#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh — the hard-block gate.
#
# Covers:
#   - real positives for every pattern key
#   - false positives that bit v0.1.5 (HEREDOC commit, in-quote substrings)
#   - token-based override mechanism (one-shot pass)

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

GATE="$HOOKS_DIR/maude-gate.sh"

# Run the gate against a synthetic command. Captures exit + stderr.
# Sets $RC and $ERR.
run_gate() {
  local cmd="$1"
  ERR="$(make_bash_tool_input "$cmd" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

# ── Real positives — every pattern key ─────────────────────────────────

test_start "gate blocks bare git push"
run_gate "git push origin main"
assert_exit "$RC" "2" "git push exit"

test_start "gate stderr on git push mentions key hint"
assert_contains "$ERR" "/maude:conscience git-push" "stderr"

test_start "gate blocks --force"
run_gate "git push origin main --force"
assert_exit "$RC" "2" "force-push exit"

test_start "gate stderr on --force says force-push"
assert_contains "$ERR" "force-push" "stderr"

test_start "gate blocks --force-with-lease"
run_gate "git push --force-with-lease origin main"
assert_exit "$RC" "2" "force-with-lease exit"

test_start "gate blocks -f"
run_gate "git push origin main -f"
assert_exit "$RC" "2" "-f exit"

test_start "gate blocks --no-verify"
run_gate "git commit -m hi --no-verify"
assert_exit "$RC" "2" "no-verify exit"

test_start "gate blocks --no-gpg-sign"
run_gate "git commit -m hi --no-gpg-sign"
assert_exit "$RC" "2" "no-gpg-sign exit"

test_start "gate blocks git reset --hard"
run_gate "git reset --hard HEAD~1"
assert_exit "$RC" "2" "reset-hard exit"

test_start "gate blocks git filter-repo"
run_gate "git filter-repo --replace-text foo"
assert_exit "$RC" "2" "filter-repo exit"

test_start "gate blocks git filter-branch"
run_gate "git filter-branch --tree-filter foo HEAD"
assert_exit "$RC" "2" "filter-branch exit"

test_start "gate blocks git commit --amend"
run_gate "git commit --amend"
assert_exit "$RC" "2" "commit-amend exit"

test_start "gate blocks rm -rf /"
run_gate "rm -rf /"
assert_exit "$RC" "2" "rm-rf-root exit"

test_start "gate blocks rm -rf *"
run_gate "rm -rf *"
assert_exit "$RC" "2" "rm-rf-glob exit"

test_start "gate blocks sudo rm -rf"
run_gate "sudo rm -rf /var/log/foo"
assert_exit "$RC" "2" "sudo-rm-rf exit"

test_start "gate blocks DROP TABLE"
run_gate "echo DROP TABLE users"
assert_exit "$RC" "2" "drop-table exit"

# ── False positives — must NOT block ─────────────────────────────────

test_start "gate passes empty command"
run_gate ""
assert_exit "$RC" "0" "empty cmd"

test_start "gate passes git pull"
run_gate "git pull origin main"
assert_exit "$RC" "0" "git pull"

test_start "gate passes commit msg with quoted git push"
run_gate 'git commit -m "do not git push"'
assert_exit "$RC" "0" "quoted git push"

test_start "gate passes single-quoted git push"
run_gate "git commit -m 'do not git push'"
assert_exit "$RC" "0" "single-quoted git push"

test_start "gate passes echo of git push literal"
run_gate "echo 'git push'"
assert_exit "$RC" "0" "echo literal"

test_start "gate passes rm -rf /tmp/foo"
run_gate "rm -rf /tmp/foo"
assert_exit "$RC" "0" "rm -rf /tmp"

test_start "gate passes rm -rf *.tmp"
run_gate "rm -rf *.tmp"
assert_exit "$RC" "0" "rm -rf *.tmp"

test_start "gate passes rm -rf foo/bar"
run_gate "rm -rf foo/bar"
assert_exit "$RC" "0" "rm -rf relative"

test_start "gate passes branch ending in -f"
run_gate "git pull origin feature-stuff"
assert_exit "$RC" "0" "branch with -f"

test_start "gate passes HEREDOC commit message containing git push"
heredoc='git commit -m "$(cat <<'"'"'EOF'"'"'
v0.1.5 commit body mentions git push as a substring
EOF
)"'
run_gate "$heredoc"
assert_exit "$RC" "0" "HEREDOC self-block"

# ── After-separator real positives — must block ──────────────────────

test_start "gate blocks git push after &&"
run_gate "cd foo && git push"
assert_exit "$RC" "2" "&& git push"

test_start "gate blocks git push after ;"
run_gate "echo done; git push"
assert_exit "$RC" "2" "; git push"

# ── Trace events ─────────────────────────────────────────────────────

test_start "gate logs 'blocked' trace event on block"
n="$(count_trace_lines '.kind == "gate" and (.payload | startswith("blocked="))')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "blocked trace count > 0"

# ── Override mechanism ───────────────────────────────────────────────

test_start "gate respects live conscience token"
# Manually drop a token that says "git-push is cleared until far in the future".
mkdir -p "$TEST_TMP/.maude/plugin"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "0" "token allowed pass"

test_start "token clears after one use (one-shot)"
# After previous test, the token should have been removed.
remaining="$(read_care '.gate_cleared["git-push"].until // "absent"')"
assert_eq "$remaining" "absent" "token cleared"

test_start "second matching command after token-use re-blocks"
run_gate "git push origin main"
assert_exit "$RC" "2" "second push blocked again"

test_start "expired token does NOT pass"
printf '{"gate_cleared":{"git-push":{"until":1}}}\n' > "$(care_path)"
run_gate "git push origin main"
assert_exit "$RC" "2" "expired token blocked"

test_start "token for one key does not pass other key"
printf '{"gate_cleared":{"git-push":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_gate "git reset --hard"
assert_exit "$RC" "2" "wrong-key token blocks"

# ── Order matters: more-specific patterns fire first ────────────────

test_start "force-push pattern fires before generic git-push"
rm -f "$(care_path)"
run_gate "git push origin main --force"
# stderr should mention force-push, not generic git-push key
assert_contains "$ERR" "force-push" "force-push specificity"

print_summary
teardown_test_env
exit $FAILED
