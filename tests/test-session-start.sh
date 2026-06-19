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
# window /maude:weekly and recent.md read, so a sweep never strands them.
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

print_summary
teardown_test_env
exit $FAILED
