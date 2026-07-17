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
touch -d '40 days ago' "$OLD_TRACE"
KEEP_TRACE="$(trace_path)"
printf '{"ts":"today"}\n' > "$KEEP_TRACE"
run_start
assert_file_absent "$OLD_TRACE" "ancient trace pruned"

test_start "session-start keeps trace files inside the retention window"
assert_file_exists "$KEEP_TRACE" "today's trace kept"

test_start "session-start keeps a 7-day-old trace (weekly window safe)"
RECENT_TRACE="$TEST_TMP/.maude/plugin/trace/today-recent.jsonl"
printf '{"ts":"recent"}\n' > "$RECENT_TRACE"
touch -d '7 days ago' "$RECENT_TRACE"
run_start
assert_file_exists "$RECENT_TRACE" "7-day-old trace kept"

test_start "session-start prunes old pre-compact snapshots too"
mkdir -p "$TEST_TMP/.maude/plugin/snapshots"
OLD_SNAP="$TEST_TMP/.maude/plugin/snapshots/precompact-2020-01-01.md"
printf 'ancient snapshot\n' > "$OLD_SNAP"
touch -d '40 days ago' "$OLD_SNAP"
RECENT_SNAP="$TEST_TMP/.maude/plugin/snapshots/precompact-recent.md"
printf 'recent snapshot\n' > "$RECENT_SNAP"
touch -d '2 days ago' "$RECENT_SNAP"
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
touch -d '40 days ago' "$UNCOV"
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
touch -d '2 days ago' "$YOUNG"
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

print_summary
teardown_test_env
exit $FAILED
