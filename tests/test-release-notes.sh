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

---

## v0.18.0 - the ascii hyphen

Hyphen entry body.

---

## v0.17.0

Bare heading body.

---

## v0.16.0 - 

Separator with nothing after it.

---

## v0.15.0 - the hard break  

Two trailing spaces on the heading.
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

# --title: the Release page TITLE is the stranger's line — what a visitor reads
# without clicking. The tag workflow minted `--title "$TAG"` (bare) for v0.29.1,
# v0.29.2 and v0.30.0; the reason lives in the CHANGELOG heading, so render it
# from there and refuse to mint a bare one.
test_start "--title renders the stranger's line from the heading"
T="$(bash "$RN" --title 0.20.0 "$CL" 2>/dev/null)"; RC=$?
assert_exit "$RC" "0" "clean exit on a present version"
assert_eq "$T" "v0.20.0: the chore ledger" "em-dash heading renders as 'vX: reason'"

test_start "--title accepts the ASCII hyphen separator too"
T2="$(bash "$RN" --title 0.18.0 "$CL" 2>/dev/null)"
assert_eq "$T2" "v0.18.0: the ascii hyphen" "hyphen heading renders as 'vX: reason'"

test_start "--title refuses a heading with no reason (a bare title is the defect)"
bash "$RN" --title 0.17.0 "$CL" >/dev/null 2>&1
assert_exit "$?" "1" "nonzero on a bare heading"

test_start "--title refuses a separator with nothing after it (one trailing space is the common editor artifact)"
bash "$RN" --title 0.16.0 "$CL" >/dev/null 2>&1
assert_exit "$?" "1" "nonzero on an empty reason after the separator"

test_start "--title trims trailing whitespace from the reason (a markdown hard break is two spaces)"
T3="$(bash "$RN" --title 0.15.0 "$CL" 2>/dev/null)"
assert_eq "$T3" "v0.15.0: the hard break" "no trailing spaces in the title"

test_start "--title refuses a date where the reason should be"
bash "$RN" --title 0.19.0 "$CL" >/dev/null 2>&1
assert_exit "$?" "1" "nonzero on a date-shaped reason"

test_start "--title on an absent version fails loud"
bash "$RN" --title 9.9.9 "$CL" >/dev/null 2>&1
assert_exit "$?" "1" "nonzero on absent version"

test_start "body extraction is unchanged by the new fixture entries"
OUT3="$(bash "$RN" 0.18.1 "$CL" 2>/dev/null)"
assert_contains "$OUT3" "Oldest entry body." "0.18.1 body present"
assert_not_contains "$OUT3" "Hyphen entry body" "the entry below it does not bleed in"

print_summary
teardown_test_env
exit $FAILED
