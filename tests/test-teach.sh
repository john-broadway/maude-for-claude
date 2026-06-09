#!/usr/bin/env bash
# Tests for maude_identity_append — the testable core of /maude:teach.
# A markdown command can't be unit-tested (it's instructions to Claude); the
# actual durable write goes through this helper, so THIS is what we exercise.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

# CRITICAL ISOLATION: the helper writes to $HOME/.claude/maude/identity.md.
# Point HOME at the sandbox so a test NEVER appends to the real profile.
OLD_HOME="$HOME"
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
ID="$HOME/.claude/maude/identity.md"

test_start "append to a fresh profile creates identity.md"
maude_identity_append "I work mountain time" "2026-06-09"
assert_file_exists "$ID" "identity.md created"

test_start "fresh profile has a 'Told by the user' section"
content="$(cat "$ID" 2>/dev/null)"
assert_contains "$content" "## Told by the user" "section present"

test_start "the told fact and its date are recorded"
assert_contains "$content" "2026-06-09: I work mountain time" "dated entry"

test_start "a second fact is added"
maude_identity_append "I prefer terse answers" "2026-06-09"
content="$(cat "$ID" 2>/dev/null)"
assert_contains "$content" "I prefer terse answers" "second fact present"

test_start "still exactly one 'Told by the user' header"
assert_eq "$(grep -c '^## Told by the user' "$ID")" "1" "single section header"

test_start "empty fact is rejected with non-zero status"
maude_identity_append "" "2026-06-09"
rc=$?
[ "$rc" -ne 0 ]
assert_exit "$?" "0" "non-zero on empty fact"

test_start "empty fact leaves the file unchanged"
before="$(cat "$ID" 2>/dev/null)"
maude_identity_append "" "2026-06-09" >/dev/null 2>&1
assert_eq "$(cat "$ID" 2>/dev/null)" "$before" "unchanged on empty fact"

# Existing profile that has NO 'Told by the user' section yet: it must be added
# WITHOUT disturbing the persona preamble or existing observed blocks.
cat > "$ID" <<'EOF'
# Maude — persona preamble
She knows where things are.

## Observed 2026-06-01 — works late
EOF

test_start "append preserves an existing preamble"
maude_identity_append "I am a disabled veteran" "2026-06-09"
content="$(cat "$ID" 2>/dev/null)"
assert_contains "$content" "persona preamble" "preamble preserved"

test_start "append preserves an existing observed block"
assert_contains "$content" "## Observed 2026-06-01" "observed block preserved"

test_start "append adds the section and the told fact"
assert_contains "$content" "## Told by the user" "section added"
assert_contains "$content" "I am a disabled veteran" "fact added"

# A fact with backslash escapes must round-trip literally on the section-present
# path. awk -v does C-escape processing (\t → tab, \n → newline), which corrupted
# the entry — and only on the 2nd+ teach (awk path), so the 1st recorded clean.
test_start "a backslash-bearing fact round-trips literally (section-present awk path)"
maude_identity_append 'I keep notes in C:\notes and use \t tabs' "2026-06-09"
content="$(cat "$ID" 2>/dev/null)"
assert_contains "$content" 'C:\notes and use \t tabs' "backslashes preserved verbatim"

test_start "a whitespace-only fact is rejected (not just truly-empty)"
maude_identity_append "   " "2026-06-09"
rc=$?
[ "$rc" -ne 0 ]
assert_exit "$?" "0" "non-zero on whitespace-only fact"

test_start "leading/trailing whitespace is trimmed from a recorded fact"
maude_identity_append "   spaced out fact   " "2026-06-09"
content="$(cat "$ID" 2>/dev/null)"
assert_contains "$content" "- 2026-06-09: spaced out fact" "trimmed entry"

export HOME="$OLD_HOME"
print_summary
teardown_test_env
exit $FAILED
