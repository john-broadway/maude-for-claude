#!/usr/bin/env bash
# The file hook refuses a Write, Edit or MultiEdit into the Rolodex dir anywhere but pending/.
#
# WHY: approved pages, the ledger and what is live are rolodex.db, written only by the
# user's own approve and revoke lines. Claude writes pages under pending/ and asks. The
# hook checks the path as written (~, relative, . and ..) and as it physically resolves
# (a symlinked home, or a pending/ that is a link back into the Rolodex dir).

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

HOOK="$HOOKS_DIR/maude-pre-tool-use.sh"
export HOME="$TEST_TMP/home"
export CLAUDE_PROJECT_DIR="$TEST_TMP/proj"
R="$HOME/.claude/maude/rolodex"
mkdir -p "$R/pending" "$R/inventory" "$CLAUDE_PROJECT_DIR"
: > "$R/rolodex.db"

tool() {  # tool <Write|Edit|MultiEdit> <path> [cwd]
  jq -nc --arg t "$1" --arg fp "$2" --arg cwd "${3:-$CLAUDE_PROJECT_DIR}" \
    '{tool_name:$t, tool_input:{file_path:$fp, content:"x", old_string:"a", new_string:"b",
      edits:[{old_string:"a", new_string:"b"}]}, cwd:$cwd, hook_event_name:"PreToolUse"}'
}
run() { ERR="$(cd "${3:-$CLAUDE_PROJECT_DIR}" && tool "$1" "$2" "${3:-}" | bash "$HOOK" 2>&1 >/dev/null)"; RC=$?; }
refused() {  # <label> <tool> <path> [cwd]
  test_start "$1"
  run "$2" "$3" "${4:-}"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "approve line" "says why"
  assert_contains "$ERR" "**Maude:**" "signed"
}
allowed() {  # <label> <tool> <path> [cwd]
  test_start "$1"
  run "$2" "$3" "${4:-}"
  assert_exit "$RC" "0" "allowed"
}

refused "a Write to rolodex.db is refused" Write "$R/rolodex.db"
refused "an Edit to rolodex.db is refused" Edit "$R/rolodex.db"
refused "a MultiEdit to rolodex.db is refused" MultiEdit "$R/rolodex.db"
refused "a Write to the db's journal is refused" Write "$R/rolodex.db-journal"
refused "a Write to the inventory is refused" Write "$R/inventory/x.tsv"
refused "a Write to a new file in the Rolodex dir is refused" Write "$R/notes.md"
refused "a path that climbs out of pending/ is refused" Write "$R/pending/../rolodex.db"
# shellcheck disable=SC2088   # the literal ~ is the case under test
refused "a literal tilde path is refused" Write "~/.claude/maude/rolodex/rolodex.db"
refused "a relative path from the home is refused" Write ".claude/maude/rolodex/rolodex.db" "$HOME"
refused "a doubled slash and a dot are refused" Write "$HOME/.claude//maude/./rolodex/rolodex.db"

# a directory named with a newline inside pending/, then .. twice: physically the db
mkdir -p "$R/pending/x
"
refused "a newline in a path component cannot hide a climb out of pending/" Write "$R/pending/x
/../../rolodex.db"

# the home reached through a symlink
ln -s "$HOME" "$TEST_TMP/homelink"
refused "the Rolodex dir reached through a symlinked parent is refused" Write "$TEST_TMP/homelink/.claude/maude/rolodex/rolodex.db"

# pending/ itself a link back into the Rolodex dir
mkdir -p "$TEST_TMP/h2/.claude/maude/rolodex"
ln -s "$TEST_TMP/h2/.claude/maude/rolodex" "$TEST_TMP/h2/.claude/maude/rolodex/pending"
HOME="$TEST_TMP/h2" refused "a pending/ that links back into the Rolodex dir is refused" Write "$TEST_TMP/h2/.claude/maude/rolodex/pending/rolodex.db"

# a `..` after a symlink climbs from where the link points
mkdir -p "$TEST_TMP/deep/inner"
ln -s "$R/pending" "$TEST_TMP/deep/inner/toPending"
refused "a .. after a symlink climbs from the link's target" Write "$TEST_TMP/deep/inner/toPending/../rolodex.db"

# a link in pending/ whose target is the db
ln -s ../rolodex.db "$R/pending/evil.md"
refused "a pending/ file that is a link to the db is refused" Edit "$R/pending/evil.md"

# a chain of links longer than any small hop cap, ending at the db
CH="$TEST_TMP/chain"; mkdir -p "$CH"
ln -s "$R/rolodex.db" "$CH/l0"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ln -s "$CH/l$((i - 1))" "$CH/l$i"; done
refused "a chain of twelve links ending at the db is refused" Write "$CH/l12"

# a link loop: never resolves, so it is refused rather than waved through
ln -s "$CH/loopB" "$CH/loopA"; ln -s "$CH/loopA" "$CH/loopB"
refused "a link that never resolves is refused (fail closed)" Write "$CH/loopA"

# a dangling link elsewhere is an ordinary write
ln -s "$TEST_TMP/nowhere/file.txt" "$CLAUDE_PROJECT_DIR/dangling"
allowed "a dangling link outside the Rolodex passes" Write "$CLAUDE_PROJECT_DIR/dangling"

# a case-insensitive filesystem reaches the store through any casing
refused "the Rolodex dir spelled in another case is refused" Write "$HOME/.claude/maude/Rolodex/rolodex.db"
refused "the db spelled in another case is refused" Write "$R/ROLODEX.DB"
allowed "pending/ spelled in another case still passes" Write "$R/Pending/a.md"

# a non-ASCII name under her user dir: a folding filesystem may map it onto the store
refused "a non-ASCII spelling of the Rolodex dir is refused" Write "$HOME/.claude/maude/rolodéx/rolodex.db"
refused "a non-ASCII name inside pending/ is refused too" Write "$R/pending/café.md"
allowed "a non-ASCII name outside her user dir passes" Write "$CLAUDE_PROJECT_DIR/café.md"
NONASCII_HOME="$TEST_TMP/josé"
mkdir -p "$NONASCII_HOME/.claude/maude/rolodex/pending"
HOME="$NONASCII_HOME" allowed "a non-ASCII home can still write under pending/" Write "$NONASCII_HOME/.claude/maude/rolodex/pending/a.md"
HOME="$NONASCII_HOME" refused "a non-ASCII home still guards its db" Write "$NONASCII_HOME/.claude/maude/rolodex/rolodex.db"
refused "a newline is a byte outside printable ASCII too" Write "$HOME/.claude/maude/rolodex/pending/a
b.md"
ln -s "$HOME/.claude/maude" "$TEST_TMP/maudelink"
refused "a non-ASCII name reached through a link to her user dir is refused" Write "$TEST_TMP/maudelink/rolodéx/rolodex.db"

# a sibling of pending/ whose name starts the same
refused "a sibling named pending-x is not pending/" Write "$R/pending-x/a.md"

allowed "a Write under pending/ passes" Write "$R/pending/mending.md"
allowed "an Edit under pending/ passes" Edit "$R/pending/mending.md"
allowed "a sibling named like the dir passes (the false-block contract)" Write "$HOME/.claude/maude/rolodex-notes.md"
allowed "a rolodex dir somewhere else passes" Write "$TEST_TMP/elsewhere/.claude/maude/rolodex/rolodex.db"
allowed "an ordinary project file passes" Write "$CLAUDE_PROJECT_DIR/a.txt"

test_start "a refused write leaves no undo snapshot"
before="$(find "$TEST_TMP" -path '*undo*' -type f 2>/dev/null | wc -l | tr -d ' ')"
run Write "$R/rolodex.db"
after="$(find "$TEST_TMP" -path '*undo*' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_exit "$RC" "2" "refused"
assert_eq "$after" "$before" "no new undo file"

test_start "with no jq the hook does not refuse (its no-jq behavior stands)"
NOJQ="$(make_no_binary_bin jq)"
ERR="$(cd "$CLAUDE_PROJECT_DIR" && tool Write "$R/rolodex.db" | PATH="$NOJQ" bash "$HOOK" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "0" "no refusal without jq"

print_summary
teardown_test_env
exit $FAILED
