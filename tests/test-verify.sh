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

# ── CHECK 4 READS THE FILE'S HISTORY, NEVER THE CALENDAR ─────────────
# `Revised: D` claims the file last changed on D. Until 2026-09-29 the check was "older
# than 14 days is stale": main went red on 09-28 with no commit between the green run and
# the red, eight stamps were named (seven honest), the one stamp that WAS behind its file passed,
# and the only cure was to restamp files nobody had touched. A gate whose fix is a lie.
# Now the stamp is read against the last change: the last commit touching the file, or
# today if the file is dirty. Outside git there is nothing to read against, and a check
# that examined nothing must say so and red, never print a clean bill.
test_start "outside a git tree a Revised header is a finding that says NOT checked"
assert_contains "$OUT_W" "cannot anchor Revised dates on the file history (not a git work tree) — revised dates NOT checked" "the check names why it could not run"

# On its own fixture, where nothing else is wrong. $HWIN's version mismatch already makes
# the exit non-zero, so asserting RC there proved nothing: a refusal demoted to a printf
# survived it (mutation M5, 2026-09-29). Here the refusal is the only finding there is.
HNOGIT="$(mktemp -d)"
mkdir -p "$HNOGIT/.claude-plugin"
printf '{"name":"x","version":"2.0.0"}\n' > "$HNOGIT/.claude-plugin/plugin.json"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2020-01-01 -->\n\n# nothing else wrong\n' > "$HNOGIT/only.md"
OUT_NG="$(bash "$VERIFY" "$HNOGIT" 2>&1)"; RC_NG=$?
cd "$MAUDE_ROOT" || exit 1
rm -rf "$HNOGIT"

test_start "and that refusal is a FINDING that reaches the exit code"
assert_eq "$(printf '%s\n' "$OUT_NG" | grep -cE '^1 findings$')" "1" "exactly one finding, the refusal itself"

test_start "so an unexamined stamp cannot pass"
assert_exit "$RC_NG" "1" "an unexamined stamp must not pass"

# A repo whose commit dates are PLANTED, so every assertion below is clock-free and
# zone-free: the pair that admits exactly the rule is a stamp ON the day of the change
# (silent) and one a day BEHIND it (a finding). The old boundary pair needed `_ymd_back`, a
# UTC pin on both sides and a DST essay to say the same thing about a number that is gone.
# `-c` on every commit: the runners may have no identity, and a user's global gpgsign or
# hooksPath must not reach into a fixture.
_git_fixture() {  # $1 = dir
  git -C "$1" init -q
  # Two hostile user configs, on every fixture: colour would paint the `+` the restamp
  # rule greps for, and hidden untracked files would make a new file read as clean.
  git -C "$1" config color.ui always
  git -C "$1" config status.showUntrackedFiles no
}
_git_commit_on() {  # $1 = dir, $2 = author YYYY-MM-DD, $3 = message, [$4 = committer YYYY-MM-DD, default $2]
  git -C "$1" add -A
  GIT_AUTHOR_DATE="${2}T12:00:00Z" GIT_COMMITTER_DATE="${4:-$2}T12:00:00Z" \
    git -C "$1" -c user.name=x -c user.email=x@y -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m "$3"
}
_doc() {  # $1 = path, $2 = version, $3 = revised, $4 = body line
  printf '<!-- Version: %s -->\n<!-- Revised: %s -->\n\n# %s\n' "$2" "$3" "$4" > "$1"
}
HGIT="$(mktemp -d)"
mkdir -p "$HGIT/.claude-plugin"
_git_fixture "$HGIT"
printf '{"name":"x","version":"2.0.0"}\n' > "$HGIT/.claude-plugin/plugin.json"
printf 'ignored.md\n' > "$HGIT/.gitignore"
# The ON-day file carries a deliberate version MISMATCH so the version check names it.
# That is the only way this pair can prove the file was READ: a truthful stamp is silent in
# every check, and silence is what a fixture that was never created looks like too.
_doc "$HGIT/even.md"      1.0.0 2026-01-10 "stamped on its commit day"
_doc "$HGIT/behind.md"    2.0.0 2026-01-10 "edited two days later, never restamped"
_doc "$HGIT/ahead.md"     2.0.0 2026-01-13 "edited two days later, stamp already past it"
_doc "$HGIT/restamped.md" 2.0.0 2026-01-09 "edited and restamped in one re-dated commit"
_doc "$HGIT/moved.md"     2.0.0 2026-01-10 "renamed later, untouched"
_doc "$HGIT/movedlie.md"  2.0.0 2026-01-10 "edited without a restamp, then renamed"
_doc "$HGIT/mention.md"   2.0.0 2026-01-10 "edited later; the edit only mentions the word"
printf 'note: Revised: 2026-01-05 was the old convention\ny-<!-- Revised: 2026-01-05 -->\n' >> "$HGIT/mention.md"
_doc "$HGIT/rs-old.md"    2.0.0 2026-01-09 "restamped forward under this name, then renamed"
_doc "$HGIT/backward.md"  2.0.0 2026-01-12 "edited later; the stamp moved BACKWARDS"
_doc "$HGIT/space.md"     2.0.0 2026-01-10 "edited later; the stamp line changed by a space"
_doc "$HGIT/copied.md"    2.0.0 2020-01-01 "a new file carrying a copied, ancient header"
_doc "$HGIT/me-old.md"    2.0.0 2026-01-10 "moved AND edited in one commit, never restamped"
_doc "$HGIT/mr-old.md"    2.0.0 2026-01-09 "moved, edited AND restamped forward in one commit"
_doc "$HGIT/naïve.md"     2.0.0 2026-01-10 "a non-ASCII name edited later, never restamped"
_doc "$HGIT/a[1].md"      2.0.0 2026-01-09 "a glob in the name; restamped forward later"
_doc "$HGIT/a1.md"        2.0.0 2026-01-09 "the glob's neighbour; edited later, never restamped"
_doc "$HGIT/c[1].md"      2.0.0 2026-01-09 "a glob in the name; edited later, never restamped"
_doc "$HGIT/c1.md"        2.0.0 2026-01-09 "the glob's neighbour; restamped forward later"
_doc "$HGIT/b*.md"        2.0.0 2026-01-10 "a star in the name; edited later, never restamped"
_doc "$HGIT/bx.md"        2.0.0 2026-01-09 "the star's neighbour; restamped forward later"
_doc "$HGIT/d[1].md"      2.0.0 2026-01-10 "a glob in the name; clean beside a dirty neighbour"
_doc "$HGIT/d1.md"        2.0.0 2026-01-10 "the glob's neighbour; made dirty later"
printf 'restamped.md -diff\n' > "$HGIT/.gitattributes"
_doc "$HGIT/café.md"      2.0.0 2026-01-09 "a name git would print as caf\\303\\251.md"
printf '<!-- Version: 2.0.0 -->\n\n# born without a stamp\n' > "$HGIT/late.md"
_doc "$HGIT/rebased.md"   2.0.0 2026-01-10 "edited on its stamp day, committed ten days later"
_doc "$HGIT/future.md"    2.0.0 2999-01-01 "a year nobody has reached"
_doc "$HGIT/bad.md"       2.0.0 2026-00-99 "the shape of a date and not one; edited later so an anchor would call it behind"
_doc "$HGIT/fence.md"     2.0.0 2026-01-10 "quotes the header format at column 0 in a fenced example"
# Past the header window: MAUDE_HEADER_LINES lines of body first, or the example IS header.
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'body line %s\n' "$_i" >> "$HGIT/fence.md"; done
printf '```\n<!-- Revised: 2026-01-01 -->\n```\n' >> "$HGIT/fence.md"
_git_commit_on "$HGIT" 2026-01-10 "first"
# The second commit edits two files WITHOUT touching their stamps: one stamp is now behind
# its change, the other was already past it. It also gives the shallow clone below a
# boundary that is NOT the commit that last changed even.md.
printf 'an edit\n' >> "$HGIT/behind.md"
printf 'an edit\n' >> "$HGIT/ahead.md"
printf 'an edit\n' >> "$HGIT/movedlie.md"
# The body line carries a date-shaped mention that moves FORWARD, the exact shape an
# unanchored restamp regex would take for a restamp. Only the header line counts.
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2026-01-10 -->\n\n# edited later; the edit only mentions the word\nnote: Revised: 2026-01-11 is the new convention\n- the Revised: header is mandatory\nx+<!-- Revised: 2026-01-11 -->\n' > "$HGIT/mention.md"
printf 'an edit\n' >> "$HGIT/naïve.md"
printf 'an edit\n' >> "$HGIT/bad.md"
# The commit changes ONLY the fenced example, forward: the shape of a restamp, in the body.
sed 's/^<!-- Revised: 2026-01-01 -->$/<!-- Revised: 2026-01-05 -->/' "$HGIT/fence.md" > "$HGIT/fence.md.new" && mv "$HGIT/fence.md.new" "$HGIT/fence.md"
printf 'an edit\n' >> "$HGIT/a1.md"
printf 'an edit\n' >> "$HGIT/c[1].md"
printf 'an edit\n' >> "$HGIT/b*.md"
_doc "$HGIT/a[1].md"      2.0.0 2026-01-12 "a glob in the name; restamped forward later, again"
_doc "$HGIT/c1.md"        2.0.0 2026-01-12 "the glob's neighbour; restamped forward later, again"
_doc "$HGIT/bx.md"        2.0.0 2026-01-12 "the star's neighbour; restamped forward later, again"
_doc "$HGIT/backward.md"  2.0.0 2026-01-01 "edited later; the stamp moved BACKWARDS, and the body changed"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2026-01-10 --> \n\n# edited later; the stamp line changed by a space, and the body changed\n' > "$HGIT/space.md"
_doc "$HGIT/later.md"     2.0.0 2026-01-12 "touched later"
_git_commit_on "$HGIT" 2026-01-12 "second"
# The third is dated ten days after the stamp it writes: the shape of a squash merge, one
# re-dated commit carrying a branch's restamp. It also moves a file without changing it.
_doc "$HGIT/restamped.md" 2.0.0 2026-01-12 "edited and restamped in one re-dated commit, again"
_doc "$HGIT/rs-old.md"    2.0.0 2026-01-12 "restamped forward under this name, then renamed, again"
git -C "$HGIT" mv moved.md renamed.md
git -C "$HGIT" mv movedlie.md renamedlie.md
git -C "$HGIT" mv me-old.md me-new.md
printf 'an edit\n' >> "$HGIT/me-new.md"
# A small edit plus the restamp, so git calls it a rename with a similarity, not D+A: a
# rewrite below 50% is an add and would be taken at its word for the wrong reason.
git -C "$HGIT" mv mr-old.md mr-new.md
sed 's/^<!-- Revised: 2026-01-09 -->/<!-- Revised: 2026-01-12 -->/' "$HGIT/mr-new.md" > "$HGIT/mr-new.md.new" && mv "$HGIT/mr-new.md.new" "$HGIT/mr-new.md"
printf 'an edit\n' >> "$HGIT/mr-new.md"
_doc "$HGIT/café.md"      1.0.0 2026-01-12 "a name git would print as caf\\303\\251.md, restamped; version mismatched so the walk names it"
printf '<!-- Version: 2.0.0 -->\n<!-- Revised: 2020-01-01 -->\n\n# born without a stamp, given an ancient one later\n' > "$HGIT/late.md"
_git_commit_on "$HGIT" 2026-01-20 "third"
# The fourth is a rebase: authored on the stamp day, committed ten days later.
printf 'an edit\n' >> "$HGIT/rebased.md"
git -C "$HGIT" mv rs-old.md rs-new.md
_git_commit_on "$HGIT" 2026-01-10 "fourth" 2026-01-20
# An ignored file with an ancient stamp, written after the commits so it is never in one.
_doc "$HGIT/ignored.md"   2.0.0 2020-01-01 "not this tree's document"
OUT_G="$(TZ=UTC bash "$VERIFY" "$HGIT" 2>&1)"; RC_G=$?
cd "$MAUDE_ROOT" || exit 1

test_start "the planted fixture was actually read"
assert_contains "$OUT_G" "even.md says Version:" "a different check names the file, so it exists and was walked"

test_start "a stamp ON the day of its last change is not a finding"
assert_not_contains "$OUT_G" "even.md Revised:" "the file says 01-10 and last changed 01-10"

test_start "a stamp BEHIND a later edit is a finding that names both dates"
assert_contains "$OUT_G" "behind.md Revised: 2026-01-10 but last changed 2026-01-12 — the stamp is behind the file" "the lie and the truth, side by side"

test_start "a stamp already PAST a later edit is not a finding"
assert_not_contains "$OUT_G" "ahead.md Revised:" "01-13 covers a change on 01-12"

test_start "a commit that restamps the file it changes is honest whatever its date"
assert_not_contains "$OUT_G" "restamped.md Revised:" "the squash-merge shape: stamp 01-12 in a commit dated 01-20"

# The first cut of this fixture ran `git mv -q`, which does not exist; the move never
# happened and the assertion below could not fail (lens round 2). The file is proven first.
test_start "the rename fixture really renamed"
assert_eq "$([ -f "$HGIT/renamed.md" ] && [ ! -f "$HGIT/moved.md" ] && echo ok)" "ok" "moved.md is now renamed.md"

test_start "a renamed file keeps its stamp"
assert_not_contains "$OUT_G" "renamed.md Revised:" "a move is not a revision"

# The restamp happened under the OLD name; `git show` has to be asked about the path the
# file had at that commit, or the diff comes back empty and the honest file is named.
test_start "a forward restamp under a file's old name still counts after the rename"
assert_not_contains "$OUT_G" "rs-new.md Revised:" "the diff is read at the historical path"

test_start "a rename does not launder a stamp left behind by an earlier edit"
assert_contains "$OUT_G" "renamedlie.md Revised: 2026-01-10 but last changed 2026-01-12" "the anchor follows the rename back to the edit"

test_start "an edit that only MENTIONS the word is not a restamp"
assert_contains "$OUT_G" "mention.md Revised: 2026-01-10 but last changed 2026-01-12" "a body line, a bullet, a context line: none is the header"

test_start "a stamp moved BACKWARDS is not a restamp"
assert_contains "$OUT_G" "backward.md Revised: 2026-01-01 but last changed 2026-01-12" "forward or nothing"

test_start "a whitespace change to the stamp line is not a restamp"
assert_contains "$OUT_G" "space.md Revised: 2026-01-10 but last changed 2026-01-12" "same date, same lie"

# By choice, and named as one: the add commit carries whatever the writer wrote, and a
# squash merge re-dates it to the merge day, so a date test on adds would red every new
# doc that came in on a branch. The copied header is caught while the file is untracked.
test_start "a move that also edits is a revision, not an add"
assert_contains "$OUT_G" "me-new.md Revised: 2026-01-10 but last changed 2026-01-20" "git mv plus an edit in one commit does not launder the stamp"

test_start "the non-ASCII fixture was actually read"
assert_contains "$OUT_G" "café.md says Version:" "a different check names it, so it exists and was walked"

test_start "a non-ASCII name is asked about as itself"
assert_not_contains "$OUT_G" "café.md Revised:" "restamped forward under a name git quotes by default"

test_start "and a lying non-ASCII name is still named (the control for the line above)"
assert_contains "$OUT_G" "naïve.md Revised: 2026-01-10 but last changed 2026-01-12" "non-ASCII names are read, not skipped"

test_start "the move-with-edit fixture really is a rename to git"
assert_eq "$(git -C "$HGIT" log -1 --follow --format= --name-status -- mr-new.md | cut -c1)" "R" "R<100, not D+A"

test_start "a move that edits AND restamps forward in one commit is honest"
assert_not_contains "$OUT_G" "mr-new.md Revised:" "both paths of the move are asked about"

# A `[` in a name is a glob to git: `a[1].md` matched its neighbour a1.md too, whose diff
# came first, and its stamp lines were read as this file's (lens round 4): a false GREEN
# when the neighbour restamped and this file lied, a false RED the other way round.
test_start "a glob-named lie does not borrow its neighbour's restamp"
assert_contains "$OUT_G" "c[1].md Revised: 2026-01-09 but last changed 2026-01-12" "the false GREEN direction"

test_start "and a glob-named honest file is not blamed for its neighbour's lie"
assert_not_contains "$OUT_G" "a[1].md Revised:" "the false RED direction"

test_start "the neighbours keep their own truths"
assert_contains "$OUT_G" "a1.md Revised: 2026-01-09 but last changed 2026-01-12" "a1 lied"
assert_not_contains "$OUT_G" "c1.md Revised:" "c1 did not"

test_start "a star in the name is a star, not a pattern"
assert_contains "$OUT_G" "b*.md Revised: 2026-01-10 but last changed 2026-01-12" "the lie under the star is named"
assert_not_contains "$OUT_G" "bx.md Revised:" "the honest neighbour is not"

test_start "a file marked -diff in .gitattributes is still read as text"
assert_not_contains "$OUT_G" "restamped.md Revised:" "Binary files differ carries no stamp lines"

test_start "a stamp ADDED late with an ancient date is behind the file"
assert_contains "$OUT_G" "late.md Revised: 2020-01-01 but last changed 2026-01-20" "no old stamp to move forward from"

test_start "a committed new file's stamp is taken at its word"
assert_not_contains "$OUT_G" "copied.md Revised:" "caught untracked, not once committed"

test_start "a rebased commit anchors on its AUTHOR date"
assert_not_contains "$OUT_G" "rebased.md Revised:" "authored 01-10, committed 01-20: the stamp says 01-10"

test_start "a stamp in the future is a finding"
assert_contains "$OUT_G" "future.md Revised: 2999-01-01 is after today" "a date the file cannot have"

test_start "a stamp that is not a date is a finding"
assert_contains "$OUT_G" "bad.md Revised: 2026-00-99 is not a date this clock can place" "the regex admits it; the calendar does not"

test_start "and it is reported once, not anchored as well"
assert_eq "$(printf '%s\n' "$OUT_G" | grep -c 'bad.md Revised:')" "1" "an unplaceable date does not fall through to the date test"

test_start "a fenced example of the header, edited forward, is not a restamp"
assert_contains "$OUT_G" "fence.md Revised: 2026-01-10 but last changed 2026-01-12" "only the header window counts"

test_start "a file touched by a later commit anchors on THAT commit"
assert_not_contains "$OUT_G" "later.md Revised:" "01-12 stamp, 01-12 commit"

test_start "an ignored file is nobody's finding"
assert_not_contains "$OUT_G" "ignored.md" "not tracked, not dirty, not this tree's document"

test_start "exactly twelve stamps in the planted history are behind their files"
assert_eq "$(printf '%s\n' "$OUT_G" | grep -c 'the stamp is behind the file')" "12" "behind, renamedlie, mention, backward, space, me-new, late, naïve, a1, c[1], b*, fence: not the honest twelve"

test_start "and it reaches the exit code"
assert_exit "$RC_G" "1" "a lying stamp must make verify exit non-zero"

# An old git echoes an unknown placeholder back, so `%as` comes out as the text "%as" and
# a string compare against it passes every stamp. A shim git does what that git would.
SHIM="$(_mk_shim_dir)"
REALGIT="$(command -v git)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = log ] && { echo "0000 %%as"; exit 0; }; done\nexec %s "$@"\n' "$REALGIT" > "$SHIM/git"
chmod +x "$SHIM/git"
test_start "the shim git exists"
assert_eq "$([ -x "$SHIM/git" ] && echo ok)" "ok" "a dead shim dir leaves the real git on PATH and the assertion below proving nothing"
OUT_OLD="$(PATH="$SHIM:$PATH" TZ=UTC bash "$VERIFY" "$HGIT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
rm -rf "$SHIM"

test_start "a git that gives no date for the last commit is a finding, not a pass"
assert_contains "$OUT_OLD" "behind.md Revised: 2026-01-10 could not be anchored (git gave no date for its last commit) — NOT checked" "unknown is never a pass"

# The working tree. A file edited after its stamp has not been committed yet, and that is
# exactly when the stamp should be caught: before the commit carries the lie.
printf 'an edit after the stamp\n' >> "$HGIT/even.md"
printf 'an edit\n' >> "$HGIT/d1.md"
_doc "$HGIT/untracked.md" 2.0.0 2020-01-01 "new file, old stamp"
OUT_D="$(TZ=UTC bash "$VERIFY" "$HGIT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "a file modified in the working tree anchors on today"
assert_contains "$OUT_D" "even.md Revised: 2026-01-10 but modified in the working tree $(TZ=UTC date +%Y-%m-%d) — the stamp is behind the file" "dirty means changed now"

test_start "an untracked file with an old stamp is a finding too"
assert_contains "$OUT_D" "untracked.md Revised: 2020-01-01 but modified in the working tree" "a new file did not last change in 2020"

test_start "a clean file beside a dirty one keeps its commit anchor"
assert_not_contains "$OUT_D" "ahead.md Revised:" "one dirty file does not make every file dirty"

# A vendored repository inside the tree: its doc is neither tracked here, nor dirty here,
# nor in this history. Fail toward a finding, and say the true reason (lens round 5).
mkdir -p "$HGIT/nested" && git -C "$HGIT/nested" init -q
_doc "$HGIT/nested/n.md" 2.0.0 2020-01-10 "a doc inside a nested repository"
OUT_N="$(TZ=UTC bash "$VERIFY" "$HGIT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
rm -rf "$HGIT/nested"

test_start "a doc inside a nested repository is a finding that names the reason"
assert_contains "$OUT_N" "nested/n.md Revised: 2020-01-10 could not be anchored (not tracked by this repository: a nested repository or a submodule) — NOT checked" "not a lie about a date git never gave"

test_start "a glob-named clean file is not dirtied by its neighbour"
assert_not_contains "$OUT_D" "d[1].md Revised:" "git status asked literally"
assert_contains "$OUT_D" "d1.md Revised: 2026-01-10 but modified in the working tree" "the neighbour is the dirty one"

# The control for the dirty path: restamp the edited file to today and it goes quiet.
# Without this a mutation that flags EVERY dirty file passes the assertions above.
sed "s/^<!-- Revised: 2026-01-10 -->/<!-- Revised: $(TZ=UTC date +%Y-%m-%d) -->/" "$HGIT/even.md" > "$HGIT/even.md.new" && mv "$HGIT/even.md.new" "$HGIT/even.md"
OUT_D2="$(TZ=UTC bash "$VERIFY" "$HGIT" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "a dirty file restamped to today is not a finding"
assert_not_contains "$OUT_D2" "even.md Revised:" "the stamp now matches the change"

# The shallow clone. Its boundary commit is a root that "adds" every file, so `git log -1`
# on even.md returns the boundary and an honest 01-10 stamp reads as behind. The guard
# must refuse to measure rather than accuse the innocent file. This is the control that
# has to go red FIRST: with the guard deleted, even.md is named below.
git -C "$HGIT" -c core.hooksPath=/dev/null checkout -q -- even.md
rm -f "$HGIT/untracked.md" "$HGIT/ignored.md"
HSHALLOW="$(mktemp -d)"
git clone -q --depth 1 "file://$HGIT" "$HSHALLOW/clone" 2>/dev/null
OUT_S="$(TZ=UTC bash "$VERIFY" "$HSHALLOW/clone" 2>&1)"; RC_S=$?
cd "$MAUDE_ROOT" || exit 1

test_start "the shallow fixture is really shallow"
assert_eq "$(git -C "$HSHALLOW/clone" rev-parse --is-shallow-repository)" "true" "otherwise the next three assertions test nothing"

test_start "a shallow clone is a finding that says NOT checked"
assert_contains "$OUT_S" "cannot anchor Revised dates on the file history (shallow clone" "the check names why it could not run"

test_start "and it does not accuse the file whose history lies past the boundary"
assert_not_contains "$OUT_S" "even.md Revised:" "an honest stamp is not named for a history the clone cannot see"

test_start "and the refusal is counted as a finding"
# Five, exactly: even.md's and café.md's planted version mismatches, future.md's date,
# bad.md's non-date, and the refusal. A refusal demoted to a printf leaves four and the
# exit code cannot tell.
assert_eq "$(printf '%s\n' "$OUT_S" | grep -cE '^5 findings$')" "1" "two mismatches + future + non-date + refusal"
assert_exit "$RC_S" "1" "unexamined stamps must not pass"

# A git older than 2.15 does not know the flag and echoes it back, which is not "true";
# the clone is then read as deep and even.md accused. The marker file every shallow clone
# carries is the second spelling. A shim git does what that git would.
SHIM2="$(_mk_shim_dir)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = --is-shallow-repository ] && { touch %s/used; echo "--is-shallow-repository"; exit 0; }; done\nexec %s "$@"\n' "$SHIM2" "$REALGIT" > "$SHIM2/git"
chmod +x "$SHIM2/git"
test_start "the second shim git exists"
assert_eq "$([ -x "$SHIM2/git" ] && echo ok)" "ok" "a dead shim dir leaves the real git on PATH and the assertion below proving nothing"
OUT_S2="$(PATH="$SHIM2:$PATH" TZ=UTC bash "$VERIFY" "$HSHALLOW/clone" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
SHIM2_USED="$([ -f "$SHIM2/used" ] && echo yes)"
rm -rf "$SHIM2"

# Present is not used: with the interception deleted the real clone is shallow by the flag
# and the assertion below passes for the wrong reason (lens round 3).
test_start "and the shim really answered the shallow question"
assert_eq "$SHIM2_USED" "yes" "the interception ran"

test_start "a git that echoes the shallow flag back is still caught by the marker file"
assert_contains "$OUT_S2" "cannot anchor Revised dates on the file history (shallow clone" "two spellings of shallow, either one refuses"
rm -rf "$HSHALLOW" "$HGIT"

# A project that is a SUBDIRECTORY of its repo: git prints history paths from the repo
# root, and `git show` run from the subdirectory must be asked from the top or the honest
# restamp comes back as an empty diff and is named (lens round 3).
HSUB="$(mktemp -d)"
mkdir -p "$HSUB/sub/.claude-plugin"
_git_fixture "$HSUB"
printf '{"name":"x","version":"2.0.0"}\n' > "$HSUB/sub/.claude-plugin/plugin.json"
_doc "$HSUB/sub/ok.md"   2.0.0 2026-01-09 "restamped forward from a subdirectory"
_doc "$HSUB/sub/lie.md"  2.0.0 2026-01-09 "edited from a subdirectory, never restamped"
_git_commit_on "$HSUB" 2026-01-09 "first"
_doc "$HSUB/sub/ok.md"   2.0.0 2026-01-12 "restamped forward from a subdirectory, again"
printf 'an edit\n' >> "$HSUB/sub/lie.md"
_git_commit_on "$HSUB" 2026-01-20 "second"
OUT_SUB="$(TZ=UTC bash "$VERIFY" "$HSUB/sub" 2>&1)"
cd "$MAUDE_ROOT" || exit 1
rm -rf "$HSUB"

test_start "a subdirectory project reads its history at all"
assert_contains "$OUT_SUB" "lie.md Revised: 2026-01-09 but last changed 2026-01-20" "the control: a real lie is still named from a subdirectory"

test_start "a forward restamp is honest when the project is a subdirectory of its repo"
assert_not_contains "$OUT_SUB" "ok.md Revised:" "the diff is asked for from the repo top"

# ── The seam's own behaviour, on a planted history so the pin is the ONLY finding. ──
HSEAM="$(mktemp -d)"
mkdir -p "$HSEAM/.claude-plugin"
_git_fixture "$HSEAM"
printf '{"name":"x","version":"2.0.0"}\n' > "$HSEAM/.claude-plugin/plugin.json"
_doc "$HSEAM/near.md" 2.0.0 2026-03-19 "one day before the pin"
# A writer east of the checker's clock has already reached tomorrow. One day ahead is
# theirs; two is a typo.
_doc "$HSEAM/skew.md" 2.0.0 2026-03-21 "one day past the pin"
_git_commit_on "$HSEAM" 2026-03-19 "stamped and committed the same day"

OUT_PIN="$(TZ=UTC MAUDE_VERIFY_TODAY=2026-03-20 bash "$VERIFY" "$HSEAM" 2>&1)"; RC_PIN=$?
OUT_PIN2="$(TZ=UTC MAUDE_VERIFY_TODAY=2026-03-17 bash "$VERIFY" "$HSEAM" 2>&1)"
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
# skew.md is one day past the pin and must be inside that count of one.
assert_eq "$(printf '%s\n' "$OUT_PIN" | grep -cE '^1 findings$')" "1" "exactly one finding, the pin itself"

test_start "two days past today is after today"
assert_contains "$OUT_PIN2" "near.md Revised: 2026-03-19 is after today (2026-03-17)" "the allowance is one day, not two"

# An anchor it cannot resolve must SAY so. Without this the dirty-file and future-date
# reads fail for every file and the run prints a clean bill for a check that examined
# nothing. Measured before the guard existed: MAUDE_VERIFY_TODAY=banana turned a stale
# file into 0 findings, exit 0.
OUT_NT="$(TZ=UTC MAUDE_VERIFY_TODAY=banana bash "$VERIFY" "$HSEAM" 2>&1)"; RC_NT=$?
cd "$MAUDE_ROOT" || exit 1

test_start "an unresolvable today is a finding, not a clean bill"
assert_contains "$OUT_NT" "cannot resolve today's date" "the check says it did not run"

test_start "and it too reaches the exit code"
assert_exit "$RC_NT" "1" "an unresolvable anchor must make verify exit non-zero"

# And an empty value must NOT be one: an ambient empty used to make this exit 2, which took
# make verify and ship.sh's release gate down with it. The seam-less run of the same clean
# fixture is the reference: empty must be indistinguishable from unset, byte for byte.
OUT_EMPTY="$(TZ=UTC MAUDE_VERIFY_TODAY="" bash "$VERIFY" "$HSEAM" 2>&1)"; RC_EMPTY=$?
OUT_UNSET="$(TZ=UTC bash "$VERIFY" "$HSEAM" 2>&1)"
cd "$MAUDE_ROOT" || exit 1

test_start "an empty seam falls back to today rather than blocking the gate"
assert_not_contains "$OUT_EMPTY" "cannot resolve today's date" "empty means use today"

test_start "and an empty seam leaves the gate passable"
assert_exit "$RC_EMPTY" "0" "empty must never block a release"

# The first version of this asserted the output lacked the literal "today is pinned", which
# a mutation that pins an empty seam under ANY other wording walks straight past. "Empty
# means today" is exactly "empty is indistinguishable from unset", so compare the two runs.
test_start "an empty seam is indistinguishable from an unset one"
assert_eq "$OUT_EMPTY" "$OUT_UNSET" "empty must behave exactly as unset, byte for byte"

# The equality above runs on a clean tree, and Check 4 prints nothing for a clean tree: a
# scan that ran and a scan that never ran leave the same bytes. So a mutation that switched
# Check 4 off for an empty-but-set seam passed every assertion in this file and the whole
# gate (sixteenth pass). A lying stamp makes the scan observable: created with an ancient
# stamp, then edited without one.
_doc "$HSEAM/stale.md" 2.0.0 2020-01-01 "behind by any history"
_git_commit_on "$HSEAM" 2026-03-19 "a stamp six years behind its commit"
printf 'an edit\n' >> "$HSEAM/stale.md"
_git_commit_on "$HSEAM" 2026-03-19 "edited, not restamped"
OUT_EMPTY_STALE="$(TZ=UTC MAUDE_VERIFY_TODAY="" bash "$VERIFY" "$HSEAM" 2>&1)"; RC_EMPTY_STALE=$?
cd "$MAUDE_ROOT" || exit 1

test_start "an empty seam still examines the files"
assert_contains "$OUT_EMPTY_STALE" "stale.md Revised: 2020-01-01 but last changed 2026-03-19" "the scan ran on the empty path"

test_start "and its finding reaches the exit code"
assert_exit "$RC_EMPTY_STALE" "1" "a lying stamp under an empty seam must still block"
rm -rf "$HSEAM"

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
