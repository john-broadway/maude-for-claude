#!/usr/bin/env bash
# Tests for hooks/scripts/maude-pre-compact.sh — snapshot before compaction.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

PC="$HOOKS_DIR/maude-pre-compact.sh"

run_pc() {
  ERR="$(printf '{}' | bash "$PC" 2>&1 >/dev/null)"
  RC=$?
}

# No live buffer — snapshot is a no-op but trace still fires
test_start "pre-compact exits 0 with no live buffer"
run_pc
assert_exit "$RC" "0" "exit"

test_start "pre-compact logs trace event"
n="$(count_trace_lines '.kind == "pre-compact"')"
[ "$n" -gt "0" ]
assert_exit "$?" "0" "trace logged"

# With a live buffer (Anthropic memory now.md present)
SLUG="$(printf '%s' "$TEST_TMP" | sed 's/[^a-zA-Z0-9]/-/g')"
MEM="$HOME/.claude/projects/$SLUG/memory"
mkdir -p "$MEM"
cat > "$MEM/now.md" <<'EOF'
## 18:00 | testing
Test buffer content for snapshot.
EOF

test_start "pre-compact creates snapshot when now.md exists"
run_pc
SNAPSHOT="$(ls "$TEST_TMP/.maude/plugin/snapshots/"precompact-*.md 2>/dev/null | head -1)"
[ -f "$SNAPSHOT" ]
assert_exit "$?" "0" "snapshot file created"

test_start "snapshot includes source content"
content="$(cat "$SNAPSHOT" 2>/dev/null)"
assert_contains "$content" "Test buffer content" "buffer copied"

test_start "pre-compact emits stderr note when snapshot taken"
assert_contains "$ERR" "snapshot" "stderr note"

# ── Best-effort redaction before write ───────────────────────────────
# The snapshot dumps the live buffer to disk; obvious high-signal secrets must
# be masked first (best-effort, not a guarantee). Before this, the buffer was
# written verbatim while the header falsely claimed it was "redaction-filtered".
# Secrets are assembled at RUNTIME from split pieces so no scanner-matchable
# literal sits in committed source — GitHub push protection pattern-matches a
# fake test token the same as a real one. The runtime buffer still carries the
# real shape, so the redactor is genuinely exercised.
TOKEN="ghp""_abcdefg1234567890ABCDEFGHIJKLMNOP"   # split prefix → no committed PAT literal
{
  printf '## 18:00 | secrets\n'
  printf 'token %s and\n' "$TOKEN"
  printf 'url https://user:supersecretpw@example.com/repo\n'
} > "$MEM/now.md"

test_start "snapshot masks an obvious token"
run_pc
SNAP2="$(ls "$TEST_TMP/.maude/plugin/snapshots/"precompact-*.md 2>/dev/null | tail -1)"
body="$(cat "$SNAP2" 2>/dev/null)"
assert_not_contains "$body" "$TOKEN" "raw token masked"

test_start "snapshot masks basic-auth credentials in a URL"
assert_not_contains "$body" "supersecretpw" "raw url password masked"

test_start "redaction is surgical — non-secret host/path survives"
assert_contains "$body" "@example.com/repo" "host preserved, only creds masked"

# A full PEM private-key block: the BODY must be masked, not just the marker.
# Markers are assembled at runtime (the "PRIVATE KEY" phrase and the armor are
# split in source so no committed armored-header literal trips a scanner); the
# body is obviously-fake (no real DER prefix). The range-mask replaces the block.
PK="PRIVATE"" KEY"
BEG="-----BEGIN RSA ${PK}-----"
END="-----END RSA ${PK}-----"
{
  printf '## 18:00 | pem\n'
  printf '%s\n' "$BEG"
  printf 'fakeKeyBodyAAA1234567890abcdefMUSTNOTLAND\n'
  printf 'fakeKeyBodyBBB0987654321ALSOmustNOTland\n'
  printf '%s\n' "$END"
} > "$MEM/now.md"

test_start "snapshot masks the PEM key body, not just the marker line"
run_pc
SNAP3="$(ls "$TEST_TMP/.maude/plugin/snapshots/"precompact-*.md 2>/dev/null | tail -1)"
pem="$(cat "$SNAP3" 2>/dev/null)"
assert_not_contains "$pem" "fakeKeyBodyAAA1234567890abcdefMUSTNOTLAND" "key body line 1 masked"

test_start "PEM key body second line masked too"
assert_not_contains "$pem" "fakeKeyBodyBBB0987654321ALSOmustNOTland" "key body line 2 masked"

test_start "PEM block replaced with the [redacted-key] marker"
assert_contains "$pem" "[redacted-key]" "marker present"

# Cleanup MEM
rm -rf "$MEM"

# ── The snapshot keeps the TAIL of an oldest-first buffer and names the cut; the handoff
# is APPENDED, never truncated, and read back before it is claimed (the memory lens,
# 2026-09-06: five snapshots on disk were byte-identical copies of the 35-day-old head of
# a 2,554-line buffer, and the handoff write was a `>` over a 31-handoff file).
test_start "the snapshot keeps the newest lines of an append-only buffer and names the cut"
mkdir -p "$MEM"   # an earlier case removes the memory dir
{ printf 'OLDMARK line 1\n'; for i in $(seq 2 299); do printf 'filler %d\n' "$i"; done; printf 'NEWMARK line 300\n'; } > "$MEM/now.md"
run_pc
SNAP="$(ls -t "$TEST_TMP/.maude/plugin/snapshots/"precompact-*.md 2>/dev/null | head -1)"
assert_contains "$(cat "$SNAP")" "NEWMARK" "the newest line is in the snapshot"
assert_not_contains "$(cat "$SNAP")" "OLDMARK" "the oldest line, 300 back, is not"
assert_contains "$(head -4 "$SNAP" | tr '\n' ' ')" "last 200 of 300 lines" "the header names the cut"

test_start "a stale handoff is APPENDED to, never truncated, and the write is read back"
mkdir -p "$TEST_TMP/.remember"
printf '# Handoff\n\n## Next\nKEEPME the prior handoff.\n' > "$TEST_TMP/.remember/remember.md"
touch_ago 1200 "$TEST_TMP/.remember/remember.md"
run_pc
HAND="$(cat "$TEST_TMP/.remember/remember.md")"
assert_contains "$HAND" "KEEPME" "the prior handoff survives"
assert_contains "$HAND" "## Handoff (maude pre-compact " "the new handoff is a dated section"
assert_eq "$(grep -c '^## Next' "$TEST_TMP/.remember/remember.md")" "2" "both ## Next blocks present"
assert_contains "$(tail -1 "$(trace_path)")" "sourced=snapshot remember" "the trace claims the handoff after reading it back"

print_summary
teardown_test_env
exit $FAILED
