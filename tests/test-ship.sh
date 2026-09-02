#!/usr/bin/env bash
# tests/test-ship.sh — ship.sh: the one-button ship rail (build + open).
#
# Fixture: a scratch git repo with a bare fake "origin" whose main is a
# separate public lineage (mirrors the real repo's private/public split).
# gh interactions are covered through `open --dry-run`, which prints the
# commands it WOULD run — orchestration is asserted without touching GitHub.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

SHIP="$(cd "$DIR/.." && pwd)/scripts/ship.sh"

# Leak-quad for the audit test, assembled at runtime so no dotted quad ever
# appears in this file's own source (the repo's pre-push guard scans commits).
QUAD="10.20.30"; QUAD="$QUAD.40"

# ── Fixture ─────────────────────────────────────────────────────────────
FIX="$TEST_TMP/fix"
mkdir -p "$FIX"
git init -q --bare "$FIX/origin.git"
git init -q -b main "$FIX/repo"
cd "$FIX/repo" || exit 1
git config user.email "t@example.invalid"
git config user.name "t"
mkdir -p docs/dogfood docs/superpowers
printf 'public readme\n' > README.md
printf 'names people — internal\n' > docs/VISION.md
printf 'sdd scaffolding\n' > docs/superpowers/x.md
printf 'tuning log\n' > docs/dogfood/y.md
printf 'docs/superpowers/\ndocs/VISION.md\ndocs/dogfood/\n.publishignore\n' > .publishignore
git add -A && git commit -qm "private main"
# Public lineage: orphan branch carrying only the public file, pushed as origin main.
git checkout -q --orphan pub
git rm -rq --cached . >/dev/null 2>&1
rm -rf docs .publishignore
git add README.md && git commit -qm "public main"
git push -q "$FIX/origin.git" pub:main
git checkout -q main
# Restore working files clobbered by the orphan dance (main's tree is intact).
git checkout -q -- .
git remote add origin "$FIX/origin.git"
git fetch -q origin
# A public-visible delta on private main, so there is something TO ship
# (without this, build correctly refuses with "nothing to ship").
printf 'usage notes\n' > USAGE.md
git add USAGE.md && git commit -qm "public-visible change"

# ── build: preconditions ────────────────────────────────────────────────
test_start "ship build refuses a dirty tree"
printf 'wip\n' > dirty.txt
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t1 bash "$SHIP" build 2>&1)"
RC=$?
rm -f dirty.txt
if [ "$RC" -ne 0 ]; then _pass; else _fail "expected nonzero on dirty tree, got rc=0: $OUT"; fi

test_start "ship build refuses when gates can't run (no silent skip)"
OUT="$(SHIP_BRANCH=t2 bash "$SHIP" build 2>&1)"   # fixture has no Makefile
RC=$?
git checkout -q main 2>/dev/null
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'gate'; then
  _pass
else
  _fail "expected gate failure to block, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

# ── build: the public branch ────────────────────────────────────────────
test_start "ship build creates the public branch minus the internal set"
SHIP_SKIP_GATES=1 SHIP_BRANCH=t3 bash "$SHIP" build >/dev/null 2>&1
RC=$?
TREE="$(git ls-tree -r --name-only t3 2>/dev/null)"
if [ "$RC" -eq 0 ] && printf '%s\n' "$TREE" | grep -qx 'README.md' \
   && ! printf '%s\n' "$TREE" | grep -q 'docs/VISION.md' \
   && ! printf '%s\n' "$TREE" | grep -q 'docs/superpowers' \
   && ! printf '%s\n' "$TREE" | grep -q '.publishignore'; then
  _pass
else
  _fail "rc=$RC tree=[$TREE]"
fi

test_start "ship build roots the branch on origin/main"
BASE="$(git merge-base t3 origin/main 2>/dev/null)"
assert_eq "$BASE" "$(git rev-parse origin/main)" "branch descends from origin/main"

test_start "ship build prints the one push line for John's hand"
git checkout -q main
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t4 bash "$SHIP" build 2>&1)"
git checkout -q main
assert_contains "$OUT" "git push -u origin t4" "push line printed"

# ── build: the leak-audit ───────────────────────────────────────────────
test_start "ship build blocks a planted leak shape and names the file"
git checkout -q main
printf 'server lives at %s ok\n' "$QUAD" > leaky.md
git add leaky.md && git commit -qm "plant"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5 bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'leaky.md'; then
  _pass
else
  _fail "expected leak block naming leaky.md, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

# ── build: fail-closed guards (review round) ────────────────────────────
test_start "ship build refuses when .publishignore is missing (fail-open is the disease)"
git checkout -q main
git rm -q .publishignore && git commit -qm "drop manifest"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t6 bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main; git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'publishignore'; then
  _pass
else
  _fail "expected refusal naming the manifest, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship build refuses a binary file (audit can't read it)"
git checkout -q main
printf 'leak %s here\x00\x01\x02' "$QUAD" > blob.bin
git add blob.bin && git commit -qm "binary"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t7 bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main; git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'blob.bin'; then
  _pass
else
  _fail "expected binary refusal naming blob.bin, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship build audits files with non-ASCII names (quotepath evasion)"
git checkout -q main
printf 'server at %s\n' "$QUAD" > 'café-leak.md'
git add 'café-leak.md' && git commit -qm "unicode name"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t8 bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main; git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'leak'; then
  _pass
else
  _fail "expected leak block on unicode-named file, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship build refuses to clobber an existing branch"
git checkout -q main
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t3 bash "$SHIP" build 2>&1)"   # t3 exists from earlier
RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 't3'; then
  _pass
else
  _fail "expected existing-branch refusal, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship build failure prints the recovery path"
git checkout -q main
printf 'oops %s\n' "$QUAD" > leaky2.md
git add leaky2.md && git commit -qm "plant2"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t9 bash "$SHIP" build 2>&1)"
git checkout -qf main; git reset -q --hard HEAD~1; git branch -qD t9 2>/dev/null
if printf '%s' "$OUT" | grep -qi 'recover'; then
  _pass
else
  _fail "expected a recovery hint on failed build: $(printf '%s' "$OUT" | head -c 300)"
fi

# ── the rail must be able to ship itself ────────────────────────────────
test_start "ship.sh source carries no guard-shaped literals (self-shippable)"
# Shapes assembled at runtime (same reason as QUAD above): the audit pattern
# line must be built by concatenation and never spell a guard shape whole —
# else the rail's own audit (and the real pre-push guard) flag the rail.
RT="/ro"; RT="${RT}ot/"
BF=".bff"; BF="${BF}.lan"
GA="gitea"; GA="${GA}@"
V="$(grep -nE "$RT|$BF|$GA" "$(dirname "$SHIP")/ship.sh" | grep -vE '^[0-9]+:[[:space:]]*#')"
assert_eq "$V" "" "guard-shaped literal in ship.sh: $V"

# ── open: the law is structural ─────────────────────────────────────────
test_start "ship open without --review opens a DRAFT (no-self-merge law)"
git checkout -q t3 2>/dev/null
OUT="$(bash "$SHIP" open --dry-run 2>&1)"
git checkout -q main
if printf '%s' "$OUT" | grep -q -- '--draft' && printf '%s' "$OUT" | grep -qi 'second lens'; then
  _pass
else
  _fail "expected draft + second-lens warning: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship open --review arms auto-merge, not draft"
git checkout -q t3 2>/dev/null
OUT="$(bash "$SHIP" open --dry-run --review "sonnet adversarial pass, findings fixed" 2>&1)"
git checkout -q main
if printf '%s' "$OUT" | grep -q 'pr merge' && printf '%s' "$OUT" | grep -q -- '--auto' \
   && ! printf '%s' "$OUT" | grep -q -- '--draft' \
   && printf '%s' "$OUT" | grep -q 'sonnet adversarial pass'; then
  _pass
else
  _fail "expected auto-merge armed with review in body: $(printf '%s' "$OUT" | head -c 300)"
fi

# ── open: the second lens must have RUN (v0.27.0 lens_check) ─────────────
# A stamp file is the mechanical signal redteam-watch writes when an
# adversarial dispatch COMPLETES. Prose alone (--review) no longer suffices
# when her state is reachable; no state at all keeps the prose-only behavior
# (asserted implicitly by the two open tests above — the fixture has no
# care.json on the walk path).

CARE="$TEST_TMP/care.json"

test_start "ship open --review REFUSES on a stale lens stamp"
printf '{"last_redteam_iso":{"aaaa1111":"2001-01-01T00:00:00Z"}}\n' > "$CARE"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "prose only" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'SECOND LENS NOT PROVEN'; then
  _pass
else
  _fail "expected refusal on stale stamp (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship open --review proceeds on a FRESH lens stamp"
printf '{"last_redteam_iso":{"aaaa1111":"%s"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CARE"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "sonnet adversarial pass" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'pr merge'; then
  _pass
else
  _fail "expected proceed on fresh stamp (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship open --review REJECTS a future stamp (planted, not fresh)"
printf '{"last_redteam_iso":{"aaaa1111":"%s"}}\n' "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" > "$CARE"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "prose" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'SECOND LENS NOT PROVEN'; then
  _pass
else
  _fail "expected refusal on future stamp (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship open DRAFT stays available even with a stale stamp"
printf '{"last_redteam_iso":{"aaaa1111":"2001-01-01T00:00:00Z"}}\n' > "$CARE"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q -- '--draft'; then
  _pass
else
  _fail "expected draft to proceed (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# The candidate WALK, which no test exercised because every test above injects
# SHIP_CARE_FILE. lens_check took the first candidate that EXISTED, not the first that
# carried a stamp — so a repo-local care.json that exists and is empty shadowed the real
# one forever. Under the canonical-root law the session's project dir IS the workspace
# root, so the stamp always lands in the parent and the repo-local file is always empty:
# the gate was structurally unsatisfiable for this repo, and silently so.
test_start "lens_check walks PAST an empty repo-local care.json to a fresh parent stamp"
mkdir -p "$FIX/repo/.maude/plugin" "$FIX/.maude/plugin"
printf '{"last_redteam_iso":{}}\n' > "$FIX/repo/.maude/plugin/care.json"
printf '{"last_redteam_iso":{"bbbb2222":"%s"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$FIX/.maude/plugin/care.json"
git checkout -q t3 2>/dev/null
OUT="$(bash "$SHIP" open --dry-run --review "a real second lens ran" 2>&1)"
RC=$?
git checkout -q main
rm -rf "$FIX/repo/.maude" "$FIX/.maude"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'SECOND LENS NOT PROVEN'; then
  _pass
else
  _fail "empty repo-local care.json shadowed the parent's fresh stamp (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# The rail used to leave you STANDING ON the ship branch. A warning was tried first and was
# not enough — the same mistake happened twice on 2026-08-17, the second time with the
# warning printed and quoted back. Work committed there is invisible to the next build, so
# a release shipped without a fix whose own commit message described it. Leaving the tree
# in a safe state is the rail; the warning was only a diary.
test_start "ship build RETURNS to the source branch instead of stranding you on the ship branch"
git checkout -q main
printf 'another public change\n' > USAGE2.md
git add USAGE2.md && git commit -qm "another public-visible change"
SHIP_SKIP_GATES=1 SHIP_BRANCH=tret bash "$SHIP" build >/dev/null 2>&1
AFTER="$(git rev-parse --abbrev-ref HEAD)"
if [ "$AFTER" = "main" ]; then
  _pass
else
  _fail "left standing on '$AFTER' instead of returning to main"
fi

test_start "the ship branch still exists after the build returns"
if git rev-parse --verify -q refs/heads/tret >/dev/null; then _pass; else _fail "build lost its branch"; fi

# `open` used to auto-move to the ship branch only from `main`. Its sibling fix returns
# build to the SOURCE branch, which is usually not main — so open accepted the source as
# the PR head and gh refused with "no commits between main and <source>". Both fixes were
# right; the seam between them was not.
test_start "ship open REFUSES a source branch that is many commits ahead, not just main"
git checkout -q -B feature-src main 2>/dev/null
printf 'a\n' > f1.md && git add f1.md && git commit -qm "one"
printf 'b\n' > f2.md && git add f2.md && git commit -qm "two"
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run 2>&1)"; RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'ahead of origin/main'; then
  _pass
else
  _fail "accepted a multi-commit source branch as the PR head (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# ── the PUBLIC remote is resolved by URL, never by NAME ─────────────────
#
# Added 2026-08-30. Every `$PUB/main` in ship.sh used to read `origin/main`,
# which worked only because this repo is the one place in the estate where
# `origin` means github. The leak audit IS `git diff $PUB/main`, so pointing
# it at canon makes it compare the internal tree against itself, find nothing,
# and report clean while shipping everything. These tests exist so the rename
# to the estate convention (origin=gitea, github=github) cannot do that.
#
# NOTE the fixture above has ONE remote on a local path, so it exercises the
# single-remote rule and NOT the github rule. Every case below builds its own
# remote set; a test that reuses the fixture would prove nothing new.

_pubremote() {  # echo the remote ship.sh treats as public, or "REFUSED: <its own message>"
  # Runs the REAL script. The first draft sed-extracted resolve_public_remote and ran
  # the text in a subshell with its own die(), which meant these tests could never see
  # a defect in how $PUB is USED, and they asserted on a "REFUSED:" string the rail
  # never emits. An adversarial pass proved the cost: two mutants that blinded the
  # audit and the fetch both survived the whole suite.
  #
  # With no subcommand ship.sh still resolves and announces, then dies on usage. We key
  # on the announcement, not the exit code.
  local dir="$1"; shift
  local out
  out="$( cd "$dir" && env "$@" bash "$SHIP" 2>&1 )"
  if printf '%s\n' "$out" | grep -q '^ship: public remote = '; then
    printf '%s\n' "$out" | sed -n 's/^ship: public remote = \([^ ]*\) .*/\1/p' | head -1
  else
    printf 'REFUSED: %s' "$(printf '%s\n' "$out" | head -1)"
  fi
}

_mkrepo() {  # $1=dir, then name=url pairs
  local d="$1"; shift
  git init -q -b main "$d"; ( cd "$d" || exit 1
    git config user.email t@example.invalid; git config user.name t
    printf x > f; git add f; git commit -qm c
    for spec in "$@"; do git remote add "${spec%%=*}" "${spec#*=}"; done )
}

R="$TEST_TMP/remotes"; mkdir -p "$R"

test_start "public remote is the github one even when it is NOT named origin"
_mkrepo "$R/a" "origin=https://gitea.example.invalid/o/x.git" "github=https://github.com/john-broadway/x.git"
assert_eq "$(_pubremote "$R/a")" "github" "post-rename shape"

test_start "public remote is still found when github IS named origin"
_mkrepo "$R/b" "origin=https://github.com/john-broadway/x.git" "gitea=https://gitea.example.invalid/o/x.git"
assert_eq "$(_pubremote "$R/b")" "origin" "pre-rename shape"

test_start "two github remotes REFUSE rather than guess"
_mkrepo "$R/c" "one=https://github.com/a/x.git" "two=https://github.com/b/x.git"
case "$(_pubremote "$R/c")" in REFUSED*) _pass ;; *) _fail "picked one instead of refusing: $(_pubremote "$R/c")" ;; esac

test_start "a lone GITEA remote REFUSES (there is nothing public to ship against)"
_mkrepo "$R/d" "origin=https://gitea.example.invalid/o/x.git"
case "$(_pubremote "$R/d")" in REFUSED*) _pass ;; *) _fail "accepted canon as public: $(_pubremote "$R/d")" ;; esac

test_start "a lone non-gitea remote is accepted (the test-fixture shape)"
_mkrepo "$R/e" "origin=$FIX/origin.git"
assert_eq "$(_pubremote "$R/e")" "origin" "single local remote"

test_start "no remotes at all REFUSES"
_mkrepo "$R/f"
case "$(_pubremote "$R/f")" in REFUSED*) _pass ;; *) _fail "accepted a repo with no remotes: $(_pubremote "$R/f")" ;; esac

test_start "SHIP_PUBLIC_REMOTE overrides the URL rule"
_mkrepo "$R/g" "origin=https://gitea.example.invalid/o/x.git" "github=https://github.com/john-broadway/x.git"
assert_eq "$(_pubremote "$R/g" SHIP_PUBLIC_REMOTE=origin)" "origin" "explicit override"

test_start "SHIP_PUBLIC_REMOTE naming a remote that is not there REFUSES"
case "$(_pubremote "$R/g" SHIP_PUBLIC_REMOTE=nosuch)" in REFUSED*) _pass ;; *) _fail "accepted a phantom remote" ;; esac

test_start "build roots on the PUBLIC main after a rename, not on canon"
# The whole point, end to end. Put the repo into the ESTATE convention
# (origin=canon, github=public) and give canon a DIFFERENT lineage. If ship.sh
# followed the NAME it would root on canon and the leak audit would go blind.
#
# The public bare repo lives under a directory literally called github.com so its
# URL satisfies the same rule a real remote does. Without that the resolver
# refuses two local paths, which is correct and is asserted separately above.
CANON="$TEST_TMP/canon.git"; git init -q --bare "$CANON"
mkdir -p "$TEST_TMP/github.com"; PUBBARE="$TEST_TMP/github.com/pub.git"
git init -q --bare "$PUBBARE"
cd "$FIX/repo" || exit 1
git push -q "$PUBBARE" "$(git rev-parse origin/main)":refs/heads/main
git push -q "$CANON" main:main
git remote remove origin
git remote add github "$PUBBARE"
git remote add origin "$CANON"
git fetch -q github; git fetch -q origin
SHIP_BRANCH=ship-rename SHIP_SKIP_GATES=1 "$SHIP" build -m "rename probe" >/dev/null 2>&1
_base="$(git merge-base ship-rename github/main 2>/dev/null)"
assert_eq "$_base" "$(git rev-parse github/main)" "ship branch is rooted on the PUBLIC main"

test_start "and that ship branch is NOT rooted on canon"
assert_ne "$(git merge-base ship-rename origin/main 2>/dev/null)" "$(git rev-parse origin/main)" "must not root on canon"

test_start "the leak audit diffs against the PUBLIC main, not canon"
# THE test for this change, and the one the first ten missed. An adversarial pass
# reverted ONLY audit_staged's baseline to origin/main -- the exact catastrophe the
# decoupling exists to prevent -- and the suite stayed 32/32 green. The rename tests
# above assert where the BRANCH is rooted, which comes from a different line; the
# leak-plant tests run in the original fixture where origin IS the public remote, so
# a hardcoded origin/main is indistinguishable from correct there.
#
# So plant a leak that CANON ALREADY CARRIES and the public main does not. Audited
# against public/main it is an ADDED line and must be caught. Audited against canon
# it is unchanged, and the audit goes blind while reporting clean.
#
# --no-verify is on the PLANT'S DELIVERY to the bare canon repo, never on the subject
# under test: the estate's own pre-push guard fires on fixture pushes and would make
# this flaky by environment rather than by behaviour.
git checkout -q main
printf 'internal box at %s\n' "$QUAD" > canon-only-leak.md
git add canon-only-leak.md && git commit -qm "a leak that canon already carries"
git push -q --no-verify "$CANON" main:main
git fetch -q origin
_out="$(SHIP_BRANCH=ship-auditbase SHIP_SKIP_GATES=1 "$SHIP" build 2>&1)"; _rc=$?
git checkout -qf main >/dev/null 2>&1
git branch -qD ship-auditbase >/dev/null 2>&1
git reset -q --hard HEAD~1
if [ "$_rc" -ne 0 ] && printf '%s' "$_out" | grep -q 'canon-only-leak.md'; then
  _pass
else
  _fail "audit was blind to a leak canon already had (rc=$_rc): $(printf '%s' "$_out" | head -c 200)"
fi

test_start "build fetches the PUBLIC remote, not whatever is named origin"
# The second surviving mutant: `git fetch -q origin` in place of "$PUB". Invisible to
# every other test because the fixture pre-fetches both remotes, so a wrong fetch
# target still finds a usable ref sitting in the repo.
#
# Delete the public remote-tracking ref and build. A build that fetches the right
# remote restores it; one that fetches canon leaves it gone and dies on the missing
# baseline. (No $PUB here: that is ship.sh's variable, not this file's. Referencing
# it under `set -u` killed this suite on the first draft.)
git update-ref -d refs/remotes/github/main
SHIP_BRANCH=ship-fetch SHIP_SKIP_GATES=1 "$SHIP" build -m "fetch probe" >/dev/null 2>&1
if git rev-parse --verify -q refs/remotes/github/main >/dev/null 2>&1; then
  _pass
else
  _fail "build left refs/remotes/github/main deleted, so it fetched something else"
fi
git checkout -qf main >/dev/null 2>&1; git branch -qD ship-fetch >/dev/null 2>&1

cd "$DIR" || exit 1
teardown_test_env
print_summary
exit "$FAILED"