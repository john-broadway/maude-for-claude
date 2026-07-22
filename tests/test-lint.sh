#!/usr/bin/env bash
# tests/test-lint.sh — /maude:lint: the entropy-reduction pass (issue #42).
#
# The lint's laws, enforced as tests: scope first (archives/letters/dailies
# are NEVER scanned — verbatim by design), report-first (it proposes, the
# human applies — the script writes NOTHING into the memory it lints), and
# receipts (every pass logs counts to the trace, counts never content).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

LINT="$SCRIPTS_DIR/maude-lint.sh"
MEMFIX="$TEST_TMP/memfix"
mkdir -p "$MEMFIX"
export MAUDE_MEM_DIR_OVERRIDE="$MEMFIX"

# ── Fixture vault ──
cat > "$MEMFIX/MEMORY.md" <<'EOF'
# Index
- [Good](project_alpha.md) — resolves
- [Broken](project_ghost.md) — target missing
- [Old ref](reference_old.md) — superseded target still indexed
EOF
cat > "$MEMFIX/project_alpha.md" <<'EOF'
---
name: project_alpha
---
Live topic. Points at [[reference_new]] and at [[not-written-yet]],
and at [[alpha]] (prefix-less house convention: resolves to project_alpha.md).
🔴OPEN: the thing still pending
EOF
cat > "$MEMFIX/reference_new.md" <<'EOF'
---
name: reference_new
---
Fresh reference.
EOF
cat > "$MEMFIX/reference_old.md" <<'EOF'
---
name: reference_old
superseded_by: reference_new
---
Superseded content.
EOF
# Excluded-by-law files, each carrying what would otherwise be findings:
cat > "$MEMFIX/archive_index-compaction-2026-01-01.md" <<'EOF'
- [ArchivedBroken](project_vanished.md)
🔴OPEN ARCHIVEMARKER
EOF
cat > "$MEMFIX/letter-from-claude-2026-01-01.md" <<'EOF'
[[letter-ref-never-written]] LETTERMARKER
EOF
cat > "$MEMFIX/today-2026-01-01.md" <<'EOF'
🔴OPEN TODAYMARKER
EOF
# Make the live topic old enough to be a stale-state candidate.
touch_ago $(( 40*86400 )) "$MEMFIX/project_alpha.md"

BEFORE="$(cd "$MEMFIX" && cksum ./*.md | sort)"
OUT="$(bash "$LINT" 2>/dev/null)"
RC=$?
AFTER="$(cd "$MEMFIX" && cksum ./*.md | sort)"

test_start "lint exits 0"
assert_exit "$RC" "0" "exit"

test_start "lint finds the broken index link"
assert_contains "$OUT" "project_ghost.md" "broken link named"

test_start "lint counts the unwritten [[pointer]] without calling it an error"
assert_contains "$OUT" "not-written-yet" "unwritten pointer tallied"

test_start "a prefix-less [[pointer]] resolves against any typed filename (house convention)"
assert_not_contains "$OUT" "[[alpha]]" "prefix-less ref not miscounted as unwritten"

test_start "lint flags the superseded-but-still-indexed file"
assert_contains "$OUT" "reference_old" "supersession drift candidate"

test_start "lint lists the stale-OPEN candidate from a live topic file"
assert_contains "$OUT" "project_alpha.md" "stale candidate named"

test_start "lint reports the index size"
assert_contains "$OUT" "index" "index size stated"

# ── Scope law: archives, letters, dailies are NEVER scanned ──
test_start "lint never scans archives"
assert_not_contains "$OUT" "project_vanished" "archive findings excluded"

test_start "lint never scans letters"
assert_not_contains "$OUT" "letter-ref-never-written" "letter refs excluded"

test_start "lint never scans dailies"
assert_not_contains "$OUT" "TODAYMARKER" "daily content excluded"

# ── Report-first: the lint writes NOTHING into what it lints ──
test_start "lint modifies no memory file (report-only)"
assert_eq "$BEFORE" "$AFTER" "vault untouched"

# ── Receipts: the pass logs its counts (counts, never content) ──
test_start "lint logs a trace receipt with counts"
LINE="$(jq -c 'select(.kind == "lint")' "$(trace_path)" 2>/dev/null | tail -1)"
printf '%s' "$LINE" | grep -qE 'index_broken=1' && ! printf '%s' "$LINE" | grep -q "ARCHIVEMARKER"
assert_exit "$?" "0" "receipt with counts, no content"

# ── Degradation: an empty/missing vault is a note, not a crash ──
test_start "lint degrades gracefully with no MEMORY.md"
EMPTYFIX="$TEST_TMP/emptyfix"; mkdir -p "$EMPTYFIX"
MAUDE_MEM_DIR_OVERRIDE="$EMPTYFIX" bash "$LINT" >/dev/null 2>&1
assert_exit "$?" "0" "still exits 0"

# ── A vault with an index but ZERO live topic files (freshly walked, or fully
# compacted into archives) must produce a complete report, not a crash —
# "${LIVE[@]}" on an empty array is an unbound reference under set -u on
# bash 3.2 (stock macOS), so every expansion site carries the house guard. ──
test_start "lint completes on a live-file-less vault (index + archives only)"
BAREFIX="$TEST_TMP/barefix"; mkdir -p "$BAREFIX"
printf '# Index\n- [Gone](project_gone.md)\n' > "$BAREFIX/MEMORY.md"
printf 'archived verbatim\n' > "$BAREFIX/archive_index-compaction-x.md"
OUTB="$(MAUDE_MEM_DIR_OVERRIDE="$BAREFIX" bash "$LINT" 2>/dev/null)"
RCB=$?
assert_exit "$RCB" "0" "no crash on empty LIVE"

test_start "live-file-less report reaches the scope footer (ran to completion)"
assert_contains "$OUTB" "0 live topic file(s) scanned" "full report emitted"

test_start "live-file-less pass still logs its receipt"
LINEB="$(jq -c 'select(.kind == "lint")' "$(trace_path)" 2>/dev/null | tail -1)"
printf '%s' "$LINEB" | grep -qE 'scanned=0'
assert_exit "$?" "0" "receipt with scanned=0"

print_summary
teardown_test_env
exit "$FAILED"
