#!/usr/bin/env bash
# Tests for hooks/scripts/maude-lane-copy.sh: one rolling copy per lane at rest, and a
# wake line when a lane shrank since then.
#
# keep  (SessionEnd): copy each lane file (now.md, now_<name>.md in the project's memory
#       dir) to ~/.claude/maude/pile/lanes/<slug>/<name>, only when its bytes changed.
#       One copy per lane, never a dated file per rest.
# check (SessionStart): a lane more than 512 bytes shorter than its copy is named, with
#       the copy's path. Silent otherwise. Restore is phase 3.
# Design: docs/specs/2026-11-11-the-circle-design.md (heal checks; the pile).

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

LC="$HOOKS_DIR/maude-lane-copy.sh"
MEMD="$TEST_TMP/mem"; mkdir -p "$MEMD"
export MAUDE_MEM_DIR_OVERRIDE="$MEMD"
SLUG="$(maude_slug)"
PILE="$HOME/.claude/maude/pile/lanes/$SLUG"
mklane() { python3 -I -c 'import sys; open(sys.argv[1],"w").write("## 2026-11-10 | e\n" + "history line\n"*int(sys.argv[2]))' "$1" "$2"; }

mklane "$MEMD/now_a.md" 400
mklane "$MEMD/now.md" 10
printf 'not a lane\n' > "$MEMD/feedback_x.md"

test_start "keep copies each lane file into the pile, and nothing else"
bash "$LC" keep >/dev/null 2>&1
assert_eq "$(cmp -s "$MEMD/now_a.md" "$PILE/now_a.md" && echo same)" "same" "now_a copied"
assert_file_absent "$PILE/now.md" "now.md is not a phase-1 lane (its writer replaces it whole)"
assert_file_absent "$PILE/feedback_x.md" "a note is not a lane"

test_start "the copy dir is private (0700)"
assert_eq "$(stat -c %a "$PILE" 2>/dev/null || stat -f %Lp "$PILE")" "700" "mode 700"

test_start "a second keep makes no second file, and leaves an unchanged copy alone"
touch -t 202601010000 "$PILE/now_a.md"
M0="$(maude_mtime "$PILE/now_a.md")"
bash "$LC" keep >/dev/null 2>&1
assert_eq "$(ls "$PILE" | wc -l | tr -d ' ')" "1" "still one file (now_a.md)"
assert_eq "$(maude_mtime "$PILE/now_a.md")" "$M0" "unchanged copy not rewritten"

test_start "check is silent when nothing shrank"
OUT="$(bash "$LC" check 2>&1)"
assert_eq "$OUT" "" "silent"

FULL="$(wc -c < "$PILE/now_a.md" | tr -d ' ')"
test_start "check is silent for a small trim (100 bytes)"
head -c "$(( $(wc -c < "$PILE/now_a.md") - 100 ))" "$PILE/now_a.md" > "$MEMD/now_a.md"
OUT="$(bash "$LC" check 2>&1)"
assert_eq "$OUT" "" "silent on small trim"

test_start "check names a lane that lost 4,000 bytes, with the copy's path"
head -c 1200 "$PILE/now_a.md" > "$MEMD/now_a.md"
OUT="$(bash "$LC" check 2>&1)"
assert_contains "$OUT" "Maude: now_a.md is" "signed, names the lane"
assert_contains "$OUT" "shorter than at the last rest" "says what happened"
assert_contains "$OUT" "$PILE/now_a.md" "points at the copy"

test_start "keep does not overwrite the good copy with a shrunken lane"
bash "$LC" keep >/dev/null 2>&1
assert_eq "$(wc -c < "$PILE/now_a.md" | tr -d ' ')" "$FULL" "copy kept at its full size"

test_start "a lane with no copy is silent"
mklane "$MEMD/now_new.md" 5
OUT="$(bash "$LC" check 2>&1)"
assert_not_contains "$OUT" "now_new.md" "no copy, no line"

test_start "no memory dir: both modes exit 0 silently"
MAUDE_MEM_DIR_OVERRIDE="$TEST_TMP/none" bash "$LC" keep >/dev/null 2>&1; RC1=$?
OUT="$(MAUDE_MEM_DIR_OVERRIDE="$TEST_TMP/none" bash "$LC" check 2>&1)"; RC2=$?
assert_eq "$RC1$RC2$OUT" "00" "quiet no-op"

test_start "now.md is not watched in phase 1: Maude's own writer replaces it whole by design"
rm -rf "$PILE"; rm -f "$MEMD/now.md"
{ printf '## 10:00 | big digest\n'; for i in $(seq 1 120); do printf 'line %d of the old block\n' "$i"; done; } \
  | bash "$SCRIPTS_DIR/maude-now-write.sh" >/dev/null 2>&1
bash "$LC" keep >/dev/null 2>&1
printf '## 11:00 | small digest\nshort\n' | bash "$SCRIPTS_DIR/maude-now-write.sh" >/dev/null 2>&1
bash "$LC" keep >/dev/null 2>&1
OUT="$(bash "$LC" check 2>&1)"
assert_not_contains "$OUT" "now.md is" "no false alarm after a routine digest"
assert_file_absent "$PILE/now.md" "now.md not copied"

test_start "a lane deleted outright is named, with its copy"
mklane "$MEMD/now_gone.md" 300
bash "$LC" keep >/dev/null 2>&1
rm -f "$MEMD/now_gone.md"
OUT="$(bash "$LC" check 2>&1)"
assert_contains "$OUT" "now_gone.md is gone" "deletion named"
assert_contains "$OUT" "$PILE/now_gone.md" "points at the copy"
rm -f "$PILE/now_gone.md"

test_start "the SessionEnd hook keeps the copy"
rm -rf "$PILE"; mklane "$MEMD/now_a.md" 400
printf '{"session_id":"s1","reason":"exit"}' | bash "$HOOKS_DIR/maude-session-end.sh" >/dev/null 2>&1
assert_eq "$(cmp -s "$MEMD/now_a.md" "$PILE/now_a.md" && echo same)" "same" "session end copied the lane"

test_start "the wake brief names a lane that shrank"
head -c 900 "$PILE/now_a.md" > "$MEMD/now_a.md"
OUT="$(bash "$HOOKS_DIR/maude-session-start.sh" < /dev/null 2>/dev/null)"
assert_contains "$OUT" "now_a.md is" "brief carries the heal line"
assert_contains "$OUT" "shorter than at the last rest" "and says what happened"

print_summary
teardown_test_env
exit $FAILED
