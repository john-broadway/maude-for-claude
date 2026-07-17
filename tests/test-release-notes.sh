#!/usr/bin/env bash
# Tests for scripts/release-notes.sh — extract one version's CHANGELOG entry
# (the Release page is a rendering of the CHANGELOG, never new prose). (#38)

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

RN="$DIR/../scripts/release-notes.sh"
CL="$TEST_TMP/CHANGELOG.md"
cat > "$CL" <<'EOF'
<!-- Version: 0.20.0 -->

# Changelog

---

## v0.20.0 — the chore ledger

Newest entry body.
Second line of newest.

---

## v0.19.0 — 2026-07-15

Middle entry body — the one we extract.

**Bold detail line.**

---

## v0.18.1 — 2026-07-15

Oldest entry body.
EOF

test_start "extracts exactly one version's entry"
OUT="$(bash "$RN" 0.19.0 "$CL" 2>/dev/null)"; RC=$?
assert_exit "$RC" "0" "clean exit on a present version"
assert_contains "$OUT" "Middle entry body — the one we extract." "entry body present"
assert_contains "$OUT" "Bold detail line." "whole section present"

test_start "neighboring entries never bleed in"
assert_not_contains "$OUT" "Newest entry body" "no newer entry"
assert_not_contains "$OUT" "Oldest entry body" "no older entry"
assert_not_contains "$OUT" "## v0.19.0" "heading itself stripped (the Release page has its own title)"

test_start "no trailing separator in the notes"
case "$OUT" in *---*) SEP=yes;; *) SEP=no;; esac
assert_eq "$SEP" "no" "no --- separator in extracted notes"

test_start "a missing version fails loud"
bash "$RN" 9.9.9 "$CL" >/dev/null 2>&1
assert_exit "$?" "1" "nonzero on absent version"

test_start "the newest entry extracts too (no next-heading needed below it)"
OUT2="$(bash "$RN" 0.20.0 "$CL" 2>/dev/null)"
assert_contains "$OUT2" "Second line of newest." "newest entry body present"
assert_not_contains "$OUT2" "Middle entry" "older entry not included"

print_summary
teardown_test_env
exit $FAILED
