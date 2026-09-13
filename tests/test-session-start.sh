#!/usr/bin/env bash
# Tests for hooks/scripts/maude-session-start.sh — degradative session brief.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

START="$HOOKS_DIR/maude-session-start.sh"

run_start() {
  # session-start emits brief on stdout (not stderr — see script)
  OUT="$(printf '{}' | bash "$START" 2>/dev/null)"
  RC=$?
}

test_start "session-start exits 0"
run_start
assert_exit "$RC" "0" "exit"

# With nothing to surface — she still greets (her voice is guaranteed), but no stale signal lines
test_start "session-start surfaces no Anthropic-now line when there's no memory"
# Make sure no Anthropic memory dir exists for this fake project slug
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
rm -rf "$HOME/.claude/projects/$SLUG"
run_start
assert_not_contains "$OUT" "Anthropic now" "no anthropic-now output"

# With house-map present
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map for test
## Watch list
EOF

test_start "session-start announces house-map ✓"
run_start
assert_contains "$OUT" "house-map" "map flagged"

# With Anthropic now.md present
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
MEM="$HOME/.claude/projects/$SLUG/memory"
mkdir -p "$MEM"
cat > "$MEM/now.md" <<'EOF'
## 18:00 | testing
First line of buffer content.
EOF

test_start "session-start surfaces Anthropic now line"
run_start
assert_contains "$OUT" "Anthropic now:" "now-line surfaced"

# With remember handoff
mkdir -p "$TEST_TMP/.remember"
cat > "$TEST_TMP/.remember/remember.md" <<'EOF'
# Handoff

## Next
The thing to do next is X.
EOF

test_start "session-start surfaces remember handoff"
run_start
assert_contains "$OUT" "Last handoff" "handoff surfaced"

# ── Fresh live buffer: $REMEMBER/now.md (the remember plugin keeps it current) ──
# The wake path must surface the NEWEST entry of the live buffer, so it reads current
# state instead of a lagging source while a fresh capture sits unread (the gap the live
# dogfood exposed). The buffer is oldest-first; the newest entry is at the bottom.
cat > "$TEST_TMP/.remember/now.md" <<'EOF'

## 06:44 | unknown
OLDERMARKER an early thing
## 07:07 | unknown
FRESHMARKER the latest thing
EOF

test_start "session-start surfaces the fresh live buffer (newest entry)"
run_start
assert_contains "$OUT" "FRESHMARKER" "newest live-buffer entry reaches the brief"

test_start "session-start shows the newest buffer entry, not the oldest"
assert_not_contains "$OUT" "OLDERMARKER" "stale buffer entry not surfaced"

# ── Session tie (the fleet fix): the leftoff line declares its source ──
# The live buffer is workspace-WIDE — under a concurrent fleet its newest entry
# may be another session's work. Unlabeled ("unknown") entries are marked
# workspace-wide so they can't masquerade as THIS session's state; a labeled
# entry (REMEMBER_BRANCH set per fleet session) shows its label.
test_start "leftoff from an unlabeled entry is marked workspace-wide"
assert_contains "$OUT" "Where you left off (workspace-wide):" "scope declared"

cat > "$TEST_TMP/.remember/now.md" <<'EOF'
## 07:30 | pacioli
LABELEDMARKER the labeled thing
EOF
test_start "leftoff from a labeled entry carries its session label"
run_start
assert_contains "$OUT" "Where you left off (pacioli): LABELEDMARKER" "label surfaced"

# ── #49: the brief logs its own bill (hook + bytes, metadata only) ──
test_start "session-start logs a spend entry for the brief it injected"
n="$(jq -c 'select(.kind == "spend" and (.payload|test("hook=session-start")))' "$(trace_path)" 2>/dev/null | wc -l | tr -d ' ')"
[ "${n:-0}" -gt 0 ]
assert_exit "$?" "0" "spend entry for the brief"

rm -f "$TEST_TMP/.remember/now.md"

# ── Local-time-aware greeting ────────────────────────────────────────
source_common

test_start "session-start greets by local clock when timezone is known"
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map for test
## Clock
timezone: system
## Watch list
EOF
run_start
assert_contains "$OUT" "$(maude_greeting)" "time-aware greeting present"

test_start "session-start stays time-neutral when timezone unknown (no false time word)"
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map for test
## Watch list
EOF
run_start
assert_contains "$OUT" "Maude here." "still greets neutrally"
assert_not_contains "$OUT" "Morning." "no morning word"
assert_not_contains "$OUT" "Afternoon." "no afternoon word"
assert_not_contains "$OUT" "Evening." "no evening word"

# Cleanup
rm -rf "$MEM"

# ── jq-missing safety notice ─────────────────────────────────────────
# Without jq the irreversible-command gate is fail-OPEN (silently disabled),
# along with drift-watch / tier-1 / watch-list nudges. SessionStart runs once
# per session and is the chokepoint for ONE consolidated notice. The gate
# clause must read as a SAFETY regression, not just "trace isn't writing".
test_start "session-start warns once when jq is missing"
NOJQ="$(make_nojq_bin)"
NOTICE="$(printf '{}' | PATH="$NOJQ" bash "$START" 2>&1 >/dev/null)"
assert_contains "$NOTICE" "jq" "jq-missing notice present"

test_start "jq-missing notice names the gate being off (safety wording)"
assert_contains "$NOTICE" "gate" "notice flags the gate"

# Pins the ORDERING the script comment calls load-bearing: the safety notice must
# fire BEFORE the early-exit, so it still shows on a PRISTINE project with no memory
# or house-map to brief. (The test above runs after earlier cases seeded memory, so
# it can't catch a regression that moved the notice below the brief's early-exit.)
test_start "jq-missing notice fires even on a pristine project (nothing to brief)"
PRISTINE="$(mktemp -d)"
NOTICE_BARE="$(printf '{}' | CLAUDE_PROJECT_DIR="$PRISTINE" HOME="$PRISTINE/home" PATH="$NOJQ" bash "$START" 2>&1 >/dev/null)"
assert_contains "$NOTICE_BARE" "gate" "notice fires with no memory/house-map present"
rm -rf "$PRISTINE"

test_start "session-start says nothing about jq when jq is present"
NOISE="$(printf '{}' | bash "$START" 2>&1 >/dev/null)"
assert_not_contains "$NOISE" "jq not found" "silent when jq present"

# ── Run-governor off-switch visibility ───────────────────────────────
# When MAUDE_RUN_GOVERNOR=off the brake is silently disabled per-tool (by design),
# but SessionStart must surface it ONCE so the user sees it on arrival.
test_start "session-start announces when the governor is OFF"
GOV_NOTICE="$(printf '{}' | MAUDE_RUN_GOVERNOR=off bash "$START" 2>&1 >/dev/null)"
assert_contains "$GOV_NOTICE" "run-governor is OFF" "off notice present"

test_start "session-start is silent about the governor by default (on)"
GOV_DEFAULT="$(printf '{}' | bash "$START" 2>&1 >/dev/null)"
assert_not_contains "$GOV_DEFAULT" "run-governor is OFF" "no notice when on"

# ── Trace + snapshot retention sweep ─────────────────────────────────
# Trace JSONL and pre-compact snapshots were append-only forever. SessionStart
# prunes files older than the retention window. Floor is well past the 7-day
# window the remember plugin's recent.md reads, so a sweep never strands them.
test_start "session-start prunes trace files older than the retention window"
OLD_TRACE="$TEST_TMP/.maude/plugin/trace/today-2020-01-01.jsonl"
printf '{"ts":"ancient"}\n' > "$OLD_TRACE"
touch_ago $(( 40*86400 )) "$OLD_TRACE"
KEEP_TRACE="$(trace_path)"
printf '{"ts":"today"}\n' > "$KEEP_TRACE"
run_start
assert_file_absent "$OLD_TRACE" "ancient trace pruned"

test_start "session-start keeps trace files inside the retention window"
assert_file_exists "$KEEP_TRACE" "today's trace kept"

test_start "session-start keeps a 7-day-old trace (weekly window safe)"
RECENT_TRACE="$TEST_TMP/.maude/plugin/trace/today-recent.jsonl"
printf '{"ts":"recent"}\n' > "$RECENT_TRACE"
touch_ago $(( 7*86400 )) "$RECENT_TRACE"
run_start
assert_file_exists "$RECENT_TRACE" "7-day-old trace kept"

test_start "session-start prunes old pre-compact snapshots too"
mkdir -p "$TEST_TMP/.maude/plugin/snapshots"
OLD_SNAP="$TEST_TMP/.maude/plugin/snapshots/precompact-2020-01-01.md"
printf 'ancient snapshot\n' > "$OLD_SNAP"
touch_ago $(( 40*86400 )) "$OLD_SNAP"
RECENT_SNAP="$TEST_TMP/.maude/plugin/snapshots/precompact-recent.md"
printf 'recent snapshot\n' > "$RECENT_SNAP"
touch_ago $(( 2*86400 )) "$RECENT_SNAP"
run_start
assert_file_absent "$OLD_SNAP" "ancient snapshot pruned"

test_start "session-start keeps a recent pre-compact snapshot (no over-prune)"
assert_file_exists "$RECENT_SNAP" "recent snapshot kept"

# ── Value before the dustpan: uncovered snapshots survive the sweep ──
# A pre-compact snapshot is CONTENT (unlike the metadata-only trace) — if the
# session never saved afterward, it may be the only copy of that context. Age
# alone must not delete one: it must ALSO be covered by a later save (capture
# anchor newer than the snapshot). Isolated env so the anchor is controlled.
test_start "sweep keeps an old snapshot when no save covers it"
VB="$(mktemp -d)"
mkdir -p "$VB/proj/.maude/plugin/snapshots" "$VB/home"
UNCOV="$VB/proj/.maude/plugin/snapshots/precompact-old-uncovered.md"
printf 'the only copy of that context\n' > "$UNCOV"
touch_ago $(( 40*86400 )) "$UNCOV"
# No now.md / remember.md anywhere → anchor is 0 → nothing is covered.
( CLAUDE_PROJECT_DIR="$VB/proj" HOME="$VB/home" bash "$START" >/dev/null 2>&1 </dev/null )
assert_file_exists "$UNCOV" "uncovered old snapshot survives"

test_start "sweep deletes an old snapshot once a later save covers it"
mkdir -p "$VB/proj/.remember"
printf '## saved\ncontent captured\n' > "$VB/proj/.remember/now.md"   # fresh anchor
( CLAUDE_PROJECT_DIR="$VB/proj" HOME="$VB/home" bash "$START" >/dev/null 2>&1 </dev/null )
assert_file_absent "$UNCOV" "covered old snapshot swept"

test_start "a covering save does not sweep snapshots inside the window"
YOUNG="$VB/proj/.maude/plugin/snapshots/precompact-young.md"
printf 'recent context\n' > "$YOUNG"
touch_ago $(( 2*86400 )) "$YOUNG"
( CLAUDE_PROJECT_DIR="$VB/proj" HOME="$VB/home" bash "$START" >/dev/null 2>&1 </dev/null )
assert_file_exists "$YOUNG" "young snapshot kept regardless of coverage"
rm -rf "$VB"

# ── Letter from her last self ────────────────────────────────────────
# /maude:rest rewrites ~/.claude/maude/letter-from-maude.md; session-start
# surfaces its first non-header, non-blank line (read-only, like every hook
# signal). Isolated HOME + project so the real user-global home is never
# touched and no other signal can mask the letter.
test_start "session-start surfaces the letter from her last self"
LH="$(mktemp -d)"
mkdir -p "$LH/home/.claude/maude" "$LH/proj"
cat > "$LH/home/.claude/maude/letter-from-maude.md" <<'EOF'
# Letter from Maude — 2026-01-01

I called the suite green without rerunning it. Verify before you say done.

Second paragraph that should not be the surfaced line.
EOF
LOUT="$(printf '{}' | CLAUDE_PROJECT_DIR="$LH/proj" HOME="$LH/home" bash "$START" 2>/dev/null)"
assert_contains "$LOUT" "Letter from my last self:" "letter label present"

test_start "letter line skips the header and lands on the first prose line"
assert_contains "$LOUT" "I called the suite green" "first body line surfaced"

# A letter ALONE must be enough to trigger the brief — pins the letter's
# inclusion in the nothing-to-surface early-exit condition (the isolated env
# above has no map, no memory, no handoff; only the letter).
test_start "a letter alone triggers the brief (early-exit includes it)"
assert_contains "$LOUT" "Maude here." "brief fired with only a letter present"

test_start "no letter line when the letter file is absent"
rm "$LH/home/.claude/maude/letter-from-maude.md"
LOUT2="$(printf '{}' | CLAUDE_PROJECT_DIR="$LH/proj" HOME="$LH/home" bash "$START" 2>/dev/null)"
assert_not_contains "$LOUT2" "Letter from my last self" "silent without letter"
rm -rf "$LH"

# ── Cross-project pattern hint: rotate headings, never grep bodies ──
# The old picker grepped patterns.md for the project basename — on any project
# whose name appeared in an entry BODY (e.g. a path), that one entry pinned
# forever, truncated mid-sentence into what read like a live alert. The picker
# now rotates through the ## HEADINGS by day-of-year: every scar gets airtime,
# and a heading is a complete dated sentence that self-identifies as history.
test_start "pattern hint surfaces a heading, rotating by day-of-year"
PH="$(mktemp -d)"
mkdir -p "$PH/home/.claude/maude" "$PH/proj"
cat > "$PH/home/.claude/maude/patterns.md" <<EOF
# Patterns

## 2026-01-01 — HEADZERO first scar
Body zero mentions $PH/proj to tempt a basename grep. BODYMARKER.

## 2026-01-02 — HEADONE second scar
Body one. BODYMARKER.

## 2026-01-03 — HEADTWO third scar
Body two. BODYMARKER.
EOF
DAY="$(date +%j | sed 's/^0*//')"
case "$((DAY % 3))" in
  0) WANT="HEADZERO" ;;
  1) WANT="HEADONE" ;;
  2) WANT="HEADTWO" ;;
esac
PHOUT="$(printf '{}' | CLAUDE_PROJECT_DIR="$PH/proj" HOME="$PH/home" bash "$START" 2>/dev/null)"
assert_contains "$PHOUT" "Cross-project pattern:" "pattern line present"
assert_contains "$PHOUT" "$WANT" "day-of-year heading selected"

test_start "pattern hint never prints entry bodies (no basename-grep pinning)"
assert_not_contains "$PHOUT" "BODYMARKER" "body text not surfaced"

test_start "no pattern line when patterns.md is absent"
rm "$PH/home/.claude/maude/patterns.md"
PHOUT2="$(printf '{}' | CLAUDE_PROJECT_DIR="$PH/proj" HOME="$PH/home" bash "$START" 2>/dev/null)"
assert_not_contains "$PHOUT2" "Cross-project pattern" "silent without patterns"
rm -rf "$PH"

# ── Guaranteed once-per-session voice ────────────────────────────────
# Her voice is a RAIL, not the (retired) dual-voice toggle: SessionStart must land
# her name EVERY session, including a stranger's first run on a pristine project
# (no map, no memory, no remember, no letter). Isolated HOME + project so nothing
# leaks in to mask the bare case.
test_start "session-start always lands her name, even on a pristine project"
PV="$(mktemp -d)"
mkdir -p "$PV/home" "$PV/proj"
PVOUT="$(printf '{}' | CLAUDE_PROJECT_DIR="$PV/proj" HOME="$PV/home" bash "$START" 2>/dev/null)"
assert_contains "$PVOUT" "Maude here." "greets on a pristine project (her voice is guaranteed)"
rm -rf "$PV"

# ── The brief renders the last cushion-flip's stamp (issue #36) ──────
test_start "brief renders the cushion stamp"
printf '%s 3\n' "$(date +%s)" > "$TEST_TMP/.maude/plugin/cushions-last"
run_start
assert_contains "$OUT" "Cushions: 3 value candidates" "cushion count surfaces"

test_start "a fresh flip reads as today"
assert_contains "$OUT" "last flipped today" "fresh stamp age"

test_start "an old stamp shows its age in days"
printf '%s 1\n' "$(( $(date +%s) - 6*86400 ))" > "$TEST_TMP/.maude/plugin/cushions-last"
run_start
assert_contains "$OUT" "Cushions: 1 value candidate" "singular count"
assert_contains "$OUT" "last flipped 6d ago" "aged stamp"

test_start "no stamp -> the never-flipped nudge"
rm -f "$TEST_TMP/.maude/plugin/cushions-last"
run_start
assert_contains "$OUT" "never flipped" "nudge lands"

test_start "a malformed stamp says nothing rather than something wrong"
printf '1751234567\n' > "$TEST_TMP/.maude/plugin/cushions-last"   # epoch only, no count
run_start
assert_not_contains "$OUT" "value candidate" "no half-rendered cushion line"
assert_not_contains "$OUT" "never flipped" "a present-but-bad stamp is not 'never'"

# ── The wake reads the TAIL of every append-only file, and says how old what it read is ──
# Both lenses on 2026-09-06: line 87 read the FIRST "## Next" of a 31-handoff file and
# labelled it "Last handoff"; the Anthropic now line took the first "## HH:MM" header of an
# oldest-first buffer; the house-map tick asserted a currency the file never claimed. A
# presence check is not a currency check.
mkdir -p "$TEST_TMP/.remember"
test_start "the handoff line takes the NEWEST ## Next block of an append-only handoff, not the first"
cat > "$TEST_TMP/.remember/remember.md" <<'EOF'
# Handoff

## Next
OLDHANDOFF from three weeks ago.

## MAUDE 2026-09-06 addendum

## Next
NEWHANDOFF from last night.
EOF
run_start
assert_contains "$OUT" "NEWHANDOFF" "newest ## Next surfaced"
assert_not_contains "$OUT" "OLDHANDOFF" "the first ## Next is not presented as the last"

test_start "and the handoff line carries the file's own age, so a stale one says so"
touch_ago 259200 "$TEST_TMP/.remember/remember.md"
run_start
assert_contains "$OUT" "Last handoff (.remember, 3d ago):" "age from the file's mtime beside the label"

test_start "the Anthropic now line takes the NEWEST entry of an append-only buffer"
mkdir -p "$MEM"   # an earlier case removes the memory dir
cat > "$MEM/now.md" <<'EOF'
## 09:00 | old
OLDNOW first thing
## 21:00 | new
NEWNOW latest thing
EOF
run_start
assert_contains "$OUT" "Anthropic now: ## 21:00" "newest header surfaced"
assert_not_contains "$OUT" "## 09:00" "the oldest header is not presented as now"

test_start "the house-map tick carries the map's own walk date and age, and names the re-walk past a week"
cat > "$TEST_TMP/.maude/plugin/house-map.md" <<'EOF'
# House map for test
# Walked: 2026-08-01 (fixture walk)
## Watch list
EOF
touch_ago 3110400 "$TEST_TMP/.maude/plugin/house-map.md"
run_start
assert_contains "$OUT" "(house-map ✓ walked 2026-08-01, 36d old; /maude:found)" "date the map claims, age from its mtime, the re-walk named"

test_start "a fresh map shows its age without the nudge"
touch "$TEST_TMP/.maude/plugin/house-map.md"
run_start
assert_contains "$OUT" "(house-map ✓ walked 2026-08-01, 0d old)" "no nudge inside a week"
assert_not_contains "$OUT" "/maude:found" "the re-walk is not named for a fresh map"

test_start "a map with no walk line is ticked as undated, never as current"
printf '# House map for test\n## Watch list\n' > "$TEST_TMP/.maude/plugin/house-map.md"
run_start
assert_contains "$OUT" "(house-map ✓, undated)" "no date claimed means none printed"


# ── a lens that died before it reported is named at the next wake ──────────────────
# A background lens leaves a PENDING stamp at launch (test-redteam-watch.sh); if its session
# ends first, nothing promotes it and nothing says so. The 23rd lens on 2026-09-06 died
# three minutes after dispatch and the next wake read a 477-byte stub as "running". The
# wake names a pending entry older than ten minutes: a live lens in a sibling session is
# younger than that; a dead one only gets older.
test_start "a lens dispatched in a past session that never reported is named at the wake"
printf '{"redteam_pending":{"a7f93cda58bbfd3cf":{"ts":"2026-09-06T17:24:00Z","refs":["b24203c"],"sid":"86c33f26"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "pending" "the wake says a lens is pending"
assert_contains "$OUT" "b24203c" "and what it was to review"

test_start "a pending lens launched moments ago is not called dead"
printf '{"redteam_pending":{"a7f93cda58bbfd3cf":{"ts":"%s","refs":["b24203c"],"sid":"86c33f26"}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(care_path)"
run_start
assert_not_contains "$OUT" "pending" "young pending is silent"

# A store holding nothing but EXPIRED tokens was never pruned: the prune ran only inside a
# reservation, and a reservation only happens when that key's token is LIVE. So the cheap exit
# on every Bash completion stayed dead on any box that had ever been given a clear (the 27th
# lens, MINOR-2). The wake prunes them once per session.
test_start "the wake prunes expired gate tokens (27th lens, MINOR-2)"
printf '{"gate_cleared":{"stale-june":{"until":1782168902},"live-one":{"until":%d}}}\n' $(($(date +%s) + 600)) > "$(care_path)"
run_start
assert_eq "$(read_care '.gate_cleared["stale-june"] // "gone"')" "gone" "the expired token is gone"
assert_ne "$(read_care '.gate_cleared["live-one"].until // "absent"')" "absent" "the live one stays"
printf '{}\n' > "$(care_path)"

test_start "a MALFORMED pending entry does not silence the alarm for the good one beside it (25th lens, MINOR-1)"
printf '{"redteam_pending":{"bad1":42,"a7f93cda58bbfd3cf":{"ts":"2026-09-06T01:00:00Z","refs":["b24203c"],"sid":"86c33f26"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "pending" "the good entry is still named"
assert_contains "$OUT" "b24203c" "with its subject"

test_start "with several pending lenses the OLDEST is named and every id is accounted for (25th lens, MINOR-2)"
printf '{"redteam_pending":{"znewest":{"ts":"2026-09-06T10:00:00Z","refs":["ccccccc3"],"sid":"s3"},"aoldest":{"ts":"2026-09-06T01:00:00Z","refs":["aaaaaaa1"],"sid":"s1"},"mmiddle":{"ts":"2026-09-06T05:00:00Z","refs":["bbbbbbb2"],"sid":"s2"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "aaaaaaa1" "the OLDEST is the one named in full"
assert_contains "$OUT" "bbbbbbb2" "and the others' subjects are named too"
assert_contains "$OUT" "ccccccc3" "all of them"

# The "name them all" rewrite reads EVERY entry's refs, so one entry whose refs holds a
# non-scalar silenced the whole line — a REGRESSION against the sha it was fixing, in the
# commit titled after that failure (the 26th lens, IMPORTANT-5).
test_start "one entry whose refs holds a non-scalar does not silence the line for the good one (26th lens, IMPORTANT-5)"
printf '{"redteam_pending":{"bad1":{"ts":"2026-09-06T02:00:00Z","refs":[[1]],"sid":"s2"},"good1":{"ts":"2026-09-06T01:00:00Z","refs":["aaaaaaa1"],"sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "pending" "the line is printed"
assert_contains "$OUT" "aaaaaaa1" "and the good subject is named"

test_start "…and refs that is an object does not silence it either"
printf '{"redteam_pending":{"bad2":{"ts":"2026-09-06T02:00:00Z","refs":{"a":1},"sid":"s2"},"good2":{"ts":"2026-09-06T01:00:00Z","refs":["aaaaaaa1"],"sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "aaaaaaa1" "the good subject survives an object refs"

# With many out, the byte cut ended mid-sha: a truncated ref reads exactly like a whole one
# and a reader could check the wrong commit (MINOR-5).
test_start "with fifty pending lenses the line never ends mid-subject (26th lens, MINOR-5)"
python3 -c "
import json, sys
p = {('a%015x' % i): {'ts': '2026-09-06T0%d:00:00Z' % (i % 10), 'refs': ['%040x' % i], 'sid': 's%d' % i} for i in range(50)}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" > "$(care_path)"
run_start
PLINE="$(printf '%s' "$OUT" | grep -o 'A lens dispatched.*' || true)"
case "$PLINE" in
  *".") assert_exit "0" "0" "the line ends on a sentence, not mid-sha" ;;
  *)    assert_exit "1" "0" "the line ends on a sentence, not mid-sha (got: ...${PLINE#"${PLINE%??????????}"})" ;;
esac
assert_contains "$OUT" "more" "and it says how many more"
printf '{}\n' > "$(care_path)"

# `.[1:5]` bounded the number of SUBJECTS and nothing bounded the WIDTH of one, and this hook
# writes up to 64 refs per entry, so the line still ended mid-sha — and a truncated ref reads
# exactly like a whole one (the 27th lens, IMPORTANT-4).
test_start "one pending entry at the hook's own 64-ref cap does not end the line mid-sha (27th lens, IMPORTANT-4)"
python3 -c "
import json, sys
p = {'aaa0000000000001': {'ts': '2026-09-06T01:00:00Z', 'refs': ['%040x' % i for i in range(64)], 'sid': 's1'},
     'bbb0000000000002': {'ts': '2026-09-06T02:00:00Z', 'refs': ['%040x' % (i + 100) for i in range(64)], 'sid': 's2'}}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" > "$(care_path)"
run_start
PLINE="$(printf '%s' "$OUT" | grep -o 'A lens dispatched.*' || true)"
case "$PLINE" in
  *".") assert_exit "0" "0" "the line ends on a sentence" ;;
  *)    assert_exit "1" "0" "the line ends on a sentence (tail: ${PLINE#"${PLINE%????????????????????}"})" ;;
esac

test_start "…and six pending reads as plural, not \"and 1 others\" (27th lens, MINOR-5)"
python3 -c "
import json, sys
p = {('c%015x' % i): {'ts': '2026-09-06T0%d:00:00Z' % i, 'refs': ['%040x' % i], 'sid': 's%d' % i} for i in range(6)}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" > "$(care_path)"
run_start
assert_not_contains "$OUT" "1 others" "no singular in a plural sentence"
printf '{}\n' > "$(care_path)"

# Bounding the ref COUNT per subject is not bounding the line's WIDTH: four subjects at four
# 40-character shas passes the byte cut before a word of prose, and the cut lands mid-sha where a
# fragment reads exactly like a whole reference (the 28th lens, IMPORTANT-4).
for _n in 4 5; do
  test_start "$_n pending entries at nine refs each still end the line on a sentence (28th lens, IMPORTANT-4)"
  python3 -c "
import json, sys
n = int(sys.argv[1])
p = {('p%015d' % i): {'ts': '2026-09-06T0%d:00:00Z' % i, 'refs': ['%040x' % (i * 100 + j) for j in range(9)], 'sid': 's%d' % i} for i in range(n)}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" "$_n" > "$(care_path)"
  run_start
  PLINE="$(printf '%s' "$OUT" | grep -o 'A lens dispatched.*' || true)"
  case "$PLINE" in
    *".") assert_exit "0" "0" "ends on a sentence at $_n pending" ;;
    *)    assert_exit "1" "0" "ends on a sentence at $_n pending (tail: ${PLINE#"${PLINE%????????????????????}"})" ;;
  esac
done

test_start "a single subject whose refs are one enormous string does not run the line off its budget"
python3 -c "
import json, sys
p = {'huge000000000001': {'ts': '2026-09-06T01:00:00Z', 'refs': ['Z' * 4000], 'sid': 's1'},
     'good00000000002': {'ts': '2026-09-06T02:00:00Z', 'refs': ['aaaaaaa1'], 'sid': 's2'}}
sys.stdout.write(json.dumps({'redteam_pending': p}))
" > "$(care_path)"
run_start
PLINE="$(printf '%s' "$OUT" | grep -o 'A lens dispatched.*' || true)"
case "$PLINE" in
  *".") assert_exit "0" "0" "ends on a sentence" ;;
  *)    assert_exit "1" "0" "ends on a sentence (tail: ${PLINE#"${PLINE%????????????????????}"})" ;;
esac
printf '{}\n' > "$(care_path)"

test_start "a box that cannot convert the cutoff (no date -d, no date -r) names EVERY pending lens: loud, never silent (24th lens, MINOR-4)"
printf '{"redteam_pending":{"a7f93cda58bbfd3cf":{"ts":"%s","refs":["b24203c"],"sid":"86c33f26"}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(care_path)"
NODATE="$(mktemp -d)"   # a fresh dir with ONE shim, not a symlink farm: nothing to write through
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in -d|-r) exit 1;; esac; done\nexec %q "$@"\n' "$(command -v date)" > "$NODATE/date"; chmod +x "$NODATE/date"
OUT="$(printf '{}' | PATH="$NODATE:$PATH" bash "$START" 2>/dev/null)"
assert_contains "$OUT" "pending" "named even though its age cannot be told"
assert_contains "$OUT" "b24203c" "with its subject"
rm -rf "$NODATE"
printf '{}\n' > "$(care_path)"

# ── a pending entry that named no subject still prints a subject ───────────────────
# The wake said "its stamp on  is pending": refstr joins an EMPTY refs array to the
# empty string, and the sentence lost the only noun it had. Not theoretical — this hook
# itself writes refs:[] whenever a brief names no literal sha — the stamp scrapes literal
# shas only, and records the empty list when it finds none — and ad21d0f7 sat on this box
# carrying exactly that (verified in the live store, not cited from a test that asserts
# the opposite: "a launch that errored" leaves NOTHING pending), so the
# live whisper on 2026-09-07 read "its stamp on  is pending" to a reader who then had
# nothing to grep for.
test_start "a pending entry with an EMPTY refs array still names a subject"
printf '{"redteam_pending":{"ad21d0f73ba6c0dc1":{"ts":"2026-09-06T19:35:14Z","refs":[],"sid":"41158c31"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "pending" "the line is printed"
assert_not_contains "$OUT" "stamp on  is" "the subject is not an empty join"
assert_contains "$OUT" "unnamed subject" "it says plainly that the brief named none"

test_start "…refs holding only an empty string reads the same way"
printf '{"redteam_pending":{"a1":{"ts":"2026-09-06T19:35:14Z","refs":[""],"sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "unnamed subject" "an empty ref names no subject either"

test_start "…and a named subject is still named exactly as before"
printf '{"redteam_pending":{"a1":{"ts":"2026-09-06T19:35:14Z","refs":["b24203c"],"sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "b24203c" "the ref is still the subject"
assert_not_contains "$OUT" "unnamed subject" "and the placeholder does not leak onto it"
printf '{}\n' > "$(care_path)"

# ── the placeholder covers every spelling of "named nothing" (29th lens, MINOR-2/5) ──
# The first cut tested only [] and [""], so neither gsub in refstr was load-bearing:
# deleting gsub(",";"") or gsub(" ";"") left the whole fleet green. A guard no test can
# see the absence of is not a guard, it is a comment. And refs:null rendered "?" while
# refs:[] rendered the placeholder — two spellings of one fact, for a reader who has to
# tell "named nothing" from "the line broke".
test_start "refs of several empty strings still names no subject (the comma is not a subject)"
printf '{"redteam_pending":{"a1":{"ts":"2026-09-06T19:35:14Z","refs":["",""],"sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "unnamed subject" "a run of commas is not a named subject"

test_start "refs of a single blank still names no subject (the space is not a subject)"
printf '{"redteam_pending":{"a1":{"ts":"2026-09-06T19:35:14Z","refs":[" "],"sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "unnamed subject" "whitespace is not a named subject"

test_start "a MISSING refs field reads the same as an empty one, not as a different symbol"
printf '{"redteam_pending":{"a1":{"ts":"2026-09-06T19:35:14Z","sid":"s1"}}}\n' > "$(care_path)"
run_start
assert_contains "$OUT" "unnamed subject" "null refs names no subject either"
assert_not_contains "$OUT" "stamp on ? is" "not a second spelling of the same fact"
printf '{}\n' > "$(care_path)"

print_summary
teardown_test_env
exit $FAILED
