#!/usr/bin/env bash
# Tests for scripts/maude-cushions.sh — the cushion-flip: find change that
# fell where no sensor watches. Reports only; never deletes.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

CUSHIONS="$(dirname "$0")/../scripts/maude-cushions.sh"
export MAUDE_CUSHION_DAYS=14

# Hermetic git identity — fixture commits must not depend on host config.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

W="$TEST_TMP/house"
mkdir -p "$W"

mkrepo() { # mkrepo <dir> — init + one committed file
  git init -q "$1" && printf 'hello\n' > "$1/base.txt" \
    && git -C "$1" add -A && git -C "$1" commit -qm init
}

run_cushions() { OUT="$(bash "$CUSHIONS" "$W" 2>/dev/null)"; RC=$?; }

# ── Fixture: repo with uncommitted change (remote'd + pushed, so the
# uncommitted signal is isolated from the local-only signal) ──────────
git init -q --bare "$TEST_TMP/origin0.git"
mkrepo "$W/dirty"
git -C "$W/dirty" remote add origin "$TEST_TMP/origin0.git"
git -C "$W/dirty" push -q origin HEAD 2>/dev/null
printf 'changed\n' >> "$W/dirty/base.txt"
printf 'loose\n' > "$W/dirty/loose.txt"

# ── Fixture: repo with a remote, one unpushed commit ─────────────────
git init -q --bare "$TEST_TMP/origin.git"
mkrepo "$W/ahead"
git -C "$W/ahead" remote add origin "$TEST_TMP/origin.git"
git -C "$W/ahead" push -q origin HEAD 2>/dev/null
printf 'more\n' > "$W/ahead/new.txt" && git -C "$W/ahead" add -A && git -C "$W/ahead" commit -qm ahead

# ── Fixture: local-only repo (no remote at all) ──────────────────────
mkrepo "$W/soleco"

# ── Fixture: clean, fully pushed repo ────────────────────────────────
git init -q --bare "$TEST_TMP/origin2.git"
mkrepo "$W/clean"
git -C "$W/clean" remote add origin "$TEST_TMP/origin2.git"
git -C "$W/clean" push -q origin HEAD 2>/dev/null

# ── Fixture: scratch dir with old-and-substantial vs fresh vs tiny ───
mkdir -p "$W/.scratch"
head -c 1024 /dev/zero | tr '\0' 'x' > "$W/.scratch/old-proposal.md"
touch_ago $(( 20*86400 )) "$W/.scratch/old-proposal.md"
head -c 1024 /dev/zero | tr '\0' 'y' > "$W/.scratch/fresh-notes.md"
printf 'tiny\n' > "$W/.scratch/old-tiny.md"
touch_ago $(( 20*86400 )) "$W/.scratch/old-tiny.md"

test_start "cushions exits 0 (a report, not a gate)"
run_cushions
assert_exit "$RC" "0" "exit"

test_start "cushions flags uncommitted files"
assert_contains "$OUT" "dirty — 2 uncommitted file(s)" "dirty repo flagged"

test_start "cushions flags unpushed commits"
assert_contains "$OUT" "ahead — 1 unpushed commit(s)" "ahead repo flagged"

# A month of unpushed main went unflagged on 2026-11-04 because the repo sat outside the
# walk root (a box's git hooks dir), and a count alone says nothing about how long it has
# been that way. The line now carries the oldest unpushed commit's date, and roots outside
# the project are walked too, one per line in ~/.claude/maude/cushion-roots or
# MAUDE_CUSHION_ROOTS (colon-separated).
test_start "the unpushed line names the oldest unpushed commit's date"
OLDEST="$(git -C "$W/ahead" log -1 --format=%cs)"
assert_contains "$OUT" "ahead — 1 unpushed commit(s), oldest $OLDEST" "the date on the line"

test_start "a repo outside the walk root, named in cushion-roots, is flipped too"
OUTSIDE="$TEST_TMP/outside"; mkdir -p "$OUTSIDE"
git init -q --bare "$TEST_TMP/origin-hooks.git"
mkrepo "$OUTSIDE/box-hooks"
git -C "$OUTSIDE/box-hooks" remote add origin "$TEST_TMP/origin-hooks.git"
git -C "$OUTSIDE/box-hooks" push -q origin HEAD 2>/dev/null
printf 'hook\n' > "$OUTSIDE/box-hooks/pre-push" && git -C "$OUTSIDE/box-hooks" add -A && git -C "$OUTSIDE/box-hooks" commit -qm hook
run_cushions
assert_not_contains "$OUT" "box-hooks" "not walked until it is named"
mkdir -p "$HOME/.claude/maude"
printf '%s\n%s\n' "$OUTSIDE/box-hooks" "$TEST_TMP/no-such-root" > "$HOME/.claude/maude/cushion-roots"
run_cushions
assert_exit "$RC" "0" "a listed root that does not exist is skipped, not an error"
assert_contains "$OUT" "$OUTSIDE/box-hooks — 1 unpushed commit(s), oldest $OLDEST" "the outside repo, by its full path, with its date"
rm -f "$HOME/.claude/maude/cushion-roots"

test_start "a commit on a detached HEAD counts as unpushed (the lens on c898dca, m5)"
git init -q --bare "$TEST_TMP/origin-det.git"
mkrepo "$W/detached"
git -C "$W/detached" remote add origin "$TEST_TMP/origin-det.git"
git -C "$W/detached" push -q origin HEAD 2>/dev/null
git -C "$W/detached" checkout -q --detach
printf 'loose\n' > "$W/detached/d.txt" && git -C "$W/detached" add -A && git -C "$W/detached" commit -qm detached
run_cushions
assert_contains "$OUT" "detached — 1 unpushed commit(s)" "flagged"

test_start "MAUDE_CUSHION_ROOTS names extra roots the same way"
OUT="$(MAUDE_CUSHION_ROOTS="$OUTSIDE:$TEST_TMP/no-such-root" bash "$CUSHIONS" "$W" 2>/dev/null)"; RC=$?
assert_exit "$RC" "0" "exit"
assert_contains "$OUT" "box-hooks — 1 unpushed commit(s)" "the outside repo found under the env root"
run_cushions

test_start "cushions flags a local-only repo as sole-copy risk"
assert_contains "$OUT" "soleco — LOCAL-ONLY repo" "local-only repo flagged"

test_start "cushions stays quiet about a clean pushed repo"
assert_not_contains "$OUT" "clean —" "clean repo not flagged"

test_start "cushions flags old substantial scratch"
assert_contains "$OUT" "old-proposal.md" "aging scratch flagged"

test_start "cushions ignores fresh scratch"
assert_not_contains "$OUT" "fresh-notes.md" "fresh scratch not flagged"

test_start "cushions ignores tiny old scratch"
assert_not_contains "$OUT" "old-tiny.md" "tiny scratch not flagged"

test_start "cushions ends with a candidate count"
assert_contains "$OUT" "value candidates" "count line present"

# ── Parked: per-file, whole-repo, and scratch entries ────────────────
printf 'loose.txt — demo tweak by design\n' > "$W/dirty/.parked"
printf '.\n' > "$W/soleco/.parked"
printf 'old-proposal.md — parked pending review\n' > "$W/.scratch/.parked"

test_start "a per-file park moves the file out of the uncommitted count"
run_cushions
assert_contains "$OUT" "dirty — 1 uncommitted file(s)" "parked file not counted"
assert_contains "$OUT" "dirty/loose.txt" "parked file named in parked section"

test_start "a whole-repo park silences the local-only flag"
assert_not_contains "$OUT" "LOCAL-ONLY" "parked repo not flagged"
assert_contains "$OUT" "soleco — whole repo parked" "parked repo named"

test_start "a scratch park silences the aging-scratch flag"
assert_contains "$OUT" "0 aging scratch file(s)" "no scratch finding counted"
assert_contains "$OUT" ".scratch/old-proposal.md" "parked scratch named in parked section"

test_start "cushions never deletes anything (report only)"
assert_file_exists "$W/.scratch/old-proposal.md" "scratch intact"
assert_file_exists "$W/dirty/loose.txt" "loose file intact"

# ── The flip stamps the closet so the wake brief can read it (issue #36) ──
test_start "flip stamps the closet for the wake brief"
run_cushions
STAMP="$W/.maude/plugin/cushions-last"
[ -f "$STAMP" ] && S_OK=yes || S_OK=no
assert_eq "$S_OK" "yes" "cushions-last written"

test_start "stamp carries epoch + the reported candidate count"
COUNT_OUT="$(printf '%s\n' "$OUT" | tail -1 | awk '{print $1}')"
assert_eq "$(awk '{print $2}' "$STAMP" 2>/dev/null)" "$COUNT_OUT" "stamp count matches report"
case "$(awk '{print $1}' "$STAMP" 2>/dev/null)" in ''|*[!0-9]*) EP=bad;; *) EP=ok;; esac
assert_eq "$EP" "ok" "stamp epoch is numeric"

# Writer and reader must resolve the SAME closet: no arg + no env must go
# through maude_project_dir() (the hooks' resolver), never bare pwd — else a
# slash-command run stamps the wrong .maude and the brief says "never flipped"
# forever (adversarial-review finding on #36).
test_start "argless flip resolves the project like the hooks do"
DECOY="$TEST_TMP/elsewhere"; mkdir -p "$DECOY"
rm -f "$W/.maude/plugin/cushions-last"
CUSH_ABS="$(cd "$(dirname "$CUSHIONS")" && pwd)/$(basename "$CUSHIONS")"
( cd "$DECOY" && CLAUDE_PROJECT_DIR='' MAUDE_PROJECT_DIR_OVERRIDE="$W" bash "$CUSH_ABS" >/dev/null 2>&1 )
[ -f "$W/.maude/plugin/cushions-last" ] && R_OK=yes || R_OK=no
assert_eq "$R_OK" "yes" "stamp lands in the resolved project, not pwd"
[ -f "$DECOY/.maude/plugin/cushions-last" ] && D_HIT=yes || D_HIT=no
assert_eq "$D_HIT" "no" "no stray closet in the decoy dir"

print_summary
teardown_test_env
exit $FAILED
