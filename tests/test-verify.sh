#!/usr/bin/env bash
# Tests for scripts/maude-verify.sh — the project audit.
#
# HERMETIC: the green case runs against a committed, stable fixture
# (tests/fixtures/clean-project/) — NOT the live repo. The old test cd'd to
# MAUDE_ROOT and asserted 0 findings against whatever transient untracked state
# happened to be present (a dogfooding house-map, just-edited files with stale
# Revised: dates), so it failed locally while passing on a clean CI checkout.

set +e
. "$(dirname "$0")/lib.sh"

VERIFY="$SCRIPTS_DIR/maude-verify.sh"
FIXTURE="$MAUDE_ROOT/tests/fixtures/clean-project"

test_start "verify is executable"
[ -x "$VERIFY" ] || [ -r "$VERIFY" ]
assert_exit "$?" "0" "readable"

# ── Green case: a clean fixture yields zero findings ─────────────────
OUT="$(bash "$VERIFY" "$FIXTURE" 2>&1)"
RC=$?

test_start "verify exits 0 on the clean fixture"
assert_exit "$RC" "0" "exit"

test_start "verify reports 0 findings on the clean fixture"
assert_contains "$OUT" "0 findings" "zero findings"

test_start "verify output ends with an 'N findings' summary"
assert_contains "$(printf '%s' "$OUT" | tail -1)" "findings" "summary line"

# ── Parser: a watch-list entry with a trailing description must NOT be ─
# misread as a missing path (the bug that tripped the dogfooding house-map).
# Use a SLASH-containing path so it reaches verify's path-detection branch
# (`/*|./*|[a-zA-Z0-9._-]*/*` requires a slash) — a bare filename is skipped
# regardless of the parser, which would make this test hollow. With the buggy
# whole-line parser the trailing "(description)" makes the path look missing;
# with the first-field fix it resolves. This goes RED if the fix is reverted.
PMAP="$(mktemp -d)"
mkdir -p "$PMAP/.claude-plugin" "$PMAP/.maude/plugin" "$PMAP/sub"
printf '{"name":"x","version":"9.9.9"}\n' > "$PMAP/.claude-plugin/plugin.json"
printf 'real\n' > "$PMAP/sub/realfile.md"
cat > "$PMAP/.maude/plugin/house-map.md" <<'EOF'
# House map
## Watch list
- sub/realfile.md        (a trailing description must not break path resolution)
## Notes
EOF
OUT_P="$(bash "$VERIFY" "$PMAP" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "watch-list parser ignores a trailing inline description"
printf '%s' "$OUT_P" | grep -q "Watch-list path missing: sub/realfile.md"
assert_exit "$?" "1" "no false missing-path finding for sub/realfile.md"

rm -rf "$PMAP"

# ── Version-header sync: a stale <!-- Version: --> header is a finding ─
# The release convention bumps EVERY markdown version header to the canonical
# plugin.json version; v0.4.0 missed seven (including the README's own) and
# nothing caught it. This pins the check that now does.
HSYNC="$(mktemp -d)"
mkdir -p "$HSYNC/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HSYNC/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\ncurrent file\n' > "$HSYNC/current.md"
printf '<!-- Version: 1.0.0 -->\nstale file\n' > "$HSYNC/stale.md"
OUT_H="$(bash "$VERIFY" "$HSYNC" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify flags a markdown version header behind plugin.json"
assert_contains "$OUT_H" "STALE HEADER" "stale header finding present"

test_start "stale-header finding names the file and both versions"
assert_contains "$OUT_H" "stale.md says Version: 1.0.0 (expected 2.0.0)" "specific finding"

test_start "a header matching the canonical version is not flagged"
printf '%s' "$OUT_H" | grep -q "current.md says"
assert_exit "$?" "1" "no finding for the in-sync header"

# ── THE WORN-FRAMING SCAN WALKS THE TREE TOO ─────────────────────────
# Check 7 had no test at all, which is how it kept its tree-wide walk when the other
# selectors were narrowed. It is inert until a project writes worn-framings.txt, so it fires
# for nobody today and would have fired across every sibling worktree the day someone did.
# Counting the selectors I EDITED said three of three; counting the selectors that EXIST
# said five. Count the class, not the subset.
VWORN="$(mktemp -d)"
mkdir -p "$VWORN/.claude-plugin" "$VWORN/.maude/plugin" "$VWORN/.claude/worktrees/agent-z"
printf '{"name":"x","version":"2.0.0"}\n' > "$VWORN/.claude-plugin/plugin.json"
printf 'seamless integration\n' > "$VWORN/.maude/plugin/worn-framings.txt"
printf '<!-- Version: 2.0.0 -->\nthis tree is clean\n' > "$VWORN/ok.md"
printf 'a sibling checkout says seamless integration here\n' > "$VWORN/.claude/worktrees/agent-z/other.md"
OUT_W1="$(bash "$VERIFY" "$VWORN" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "the worn-framing scan ignores a phrase inside a worktrees/ directory"
printf '%s' "$OUT_W1" | grep -q "other.md"
assert_exit "$?" "1" "another checkout's prose is not this tree's finding"

# The control. Without it the test above passes on a scan that finds nothing at all, which
# is exactly the shape that let this survive: a check that cannot fire looks like a check
# that passed.
printf 'we offer seamless integration\n' > "$VWORN/mine.md"
OUT_W2="$(bash "$VERIFY" "$VWORN" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "control: the same phrase in the tree's OWN file is still reported"
assert_contains "$OUT_W2" "mine.md" "the real tree is still scanned"

test_start "and the finding names the worn phrase"
assert_contains "$OUT_W2" "seamless integration" "the phrase is named"

# ── verify MUST NOT AUDIT SIBLING WORKTREES EITHER ───────────────────
# Same omission as release.sh's selectors: a stale header inside another branch's checkout
# is not this tree's finding, and with seven live worktrees it would bury the real report.
VWT="$(mktemp -d)"
mkdir -p "$VWT/.claude-plugin" "$VWT/.claude/worktrees/agent-y"
printf '{"name":"x","version":"2.0.0"}\n' > "$VWT/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\ncurrent\n' > "$VWT/ok.md"
printf '<!-- Version: 1.0.0 -->\na sibling branch checkout\n' > "$VWT/.claude/worktrees/agent-y/old.md"
OUT_VWT="$(bash "$VERIFY" "$VWT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify ignores a stale header inside a worktrees/ directory"
printf '%s' "$OUT_VWT" | grep -q "old.md"
assert_exit "$?" "1" "another checkout's header is not this tree's finding"

# ONE ASSERTION PER SELECTOR. A single comment-header file in the worktree left the
# blockquote, Revised-date and version-collector exclusions unpinned: removing any of them
# individually kept the suite green.
test_start "verify ignores a stale BLOCKQUOTE header inside a worktree"
printf '# T\n\n> **Version:** 1.0.0\n' > "$VWT/.claude/worktrees/agent-y/bq.md"
printf '<!-- Revised: 2001-01-01 -->\nold\n' > "$VWT/.claude/worktrees/agent-y/rev.md"
printf 'see v9.9.9 for details\n' > "$VWT/.claude/worktrees/agent-y/refs.md"
printf '{"broken": \n' > "$VWT/.claude/worktrees/agent-y/bad.json"
OUT_VWT2="$(bash "$VERIFY" "$VWT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
printf '%s' "$OUT_VWT2" | grep -q "bq.md"
assert_exit "$?" "1" "another checkout's blockquote is not this tree's finding"

test_start "verify ignores a stale REVISED date inside a worktree"
printf '%s' "$OUT_VWT2" | grep -q "rev.md"
assert_exit "$?" "1" "another checkout's date is not this tree's finding"

# The version collector only prints, but printing another checkout's versions as this
# tree's is still a wrong statement about this tree.
test_start "the version-ref collector does not report a worktree's versions"
printf '%s' "$OUT_VWT2" | grep -q "v9.9.9"
assert_exit "$?" "1" "a sibling checkout's version is not listed as this repo's"

# The JSON walk is a `find`, not a grep, which is why an enumeration of grep selectors
# missed it. It is live: 57 of the 68 files it scanned in the real repo were worktree files.
test_start "the JSON validity walk does not scan a worktree"
printf '%s' "$OUT_VWT2" | grep -q "bad.json"
assert_exit "$?" "1" "a broken JSON in another checkout is not this tree's finding"

test_start "and the tree's own files are still audited (no over-exclusion)"
assert_contains "$OUT_VWT" "0 findings" "the real tree is clean and still checked"

# The control for the JSON walk: a broken JSON in THIS tree must still be caught, or the
# exclusion bought silence rather than accuracy.
test_start "control: a broken JSON in the tree's OWN files is still reported"
printf '{"broken": \n' > "$VWT/mine-bad.json"
OUT_VJ="$(bash "$VERIFY" "$VWT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
assert_contains "$OUT_VJ" "mine-bad.json" "the real tree's broken JSON is still found"
rm -f "$VWT/mine-bad.json"

# ── THE BLOCKQUOTE HEADER WAS CHECKED BY NOTHING ─────────────────────
# release.sh stamps two header forms but verify only ever audited the HTML-comment one, so
# a stale `> **Version:**` line was invisible to every check in the house. Today that form
# covers exactly one file, .claude/CLAUDE.md, which is why nobody noticed.
HBQ="$(mktemp -d)"
mkdir -p "$HBQ/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HBQ/.claude-plugin/plugin.json"
printf '# Title\n\n> **Version:** 1.0.0\n> **License:** x\n' > "$HBQ/stale-bq.md"
printf '# Title\n\n> **Version:** 2.0.0\n' > "$HBQ/current-bq.md"
OUT_BQ="$(bash "$VERIFY" "$HBQ" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify flags a stale blockquote version header"
assert_contains "$OUT_BQ" "stale-bq.md" "the stale blockquote file is named"

test_start "and it reports both versions"
assert_contains "$OUT_BQ" "1.0.0" "found version reported"

test_start "a blockquote header matching the canonical version is not flagged"
printf '%s' "$OUT_BQ" | grep -q "current-bq.md"
assert_exit "$?" "1" "no finding for the in-sync blockquote"

# ── THE WINDOW IS DEFINED ONCE, OR THE CLAIM IS FALSE ────────────────
# maude-verify.sh restated `: "${MAUDE_HEADER_LINES:=10}"` as a fallback, which is a second
# copy of the very number the commit claimed lived in one place. Two copies drift; that is
# the whole reason the definition was centralised. With the library absent the checker must
# say so as a FINDING, not quietly substitute a guess and audit against it.
VNOLIB="$(mktemp -d)"
mkdir -p "$VNOLIB/scripts" "$VNOLIB/proj/.claude-plugin"
cp "$SCRIPTS_DIR/maude-verify.sh" "$VNOLIB/scripts/"
printf '{"name":"x","version":"2.0.0"}\n' > "$VNOLIB/proj/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\ncurrent\n' > "$VNOLIB/proj/ok.md"
OUT_NL="$(bash "$VNOLIB/scripts/maude-verify.sh" "$VNOLIB/proj" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify REPORTS a missing lib-stamp.sh instead of guessing the header window"
assert_contains "$OUT_NL" "lib-stamp" "the missing dependency is named"

test_start "the number 10 appears in ONE definition across scripts/"
assert_eq "$(grep -c 'MAUDE_HEADER_LINES:=' "$SCRIPTS_DIR/maude-verify.sh" "$SCRIPTS_DIR/lib-stamp.sh" | awk -F: '{t+=$2} END{print t}')" \
  "1" "exactly one default assignment"

# ── A version string in the BODY is not a header ─────────────────────
# Found 2026-09-04 by the v0.31.0 release-diff lens. A header is metadata in the
# file's leading block: every one in this repo sits on line 1, and the single
# blockquote form (.claude/CLAUDE.md) on line 3. Anything further down is prose
# quoting a version, and a historical plan doc is full of it.
#
# verify read the FIRST match anywhere in the file and release.sh rewrote EVERY
# match anywhere in the file, so the two exactly cancelled: the body line was kept
# current by the writer, and the checker read that same body line and was content.
# Thirteen releases rewrote a 2026-06-30 plan's "Bump version 0.13.1 -> 0.13.2"
# checklist to say 0.31.0. Both sides now look only at the header block, so a
# document that quotes a version in its prose has no header and is not checked.
HBODY="$(mktemp -d)"
mkdir -p "$HBODY/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HBODY/.claude-plugin/plugin.json"
{
  printf '# A plan from an older cycle\n\n'
  for i in $(seq 1 18); do printf 'body line %s\n' "$i"; done
  printf -- '- [ ] Step 1: Bump version 1.0.0 -> 1.0.1:\n'
  printf -- '  - `CHANGELOG.md` header comment `<!-- Version: 1.0.1 -->` and `<!-- Revised: 2020-01-01 -->`\n'
} > "$HBODY/plan.md"
OUT_B="$(bash "$VERIFY" "$HBODY" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "a version quoted in the BODY is not read as a stale header"
printf '%s' "$OUT_B" | grep -q "STALE HEADER"
assert_exit "$?" "1" "prose quoting a version is not a header"

test_start "a Revised date quoted in the BODY is not read as a stale date"
printf '%s' "$OUT_B" | grep -qi "plan.md.*[Rr]evised"
assert_exit "$?" "1" "prose quoting a date is not a header date"

# The control: the SAME strings in the header block MUST still be caught, or the
# window would have bought silence rather than accuracy.
HWIN="$(mktemp -d)"
mkdir -p "$HWIN/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HWIN/.claude-plugin/plugin.json"
printf '<!-- Version: 1.0.1 -->\n<!-- Revised: 2020-01-01 -->\n\n# real header\n' > "$HWIN/real.md"
OUT_W="$(bash "$VERIFY" "$HWIN" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "control: the same version IN the header block is still flagged"
assert_contains "$OUT_W" "real.md says Version: 1.0.1 (expected 2.0.0)" "header still checked"

test_start "control: the same date IN the header block is still flagged"
# Named the file only, once — which the VERSION finding one assertion above already
# puts in this same output. Killing Check 4 outright left this "control" green.
assert_contains "$OUT_W" "real.md Revised: 2020-01-01 (" "the stale-date finding names the file and its date"

test_start "the stale-date finding says why it is stale"
assert_contains "$OUT_W" "days ago — stale" "the staleness reason is named"

# The other direction. The assertions above die when the check is dead, but they cannot
# see it inverted to always-emit: a fixture that is only ever stale cannot tell a real
# threshold from an unconditional finding.
HFRESH="$(mktemp -d)"
mkdir -p "$HFRESH/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HFRESH/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: %s -->\n\n# fresh header\n' "$(date +%Y-%m-%d)" > "$HFRESH/fresh.md"
OUT_F="$(bash "$VERIFY" "$HFRESH" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "a Revised date inside the window is not a finding"
assert_not_contains "$OUT_F" "days ago — stale" "a date inside the window is not stale"
rm -rf "$HFRESH"

# The window's VALUE, from both sides. Everything above pins only the comparison's
# DIRECTION: with the fixtures above alone, STALE_LIMIT_DAYS could be set to 0, or to 13,
# or to anything up to the age of the 2020-01-01 control, and no assertion moved. A file
# AT the limit must stay silent and one a day PAST it must speak, which is the only pair
# that admits 14 and no other number.
# Both sides pinned to UTC: the fixture dates AND the run that reads them. The first
# version of this subtracted N*86400 from LOCAL midnight and claimed that made the
# boundary exact in any zone. It made it wrong in every zone that keeps DST: a
# spring-forward inside the window leaves a 23-hour day, so the arithmetic lands one
# calendar day early and the AT-limit file reads as fifteen days old. That is a spurious
# red for about two weeks after every spring-forward, in Central, which is where this is
# read from. A zone with no transitions has no such day. What Check 4 makes of a DST
# boundary in its own arithmetic is a separate question and not what this pair is for.
_ymd_back() {  # $1 = whole days before today, computed in UTC
  ( export TZ=UTC
    source_common
    a="$(maude_date_epoch "$(date +%Y-%m-%d)")"
    # Without this, a missing anchor fell through to a negative epoch and rendered a
    # 1969 date, which looks like a plausible fixture and quietly voids the pair.
    case "$a" in (''|*[!0-9]*) echo "_ymd_back: no epoch for today" >&2; return 1 ;; esac
    e=$(( a - $1 * 86400 ))
    s="$(date -d "@$e" +%Y-%m-%d 2>/dev/null)"                # portability-shim (GNU)
    [ -n "$s" ] || s="$(date -r "$e" +%Y-%m-%d 2>/dev/null)"  # portability-shim (BSD)
    [ -n "$s" ] || { echo "_ymd_back: no date for epoch $e" >&2; return 1; }
    printf '%s' "$s" )
}
HEDGE="$(mktemp -d)"
mkdir -p "$HEDGE/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HEDGE/.claude-plugin/plugin.json"
# The AT-limit file carries a deliberate version MISMATCH so the version check names it.
# That is the only way this pair can prove the file was READ: a healthy file at 14 days
# is silent in every check, and silence is what a fixture that was never created looks
# like too. A typo'd path or a dead run passed the bare absence check happily.
AT_D="$(_ymd_back 14)"; PAST_D="$(_ymd_back 15)"
printf '<!-- Version: 1.0.0 -->\n<!-- Revised: %s -->\n\n# at the limit\n' "$AT_D" > "$HEDGE/at-limit.md"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: %s -->\n\n# past the limit\n' "$PAST_D" > "$HEDGE/past-limit.md"
OUT_E="$(TZ=UTC bash "$VERIFY" "$HEDGE" 2>&1)"
OUT_EE="$(TZ=UTC MAUDE_VERIFY_TODAY="" bash "$VERIFY" "$HEDGE" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

# Named first, because without it a dead date helper writes `Revised:` with no digits,
# Check 4 skips the file for having no date at all, and "AT limit is not a finding" goes
# green for the wrong reason. The suite still reddened on the neighbours, but neither of
# the two assertions below could tell you which failure it was looking at.
test_start "the boundary fixture dates were computable"
assert_eq "$([ -n "$AT_D" ] && [ -n "$PAST_D" ] && echo ok)" "ok" "both dates resolved"

test_start "the AT-limit fixture was actually read"
assert_contains "$OUT_E" "at-limit.md says Version:" "a different check names the file, so it exists and was walked"

# `at-limit.md Revised:` can only come from Check 4's own emit, never from the version
# finding above — which is the exact confusion that made the old date control vacuous.
test_start "a file AT the stale limit is not a finding"
assert_not_contains "$OUT_E" "at-limit.md Revised:" "14 days is inside the window"

test_start "a file one day PAST the stale limit is a finding"
assert_contains "$OUT_E" "past-limit.md Revised:" "15 days is outside the window"

test_start "exactly one of the boundary pair is stale"
assert_eq "$(printf '%s\n' "$OUT_E" | grep -c 'days ago — stale')" "1" "one stale finding, not none and not both"

# The empty seam must anchor on the same day as no seam. The two empty-seam fixtures below sit
# far from the boundary (today, 2020), so an anchor moved by a day on the empty path only was
# invisible to them (seventeenth pass). Here a day either way makes none or both stale.
test_start "and under an empty seam the boundary pair reads the same"
assert_eq "$(printf '%s\n' "$OUT_EE" | grep -c 'days ago — stale')" "1" "one stale finding under an empty seam, not none and not both"
rm -rf "$HEDGE"

# Check 4 AT THE PRODUCTION CALLSITE, with a real DST transition inside the span. The
# boundary pair above cannot do this: it runs under TZ=UTC, and the old raw-seconds formula
# and the midnight-anchored one agree for every input in every zone OUTSIDE a daylight-saving
# window. Reverting the callsite alone, helper untouched, left all 61 test files green.
# 2026-03-08 springs forward in US Central, so 03-04 to 03-20 is 16 calendar days but only
# 15*86400+82800 real seconds. Correct reads 16. A naive midnight-to-midnight seconds count
# reads 15. The pre-fix callsite ignores this seam and reads the real clock, so it reads 184
# and climbs by one a day. One assertion separates all three.
# Without this the whole block is theatre: on a box with missing or stale zoneinfo,
# America/Chicago collapses to UTC, the span has no short day, and the assertion below
# reads 16 whether the rounding fix is present or not. Measured under an empty TZDIR.
# ── The seam's own behaviour. None of this depends on a timezone, so none of it sits
# inside the DST guard below: on a box with broken tzdata these still have to run.
HSEAM="$(mktemp -d)"
mkdir -p "$HSEAM/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HSEAM/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2026-03-19 -->\n\n# one day before the pin\n' > "$HSEAM/near.md"

# Pinned, against a file that is NOT stale relative to the pin, so the pin is the only
# finding and the exit code carries it alone.
OUT_PIN="$(TZ=UTC MAUDE_VERIFY_TODAY=2026-03-20 bash "$VERIFY" "$HSEAM" 2>&1)"; RC_PIN=$?
cd "$MAUDE_ROOT" || exit 1

test_start "a pinned today is announced"
assert_contains "$OUT_PIN" "today is pinned to 2026-03-20 by MAUDE_VERIFY_TODAY" "the seam declares itself"

# The TEXT was never the mitigation and asserting it was the defect. A printf emits the
# same string, release.sh throws it away with `| tail -3`, and CI reads only the exit
# code — so an assertion on text alone let the whole thing back in, green. This is the
# assertion that actually holds the claim.
test_start "and the pin reaches the EXIT CODE, which is all release.sh and CI read"
assert_exit "$RC_PIN" "1" "a pinned today must make verify exit non-zero"

test_start "the pin is the only finding on an otherwise clean tree"
# Anchored: "1 findings" as a substring also matches "11 findings" and "21 findings".
assert_eq "$(printf '%s\n' "$OUT_PIN" | grep -cE '^1 findings$')" "1" "exactly one finding, the pin itself"

# An anchor it cannot resolve must SAY so. Without this the helper fails for every file,
# every file is skipped, and the run prints a clean bill for a check that examined nothing:
# the shape the seventh pass found in this very script. Measured before the guard existed:
# MAUDE_VERIFY_TODAY=banana turned a 247-day-stale file into 0 findings, exit 0.
OUT_NT="$(TZ=UTC MAUDE_VERIFY_TODAY=banana bash "$VERIFY" "$HSEAM" 2>&1)"; RC_NT=$?
cd "$MAUDE_ROOT" || exit 1

test_start "an unresolvable today is a finding, not a clean bill"
assert_contains "$OUT_NT" "cannot resolve today's date" "the check says it did not run"

test_start "and it too reaches the exit code"
assert_exit "$RC_NT" "1" "an unresolvable anchor must make verify exit non-zero"

# And an empty value must NOT be one: an ambient empty used to make this exit 2, which took
# make verify and ship.sh's release gate down with it. Its own fixture, dated by the real
# clock: $HSEAM is fresh only relative to the PIN, and reads ~170 days stale without it —
# which is a true finding, and would have made this assertion fail for the right reason
# about the wrong thing.
HEMPTY="$(mktemp -d)"
mkdir -p "$HEMPTY/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HEMPTY/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: %s -->\n\n# fresh by the real clock\n' "$(date +%Y-%m-%d)" > "$HEMPTY/fresh.md"
OUT_EMPTY="$(TZ=UTC MAUDE_VERIFY_TODAY="" bash "$VERIFY" "$HEMPTY" 2>&1)"; RC_EMPTY=$?
cd "$MAUDE_ROOT" || exit 1

test_start "an empty seam falls back to today rather than blocking the gate"
assert_not_contains "$OUT_EMPTY" "cannot resolve today's date" "empty means use today"

test_start "and an empty seam leaves the gate passable"
assert_exit "$RC_EMPTY" "0" "empty must never block a release"

# The other half of "empty means today", stated as the property rather than as one phrase.
# The first version of this asserted the output lacked the literal "today is pinned", which
# a mutation that pins an empty seam under ANY other wording walks straight past. "Empty
# means today" is exactly "empty is indistinguishable from unset", so compare the two runs.
OUT_UNSET="$(TZ=UTC bash "$VERIFY" "$HEMPTY" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "an empty seam is indistinguishable from an unset one"
assert_eq "$OUT_EMPTY" "$OUT_UNSET" "empty must behave exactly as unset, byte for byte"
rm -rf "$HEMPTY"
rm -rf "$HSEAM"

# The equality above runs on a FRESH file, and Check 4 prints nothing for a fresh file: a
# scan that ran and a scan that never ran leave the same bytes. So a mutation that switched
# Check 4 off for an empty-but-set seam passed every assertion in this file and the whole
# gate (sixteenth pass). A file stale on any clock makes the scan observable. The unset path
# is proven on such files above ($HWIN, $HEDGE); this is the empty path. Not an equality
# against an unset run here: the finding carries a day count read from the clock, and a
# midnight between two runs would redden that for the clock and not the code.
HSTALE="$(mktemp -d)"
mkdir -p "$HSTALE/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HSTALE/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2020-01-01 -->\n\n# stale by any clock\n' > "$HSTALE/stale.md"
OUT_EMPTY_STALE="$(TZ=UTC MAUDE_VERIFY_TODAY="" bash "$VERIFY" "$HSTALE" 2>&1)"; RC_EMPTY_STALE=$?

test_start "an empty seam still examines the files"
assert_contains "$OUT_EMPTY_STALE" "stale.md Revised: 2020-01-01" "the scan ran on the empty path"

test_start "and its finding reaches the exit code"
assert_exit "$RC_EMPTY_STALE" "1" "a stale file under an empty seam must still block"
rm -rf "$HSTALE"

# ── DST-dependent, and only this. Guarded, not merely preceded: a failing precondition
# beside a passing assertion still leaves a green line that proved nothing, and under an
# empty TZDIR the count below reads 16 either way.
# GNU `date -d` first, BSD `date -j -f` second: with only the GNU form the guard read two
# empty strings on macOS, called them equal, and failed the suite for a zone database that
# was fine (2026-09-13, PR #68).
_chi_off() { TZ=America/Chicago date -d "$1" +%z 2>/dev/null || TZ=America/Chicago date -j -f '%Y-%m-%dT%H:%M:%S' "$1" +%z 2>/dev/null; }   # portability-shim
if [ "$(_chi_off 2026-03-08T00:30:00)" = "$(_chi_off 2026-03-08T23:30:00)" ]; then
  test_start "this box's zone database really has the 2026 spring-forward"
  _fail "no 2026 spring-forward in tzdata: the DST assertion cannot discriminate here and was NOT run"
else
  HDST="$(mktemp -d)"
  mkdir -p "$HDST/.claude-plugin"
  printf '{"name":"x","version":"2.0.0"}\n' > "$HDST/.claude-plugin/plugin.json"
  printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2026-03-04 -->\n\n# across a spring-forward\n' > "$HDST/dst.md"
  OUT_DST="$(TZ=America/Chicago MAUDE_VERIFY_TODAY=2026-03-20 bash "$VERIFY" "$HDST" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1

  test_start "Check 4 counts calendar days across a spring-forward, at the callsite"
  assert_contains "$OUT_DST" "dst.md Revised: 2026-03-04 (16 days ago" "16 calendar days, not 15 and not the real clock"
  # Inside the branch that creates it: outside the fi this crashed the whole file under bash -u.
  rm -rf "$HDST"
fi

rm -rf "$HSYNC"

# ── Failing case: a broken plugin.json must produce a finding ────────
TMP_PLUGIN="$(mktemp -d)"
mkdir -p "$TMP_PLUGIN/.claude-plugin"
cat > "$TMP_PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{ this is not valid JSON
EOF
bash "$VERIFY" "$TMP_PLUGIN" >/dev/null 2>&1
RC_B=$?
cd "$MAUDE_ROOT" || exit 1

test_start "verify exits non-zero on broken plugin.json"
[ "$RC_B" -ne 0 ]
assert_exit "$?" "0" "non-zero exit"

rm -rf "$TMP_PLUGIN"

# ── Command-reference integrity: a doc ref to a cut/missing command is a finding ─
# The recurring miss: cut a command, but a /maude:<name> reference lingers in
# README/SKILL/agents. This gate catches the straggler (commands/<name>.md gone).
CREF="$(mktemp -d)"
mkdir -p "$CREF/.claude-plugin" "$CREF/commands"
printf '{"name":"x","version":"1.0.0"}\n' > "$CREF/.claude-plugin/plugin.json"
printf 'real\n' > "$CREF/commands/wake.md"
printf '<!-- Version: 1.0.0 -->\n# x\nUse /maude:wake to start. Old: /maude:brief was cut.\n' > "$CREF/README.md"
OUT_C="$(bash "$VERIFY" "$CREF" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify flags a doc reference to a missing command"
assert_contains "$OUT_C" "/maude:brief" "dangling command ref flagged"

test_start "verify does NOT flag a command reference that resolves"
printf '%s' "$OUT_C" | grep -q "/maude:wake but"
assert_exit "$?" "1" "no false finding for an existing command"

rm -rf "$CREF"

# ── What's-new condensation: a wall of > MAX release entries is a finding ─────
# The recurring miss: each release adds a What's-new entry but never condenses the
# old ones, so the public README reads as a stale wall (24 entries at v0.9.0).
WALL="$(mktemp -d)"
mkdir -p "$WALL/.claude-plugin"
printf '{"name":"x","version":"9.0.0"}\n' > "$WALL/.claude-plugin/plugin.json"
{
  printf '<!-- Version: 9.0.0 -->\n# x\n\n## What'\''s new\n\n'
  for v in 9.0.0 8.0.0 7.0.0 6.0.0 5.0.0 4.0.0 3.0.0 2.0.0; do printf '**v%s** — entry.\n\n' "$v"; done
} > "$WALL/README.md"
OUT_W="$(bash "$VERIFY" "$WALL" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "verify flags an un-condensed What's-new wall"
assert_contains "$OUT_W" "condense" "wall finding asks to condense"

rm -rf "$WALL"

# ── Design rules: a planted schema finding is counted, tests/ is not ──
TEST_TMP="$(mktemp -d)"
if command -v python3 >/dev/null 2>&1; then
  test_start "verify counts a planted schema finding and ignores tests/"
  mkdir -p "$TEST_TMP/vproj/tests"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/vproj/bad.sql"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/vproj/tests/fixture.sql"
  OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_contains "$OUT" "SCHEMA: " "planted finding surfaced"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c 'SCHEMA: ')" "1" "the tests/ copy is not counted"

  # The schema walk is the second `find`, and it was the last selector with no test: nine
  # of ten exclusions were pinned and this one rested on trust. A keyless schema in another
  # branch's checkout is that branch's problem.
  test_start "the schema linter does not walk into a worktree"
  mkdir -p "$TEST_TMP/vproj/.claude/worktrees/agent-q"
  printf 'CREATE TABLE sibling (name TEXT);\n' > "$TEST_TMP/vproj/.claude/worktrees/agent-q/other.sql"
  OUT_SQ="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_eq "$(printf '%s\n' "$OUT_SQ" | grep -c 'SCHEMA: ')" "1" "still exactly one finding, the tree's own"
  printf '%s' "$OUT_SQ" | grep -q "other.sql"
  assert_exit "$?" "1" "the worktree schema is not named"
  # Scoped to its own test, like every other exclusion fixture in this file. Left in
  # place it survived into the five tests below, so removing the SQL exclusion reddened
  # eight assertions instead of the two that name it — a red that does not say why.
  rm -rf "$TEST_TMP/vproj/.claude"

  printf 'CREATE TABLE t (id INT PRIMARY KEY);\n' > "$TEST_TMP/vproj/bad.sql"
  OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_not_contains "$OUT" "SCHEMA: " "clean schema is silent"

  # `python3 -m` puts the CWD ahead of PYTHONPATH, and verify runs from the project
  # dir, so a project carrying its own maude_rules/ would be the linter verify runs.
  test_start "verify never runs the audited project's own maude_rules package"
  mkdir -p "$TEST_TMP/vproj/maude_rules"
  : > "$TEST_TMP/vproj/maude_rules/__init__.py"
  printf 'import sys\nprint("EVIL: 0 finding(s): clean")\nsys.exit(0)\n' > "$TEST_TMP/vproj/maude_rules/__main__.py"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/vproj/bad.sql"
  OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_not_contains "$OUT" "EVIL" "the shadowing package is not executed"
  assert_contains "$OUT" "codd-2" "the real finding is still counted"
  rm -rf "$TEST_TMP/vproj/maude_rules"

  # ── a linter that dies is a finding, never a silent clean ───────────────────
  # The stub answers the maude_python3_ok probe (`python3 -c pass`) and then fails
  # silently on `-m`, which is the shape of a crashed linter or a broken import. A
  # non-zero exit with no output must never be read as "this file is fine."
  test_start "a linter that exits non-zero with no output is a finding"
  DEADPY="$(make_no_binary_bin python3)"
  printf '#!/usr/bin/env bash\ncase " $* " in *" -c "*) exit 0 ;; esac\nexit 1\n' > "$DEADPY/python3"
  chmod +x "$DEADPY/python3"
  printf 'CREATE TABLE t (id INT PRIMARY KEY);\n' > "$TEST_TMP/vproj/bad.sql"
  OUT="$(PATH="$DEADPY" bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_contains "$OUT" "SCHEMA-LINT FAILED" "the dead linter is named"
  assert_not_contains "$OUT" "0 findings" "and it counts"

  # ── the line says what was LOOKED AT, not only how many files were opened ────
  test_start "the Design rules line counts tables, and a file with none is not a finding"
  rm -f "$TEST_TMP/vproj/bad.sql"
  printf 'ALTER TABLE orders ADD COLUMN total INT;\n' > "$TEST_TMP/vproj/alter.sql"
  OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_contains "$OUT" "0 tables in 1 schema files linted" "zero tables, one file"
  assert_not_contains "$OUT" "SCHEMA: " "a file with no CREATE TABLE is not a finding"
  printf 'CREATE TABLE a (id INT PRIMARY KEY);\nCREATE TABLE b (id INT PRIMARY KEY);\n' > "$TEST_TMP/vproj/two.sql"
  OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_contains "$OUT" "2 tables in 2 schema files linted" "the tables it read are counted"
  rm -f "$TEST_TMP/vproj/alter.sql" "$TEST_TMP/vproj/two.sql"

  # ── verify's fixture rule matches the rail's ────────────────────────────────
  # The rail skips tests/, fixtures/ AND the names test_*, *_test.*, *.spec.*.
  # Verify only skipped the two directories, so a fixture schema sitting beside
  # real code was a finding on one side of the house and not on the other.
  test_start "verify skips a fixture-NAMED schema, not only a fixture directory"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/vproj/test_orders.sql"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/vproj/orders_test.sql"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/vproj/orders.spec.sql"
  OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
  cd "$MAUDE_ROOT" || exit 1
  assert_not_contains "$OUT" "SCHEMA: " "no fixture-named schema is a finding"
  assert_contains "$OUT" "0 tables in 0 schema files linted" "none of them was even opened"
  rm -f "$TEST_TMP/vproj/test_orders.sql" "$TEST_TMP/vproj/orders_test.sql" "$TEST_TMP/vproj/orders.spec.sql"
fi
test_start "verify reports a touched, unnamed class from care.json"
mkdir -p "$TEST_TMP/vproj/.maude/plugin"
printf '{"rules":{"abcdef12":{"touched":{"memory":["tape.py"]},"named":{}}}}\n' > "$TEST_TMP/vproj/.maude/plugin/care.json"
OUT="$(CLAUDE_CODE_SESSION_ID=abcdef12-rest bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
assert_contains "$OUT" "UNNAMED: memory" "unnamed class is a finding"

# ── UNNAMED is THIS session's, never a sibling lane's ─────────────────────────
# Ruling: verify counted an unnamed class from every sid ever recorded, so a lane
# working in the same tree jammed a release run that had touched nothing at all.
test_start "a sibling lane's unnamed class is a note, not a finding"
printf '{"rules":{"abcdef12":{"touched":{"memory":["tape.py"]},"named":{}},"99999999":{"touched":{"ui":["x.html"]},"named":{}}}}\n' \
  > "$TEST_TMP/vproj/.maude/plugin/care.json"
OUT="$(CLAUDE_CODE_SESSION_ID=abcdef12-rest bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
assert_contains "$OUT" "UNNAMED: memory" "my own class is still a finding"
assert_not_contains "$OUT" "UNNAMED: ui" "the sibling lane is not a finding"
assert_contains "$OUT" "note: ui" "the sibling lane is reported as a note"

test_start "with no session id nothing is a finding and everything is a note"
OUT="$(bash "$VERIFY" "$TEST_TMP/vproj" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
assert_not_contains "$OUT" "UNNAMED:" "a release run has no session context and is not jammed"
assert_contains "$OUT" "note: memory" "still listed"
assert_contains "$OUT" "note: ui" "both listed"

rm -rf "$TEST_TMP"

print_summary
exit $FAILED
