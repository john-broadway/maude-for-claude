#!/usr/bin/env bash
# Tests for maude_letter_archive — the testable core of /maude:rest step 5's
# archive-before-rewrite. The live letter is ONE user-global file shared by
# every lane; before this helper existed the archive step lived only in habit,
# and on 2026-08-17 the second lane to rest erased the first lane's letter.
# A markdown command can't be unit-tested (it's instructions to Claude); the
# durable copy goes through this helper, so THIS is what we exercise.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

# CRITICAL ISOLATION: the helper writes to $HOME/.claude/maude. Point HOME at
# the sandbox so a test NEVER touches the real letters.
OLD_HOME="$HOME"
export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.claude/maude"
UD="$HOME/.claude/maude"
LETTER="$UD/letter-from-maude.md"

test_start "missing letter → rc 2, nothing created"
OUT="$(maude_letter_archive some-theme)"
RC=$?
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ -z "$(ls "$UD")" ]; then
  _pass
else
  _fail "expected rc 2 + empty, got rc=$RC out='$OUT' dir='$(ls "$UD")'"
fi

test_start "empty letter → rc 2 (nothing worth archiving)"
: > "$LETTER"
maude_letter_archive some-theme >/dev/null
assert_exit "$?" "2" "empty letter refused"
rm -f "$LETTER"

printf '# Letter from Maude — 2026-08-01\n\nHold the line on the gate.\n' > "$LETTER"

test_start "empty slug → rc 1, letter untouched"
maude_letter_archive "" >/dev/null
RC=$?
if [ "$RC" -eq 1 ] && [ "$(ls "$UD")" = "letter-from-maude.md" ]; then
  _pass
else
  _fail "expected rc 1 + no archive, got rc=$RC dir='$(ls "$UD")'"
fi

test_start "punctuation-only slug normalizes to empty → rc 1"
maude_letter_archive "!!! ???" >/dev/null
assert_exit "$?" "1" "unusable slug refused"

test_start "archives under the letter's OWN dated header, not today"
OUT="$(maude_letter_archive "The Empty Buffer!")"
RC=$?
A="$UD/letter-from-maude-2026-08-01-the-empty-buffer.md"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$A" ] && cmp -s "$LETTER" "$A"; then
  _pass
else
  _fail "expected rc 0 + $A byte-equal, got rc=$RC out='$OUT'"
fi

test_start "the live letter survives the archive (copy, never move)"
assert_file_exists "$LETTER" "live letter still present"

test_start "re-running on the same letter is idempotent (no -2 spawned)"
OUT2="$(maude_letter_archive "the-empty-buffer")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT2" = "$A" ] && [ ! -e "$UD/letter-from-maude-2026-08-01-the-empty-buffer-2.md" ]; then
  _pass
else
  _fail "expected same path again, got rc=$RC out='$OUT2'"
fi

test_start "a DIFFERENT letter never overwrites a same-named archive"
# The defect scenario: second lane, same day, and (worst case) same slug.
printf '# Letter from Maude — 2026-08-01\n\nA second lane wrote this one.\n' > "$LETTER"
OUT3="$(maude_letter_archive "the empty buffer")"
RC=$?
A2="$UD/letter-from-maude-2026-08-01-the-empty-buffer-2.md"
if [ "$RC" -eq 0 ] && [ "$OUT3" = "$A2" ] && cmp -s "$LETTER" "$A2" \
   && grep -q "Hold the line" "$A"; then
  _pass
else
  _fail "expected -2 archive + first untouched, got rc=$RC out='$OUT3'"
fi

test_start "an undated letter is stamped with the day it was archived"
printf 'No header on this one, just prose.\n' > "$LETTER"
OUT4="$(maude_letter_archive stray-note)"
RC=$?
TODAY="$(date +%Y-%m-%d)"
if [ "$RC" -eq 0 ] && [ "$OUT4" = "$UD/letter-from-maude-$TODAY-stray-note.md" ]; then
  _pass
else
  _fail "expected today's stamp, got rc=$RC out='$OUT4'"
fi

test_start "a copy that does not land → rc 3, success is not reported"
# PATH sandbox without cp (and without cmp): the copy cannot happen and the
# read-back cannot pass — the helper must refuse, not print a path.
printf '# Letter from Maude — 2026-08-02\n\nOnly copy.\n' > "$LETTER"
NOCP="$(make_no_binary_bin cp)"
OUT5="$(PATH="$NOCP" bash -c '. "'"$HOOKS_DIR"'/_maude-common.sh"; maude_letter_archive only-copy' 2>/dev/null)"
RC=$?
if [ "$RC" -eq 3 ] && [ -z "$OUT5" ]; then
  _pass
else
  _fail "expected rc 3 + no output, got rc=$RC out='$OUT5'"
fi
rm -rf "$NOCP"

test_start "/maude:rest step 5 actually calls the helper (not dead code)"
REST="$(dirname "$0")/../commands/rest.md"
if grep -q 'maude_letter_archive' "$REST" && grep -q 'ARCHIVE_FAILED' "$REST"; then
  _pass
else
  _fail "rest.md does not gate the rewrite on maude_letter_archive"
fi

export HOME="$OLD_HOME"
print_summary
teardown_test_env
exit "$FAILED"
