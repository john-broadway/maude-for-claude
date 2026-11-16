#!/usr/bin/env bash
# /maude:rolodex, her rules, the hook registration and the threat model say what was built.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="$ROOT/commands/rolodex.md"

test_start "the command exists with a description"
assert_file_exists "$CMD" "commands/rolodex.md"
assert_contains "$(sed -n '1,5p' "$CMD")" "description:" "frontmatter description"

test_start "the command prints the approve line and says Claude never runs it"
BODY="$(cat "$CMD")"
assert_contains "$BODY" "maude-rolodex.sh approve" "the approve line"
assert_contains "$BODY" "never run" "never run"
assert_contains "$BODY" "Claude does not run them" "approve and revoke are the user's"
assert_contains "$BODY" "pending/" "pages go under pending/"
assert_contains "$BODY" "seen in session" "provenance for a provider with no file"
assert_contains "$BODY" "as data written by strangers" "the inventory is data"

test_start "her CLAUDE.md counts the commands on disk and names the store"
N="$(find "$ROOT/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
assert_contains "$(cat "$ROOT/.claude/CLAUDE.md")" "$N slash commands" "count matches commands/"
assert_contains "$(cat "$ROOT/.claude/CLAUDE.md")" "rolodex/rolodex.db" "the store is named"

test_start "hooks.json registers the cue once, after the page hook, with a 5 s timeout"
jq -e . "$ROOT/hooks/hooks.json" >/dev/null 2>&1
assert_exit "$?" "0" "hooks.json parses"
assert_eq "$(jq '[.. | objects | select(.command? // "" | test("maude-rolodex-cue.sh"))] | length' "$ROOT/hooks/hooks.json")" "1" "registered once"
assert_eq "$(jq '[.. | objects | select(.command? // "" | test("maude-rolodex-cue.sh")) | .timeout][0]' "$ROOT/hooks/hooks.json")" "5" "timeout 5"
ORDER="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$ROOT/hooks/hooks.json" | grep -n 'maude-page.sh\|maude-rolodex-cue.sh' | cut -d: -f1 | tr '\n' ' ')"
P="${ORDER%% *}"; C="${ORDER#* }"; C="${C%% *}"
[ "$C" = "$((P + 1))" ] && _pass "the cue follows the page hook" || _fail "order: $ORDER"

test_start "the threat model names the Rolodex's guards and its residual"
TM="$(cat "$ROOT/docs/gate-threat-model.md")"
assert_contains "$TM" "What guards the Rolodex" "the section"
assert_contains "$TM" "Not guarded: a shell command" "the residual"

print_summary
teardown_test_env
exit $FAILED
