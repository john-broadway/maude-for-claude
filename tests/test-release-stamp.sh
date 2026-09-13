#!/usr/bin/env bash
# Tests for the release stamper (scripts/lib-stamp.sh) — the version and date headers
# release.sh propagates.
#
# WHY THIS FILE EXISTS (2026-09-04, found by the v0.31.0 release-diff lens):
# release.sh stamped with an unanchored `sed s|...|...|`, which rewrites EVERY matching
# line in a file, not the header. maude-verify.sh reads the header with `grep -m1`, the
# FIRST match only. So the writer touched every occurrence and the checker looked at one,
# and the two blind spots cancelled: a body line rewritten to the current version was
# never reported by anything. It ran for 13 releases and left
# docs/superpowers/plans/2026-06-30-gate-bypass-hardening.md self-contradictory — a step
# headed "Bump version 0.13.1 -> 0.13.2" whose own checklist said to write 0.31.0.
#
# The fix is not a line window. It is that the writer stamps THE SAME OCCURRENCE THE
# CHECKER READS: the first. Writer and checker cannot disagree about their subject if
# they are pointed at the same one by construction.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

. "$DIR/../scripts/lib-stamp.sh"

VER_RE='<!-- Version: [0-9][0-9A-Za-z.-]* -->'
REV_RE='<!-- Revised: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][^>]*-->'
BQ_RE='> \*\*Version:\*\* [0-9][0-9A-Za-z.-]*'

# A document shaped like the one that was corrupted: a real header on line 1, and further
# down a HISTORICAL quotation of a header that must never move.
fixture() {
  cat > "$1" <<'EOF'
<!-- Version: 0.20.0 -->
<!-- Revised: 2026-01-01 -->

# A plan from an older cycle

- [ ] **Step 1: Bump version 0.13.1 -> 0.13.2** on all four surfaces:
  - `CHANGELOG.md` header comment `<!-- Version: 0.13.2 -->` and `<!-- Revised: 2026-06-30 -->`
  - `.claude/CLAUDE.md` `> **Version:** 0.13.2`
EOF
}

BQ_FIXTURE() {
  cat > "$1" <<'EOF'
# Project notes

> **Version:** 0.20.0. Surfaces that must agree.

Later, quoting the old cycle: `> **Version:** 0.13.2` stays as written.
EOF
}

# ── the header IS stamped ───────────────────────────────────────────────────
F="$TEST_TMP/plan.md"

test_start "the version header on line 1 is stamped"
fixture "$F"
stamp_header "$F" "$VER_RE" "<!-- Version: 0.99.0 -->"
assert_eq "$(sed -n '1p' "$F")" "<!-- Version: 0.99.0 -->" "line 1 moved to the new version"

# ── THE DEFECT: a body occurrence must NOT move ─────────────────────────────
test_start "a version quoted in the BODY is left alone"
assert_contains "$(sed -n '7p' "$F")" "0.13.2" "the historical line still says 0.13.2"

test_start "and the body line was not rewritten to the new version"
assert_not_contains "$(sed -n '7p' "$F")" "0.99.0" "the stamper did not reach into the body"

test_start "the revised header on line 2 is stamped"
fixture "$F"
stamp_header "$F" "$REV_RE" "<!-- Revised: 2026-09-04 -->"
assert_eq "$(sed -n '2p' "$F")" "<!-- Revised: 2026-09-04 -->" "line 2 moved to today"

test_start "a revised date quoted in the BODY is left alone"
assert_contains "$(sed -n '7p' "$F")" "2026-06-30" "the historical date still says 2026-06-30"

# ── the blockquote form, which lives on line 3 in .claude/CLAUDE.md ─────────
G="$TEST_TMP/notes.md"

test_start "the blockquote version header is stamped wherever it first appears"
BQ_FIXTURE "$G"
stamp_header "$G" "$BQ_RE" "> **Version:** 0.99.0"
assert_contains "$(sed -n '3p' "$G")" "0.99.0" "the first blockquote moved"

test_start "a blockquote version quoted LATER is left alone"
assert_contains "$(sed -n '5p' "$G")" "0.13.2" "the quoted one still says 0.13.2"

# ── THE SHAPE THAT WAS ACTUALLY CORRUPTED ───────────────────────────────────
# docs/superpowers/plans/2026-06-30-gate-bypass-hardening.md has NO version header of
# either form. Its only matches are two lines of prose at 655-656 quoting an older
# cycle's headers. "First match" alone would still have rewritten them, because the
# first match in that file IS the prose. Only the header-block bound saves it, and this
# is the case the earlier tests all missed: every one of them had a header on line 1.
test_start "a file whose ONLY match is in the body is left byte-identical"
B="$TEST_TMP/bodyonly.md"
{ printf '# A plan from an older cycle\n\n> **For agentic workers:** read this first.\n\n'
  for i in $(seq 1 20); do printf 'body line %s\n' "$i"; done
  printf -- '  - `CHANGELOG.md` header comment `<!-- Version: 0.13.2 -->`\n'
  printf -- '  - `.claude/CLAUDE.md` `> **Version:** 0.13.2`\n'; } > "$B"
BODY_BEFORE="$(cksum < "$B")"
stamp_header "$B" "$VER_RE" "<!-- Version: 0.99.0 -->"
stamp_header "$B" "$BQ_RE" "> **Version:** 0.99.0"
assert_eq "$(cksum < "$B")" "$BODY_BEFORE" "a document with no header is not stamped at all"

test_start "and its quoted historical versions survive verbatim"
assert_contains "$(cat "$B")" '<!-- Version: 0.13.2 -->' "the quoted comment header is intact"
assert_contains "$(cat "$B")" '> **Version:** 0.13.2' "the quoted blockquote header is intact"

# ── it must also not damage what it does not match ──────────────────────────
test_start "a file with no matching header is left byte-identical"
H="$TEST_TMP/plain.md"
printf '# nothing to stamp\n\n- **Version:** 0.20.0 in a list item, not a header\n' > "$H"
BEFORE="$(cksum < "$H")"
stamp_header "$H" "$VER_RE" "<!-- Version: 0.99.0 -->"
assert_eq "$(cksum < "$H")" "$BEFORE" "untouched"

# The docstring promises the replacement is literal. awk's sub() would expand `&` into
# the matched text, so without this the promise is untested and a future edit to sub()
# would pass. No current caller passes an `&`, which is exactly why it needs a test.
test_start "an ampersand in the replacement is literal, not the matched text"
fixture "$F"
stamp_header "$F" "$VER_RE" "<!-- Version: 1.0.0 & later -->"
assert_eq "$(sed -n '1p' "$F")" "<!-- Version: 1.0.0 & later -->" "& written as itself"

test_start "the rest of the document survives the stamp"
fixture "$F"
stamp_header "$F" "$VER_RE" "<!-- Version: 0.99.0 -->"
assert_eq "$(wc -l < "$F")" "8" "no lines added or lost"
assert_contains "$(cat "$F")" "A plan from an older cycle" "body prose intact"

# ── STAMPING MUST NOT CHANGE ANYTHING BUT THE HEADER ───────────────────────
# stamp_header wrote a mktemp and mv'd it over the target, so every stamped file inherited
# mktemp's 0600 and a release quietly re-permissioned every markdown file it touched.
# Writing the finished bytes back INTO the original keeps its mode, and follows a symlink
# to its target instead of replacing the link with a regular file.
# ── A FAILED STAMP MUST LEAVE THE ORIGINAL ALONE ───────────────────────────
# The previous attempt at mode preservation replaced `mv` with `cat -- "$t" > "$f"`. The
# shell opens the target with O_TRUNC BEFORE the command runs, so a failure part-way
# through the copy left a truncated file and the original was unrecoverable. It traded a
# mode-loss bug for a data-loss bug, and the comment beside it claimed the opposite.
# `mv` is the atomic operation; the mode is carried by chmod'ing the temporary first.
test_start "a failure while building the replacement leaves the original untouched"
A="$TEST_TMP/atomic.md"
printf '<!-- Version: 0.1.0 -->\nline A\nline B\nline C\n' > "$A"
BEFORE_A="$(cksum < "$A")"
(
  # An awk that emits a partial result and then fails, exactly like a disk-full or quota
  # error part-way through writing the replacement.
  awk() { printf '<!-- Version: 9.9.9 -->\nline A\n'; return 1; }
  stamp_header "$A" "$VER_RE" "<!-- Version: 9.9.9 -->"
)
assert_eq "$(cksum < "$A")" "$BEFORE_A" "the original survived a failed stamp"

test_start "and the original still has all of its lines"
assert_contains "$(cat "$A")" "line C" "nothing was truncated away"

# The discriminating property, and it does not name the implementation: an ATOMIC replace
# swaps a new file into place, so the inode changes. An in-place truncate-and-rewrite keeps
# the same inode, and that is precisely the window in which a failure destroys the original.
# Shadowing `cat` would only pin the absence of one past mistake; this pins the guarantee.
test_start "a stamp REPLACES the file rather than rewriting it in place"
I="$TEST_TMP/inode.md"
printf '<!-- Version: 0.1.0 -->\nbody\n' > "$I"
INO_BEFORE="$(stat -c %i "$I")"
stamp_header "$I" "$VER_RE" "<!-- Version: 0.9.9 -->"
INO_AFTER="$(stat -c %i "$I")"
assert_eq "$([ "$INO_BEFORE" != "$INO_AFTER" ] && echo replaced || echo rewritten-in-place)" \
  "replaced" "an atomic rename, so no window exists where the original is half-gone"

test_start "and the replacement carries the new header"
assert_eq "$(head -1 "$I")" "<!-- Version: 0.9.9 -->" "content is right"

# The temp must be created BESIDE the target so `mv` is a same-directory rename. On a box
# where the target and /tmp share a filesystem the inode test above cannot tell the two
# apart, so observe the call instead: shadow mktemp and check the template it was handed.
# That is not a source-text tautology, it is the argument the code actually passes.
test_start "the temporary is created beside the target, so the replace cannot degrade to a copy"
P="$TEST_TMP/place.md"
printf '<!-- Version: 0.1.0 -->\nbody\n' > "$P"
SEEN="$(
  mktemp() { printf '%s\n' "$1" >&2; command mktemp "$@"; }
  stamp_header "$P" "$VER_RE" "<!-- Version: 0.9.9 -->" 2>&1 >/dev/null
)"
assert_eq "$(dirname -- "$SEEN")" "$TEST_TMP" "mktemp was pointed at the target's own directory"

test_start "a successful stamp leaves no temporary file beside the target"
stamp_header "$A" "$VER_RE" "<!-- Version: 0.9.9 -->"
assert_eq "$(find "$TEST_TMP" -maxdepth 1 -name '.stamp.*' | wc -l)" "0" "temp cleaned up"

test_start "stamping preserves the file's mode"
M="$TEST_TMP/mode.md"
printf '<!-- Version: 0.1.0 -->\nx\n' > "$M"; chmod 644 "$M"
stamp_header "$M" "$VER_RE" "<!-- Version: 0.9.9 -->"
assert_eq "$(stat -c %a "$M")" "644" "mode unchanged by the stamp"

test_start "stamping a symlink writes THROUGH it, leaving the link a link"
LT="$TEST_TMP/target.md"; LL="$TEST_TMP/link.md"
printf '<!-- Version: 0.1.0 -->\ny\n' > "$LT"; ln -sf "$LT" "$LL"
stamp_header "$LL" "$VER_RE" "<!-- Version: 0.9.9 -->"
assert_eq "$([ -L "$LL" ] && echo link || echo regular)" "link" "the symlink survived"

test_start "and the symlink's TARGET carries the new header"
assert_eq "$(head -1 "$LT")" "<!-- Version: 0.9.9 -->" "the target was stamped"

# ── A BOUND THAT DOES NOT REFUSE IS NOT A BOUND ────────────────────────────
# The symlink loop stops after 32 hops. It then carried on regardless, and because the
# kernel resolves the rest of the chain the `-f` test still passed, so it stamped whatever
# intermediate link it happened to be holding: the link was destroyed and became a regular
# file, the real target was never touched, and it returned 0. Reproduced with a 35-link
# chain, 2026-09-04. Running out of hops means the target is unknown, and unknown must
# refuse.
test_start "a symlink chain longer than the hop bound is REFUSED, not stamped blindly"
CH="$TEST_TMP/chain"; mkdir -p "$CH"
printf '<!-- Version: 0.1.0 -->\nTHE REAL CONTENT\n' > "$CH/target.md"
prev=target.md
i=1; while [ "$i" -le 35 ]; do ( cd "$CH" && ln -s "$prev" "link$i.md" ); prev="link$i.md"; i=$((i+1)); done
stamp_header "$CH/link35.md" "$VER_RE" "<!-- Version: 9.9.9 -->"
assert_eq "$?" "1" "refused rather than stamping a link it could not resolve"

test_start "and no link in the chain was turned into a regular file"
assert_eq "$(find "$CH" -maxdepth 1 -name 'link*.md' -type f | wc -l)" "0" "every link is still a link"

test_start "and the true target was left alone"
assert_eq "$(head -1 "$CH/target.md")" "<!-- Version: 0.1.0 -->" "target untouched"

# The cleanup branch after a failed replace is currently correct and NOTHING would notice
# if it stopped being. That is an untested branch in the one code path whose failure mode
# is losing a file, so it gets a test that fails when the cleanup is removed.
test_start "a failed replace leaves the original intact"
MVF="$TEST_TMP/mvfail.md"
printf '<!-- Version: 0.1.0 -->\nbody line\n' > "$MVF"
MV_BEFORE="$(cksum < "$MVF")"
( mv() { return 1; }
  stamp_header "$MVF" "$VER_RE" "<!-- Version: 9.9.9 -->" )
assert_eq "$(cksum < "$MVF")" "$MV_BEFORE" "original untouched when the rename fails"

test_start "and a failed replace leaves no temporary behind"
assert_eq "$(find "$TEST_TMP" -maxdepth 1 -name '.stamp.*' | wc -l)" "0" "temp cleaned up on the failure path"

# ── A LOOP THAT IGNORES ITS RETURN CODE IS A SILENT FAILURE ────────────────
# release.sh called stamp_header in three loops and never looked at what it returned, so a
# file that could not be stamped simply was not, and the release said nothing.
test_start "release.sh FAILS when a file cannot be stamped"
RS_BAD="$TEST_TMP/relbad"
mkdir -p "$RS_BAD/scripts" "$RS_BAD/.claude-plugin"
cp "$DIR/../scripts/release.sh" "$RS_BAD/scripts/"
printf '{"name":"x","version":"0.1.0"}\n' > "$RS_BAD/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"x","version":"0.1.0"}]}\n' > "$RS_BAD/.claude-plugin/marketplace.json"
printf '<!-- Version: 0.1.0 -->\n# doc\n' > "$RS_BAD/doc.md"
# A stamper that always refuses. Deterministic, and it does not depend on this test running
# as an unprivileged user: root ignores a read-only directory, so permissions cannot be the
# lever here.
printf '%s\n' 'stamp_header() { return 1; }' > "$RS_BAD/scripts/lib-stamp.sh"
OUT_B="$(cd "$RS_BAD" && bash scripts/release.sh 0.9.9 2>&1)"; RC_B=$?
assert_eq "$(printf '%s' "$OUT_B" | grep -c '== verify ==')" "0" "it must stop, not carry on to the gate"

test_start "and it names the file it could not stamp"
assert_contains "$OUT_B" "doc.md" "the unstamped file is named"

test_start "and it exits non-zero"
assert_eq "$RC_B" "1" "a release that could not stamp is a failed release"

# ── EACH LOOP'S rc CHECK, SEPARATELY ───────────────────────────────────────
# The first version of this covered the rc collection with ONE fixture carrying one header
# form, so removing the check from either of the other two loops left every test green.
# Testing the fix is not the same as testing each site of it. One fixture per loop.
rel_fixture() {  # $1 dir, $2 filename, $3 file body -> a tree whose stamper always refuses
  mkdir -p "$1/scripts" "$1/.claude-plugin"
  cp "$DIR/../scripts/release.sh" "$1/scripts/"
  printf '{"name":"x","version":"0.1.0"}\n' > "$1/.claude-plugin/plugin.json"
  printf '{"plugins":[{"name":"x","version":"0.1.0"}]}\n' > "$1/.claude-plugin/marketplace.json"
  printf '%s' "$3" > "$1/$2"
  printf '%s\n' 'stamp_header() { return 1; }' > "$1/scripts/lib-stamp.sh"
}

test_start "loop 2 (comment Version) reports a stamp failure"
L2="$TEST_TMP/loop2"; rel_fixture "$L2" "only-comment.md" '<!-- Version: 0.1.0 -->
# doc
'
OUT_L2="$(cd "$L2" && bash scripts/release.sh 0.9.9 2>&1)"
assert_contains "$OUT_L2" "only-comment.md" "the comment-form file is named"

test_start "loop 2b (blockquote Version) reports a stamp failure"
L2B="$TEST_TMP/loop2b"; rel_fixture "$L2B" "only-bq.md" '# Title

> **Version:** 0.1.0
'
OUT_L2B="$(cd "$L2B" && bash scripts/release.sh 0.9.9 2>&1)"
assert_contains "$OUT_L2B" "only-bq.md" "the blockquote-form file is named"

test_start "loop 3 (Revised date) reports a stamp failure"
L3="$TEST_TMP/loop3"; rel_fixture "$L3" "only-revised.md" '<!-- Revised: 2020-01-01 -->
# doc
'
OUT_L3="$(cd "$L3" && bash scripts/release.sh 0.9.9 2>&1)"
assert_contains "$OUT_L3" "only-revised.md" "the revised-date file is named"

# ── A RELEASE MUST NOT REACH INTO SIBLING WORKTREES ────────────────────────
# The selectors excluded .git, .maude and .pytest_cache and nothing else, so a release run
# in this repo today would have stamped 114 markdown files inside seven agent worktrees
# under .claude/worktrees/. Measured with /usr/bin/grep on 2026-09-04; the interactive
# shell's `grep` is ugrep, which skips those directories and reported zero, so the hand
# check saw a tree the script never would.
#
# `worktrees` and not `.claude`: .claude/CLAUDE.md carries the blockquote header and is
# exactly the file loop 2b exists to stamp.
test_start "a release does not stamp inside a worktrees/ directory"
WT="$TEST_TMP/wtree"
mkdir -p "$WT/scripts" "$WT/.claude-plugin" "$WT/.claude/worktrees/agent-x"
cp "$DIR/../scripts/release.sh" "$DIR/../scripts/lib-stamp.sh" "$WT/scripts/"
printf '{"name":"x","version":"0.1.0"}\n' > "$WT/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"x","version":"0.1.0"}]}\n' > "$WT/.claude-plugin/marketplace.json"
printf '<!-- Version: 0.1.0 -->\n# mine\n' > "$WT/doc.md"
printf '<!-- Version: 0.1.0 -->\n# a sibling branch checkout\n' > "$WT/.claude/worktrees/agent-x/doc.md"
# One file per header form, so each loop's exclusion is pinned separately. A single
# comment-form file left loops 2b and 3 unpinned: removing either exclusion kept the suite
# green, which is the same one-fixture-one-form gap this file already fixed for the rc
# checks. All three are placed before the single release run below, so every assertion
# reads the same run.
printf '# T\n\n> **Version:** 0.1.0\n' > "$WT/.claude/worktrees/agent-x/bq.md"
printf '<!-- Revised: 2020-01-01 -->\n# r\n' > "$WT/.claude/worktrees/agent-x/rev.md"
( cd "$WT" && bash scripts/release.sh 0.9.9 >/dev/null 2>&1 )
assert_eq "$(head -1 "$WT/.claude/worktrees/agent-x/doc.md")" "<!-- Version: 0.1.0 -->" \
  "the worktree file was left alone"

# ONE ASSERTION PER HEADER FORM. The first version of this test put a single comment-form
# file in the worktree, so removing the exclusion from loop 2b or loop 3 individually left
# the suite green: the same one-fixture-one-form gap this commit's own message described
# fixing for the rc checks, reproduced in the test written to prove the fix.
test_start "…nor a blockquote-form file inside a worktree (loop 2b)"
assert_contains "$(cat "$WT/.claude/worktrees/agent-x/bq.md")" "0.1.0" "worktree blockquote untouched"

test_start "…nor a Revised-date file inside a worktree (loop 3)"
assert_contains "$(cat "$WT/.claude/worktrees/agent-x/rev.md")" "2020-01-01" "worktree date untouched"

test_start "…while the repo's own file IS stamped (no over-exclusion)"
assert_eq "$(head -1 "$WT/doc.md")" "<!-- Version: 0.9.9 -->" "the real tree still gets stamped"

test_start "and .claude/CLAUDE.md itself is still reachable (worktrees, not .claude)"
mkdir -p "$WT/.claude"
printf '# CLAUDE.md\n\n> **Version:** 0.1.0\n' > "$WT/.claude/CLAUDE.md"
( cd "$WT" && bash scripts/release.sh 0.9.8 >/dev/null 2>&1 )
assert_contains "$(cat "$WT/.claude/CLAUDE.md")" "0.9.8" "the project-local CLAUDE.md is stamped"

# ── THE DEPENDENCY MUST BE LOUD WHEN IT IS ABSENT ──────────────────────────
# release.sh sourced lib-stamp.sh with no guard and no `set -e`. With the file missing the
# source failed, the script carried on, every stamp_header call was a command-not-found,
# and the release shipped an UNSTAMPED tree without a word. Silence read as success again.
# Found 2026-09-04 by the lens on the commit that introduced the source.
RS_FIX="$TEST_TMP/relfix"
mkdir -p "$RS_FIX/scripts" "$RS_FIX/.claude-plugin"
cp "$DIR/../scripts/release.sh" "$RS_FIX/scripts/"
printf '{"name":"x","version":"0.1.0"}\n' > "$RS_FIX/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"x","version":"0.1.0"}]}\n' > "$RS_FIX/.claude-plugin/marketplace.json"
printf '<!-- Version: 0.1.0 -->\n# doc\n' > "$RS_FIX/doc.md"

# The assertion has to be sharper than "it failed and said lib-stamp": bash's OWN
# "No such file or directory" contains that string, and a bare fixture fails the gates
# anyway, so the obvious version of this test passes with the bug fully present. It did.
# The discriminating fact is WHERE it stops: with the bug it runs on into the gate stage,
# with the fix it never gets there.
test_start "release.sh REFUSES when its stamper is missing, rather than shipping unstamped"
OUT_M="$(cd "$RS_FIX" && bash scripts/release.sh 0.9.9 2>&1)"; RC_M=$?
assert_eq "$(printf '%s' "$OUT_M" | grep -c '== verify ==')" "0" \
  "it must stop BEFORE the gate stage, not run on past a missing stamper"

test_start "and it refuses in its own words, not just bash's"
assert_contains "$OUT_M" "release: cannot stamp" "release.sh names the problem itself"

test_start "and it exits non-zero"
assert_eq "$RC_M" "1" "loud refusal"

test_start "and the tree it could not stamp was left untouched"
assert_eq "$(head -1 "$RS_FIX/doc.md")" "<!-- Version: 0.1.0 -->" "nothing was half-stamped"

# The version of this test that only looked at doc.md was blind to the two files that
# actually WERE mutated: the guard sat after step 1's jq bump, so a refused release still
# rewrote the canonical JSON versions and left exactly the half-stamped tree it claimed to
# prevent. The refusal has to come before ANY mutation, so assert on what step 1 touches.
# Assert the VALUE, not its formatting. The first version of this compared against jq's
# pretty-printed spacing, which only appears once jq has rewritten the file: it would have
# gone green on a fixture that jq had mangled and red on the untouched one it was meant to
# pass. The expected string was a fingerprint of the bug, not of the fix.
test_start "the canonical JSON versions were NOT bumped before the refusal"
assert_eq "$(jq -r '.version' "$RS_FIX/.claude-plugin/plugin.json")" "0.1.0" "plugin.json untouched"

test_start "and marketplace.json was not bumped either"
assert_eq "$(jq -r '.plugins[0].version' "$RS_FIX/.claude-plugin/marketplace.json")" "0.1.0" \
  "marketplace.json untouched"

test_start "with the stamper present, the same fixture DOES get stamped"
cp "$DIR/../scripts/lib-stamp.sh" "$RS_FIX/scripts/"
( cd "$RS_FIX" && bash scripts/release.sh 0.9.9 >/dev/null 2>&1 )
assert_eq "$(head -1 "$RS_FIX/doc.md")" "<!-- Version: 0.9.9 -->" "control: stamping works when the lib is there"

print_summary
teardown_test_env
exit $FAILED
