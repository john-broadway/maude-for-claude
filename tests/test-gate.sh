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

# ── Command-substitution (v0.3.3): a gated command wrapped in `...` or $(...) ──
# must still block. Backtick was missing from the separator class, so
# `result=\`git push\`` slipped the gate silently (audit finding).
test_start "gate blocks git push inside backtick substitution"
run_gate 'out=`git push origin main`'
assert_exit "$RC" "2" "backtick git push"

test_start "gate blocks rm -rf / inside backtick substitution"
run_gate 'x=`rm -rf /`'
assert_exit "$RC" "2" "backtick rm -rf /"

test_start "gate blocks git push inside \$() substitution"
run_gate 'out=$(git push origin main)'
assert_exit "$RC" "2" "dollar-paren git push"

# ── Bypass coverage (v0.3.1): ordinary command forms must NOT slip the gate ──
# These are everyday ways to write the same command — a routine whitespace or
# `git -C <dir>` variation must not defeat a hard-block.

test_start "gate blocks git push with extra interior whitespace"
run_gate "git  push origin main"
assert_exit "$RC" "2" "double-space git push"

test_start "gate blocks git -C <dir> push"
run_gate "git -C /tmp/repo push origin main"
assert_exit "$RC" "2" "git -C push"

test_start "gate blocks git -C <dir> push --force"
run_gate "git -C /repo push --force"
assert_exit "$RC" "2" "git -C force-push"

test_start "gate blocks rm -rf / with extra whitespace"
run_gate "rm  -rf /"
assert_exit "$RC" "2" "double-space rm -rf /"

test_start "gate blocks rm -fr / (reversed flags)"
run_gate "rm -fr /"
assert_exit "$RC" "2" "rm -fr /"

test_start "gate still passes git -C <dir> pull (not a push)"
run_gate "git -C /repo pull origin main"
assert_exit "$RC" "0" "git -C pull passes"

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

# ── jq-absent contract: the gate is fail-OPEN by design ──────────────
# A jq-free parse of the tool-input JSON is too fragile to trust as a SAFETY gate
# (it would reintroduce the v0.1.6 quote-stripping self-block risk), so with jq
# gone the gate passes everything. The user is told via the SessionStart
# jq-missing notice. This locks the contract so a future change can't silently
# flip it to fail-closed (block-everything) or make it crash.
test_start "gate fails OPEN (exit 0) on a would-be-blocked command when jq is absent"
NOJQ="$(make_nojq_bin)"
make_bash_tool_input "git push origin main" | PATH="$NOJQ" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "0" "no-jq gate exit"

# ── Sole-copy rm -rf — generic config-driven paths ──────────────────────────
# Write a config with two deployment-specific paths. The gate should also
# block the generic defaults (workspace = $TEST_TMP, ~/.claude, any .git).
printf '{"sole_copy_paths":["/srv/app","/srv/secrets"]}\n' > "$MAUDE_GATE_CONFIG"

test_start "gate blocks rm -rf of a configured sole-copy path"
run_gate "rm -rf /srv/app"; assert_exit "$RC" "2" "configured sole-copy"

test_start "gate blocks rm -rf of configured path with trailing slash"
run_gate "rm -rf /srv/app/"; assert_exit "$RC" "2" "configured sole-copy trailing slash"

test_start "gate blocks rm -rf of second configured sole-copy path"
run_gate "rm -rf /srv/secrets"; assert_exit "$RC" "2" "second configured sole-copy"

test_start "gate blocks rm -rf ~/.claude (generic default)"
run_gate "rm -rf ~/.claude"; assert_exit "$RC" "2" "tilde-claude"

test_start "gate blocks rm -rf \$HOME/.claude (generic default)"
run_gate 'rm -rf $HOME/.claude'; assert_exit "$RC" "2" "dollar-HOME-claude"

test_start "gate blocks rm -rf of a .git dir (generic default)"
run_gate "rm -rf /some/repo/.git"; assert_exit "$RC" "2" ".git dir"

test_start "gate blocks rm -rf multi-arg with sole-copy as second arg"
run_gate "rm -rf build/ /srv/app"; assert_exit "$RC" "2" "sole-copy 2nd arg"

test_start "gate blocks rm -Rf of configured path (capital R)"
run_gate "rm -Rf /srv/app"; assert_exit "$RC" "2" "capital R combined"

test_start "gate blocks rm -R of configured path (capital recursive, no force)"
run_gate "rm -R /srv/app"; assert_exit "$RC" "2" "capital R alone"

test_start "gate blocks rm -rf with double-quoted configured path"
run_gate 'rm -rf "/srv/app"'; assert_exit "$RC" "2" "double-quoted sole-copy"

test_start "sole-copy block names its conscience key"
assert_contains "$ERR" "rm-rf-sole-copy" "key hint"

test_start "gate PASSES rm -rf /tmp/foo (not a sole-copy path)"
run_gate "rm -rf /tmp/foo"; assert_exit "$RC" "0" "tmp path safe"

test_start "gate PASSES rm -rf /tmp/build (safe path outside any sole-copy tree)"
run_gate "rm -rf /tmp/build"; assert_exit "$RC" "0" "tmp build dir ok"

test_start "gate PASSES gh pr list (read-only)"
run_gate "gh pr list"; assert_exit "$RC" "0" "gh pr list ok"

test_start "gate PASSES git commit -m 'do not git push' (CANARY)"
run_gate 'git commit -m "do not git push"'; assert_exit "$RC" "0" "canary commit-msg git push"

# RECORDED DECISION: accepted fail-closed false-block — semicolon in commit message
# exposes the path via UNQUOTED; rare + acceptable; clearable via /maude:conscience rm-rf-sole-copy
test_start "gate blocks commit message containing rm -rf /srv/app via semicolon (fail-closed; acceptable)"
run_gate 'git commit -m "; rm -rf /srv/app"'; assert_exit "$RC" "2" "semicolon-in-commit fail-closed"

# ── Public-publish ──────────────────────────────────────────────────────────
test_start "gate blocks gh release create"
run_gate "gh release create v1.0 dist/*"; assert_exit "$RC" "2" "gh release"

test_start "gate blocks uv publish"
run_gate "uv publish"; assert_exit "$RC" "2" "uv publish"

test_start "gate blocks twine upload"
run_gate "twine upload dist/*"; assert_exit "$RC" "2" "twine"

test_start "gate blocks hf upload"
run_gate "hf upload john-broadway/x file"; assert_exit "$RC" "2" "hf"

test_start "public-publish block names its conscience key"
assert_contains "$ERR" "public-publish" "key hint"

test_start "gate PASSES an ordinary gh pr list (not a publish)"
run_gate "gh pr list"; assert_exit "$RC" "0" "gh read ok"

print_summary
teardown_test_env
exit $FAILED
