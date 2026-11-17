#!/usr/bin/env bash
# Tests for hooks/scripts/maude-journal-keep.sh: a Write never replaces a lane's history.
#
# A lane file (<slug>/memory/now.md, now_<name>.md) holds a line of work's dated
# history, newest on top. A Write tool call replaces a file whole, so a Write whose
# content does not keep the old text throws that history away. On 2026-11-11 20:24Z a
# shared handoff of ~3,900 lines was replaced with 35 that way. The rail refuses such a
# Write (exit 42; maude-pre-tool-use.sh turns 42, only 42, into the refusal 2).
# Design: docs/specs/2026-11-11-the-circle-design.md (phase 1, heal checks).

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

JK="$HOOKS_DIR/maude-journal-keep.sh"
PRE="$HOOKS_DIR/maude-pre-tool-use.sh"
MEMD="$TEST_TMP/.claude/projects/-x/memory"
LANE="$MEMD/now_a.md"
mkdir -p "$MEMD"

write_input() {  # $1 path, $2 content file
  jq -nc --arg fp "$1" --rawfile c "$2" '{tool_name:"Write", tool_input:{file_path:$fp, content:$c}}'
}
edit_input() {  # $1 path
  jq -nc --arg fp "$1" '{tool_name:"Edit", tool_input:{file_path:$fp, old_string:"a", new_string:"b"}}'
}
gate() { ERR="$(printf '%s' "$1" | bash "$JK" gate 2>&1 >/dev/null)"; RC=$?; }
mklane() { python3 -I -c 'import sys; open(sys.argv[1],"w").write("## 2026-11-10 09:00Z | old entry\n" + "history line\n"*int(sys.argv[2]))' "$1" "$2"; }

test_start "a Write that replaces a non-empty lane file is refused"
mklane "$LANE" 400
printf '# short\n' > "$TEST_TMP/new"
gate "$(write_input "$LANE" "$TEST_TMP/new")"
assert_eq "$RC" "42" "rail exit 42"
assert_contains "$ERR" "is a lane's history" "says why"
assert_contains "$ERR" "Maude:" "signed"

test_start "the pre-tool-use hook turns the refusal into the harness block"
printf '%s' "$(write_input "$LANE" "$TEST_TMP/new")" | bash "$PRE" >/dev/null 2>&1
assert_eq "$?" "2" "pre-tool-use exit 2"

test_start "a Write that puts a new dated entry on top of the old text passes"
{ printf '## 2026-11-11 21:00Z | new\n\n'; cat "$LANE"; } > "$TEST_TMP/new"
gate "$(write_input "$LANE" "$TEST_TMP/new")"
assert_eq "$RC" "0" "prepend passes"

test_start "a Write that appends below the old text passes"
{ cat "$LANE"; printf 'more\n'; } > "$TEST_TMP/new"
gate "$(write_input "$LANE" "$TEST_TMP/new")"
assert_eq "$RC" "0" "append passes"

test_start "a Write to a new lane file passes"
printf 'x\n' > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_fresh.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "new file passes"

test_start "a Write over an empty lane file passes"
: > "$MEMD/now_empty.md"
gate "$(write_input "$MEMD/now_empty.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "empty file passes"

test_start "the plain now.md is a lane too"
mklane "$MEMD/now.md" 50
printf 'x\n' > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now.md" "$TEST_TMP/new")"
assert_eq "$RC" "42" "now.md refused"

test_start "an Edit on a lane file passes (targeted; a whole-section cut is a named residual)"
gate "$(edit_input "$LANE")"
assert_eq "$RC" "0" "edit passes"

test_start "a non-lane note may be rewritten whole"
mklane "$MEMD/feedback_x.md" 50
gate "$(write_input "$MEMD/feedback_x.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "feedback note passes"

test_start "the remember plugin's handoff is not this rail's (its /remember replaces it by design)"
mkdir -p "$TEST_TMP/.remember"; mklane "$TEST_TMP/.remember/remember.md" 50
gate "$(write_input "$TEST_TMP/.remember/remember.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "remember.md passes"

test_start "a dotted path to the lane is refused the same"
gate "$(write_input "$MEMD/./now_a.md" "$TEST_TMP/new")"
assert_eq "$RC" "42" "./ path refused"
gate "$(write_input "$MEMD/../memory/now_a.md" "$TEST_TMP/new")"
assert_eq "$RC" "42" "../ path refused"

test_start "a lane reached through a symlinked memory dir is refused the same"
mkdir -p "$TEST_TMP/.claude/projects/-y"
ln -s "$MEMD" "$TEST_TMP/.claude/projects/-y/memory"
gate "$(write_input "$TEST_TMP/.claude/projects/-y/memory/now_a.md" "$TEST_TMP/new")"
assert_eq "$RC" "42" "symlinked dir refused"

test_start "CRLF and non-ASCII old text, kept whole, passes byte for byte"
printf '## 2026-11-10 | caf\303\251\r\nline two\r\n' > "$MEMD/now_crlf.md"
{ printf '## 2026-11-11 | new\r\n'; cat "$MEMD/now_crlf.md"; } > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_crlf.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "crlf+utf8 kept passes"

test_start "a lane over 128 KiB replaced is judged and refused"
mklane "$MEMD/now_big.md" 15000
printf 'x\n' > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_big.md" "$TEST_TMP/new")"
assert_eq "$RC" "42" "big lane refused"

test_start "a Write carrying over 128 KiB of new content reaches the judge (stdin, not argv)"
python3 -I -c 'import sys; open(sys.argv[1],"w").write("unrelated\n"*20000)' "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_big.md" "$TEST_TMP/new")"
assert_eq "$RC" "42" "200 KiB replacement refused"
{ printf '## 2026-11-11 | new\n'; python3 -I -c 'print("pad\n"*40000)'; cat "$MEMD/now_big.md"; } > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_big.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "big prepend keeping the old text passes"

test_start "a CRLF lane written back with LF line ends, text kept, passes"
printf '## 2026-11-10 | old\r\nline two\r\n' > "$MEMD/now_crlf2.md"
printf '## 2026-11-11 | new\n## 2026-11-10 | old\nline two\n' > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_crlf2.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "line-end change only passes"

test_start "a lane with a UTF-8 BOM, text kept without the BOM, passes"
printf '\357\273\277## 2026-11-10 | old\nline\n' > "$MEMD/now_bom.md"
printf '## 2026-11-11 | new\n## 2026-11-10 | old\nline\n' > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_bom.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "bom dropped passes"

test_start "dropping only the final newline of the old text passes"
printf '## 2026-11-10 | old\nline\n' > "$MEMD/now_nl.md"
printf '## 2026-11-11 | new\n## 2026-11-10 | old\nline' > "$TEST_TMP/new"
gate "$(write_input "$MEMD/now_nl.md" "$TEST_TMP/new")"
assert_eq "$RC" "0" "trailing newline only passes"

test_start "content with a lone surrogate replacing a lane is refused, not waved through"
IN="$(jq -nc --arg fp "$LANE" '{tool_name:"Write", tool_input:{file_path:$fp, content:"X"}}' | sed 's/"content":"X"/"content":"\\ud800 short"/')"
gate "$IN"
assert_eq "$RC" "42" "lone surrogate refused"

test_start "without jq the rail fails open"
IN="$(write_input "$LANE" "$TEST_TMP/new")"
NOJQ="$TEST_TMP/nojq-bin"; mkdir -p "$NOJQ"
for b in bash cat python3 dirname cd pwd; do p="$(command -v "$b" 2>/dev/null)"; [ -n "$p" ] && [ -x "$p" ] && ln -sf "$p" "$NOJQ/$b"; done
RC="$(printf '%s' "$IN" | PATH="$NOJQ" bash "$JK" gate >/dev/null 2>&1; echo $?)"
assert_eq "$RC" "0" "no jq: open"

print_summary
teardown_test_env
exit $FAILED
