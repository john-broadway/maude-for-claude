#!/usr/bin/env bash
# The wake carries THIS LANE's last handoff, whole enough to act on, small enough to land.
#
# Earned 2026-09-25. .remember/remember.md is append-only and shared by every lane (64
# handoffs, 677 KB). The wake gave one 200-char line: the last "## Next" in the file. The
# newest handoff had no "## Next", so the line came from the block before it and said
# "fix pmg.statistics_sender dropping orderby", a fix that block's own later note calls
# ON PURPOSE, do not fix. And it was another lane's handoff, unlabelled.
# Hook output past the harness's inline size is parked in a file nobody opens; 3.6 KB is
# the largest SessionStart output measured landing inline here, so the whole brief must
# stay under 3,500 bytes.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
START="$HOOKS_DIR/maude-session-start.sh"
R="$TEST_TMP/.remember"
mkdir -p "$R"

wake() {  # <lane>
  OUT="$(printf '{}' | MAUDE_SESSION_LABEL="$1" bash "$START" 2>/dev/null)"
}

# The real file's shapes: a header naming the lane in two spellings, State/Next/Traps
# sections, and a newest block that is one paragraph with no sections at all.
cat > "$R/remember.md" <<'EOF'
# Handoff

## Next
ANCIENT unsectioned-era handoff.

# Handoff — 2026-09-20 10:00Z (maude lane, Opus 5.5, session aaaa)

## State
MAUDESTATE the eye was shared across lanes.

## Next
MAUDENEXT key the eye per session.

# Handoff — proximo lane, 2026-09-24 03:00Z (Opus 5.5)

## State
PROXSTATE secret record landed.

## Next
PROXNEXT fix pmg dropping orderby.

## Traps (new)
- PROXTRAP orderby is ON PURPOSE, do not fix it.

# Handoff — 2026-09-24 15:40Z (proximo lane, Opus 5.5, session bbbb) → the proximo session
PROXNEWEST pass the remaining work to the proximo session; the cut is applied but uncommitted.
EOF
test_start "a lane gets ITS OWN last handoff, not the newest in the file"
wake maude
assert_contains "$OUT" "MAUDESTATE" "the lane's State is carried"
assert_contains "$OUT" "MAUDENEXT" "the lane's Next is carried"
assert_not_contains "$OUT" "PROXNEWEST" "another lane's newer handoff is not presented as ours"

test_start "a lane with no handoff gets the newest, labelled with ITS lane"
wake wick
assert_contains "$OUT" "PROXNEWEST" "the newest block's body is carried"
assert_contains "$OUT" "none yet for wick" "says this lane has none"
assert_contains "$OUT" "proximo lane" "names whose handoff it is"

test_start "a newest block with no ## Next is carried itself, never the Next of the block before"
assert_not_contains "$OUT" "PROXNEXT" "the older block's Next does not stand in for the newest"

test_start "the lane match reads the header's lane, not a word in the body"
cat >> "$R/remember.md" <<'EOF'

# Handoff — 2026-09-25 01:00Z (sur lane, session cccc)
SURBODY the maude lane was mentioned here but this is sur's.
EOF
wake maude
assert_contains "$OUT" "MAUDENEXT" "still the maude block"
assert_not_contains "$OUT" "SURBODY" "a body mention is not a lane"

test_start "the pointer names the line the full block starts on"
wake wick
SUR_HDR="$(grep -n '^# Handoff .*sur lane' "$R/remember.md" | cut -d: -f1)"
assert_contains "$OUT" "remember.md:$SUR_HDR" "points at the block's header line"

test_start "the age is the chosen BLOCK's date, not the shared file's mtime"
# Every lane appends to this file, so its mtime is "today" while this lane's handoff may
# be ten days old (the live wake said "today" beside a 09-15 handoff on 09-25).
touch "$R/remember.md"
. "$HOOKS_DIR/_maude-common.sh"
AGE_D="$(maude_days_between 2026-09-20 "$(date +%Y-%m-%d)")"
wake maude
assert_contains "$OUT" "Last handoff (.remember, ${AGE_D}d ago):" "age from the maude block's header date"
assert_not_contains "$OUT" "Last handoff (.remember, today):" "not the file's mtime"

# ── the budget ─────────────────────────────────────────────────────────
test_start "a huge handoff is capped, and the whole brief still lands inline"
{
  printf '\n# Handoff — 2026-09-25 02:00Z (big lane, session dddd)\n\n## State\n'
  for i in $(seq 1 120); do printf 'BIGLINE %03d %s\n' "$i" "$(printf 'x%.0s' $(seq 1 280))"; done
  printf '\n## Next\nBIGNEXT the end.\n'
} >> "$R/remember.md"
wake big
HB="$(printf '%s\n' "$OUT" | awk '/Last handoff/{f=1} f&&/^  [A-Z]/&&!/Last handoff/&&!/^    /{f=0} f' | wc -c | tr -d ' ')"
assert_contains "$OUT" "BIGLINE 001" "the head of the block is carried"
[ "$HB" -le 1400 ] || _fail "handoff section is $HB bytes (cap ~1200 + label)"
TOTAL="$(printf '%s' "$OUT" | wc -c | tr -d ' ')"
[ "$TOTAL" -le 3500 ] || _fail "the whole brief is $TOTAL bytes; past 3.5 KB it may be parked unread"

# ── the pre-header shape still works (a file with no '# Handoff' lane headers) ──
test_start "a file of bare '## Next' sections still yields the newest Next"
printf '## Next\nOLDONE\n\n## Next\nNEWONE\n' > "$R/remember.md"
wake maude
assert_contains "$OUT" "NEWONE" "newest Next"
assert_not_contains "$OUT" "OLDONE" "not the first"

test_start "a short fallback line survives a tiny budget (the 150-byte floor holds)"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude MAUDE_BRIEF_MAX=0 bash "$START" 2>/dev/null)"
assert_contains "$OUT" "NEWONE" "the fallback line survives a tiny budget"

# lens 5 (BLOCKING): the whole-brief budget was gated on the block-header parse, so on the
# bare-sections shape it never ran and an oversized brief shipped to the harness.
test_start "the budget re-cuts a fallback (bare sections) handoff too: the brief lands under MAUDE_BRIEF_MAX"
printf '## Next\nOLDONE\n\n## Next\nFALLLONG %s\n' "$(printf 'f%.0s' $(seq 1 190))" > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
UNCUT="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
assert_contains "$OUT" "FALLLONG" "the long fallback line is carried uncut"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude MAUDE_BRIEF_MAX=$((UNCUT - 30)) bash "$START" 2>/dev/null)"
CUT="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
assert_contains "$OUT" "FALLLONG" "the line is still there"
[ "$CUT" -le $((UNCUT - 30)) ] || _fail "brief is $CUT bytes against MAUDE_BRIEF_MAX=$((UNCUT - 30)) on the fallback shape"

# lens 5 (MAJOR): the lane was read with a [a-z0-9_-]+ regex, so "ma.ude+ lane" matched
# as "ude" and the lane was told its own block was "none yet for ma.ude+".
test_start "a lane name outside [a-z0-9_-] still matches its own block (read whole from the parentheses)"
printf '# Handoff — 2026-09-25 10:00Z (ma.ude+ lane, session e4)\n\n## Next\nMETALANE here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL='ma.ude+' bash "$START" 2>/dev/null)"
assert_contains "$OUT" "METALANE" "its block is carried"
assert_not_contains "$OUT" "none yet for" "and it is recognised as this lane's own"
# lens 6 (MAJOR): the parenthesised read took EVERYTHING before " lane", so the live shape
# "(Opus 5, sur lane)" read as "opus 5, sur" and sur's own blocks went invisible.
test_start "the lane is the last comma item before ' lane': '(Opus 5, sur lane)' is sur"
printf '# Handoff — 2026-09-25 10:00Z (Opus 5, sur lane)\n\n## Next\nSURMODEL here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=sur bash "$START" 2>/dev/null)"
assert_contains "$OUT" "SURMODEL" "its block"
assert_not_contains "$OUT" "none yet for" "recognised"
printf '# Handoff — 2026-09-25 10:00Z (Opus 5, session Y, proximo lane, 0.44.0)\n\n## Next\nPROXMODEL here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=proximo bash "$START" 2>/dev/null)"
assert_contains "$OUT" "PROXMODEL" "its block, lane not last in the parens"
assert_not_contains "$OUT" "none yet for" "recognised"
test_start "a lane name with a space matches whole, not its first word"
printf '# Handoff — 2026-09-25 10:00Z (my lane lane, session e4)\n\n## Next\nSPACELANE here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL='my lane' bash "$START" 2>/dev/null)"
assert_contains "$OUT" "SPACELANE" "its block is carried"
assert_not_contains "$OUT" "none yet for" "recognised whole"

# lens 5 (MINOR): a header with no ISO date fell back to the shared file's mtime ("today").
test_start "a block header with no ISO date reads 'undated', never the file's mtime"
printf '# Handoff — 09/20/2026 10:00Z (maude lane, session e5)\n\n## Next\nUNDATED here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
assert_contains "$OUT" "Last handoff (.remember, undated):" "undated"
assert_not_contains "$OUT" "Last handoff (.remember, today):" "not the mtime"
# lens 6 (MAJOR): "three numbers joined by dots" is a version, not a date.
test_start "a version number in a dateless header is not a date: the mtime still reads"
printf '# Handoff — (maude lane, v1.2.34)\n\n## Next\nVERSIONED here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
assert_contains "$OUT" "Last handoff (.remember, today):" "the fresh file's mtime"
assert_not_contains "$OUT" "undated" "not undated"
# lens 7: a version with a four-digit segment is still a version.
test_start "a version with a four-digit segment (v2026.1.2, v9.21.2026) is not a date either"
for V in v2026.1.2 v9.21.2026; do
  printf '# Handoff — (maude lane, %s)\n\n## Next\nVERSIONED here\n' "$V" > "$R/remember.md"
  OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
  assert_contains "$OUT" "Last handoff (.remember, today):" "$V: the mtime"
done
# lens 7: the bare form took one word, so the live "pierce county lane" header read "county".
test_start "a two-word lane in the bare header form matches whole"
printf '# Handoff — pierce county lane (75b1d8b8), 2026-09-15 05:40Z\n\n## Next\nPIERCE here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL='pierce county' bash "$START" 2>/dev/null)"
assert_contains "$OUT" "PIERCE" "its block"
assert_not_contains "$OUT" "none yet for" "recognised whole"
test_start "a date and time before the lane in the bare form are not swept into it"
printf '# Handoff — 2026-09-25 07:5xZ maude lane\n\n## Next\nBARETIME here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
assert_contains "$OUT" "BARETIME" "its block"
assert_not_contains "$OUT" "none yet for" "recognised"
test_start "a dotted real date still reads undated (2026.09.25 is not ISO)"
printf '# Handoff — 2026.09.25 (maude lane)\n\n## Next\nDOTTED here\n' > "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
assert_contains "$OUT" "Last handoff (.remember, undated):" "undated"

# ── lens 2: the cap bounds what is PRINTED, whatever the shapes ─────────
test_start "the cap counts every printed byte: many short lines and a long header stay bounded"
{
  printf '\n# Handoff — 2026-09-25 03:00Z (short lane, %s)\n\n## State\n' "$(printf 'h%.0s' $(seq 1 1100))"
  for i in $(seq 1 400); do printf -- '- x\n'; done
} >> "$R/remember.md"
wake short
HB="$(printf '%s\n' "$OUT" | awk '/Last handoff/{f=1} f&&/^  [A-Z]/&&!/Last handoff/&&!/^    /{f=0} f' | wc -c | tr -d ' ')"
[ "$HB" -le 1500 ] || _fail "handoff section is $HB bytes against a 1200 cap (+ header cap + pointer)"

test_start "a cut inside a run of multibyte text keeps the run and stays valid UTF-8"
{
  printf '\n# Handoff — 2026-09-25 04:00Z (utf lane)\n\n## State\n'
  # One ASCII byte first: 1179 bytes of em dashes is 3 x 393, so without it the cut always
  # landed on a character boundary and the partial-sequence strip was never exercised (lens 3).
  printf 'a%s\n' "$(printf '—%.0s' $(seq 1 700))"
} >> "$R/remember.md"
wake utf
assert_contains "$OUT" "———" "the multibyte line is cut, not dropped"
printf '%s' "$OUT" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
  || _fail "the brief is not valid UTF-8"

test_start "a CRLF file leaves no carriage return in the brief"
printf '\r\n# Handoff — 2026-09-25 05:00Z (crlf lane)\r\n\r\n## State\r\nCRLFSTATE here\r\n' >> "$R/remember.md"
wake crlf
assert_contains "$OUT" "CRLFSTATE here" "carried"
case "$OUT" in *$'\r'*) _fail "a carriage return reached the brief" ;; esac

test_start "this lane's own handoff is not labelled as someone else's"
# The file was rewritten above (bare "## Next" sections): give the maude lane a block again.
printf '\n# Handoff — 2026-09-20 10:00Z (maude lane, again)\n\n## Next\nMAUDENEXT again.\n' >> "$R/remember.md"
wake maude
assert_not_contains "$OUT" "none yet for maude" "own lane: no 'none yet'"

test_start "the lane match ignores case on both sides"
# A newer block from another lane, so the "newest" fallback cannot pass for a match (the
# case mutation survived until this was here).
printf '\n# Handoff — 2026-09-21 10:00Z (other lane)\n\n## Next\nOTHERNEWER\n' >> "$R/remember.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=Maude bash "$START" 2>/dev/null)"
assert_contains "$OUT" "MAUDENEXT" "a capitalised tmux name finds the 'maude lane' block"
assert_not_contains "$OUT" "OTHERNEWER" "not the newest block standing in"

test_start "the age reads the header's LAST date (a date in a reference comes first)"
printf '\n# Handoff — (session 2026-01-01 ref) 2026-09-20 06:00Z (dated lane)\n\n## State\nDATED\n' >> "$R/remember.md"
AGE_D2="$(maude_days_between 2026-09-20 "$(date +%Y-%m-%d)")"
wake dated
assert_contains "$OUT" "Last handoff (.remember, ${AGE_D2}d ago):" "the last date"

test_start "the WHOLE brief stays under budget with every other line at its cap (lens 3, I-D)"
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
MEMD="$HOME/.claude/projects/$SLUG/memory"; mkdir -p "$MEMD" "$HOME/.claude/maude"
printf '## 09:00 | x\n%s\n' "$(printf 'n%.0s' $(seq 1 400))" > "$MEMD/now.md"
printf '## %s\n' "$(printf 'p%.0s' $(seq 1 400))" > "$HOME/.claude/maude/patterns.md"
printf '%s\n' "$(printf 'l%.0s' $(seq 1 400))" > "$HOME/.claude/maude/letter-from-maude.md"
{
  printf '\n# Handoff — 2026-09-25 07:00Z (full lane)\n\n## State\n'
  for i in $(seq 1 60); do printf 'FULLLINE %03d %s\n' "$i" "$(printf 'y%.0s' $(seq 1 100))"; done
} >> "$R/remember.md"
# The other lines cap themselves near 200 bytes each, so to prove the re-cut (and not the
# other caps) holds the total, the budget is set below what they and a full handoff make.
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_BRIEF_MAX=1800 bash "$START" 2>/dev/null)"
TOTAL="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
assert_contains "$OUT" "FULLLINE 001" "the handoff still leads with its head"
[ "$TOTAL" -le 1800 ] || _fail "the whole brief is $TOTAL bytes against MAUDE_BRIEF_MAX 1800"

test_start "the whole-brief budget holds by default (3300) with a big handoff cap"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_HANDOFF_CAP=4000 bash "$START" 2>/dev/null)"
TOTAL="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
[ "$TOTAL" -le 3300 ] || _fail "default budget: $TOTAL bytes"

test_start "a handoff already UNDER its cap is still cut to meet the budget, in one pass"
# A ~900-byte body under a huge cap, with a long header: the re-cut must start from the
# BODY's size (a lower cap on a body under it cut nothing; the whole block's size kept the
# cap above the body when the header was long).
{
  printf '\n# Handoff — 2026-09-25 08:00Z (small lane, %s)\n\n## State\n' "$(printf 'h%.0s' $(seq 1 150))"
  for i in $(seq 1 9); do printf 'SMALLLINE %d %s\n' "$i" "$(printf 'z%.0s' $(seq 1 85))"; done
} >> "$R/remember.md"
UNCUT="$(printf '{}' | MAUDE_SESSION_LABEL=small MAUDE_HANDOFF_CAP=99999 MAUDE_BRIEF_MAX=99999 bash "$START" 2>/dev/null | wc -c | tr -d ' ')"
MAX=$((UNCUT - 300))
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=small MAUDE_HANDOFF_CAP=99999 MAUDE_BRIEF_MAX=$MAX bash "$START" 2>/dev/null)"
TOTAL="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
[ "$TOTAL" -le "$MAX" ] || _fail "a 300-byte overrun left $TOTAL against $MAX"

test_start "at the floor the handoff keeps its head, stays small, and the overrun is in the trace"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_BRIEF_MAX=0 bash "$START" 2>/dev/null)"
assert_contains "$OUT" "FULLLINE 001" "the head survives at the floor"
HB="$(printf '%s\n' "$OUT" | awk '/Last handoff/{f=1} f&&/^  [A-Z]/&&!/Last handoff/&&!/^    /{f=0} f' | wc -c | tr -d ' ')"
[ "$HB" -le 400 ] || _fail "handoff at the floor is $HB bytes (floor 150 + header + pointer)"
TR="$TEST_TMP/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
grep -q "over MAUDE_BRIEF_MAX 0" "$TR" 2>/dev/null || _fail "the overrun at the floor was not traced"

test_start "a leading-zero budget is base 10 (08 was an arithmetic error; the brief went unbudgeted)"
ERR="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_BRIEF_MAX=08 bash "$START" 2>&1 >/dev/null)"
assert_not_contains "$ERR" "value too great" "no arithmetic error"
UNB="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_BRIEF_MAX=99999 bash "$START" 2>/dev/null | wc -c | tr -d ' ')"
OCT="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_BRIEF_MAX=0800 bash "$START" 2>/dev/null | wc -c | tr -d ' ')"
[ "$OCT" -lt "$UNB" ] || _fail "0800 did not budget the brief ($OCT vs unbudgeted $UNB)"
# lens 5 (mutation survivor): the sibling cap had this test and this one did not.
test_start "a leading-zero HANDOFF cap is base 10 too (08 = 8, no arithmetic error)"
ERR="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_HANDOFF_CAP=08 bash "$START" 2>&1 >/dev/null)"
assert_not_contains "$ERR" "value too great" "no arithmetic error"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=full MAUDE_HANDOFF_CAP=08 bash "$START" 2>/dev/null)"
HB="$(printf '%s\n' "$OUT" | awk '/Last handoff/{f=1} f&&/^  [A-Z]/&&!/Last handoff/&&!/^    /{f=0} f' | wc -c | tr -d ' ')"
[ "$HB" -le 400 ] || _fail "a cap of 08 read as more than 8 bytes of body ($HB bytes in the section)"
rm -f "$MEMD/now.md" "$HOME/.claude/maude/patterns.md" "$HOME/.claude/maude/letter-from-maude.md"

# ── where you left off: THIS lane's newest live-buffer entry ─────────────
# Earned 2026-09-25: every entry in the live buffer read "## HH:MM | unknown" (remember's
# REMEMBER_BRANCH_CMD was never set), so the wake greeted the maude lane with a pacioli
# line. scripts/maude-lane is the writer's half; this is the reader's.
cat > "$R/now.md" <<'EOF'

## 03:00 | maude
MAUDELEFT the eye was keyed per session.
## 04:00 | pacioli
PACLEFT the 0.40.1 cut.
## 05:00 | unknown
UNKLEFT something from a session with no label.
EOF

test_start "left-off: a lane gets its own newest entry, not the newest in the file"
wake maude
assert_contains "$OUT" "Where you left off (maude): MAUDELEFT" "this lane's entry"
assert_not_contains "$OUT" "PACLEFT" "not a neighbour's"
assert_not_contains "$OUT" "UNKLEFT" "not an unlabelled one"

test_start "left-off: a lane with no entry gets the newest, and is told it is not its own"
wake wick
assert_contains "$OUT" "Where you left off (workspace-wide; none yet for wick): UNKLEFT" "newest, labelled"

test_start "left-off: a capitalised lane still finds its lowercase entries"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL=MAUDE bash "$START" 2>/dev/null)"
assert_contains "$OUT" "MAUDELEFT" "case-insensitive"

test_start "left-off: an ambient LANE variable does not relabel the line"
OUT="$(printf '{}' | LANE=pacioli MAUDE_SESSION_LABEL=maude bash "$START" 2>/dev/null)"
assert_contains "$OUT" "Where you left off (maude): MAUDELEFT" "the session's lane, not the environment's"

test_start "left-off: a single-digit hour header parses (no awk interval: old mawk lacks them)"
printf '\n## 7:05 | maude\nSINGLEDIGIT entry\n' >> "$R/now.md"
wake maude
assert_contains "$OUT" "SINGLEDIGIT entry" "## 7:05 read"

test_start "left-off: a long body and label are cut, and CRs never reach the brief"
printf '\n## 08:00 | %s\n%s\n' "$(printf 'L%.0s' $(seq 1 150))" "$(printf 'B%.0s' $(seq 1 1000))" >> "$R/now.md"
OUT="$(printf '{}' | MAUDE_SESSION_LABEL="$(printf 'q%.0s' $(seq 1 100))" bash "$START" 2>/dev/null)"
LINE="$(printf '%s\n' "$OUT" | grep 'Where you left off')"
[ "${#LINE}" -le 400 ] || _fail "left-off line is ${#LINE} chars (label 60 + lane 20 + body 240 + prefix)"
# Short, so no cut can remove the CR before the check sees it (a 1000-char body hid it).
printf '\r\n## 08:05 | crlane\r\nCRBODY short\r\n' >> "$R/now.md"
wake crlane
LINE="$(printf '%s\n' "$OUT" | grep 'Where you left off')"
assert_contains "$LINE" "CRBODY short" "the CRLF entry is the one read"
case "$LINE" in *$'\r'*) _fail "a CR reached the left-off line" ;; esac
printf '\n## 08:30 | maude\n%s\n' "$(printf 'M%.0s' $(seq 1 1000))" >> "$R/now.md"
wake maude
LINE="$(printf '%s\n' "$OUT" | grep 'Where you left off')"
[ "${#LINE}" -le 300 ] || _fail "own-lane left-off line is ${#LINE} chars (body cap 240)"

test_start "left-off: a labelled neighbour's entry names that neighbour"
printf '\n## 06:00 | pacioli\nPACNEWEST\n' >> "$R/now.md"
wake wick
assert_contains "$OUT" "Where you left off (pacioli; none yet for wick): PACNEWEST" "names whose it is"

# ── the writer's half: scripts/maude-lane feeds remember's REMEMBER_BRANCH_CMD ──
LANE_CMD="$HOOKS_DIR/../../scripts/maude-lane"
test_start "maude-lane prints the lane the wake reads by, one line"
assert_eq "$(MAUDE_SESSION_LABEL=pacioli bash "$LANE_CMD" sid-ignored)" "pacioli" "the label"
assert_eq "$(env -u TMUX -u MAUDE_SESSION_LABEL bash "$LANE_CMD" 0123456789abcdef)" "01234567" "outside tmux: the session id's first 8"

test_start "maude-lane refuses an unsafe label: prints nothing, exits 1 (remember falls back)"
OUTL="$(MAUDE_SESSION_LABEL='bad lane' bash "$LANE_CMD" x)"
RC=$?
assert_eq "$OUTL" "" "nothing printed"
assert_exit "$RC" "1" "non-zero, so remember uses its own default"

print_summary
teardown_test_env
exit $FAILED
