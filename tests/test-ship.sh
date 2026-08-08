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

cd "$DIR" || exit 1
teardown_test_env
print_summary
exit "$FAILED"
