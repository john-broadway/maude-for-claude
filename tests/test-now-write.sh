#!/usr/bin/env bash
# Tests for scripts/maude-now-write.sh — the one writer of the live buffer (now.md).
#
# Earned 2026-10-06: save.md said "overwrite now.md", rest.md appended a "## Tomorrow"
# block to it, and the session-start hook read it as an append-only log. Nothing
# enforced any of the three, so lanes stacked blocks newest-first and oldest-first in
# one file (496 KB, 18 timed headers, a 09-30 block after the 10-04 ones) and the wake
# greeted a day-old entry. The contract under test: now.md holds exactly ONE block, the
# block's history goes to today-<date>.md + recent.md FIRST, and anything in now.md
# that is not provably elsewhere is archived whole before it is replaced.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

W="$SCRIPTS_DIR/maude-now-write.sh"
START="$HOOKS_DIR/maude-session-start.sh"
MEM="$TEST_TMP/mem"
export MAUDE_MEM_DIR_OVERRIDE="$MEM"
mkdir -p "$MEM"
TODAY="$(date +%Y-%m-%d)"

# write <digest>: feeds the writer on stdin; OUT/ERR/RC for the asserts.
write() {
  local errf="$TEST_TMP/err"
  OUT="$(printf '%s\n' "$1" | bash "$W" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
}
headers() { grep -cE '^## [0-9]{2}:[0-9]{2}' "$1" 2>/dev/null; }

# ── Refusals leave every file as it was ──────────────────────────────
printf '## 08:00 | before\nBEFORE body\n' > "$MEM/now.md"
printf '## 08:00 | before\nBEFORE body\n' >> "$MEM/today-$TODAY.md"
SUM_BEFORE="$(file_digest "$MEM/now.md")"

test_start "an empty digest is refused and now.md is untouched"
write ""
assert_eq "$RC" "2" "exit 2"
assert_eq "$(file_digest "$MEM/now.md")" "$SUM_BEFORE" "now.md bytes unchanged"

test_start "a first line the wake cannot read is refused, nothing written"
write "$(printf 'Session notes\n## 09:00 | late header')"
assert_eq "$RC" "2" "exit 2"
assert_contains "$ERR" "## HH:MM" "the refusal names the shape it wants"
assert_eq "$(file_digest "$MEM/now.md")" "$SUM_BEFORE" "now.md bytes unchanged"
assert_eq "$(headers "$MEM/today-$TODAY.md")" "1" "no history appended on a refusal"
assert_file_absent "$MEM/recent.md" "no recent line on a refusal"

test_start "a missing memory dir is refused, never created"
MAUDE_MEM_DIR_OVERRIDE="$TEST_TMP/nope" write "## 09:00 | x"
assert_eq "$RC" "3" "exit 3"
[ ! -e "$TEST_TMP/nope" ]; assert_exit "$?" "0" "dir not created"

# ── The one-block write ──────────────────────────────────────────────
test_start "a write leaves now.md as exactly the block given"
DIGEST="$(printf '## 10:15 | maude (save)\nDid the thing.\n\n## Tomorrow\n- finish it')"
write "$DIGEST"
assert_eq "$RC" "0" "exit 0"
assert_eq "$(cat "$MEM/now.md")" "$DIGEST" "now.md == digest"
assert_eq "$(headers "$MEM/now.md")" "1" "one timed header"
assert_contains "$(cat "$MEM/now.md")" "## Tomorrow" "the Tomorrow line travels inside the block"

test_start "the write prints the header that landed, read back from the file"
assert_contains "$OUT" "## 10:15 | maude (save)" "readback names the header"

test_start "the block's history lands in today-<date>.md and recent.md"
assert_contains "$(cat "$MEM/today-$TODAY.md")" "Did the thing." "body in today"
assert_eq "$(headers "$MEM/today-$TODAY.md")" "2" "appended, the earlier block kept"
assert_contains "$(cat "$MEM/recent.md")" "## 10:15 | maude (save)" "header line in recent"

test_start "a writer-shaped now.md (its header already in a daily) is not archived"
assert_file_absent "$MEM/today-$TODAY-now-archive.md" "no archive for a block that lives in today"

test_start "the write leaves no temp file in the memory dir"
assert_eq "$(find "$MEM" -name '.now*' | wc -l | tr -d ' ')" "0" "no .now* leftovers"

test_start "a second lane's write replaces the block; both stay in today"
write "$(printf '## 11:40 | gitea (rest)\nSecond lane.')"
assert_eq "$RC" "0" "exit 0"
assert_eq "$(headers "$MEM/now.md")" "1" "still one header"
assert_contains "$(cat "$MEM/now.md")" "Second lane." "newest block is the buffer"
assert_not_contains "$(cat "$MEM/now.md")" "Did the thing." "older block is gone from now.md"
assert_contains "$(cat "$MEM/today-$TODAY.md")" "Did the thing." "older block kept in today"
assert_contains "$(cat "$MEM/today-$TODAY.md")" "Second lane." "newer block in today"
assert_eq "$(grep -c '^## ' "$MEM/recent.md")" "2" "two recent lines"

test_start "the wake greets the header just written"
OUT="$(printf '{}' | bash "$START" 2>/dev/null)"
assert_contains "$OUT" "Anthropic now: ## 11:40 | gitea (rest)" "wake reads the newest write"

test_start "TMPDIR is not where the temp lives (an unwritable TMPDIR does not matter)"
TMPDIR="$TEST_TMP/no-such-tmp" write "$(printf '## 12:00 | tmpdir\nok')"
assert_eq "$RC" "0" "exit 0"
assert_contains "$(cat "$MEM/now.md")" "## 12:00 | tmpdir" "written"

# ── Legacy buffers are kept whole before the first one-block write ───
test_start "a stacked legacy now.md is archived byte-for-byte, then replaced"
cat > "$MEM/now.md" <<'EOF'
## 22:00 | newest-on-top
NEW TOP
## 03:00 | old
OLD MIDDLE
## 01:00 | straggler
OLD TAIL
EOF
LEGACY_SUM="$(file_digest "$MEM/now.md")"
LEGACY_BYTES="$(wc -c < "$MEM/now.md" | tr -d ' ')"
write "$(printf '## 13:00 | after-migration\nclean')"
assert_eq "$RC" "0" "exit 0"
ARCH="$MEM/today-$TODAY-now-archive.md"
assert_file_exists "$ARCH" "archive written"
tail -c "$LEGACY_BYTES" "$ARCH" > "$TEST_TMP/arch-tail"
assert_eq "$(file_digest "$TEST_TMP/arch-tail")" "$LEGACY_SUM" "archive tail == the legacy bytes"
assert_eq "$(headers "$MEM/now.md")" "1" "now.md is one block"
assert_contains "$OUT" "archived" "the write says it archived"

test_start "a second archive the same day appends, never overwrites the first"
FIRST_ARCH_BYTES="$(wc -c < "$ARCH" | tr -d ' ')"
printf '## 05:00 | hand-written\nNOT IN ANY DAILY\n' > "$MEM/now.md"
write "$(printf '## 14:00 | again\nok')"
assert_eq "$RC" "0" "exit 0"
assert_contains "$(cat "$ARCH")" "OLD TAIL" "first archive still there"
assert_contains "$(cat "$ARCH")" "NOT IN ANY DAILY" "a single block absent from every daily is archived too"
[ "$(wc -c < "$ARCH" | tr -d ' ')" -gt "$FIRST_ARCH_BYTES" ]; assert_exit "$?" "0" "archive grew"

# ── Lens round 1 (2026-10-06): a header match is not a content match ──
test_start "a one-block buffer with a ## Tomorrow tail the daily never got is archived"
printf '## 15:00 | lane\nlane body\n' >> "$MEM/today-$TODAY.md"
printf '## 15:00 | lane\nlane body\n\n## Tomorrow\n- TOMORROW-ONLY-HERE\n' > "$MEM/now.md"
write "$(printf '## 15:30 | next\nok')"
assert_eq "$RC" "0" "exit 0"
assert_contains "$(cat "$ARCH")" "TOMORROW-ONLY-HERE" "the tail is in the archive"

test_start "a header that collides with another day's daily does not vouch for a different body"
printf '## 10:00 | session\nsome other day\n' > "$MEM/today-2020-01-01.md"
printf '## 10:00 | session\nUNIQUE-BODY\n' > "$MEM/now.md"
write "$(printf '## 16:00 | next\nok')"
assert_eq "$RC" "0" "exit 0"
assert_contains "$(cat "$ARCH")" "UNIQUE-BODY" "the body is in the archive"

test_start "a body edited after its daily copy is archived"
write "$(printf '## 16:30 | edited\noriginal line')"
printf '## 16:30 | edited\noriginal line\nEDITED-LATER\n' > "$MEM/now.md"
write "$(printf '## 17:00 | next\nok')"
assert_contains "$(cat "$ARCH")" "EDITED-LATER" "the edit is in the archive"

test_start "a digest with a second timed header is refused before anything is written"
SUM_NOW="$(file_digest "$MEM/now.md")"; SUM_DAY="$(file_digest "$MEM/today-$TODAY.md")"; SUM_REC="$(file_digest "$MEM/recent.md")"
write "$(printf '## 18:00 | outer\nx\n## 09:00 | inner\ny')"
assert_eq "$RC" "2" "exit 2"
assert_eq "$(file_digest "$MEM/now.md")" "$SUM_NOW" "now.md untouched"
assert_eq "$(file_digest "$MEM/today-$TODAY.md")" "$SUM_DAY" "daily untouched"
assert_eq "$(file_digest "$MEM/recent.md")" "$SUM_REC" "recent untouched"

# ── Lens round 2: the match is line-aligned ──────────────────────────
# A substring match judged "b" kept because a daily held the line "ab". Each case gets a
# fresh dir, so the archive file existing at all is the evidence, not a token grep.
line_case() {  # <name> <now.md bytes> <daily bytes>
  MEM="$TEST_TMP/mem-$1"; rm -rf "$MEM"; mkdir -p "$MEM"
  printf '%b' "$3" > "$MEM/today-$TODAY.md"
  printf '%b' "$2" > "$MEM/now.md"
  MAUDE_MEM_DIR_OVERRIDE="$MEM" write "$(printf '## 19:00 | x\nbody')"
  ARCH="$MEM/today-$TODAY-now-archive.md"
}
test_start "a buffer that is the tail of a daily line is archived, not judged kept"
line_case suffix 'b\n' 'ab\n'
assert_eq "$RC" "0" "exit 0"
assert_file_exists "$ARCH" "archived"
test_start "a buffer that is the head of a daily line is archived"
line_case prefix 'a\n' 'ab\n'
assert_file_exists "$ARCH" "archived"
test_start "a run whose first line ends a daily line and last line starts one is archived"
line_case straddle 'b\nc\n' 'ab\ncd\n'
assert_file_exists "$ARCH" "archived"
test_start "a blank-line buffer is archived, not matched by any daily"
line_case blank '\n' 'foo\n'
assert_file_exists "$ARCH" "archived"
test_start "a whole-line run that IS in a daily is still judged kept (the positive control)"
line_case aligned 'cd\nef\n' 'ab\ncd\nef\ngh\n'
assert_file_absent "$ARCH" "not archived"

# ── The one-pass matcher's own edges (mutants that survived the cases above) ──
multi_case() {  # <name> <now.md bytes> then pairs: <daily name> <bytes>
  MEM="$TEST_TMP/mem-$1"; rm -rf "$MEM"; mkdir -p "$MEM"; printf '%b' "$2" > "$MEM/now.md"; shift 2
  while [ $# -ge 2 ]; do printf '%b' "$2" > "$MEM/$1"; shift 2; done
  MAUDE_MEM_DIR_OVERRIDE="$MEM" write "$(printf '## 19:30 | x\nbody')"
  ARCH="$MEM/today-$TODAY-now-archive.md"
}
test_start "a run split across two dailies is not one run: archived"
multi_case split 'x\ny\n' today-2020-001.md 'a\nx\n' today-2020-002.md 'y\nb\n'
assert_file_exists "$ARCH" "archived"
test_start "a shorter daily does not read the longer one's leftover lines"
multi_case stale 'x\ny\n' today-2020-001.md 'a\ny\n' today-2020-002.md 'x\n'
assert_file_exists "$ARCH" "archived"
test_start "the daily that holds the run need not be the last one read"
multi_case early 'x\ny\n' today-2020-001.md 'x\ny\n' today-2020-002.md 'other\n'
assert_file_absent "$ARCH" "kept, not archived"

# ── Lens round 3: the real store's magnitude ─────────────────────────
# The writer ran past 120 s on a copy of this box's real store: a 496 KB now.md (3,172
# lines) and 160 dailies. One awk call per daily re-read the whole buffer each time (0.4 s
# mawk, 0.5 s one-true-awk, times 160). The fixture is that shape, not a guess at it.
for A in awk original-awk mawk gawk; do
  command -v "$A" >/dev/null 2>&1 || continue
  test_start "a 500 KB buffer against 160 dailies finishes in seconds ($A)"
  MEM="$TEST_TMP/mem-big-$A"; rm -rf "$MEM"; mkdir -p "$MEM" "$TEST_TMP/shim-$A"
  ln -sf "$(command -v "$A")" "$TEST_TMP/shim-$A/awk"
  awk 'BEGIN { for (i = 0; i < 3200; i++) printf "## 01:00 | stacked legacy line %05d, padded to the length of a real buffer line, which runs long in prose like this one does.....\n", i }' > "$MEM/now.md"
  awk -v dir="$MEM" 'BEGIN { for (d = 1; d <= 160; d++) { f = sprintf("%s/today-2020-%03d.md", dir, d)
      for (i = 0; i < 60; i++) printf "daily %d line %d, a run of text of a realistic length for a daily digest entry here\n", d, i > f; close(f) } }'
  T0=$SECONDS
  PATH="$TEST_TMP/shim-$A:$PATH" MAUDE_MEM_DIR_OVERRIDE="$MEM" write "$(printf '## 20:00 | big\nok')"
  assert_eq "$RC" "0" "exit 0"
  [ $((SECONDS - T0)) -le 10 ]; assert_exit "$?" "0" "took $((SECONDS - T0)) s (bound 10)"
  assert_file_exists "$MEM/today-$TODAY-now-archive.md" "archived"
done

print_summary
teardown_test_env
exit "$FAILED"
