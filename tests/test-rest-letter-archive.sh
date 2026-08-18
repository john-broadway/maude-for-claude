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

test_start "no letter beats a bad slug: empty slug + no letter → rc 2"
# A first-ever rest with a placeholder slug must hear NO_PRIOR_LETTER (safe
# to proceed), not ARCHIVE_FAILED (told to stop).
maude_letter_archive "" >/dev/null
assert_exit "$?" "2" "guard order: letter existence first"
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

test_start "two dates on the header line → ONE file, first date, no newline in the name"
# grep -o prints every match on its own line; unheaded, that put a literal
# newline byte inside the archive filename while still reporting success.
printf '# Letter from Maude — 2026-08-03 (after 2026-08-02 review)\n\nBody.\n' > "$LETTER"
OUT6="$(maude_letter_archive twin-dates)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT6" = "$UD/letter-from-maude-2026-08-03-twin-dates.md" ] \
   && [ -f "$OUT6" ]; then
  _pass
else
  _fail "expected single clean name, got rc=$RC out='$OUT6'"
fi

test_start "a date in the BODY does not name the copy (header line only)"
printf 'No header here.\nSomething happened on 2026-01-15 though.\n' > "$LETTER"
OUT7="$(maude_letter_archive body-date)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT7" = "$UD/letter-from-maude-$TODAY-body-date.md" ]; then
  _pass
else
  _fail "expected today's stamp (not the body's 2026-01-15), got rc=$RC out='$OUT7'"
fi

test_start "a newline inside the slug becomes a hyphen, never a filename byte"
# sed is line-oriented and never sees \n; the tr pass has to catch it first.
printf '# Letter from Maude — 2026-08-04\n\nBody.\n' > "$LETTER"
OUT8="$(maude_letter_archive "$(printf 'line1\nline2')")"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT8" = "$UD/letter-from-maude-2026-08-04-line1-line2.md" ]; then
  _pass
else
  _fail "expected hyphenated single-line name, got rc=$RC out='$OUT8'"
fi

test_start "cmp(1) absent but cp fine → rc 0 (python3 read-back, ritual not wedged)"
# The inverse failure mode: 'compare tool missing' must never masquerade as
# 'copy failed' and permanently block the letter step on a cmp-less box.
printf '# Letter from Maude — 2026-08-05\n\nBody.\n' > "$LETTER"
NOCMP="$(make_no_binary_bin cmp)"   # the sandbox never links cmp; cp is present
OUT9="$(PATH="$NOCMP" bash -c '. "'"$HOOKS_DIR"'/_maude-common.sh"; maude_letter_archive no-cmp-box' 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT9" = "$UD/letter-from-maude-2026-08-05-no-cmp-box.md" ] \
   && cmp -s "$LETTER" "$OUT9"; then
  _pass
else
  _fail "expected success via python3 fallback, got rc=$RC out='$OUT9'"
fi
rm -rf "$NOCMP"

test_start "a cp that lands WRONG bytes and exits 0 → rc 3 (read-back really compares)"
printf '# Letter from Maude — 2026-08-06\n\nOnly copy.\n' > "$LETTER"
BADCP="$(make_no_binary_bin cp)"
printf '#!/usr/bin/env bash\nprintf garbage > "$2"\nexit 0\n' > "$BADCP/cp"
chmod +x "$BADCP/cp"
OUT10="$(PATH="$BADCP" bash -c '. "'"$HOOKS_DIR"'/_maude-common.sh"; maude_letter_archive liar-cp' 2>/dev/null)"
RC=$?
if [ "$RC" -eq 3 ] && [ -z "$OUT10" ]; then
  _pass
else
  _fail "expected rc 3 on a half-landed copy, got rc=$RC out='$OUT10'"
fi
rm -rf "$BADCP" "$UD/letter-from-maude-2026-08-06-liar-cp.md"

test_start "a copy that does not land → rc 3, success is not reported"
# PATH sandbox without cp: nothing lands, and the read-back (python3 filecmp
# here, since the sandbox never links cmp) finds no archive — refuse, no path.
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

test_start "the maude AGENT's rest instruction archives too (the second door)"
# agents/maude.md carries its own operative 'rewrite the letter' text; the
# 2026-08-17 overwrite would come right back through it if it drifts. The
# string alone is not enough: the source must be ANCHORED (a bare relative
# path resolves to the user's project cwd, not the plugin — found.md's own
# documented rule) and the helper-less fallback must still archive-first.
AGENT="$(dirname "$0")/../agents/maude.md"
if grep -q 'maude_letter_archive' "$AGENT" \
   && grep -q 'CLAUDE_PLUGIN_ROOT/hooks/scripts/_maude-common\.sh' "$AGENT" \
   && grep -q 'no copy, no rewrite' "$AGENT"; then
  _pass
else
  _fail "agents/maude.md: helper unanchored or no archive-first fallback"
fi

export HOME="$OLD_HOME"
print_summary
teardown_test_env
exit "$FAILED"
