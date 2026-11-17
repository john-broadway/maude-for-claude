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

test_start "ship build prints the one push line for the maintainer's hand"
git checkout -q main
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t4 bash "$SHIP" build 2>&1)"
git checkout -q main
assert_contains "$OUT" "git push -u origin t4" "push line printed"

# 2026-11-08, the v0.36.0 public build: the source ref was checked out in a worktree, so
# the return checkout failed, and the build still printed "back on <ref>" with the main
# checkout left on the ship branch. The last line must name where the checkout IS.
test_start "a source ref held by a worktree: the build returns to the branch it started on, and says so"
git checkout -q main
git branch -q held main
git worktree add -q "$FIX/held-wt" held
OUT="$(SHIP_SKIP_GATES=1 SHIP_SOURCE_REF=held SHIP_BRANCH=t4w bash "$SHIP" build 2>&1)"
NOW_ON="$(git rev-parse --abbrev-ref HEAD)"
git checkout -qf main; git worktree remove -f "$FIX/held-wt"; git branch -qD held t4w 2>/dev/null
assert_eq "$NOW_ON" "main" "checkout returned to the starting branch"
assert_not_contains "$OUT" "back on held" "never claims the held ref"
assert_contains "$OUT" "back on main" "names the branch it is on"

# ── build: the leak-audit ───────────────────────────────────────────────
test_start "ship build blocks a planted session-scratch path and names the file"
git checkout -q main
printf 'line 962: /var/lib/%s/claude-0/x/scratchpad/care.json.lock\n' "claude-""scratch" > err-capture.md
git add err-capture.md && git commit -qm "plant scratch"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5s bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'err-capture.md'; then
  _pass
else
  _fail "expected leak block naming err-capture.md, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

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

# ── the audit's own defects (release 0.36.0, the first this guard audited against the
#    house's own fixtures): loopback and the RFC 5737 documentation ranges cannot be a leak
#    and sit in shipped code and docs; the credential prefix had no left boundary, so
#    `task-notification` read as `sk-` plus twelve characters ─────────────────────────
_LOOP="127.0.0"; _LOOP="$_LOOP.1"; _DOC="192.0.2"; _DOC="$_DOC.71"
test_start "ship build passes loopback and a documentation address (they cannot be a leak)"
git checkout -q main
printf 'the embedder knocks on %s; the example in the docs is %s\n' "$_LOOP" "$_DOC" > doc-ips.md
git add doc-ips.md && git commit -qm "doc ips"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5d bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git branch -q -D t5d 2>/dev/null
git reset -q --hard HEAD~1
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'doc-ips.md'; then
  _pass
else
  _fail "expected a pass with doc-ips.md unnamed, rc=$RC: $(printf '%s' "$OUT" | grep -E 'LEAK|BINARY' | head -c 200)"
fi

test_start "ship build still blocks a real-shaped address beside a documentation one"
git checkout -q main
printf 'doc %s but also %s\n' "$_DOC" "$QUAD" > mixed-ips.md
git add mixed-ips.md && git commit -qm "mixed ips"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5m bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'mixed-ips.md'; then
  _pass
else
  _fail "expected leak block naming mixed-ips.md, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship build passes task-notification (a credential prefix is read at a word boundary)"
git checkout -q main
printf 'origin kind: task-notification, from the harness\n' > kinds.md
git add kinds.md && git commit -qm "kinds"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5k bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git branch -q -D t5k 2>/dev/null
git reset -q --hard HEAD~1
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'kinds.md'; then
  _pass
else
  _fail "expected a pass with kinds.md unnamed, rc=$RC: $(printf '%s' "$OUT" | grep -E 'LEAK|BINARY' | head -c 200)"
fi

test_start "ship build still blocks a credential-shaped token at a word boundary"
git checkout -q main
_SK="sk"; _SK="$_SK-abcdefghijklmnop"
printf 'key %s end\n' "$_SK" > cred.md
git add cred.md && git commit -qm "cred"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5c bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'cred.md'; then
  _pass
else
  _fail "expected leak block naming cred.md, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi
test_start "ship build blocks a real address glued to a documentation one (the strip takes whole addresses only)"
git checkout -q main
_G="$_DOC"; _G="${_G}0.0"; _G="${_G}.0.5"
printf 'glued %s here\n' "$_G" > glued-ips.md
git add glued-ips.md && git commit -qm "glued ips"
OUT="$(SHIP_SKIP_GATES=1 SHIP_BRANCH=t5g bash "$SHIP" build 2>&1)"
RC=$?
git checkout -q main
git reset -q --hard HEAD~1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'glued-ips.md'; then
  _pass
else
  _fail "expected leak block naming glued-ips.md, rc=$RC: $(printf '%s' "$OUT" | head -c 200)"
fi
unset _LOOP _DOC _SK _G

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

# ── gate order, through the make seam (2026-11-16, the fast rail) ────────
# The cheap gates run first: on 2026-11-16 a stale Revised stamp (make verify) stopped a
# build an hour in, after both suites. A fake make logs the targets it is asked for.
FAKEMK="$TEST_TMP/fakemake"; MKLOG="$TEST_TMP/mk.log"; export MKLOG
printf '#!/usr/bin/env bash\nprintf "%%s%%s%%s\\n" "$1" "${MAUDE_SMOKE_SEPARATE:+ sep=$MAUDE_SMOKE_SEPARATE}" "${MAUDE_TEST_JOBS:+ jobs=$MAUDE_TEST_JOBS}" >> "$MKLOG"\n[ "$1" = "${MK_FAIL_ON:-}" ] && exit 1\nexit 0\n' > "$FAKEMK"
chmod +x "$FAKEMK"
FAKESMOKE="$TEST_TMP/fakesmoke"
printf '#!/usr/bin/env bash\nprintf "smoke %%s%%s\\n" "$2" "${MAUDE_TEST_JOBS:+ jobs=$MAUDE_TEST_JOBS}" >> "$MKLOG"\nexit 0\n' > "$FAKESMOKE"
chmod +x "$FAKESMOKE"

test_start "build runs lint and verify first; a verify red stops it before any suite"
git checkout -q main
: > "$MKLOG"
OUT="$(MK_FAIL_ON=verify SHIP_MAKE="$FAKEMK" SHIP_BRANCH=tg1 bash "$SHIP" build 2>&1)"; RC=$?
git checkout -qf main; git branch -qD tg1 2>/dev/null
assert_ne "$RC" "0" "the verify red stops the build"
assert_eq "$(tr '\n' ' ' < "$MKLOG")" "lint verify " "lint and verify ran, and nothing after them"

test_start "a green build still runs lint and verify before the suites"
: > "$MKLOG"
OUT="$(SHIP_MAKE="$FAKEMK" SHIP_SMOKE="$FAKESMOKE" SHIP_BRANCH=tg2 bash "$SHIP" build 2>&1)"; RC=$?
git checkout -qf main; git branch -qD tg2 2>/dev/null
assert_eq "$RC" "0" "green build: $OUT"
assert_eq "$(head -2 "$MKLOG" | tr '\n' ' ')" "lint verify " "the first two gates"

test_start "build runs test-py, the smoke on the staged tree, then the shaped pass without a nested smoke"
# 2026-11-16: a build ran the whole fleet about four times (make test, its smoke, make
# mac-shape, its smoke), and its smoke archived public main. Now: one fleet per shape, and
# the smoke is handed the exact tree the build commits.
: > "$MKLOG"
OUT="$(SHIP_MAKE="$FAKEMK" SHIP_SMOKE="$FAKESMOKE" SHIP_BRANCH=tg3 bash "$SHIP" build 2>&1)"; RC=$?
TREE3="$(git rev-parse "tg3^{tree}" 2>/dev/null)"
git checkout -qf main; git branch -qD tg3 2>/dev/null
assert_eq "$RC" "0" "green: $OUT"
assert_eq "$(tr '\n' '|' < "$MKLOG")" "lint|verify|test-py|smoke $TREE3 jobs=8|mac-shape sep=1 jobs=6|" "gates, in order, on the shipped tree"

# ── preflight: the cheap gates on the shipping tree, before an hour is spent ──
test_start "preflight runs audit, lint and verify on the staged tree and reports each, red or not"
git checkout -q main
: > "$MKLOG"
OUT="$(MK_FAIL_ON=lint SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
assert_ne "$RC" "0" "a red gate fails preflight"
assert_contains "$OUT" "preflight: audit ok" "audit reported"
assert_contains "$OUT" "preflight: lint RED" "lint reported red"
assert_contains "$OUT" "preflight: verify ok" "verify still ran after the red"
assert_contains "$OUT" "committed only" "it says it reads the committed source, not uncommitted work"
assert_eq "$(tr '\n' ' ' < "$MKLOG")" "lint verify " "only the cheap gates: no suite"

test_start "preflight is green when all three are, and catches a leak the build would"
OUT="$(SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
assert_eq "$RC" "0" "green: $OUT"
printf 'box at %s\n' "$QUAD" > leakpf.md
git add leakpf.md && git commit -qm "plant a leak"
OUT="$(SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_ne "$RC" "0" "the leak fails preflight"
assert_contains "$OUT" "preflight: audit RED" "and it is the audit that says so"

test_start "preflight leaves the author's checkout, branch, index and dirty files as found"
git checkout -q main
printf 'wip\n' > untracked-wip.txt
printf 'changed\n' >> README.md
BEFORE="$(git status --porcelain)|$(git rev-parse --abbrev-ref HEAD)|$(git rev-parse HEAD)"
WT_BEFORE="$(git worktree list | wc -l | tr -d ' ')"
SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight >/dev/null 2>&1
AFTER="$(git status --porcelain)|$(git rev-parse --abbrev-ref HEAD)|$(git rev-parse HEAD)"
assert_eq "$AFTER" "$BEFORE" "status, branch and HEAD unchanged"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "$WT_BEFORE" "no worktree left behind"
assert_eq "$(git branch --list 'ship-*' | wc -l | tr -d ' ')" "0" "no ship branch made"
rm -f untracked-wip.txt; git checkout -q -- README.md

test_start "preflight interrupted removes its worktree"
SLOWMK="$TEST_TMP/slowmake"
printf '#!/usr/bin/env bash\n[ "$1" = lint ] && sleep 30\nexit 0\n' > "$SLOWMK"; chmod +x "$SLOWMK"
WT_BEFORE="$(git worktree list | wc -l | tr -d ' ')"
# Its own process group (set -m), or a background job of this non-interactive shell starts
# with SIGINT ignored and the interrupt never lands (the lens on 3f49461: the first version
# passed with the INT trap deleted, cleaned up only when the 30 s sleep ended).
set -m
SHIP_MAKE="$SLOWMK" bash "$SHIP" preflight >/dev/null 2>&1 &
PF=$!
set +m
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(git worktree list | wc -l | tr -d ' ')" -gt "$WT_BEFORE" ] && break; sleep 0.5; done
T0="$(date +%s)"
kill -INT -- "-$PF" 2>/dev/null; wait "$PF" 2>/dev/null; PFRC=$?
assert_eq "$PFRC" "130" "it stopped on the interrupt"
assert_eq "$(( $(date +%s) - T0 < 10 ))" "1" "promptly, not when the slow gate ended"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "$WT_BEFORE" "the worktree is gone after SIGINT"

# ── the private-name list: the house's own names, refused and never printed ──
# 2026-11-16: three rebuilds were for names only this house knows (a service, a container
# term, a lane name). The list lives outside every repo; a refusal names the file and line,
# never the name.
PNL="$TEST_TMP/private-names.txt"
printf '# names that never ship\nzorbleflux\n\n' > "$PNL"

test_start "an added line carrying a private name is refused, and the name is never printed"
git checkout -q main
printf 'the zorbleflux box answers\n' > priv1.md
git add priv1.md && git commit -qm "plant a private name"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_ne "$RC" "0" "refused"
assert_contains "$OUT" "priv1.md:1: a private name (from the private list)" "names the file and line"
assert_not_contains "$OUT" "zorbleflux" "and never the name"

test_start "the match ignores case, at a word boundary only"
printf 'line one\nZORBLEFLUX again\n' > priv2.md
git add priv2.md && git commit -qm "plant upper case"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_contains "$OUT" "priv2.md:2: a private name" "upper case is the same name, on line 2"
printf 'zorblefluxes are a different word\n' > priv3.md
git add priv3.md && git commit -qm "plant a longer word"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_eq "$RC" "0" "a longer word is not the name: $OUT"

test_start "a private name on an added line whose text starts with ++ is still refused"
printf 'first\n++ the zorbleflux box\n' > priv4.md
git add priv4.md && git commit -qm "plant a ++ line"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_contains "$OUT" "priv4.md:2: a private name" "line 2, counted"

test_start "a list entry may carry a reason and trailing blanks"
printf 'zorbleflux   # why it never ships
quuxwomble  
' > "$TEST_TMP/pnl2"
printf 'the quuxwomble box
' > priv5.md
git add priv5.md && git commit -qm "plant the second name"
OUT="$(SHIP_PRIVATE_NAMES="$TEST_TMP/pnl2" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_contains "$OUT" "priv5.md:1: a private name" "an entry with trailing blanks still matches"
OUT="$(SHIP_PRIVATE_NAMES="$TEST_TMP/pnl2" SHIP_MAKE="$FAKEMK" bash -x "$SHIP" preflight 2>&1)"
assert_not_contains "$OUT" "quuxwomble" "and not even xtrace prints a name"

test_start "a user's color.diff does not blind the audit"
git config color.diff always
printf 'the zorbleflux box\n' > priv6.md
git add priv6.md && git commit -qm "plant under color"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1; git config --unset color.diff
assert_contains "$OUT" "priv6.md:1: a private name" "still refused"

test_start "a name may hold a #; only a blank then # starts a reason"
printf 'c#corp   # a name with a hash in it\n' > "$TEST_TMP/pnl3"
printf 'we use c daily\n' > priv7.md
git add priv7.md && git commit -qm "plant a lone c"
OUT="$(SHIP_PRIVATE_NAMES="$TEST_TMP/pnl3" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_eq "$RC" "0" "a lone c is not the name c#corp: $OUT"

test_start "no list: said once, and the audit still passes a clean tree"
OUT="$(SHIP_PRIVATE_NAMES="$TEST_TMP/no-such-list" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
assert_eq "$RC" "0" "clean tree passes"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'no private-name list')" "1" "said exactly once"

# ── prose shapes: a memory note's name or a quoted session id, in prose only ──
test_start "a Markdown line naming a memory note is refused"
git checkout -q main
printf 'background: see [[feedback_some-rule]]\n' > prose1.md
git add prose1.md && git commit -qm "plant a note link"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_ne "$RC" "0" "refused"
assert_contains "$OUT" "PROSE SHAPE: prose1.md" "names the file"

test_start "a shell comment quoting a session id is refused; the same text in code is not"
printf '#!/usr/bin/env bash\n# on that day session 1a2b3c4d ran it\n' > prose2.sh
git add prose2.sh && git commit -qm "plant a session id comment"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_contains "$OUT" "PROSE SHAPE: prose2.sh" "the comment is prose"
printf '#!/usr/bin/env bash\nprintf "%%s" '"'"'{"session":"feed0042"}'"'"'\n' > prose3.sh
git add prose3.sh && git commit -qm "a fixture in code"
OUT="$(SHIP_PRIVATE_NAMES="$PNL" SHIP_MAKE="$FAKEMK" bash "$SHIP" preflight 2>&1)"; RC=$?
git reset -q --hard HEAD~1
assert_eq "$RC" "0" "code is not prose: $OUT"

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

# The tip lens_check measures against: ship.sh reads SRC (main), not HEAD.
TIP="$(git rev-parse main)"

# The stamp shape redteam-watch writes since 2026-09-04 — a timestamp AND the refs the
# lens brief named. $3 is a jq array literal so a test can say "no refs" and "a ref that
# is not the tip" as easily as it says "the tip".
stamp_file() {  # $1 file, $2 ts, $3 refs-as-json-array
  jq -nc --arg ts "$2" --argjson refs "$3" \
    '{last_redteam_iso:{aaaa1111:{ts:$ts, refs:$refs}}}' > "$1"
}

test_start "ship open --review REFUSES on a stale lens stamp"
stamp_file "$CARE" "2001-01-01T00:00:00Z" "[\"$TIP\"]"
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
stamp_file "$CARE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "[\"$TIP\"]"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "sonnet adversarial pass" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'pr merge'; then
  _pass
else
  _fail "expected proceed on fresh stamp (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# ── open: the stamp must be OF the tip, not merely NEWER than it ─────────
# THE SEAM, measured on the real repo 2026-09-04. main's tip was committed at 16:09:57Z
# and care.json carried a stamp at 16:10:45Z — 48 seconds newer, so the gate said proven.
# The dispatch that wrote it had STARTED before the commit existed and could not have read
# a line of it. A timestamp answers "did a lens finish after this?"; the question the gate
# is actually asking is "did a lens look at THIS?". Only a named ref answers that.

test_start "ship open --review REFUSES a fresh stamp that names a DIFFERENT ref"
stamp_file "$CARE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '["deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"]'
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "a lens ran, on something else" 2>&1)"
RC=$?
git checkout -q main
# The reason matters: it must refuse because the ref is WRONG (so it read the stamp and
# echoes what it names), not because it could not read the file at all.
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'SECOND LENS NOT PROVEN' \
   && printf '%s' "$OUT" | grep -q 'names: deadbeef'; then
  _pass
else
  _fail "a stamp naming another ref must not satisfy the gate (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "the refusal NAMES the tip it wanted, so the remedy is obvious"
if printf '%s' "$OUT" | grep -q "$(printf '%s' "$TIP" | cut -c1-7)"; then
  _pass
else
  _fail "refusal did not name the wanted tip: $(printf '%s' "$OUT" | head -c 300)"
fi

test_start "ship open --review REFUSES a stamp that names NO ref at all"
stamp_file "$CARE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[]'
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "a lens ran, subject unrecorded" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'names NO ref'; then
  _pass
else
  _fail "a refless stamp must not satisfy the gate (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# Every stamp written before 2026-09-04 is a bare ISO string naming nothing. They are not
# grandfathered: a missed stamp costs one spurious refusal and a re-run, a false stamp
# costs a release that nothing reviewed. The rail leans the same way its writer does.
test_start "ship open --review REFUSES a LEGACY timestamp-only stamp, however fresh"
printf '{"last_redteam_iso":{"aaaa1111":"%s"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CARE"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "an old-shape stamp" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'names NO ref'; then
  _pass
else
  _fail "a legacy string stamp must not satisfy the gate (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# A brief names `7e36d82`, git resolves 40. Prefix matching is what makes the rail usable
# by a human-written brief at all.
test_start "an ABBREVIATED ref that prefixes the tip satisfies the gate"
stamp_file "$CARE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "[\"$(printf '%s' "$TIP" | cut -c1-7)\"]"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "sonnet adversarial pass on 7 chars" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'pr merge'; then
  _pass
else
  _fail "an abbreviated ref must match the tip (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

# A ref SHORTER than git's own floor is a word, not an abbreviation, and must not match.
test_start "a ref shorter than seven characters does NOT match the tip"
stamp_file "$CARE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "[\"$(printf '%s' "$TIP" | cut -c1-4)\"]"
git checkout -q t3 2>/dev/null
OUT="$(SHIP_CARE_FILE="$CARE" bash "$SHIP" open --dry-run --review "four characters is not a sha" 2>&1)"
RC=$?
git checkout -q main
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "names: $(printf '%s' "$TIP" | cut -c1-4)"; then
  _pass
else
  _fail "a 4-char prefix must not satisfy the gate (rc=$RC): $(printf '%s' "$OUT" | head -c 200)"
fi

test_start "ship open --review REJECTS a future stamp (planted, not fresh)"
stamp_file "$CARE" "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" "[\"$TIP\"]"
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
stamp_file "$CARE" "2001-01-01T00:00:00Z" "[\"$TIP\"]"
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
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tip "$TIP" \
  '{last_redteam_iso:{bbbb2222:{ts:$ts, refs:[$tip]}}}' > "$FIX/.maude/plugin/care.json"
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

# The refusal message named whichever candidate care.json was found FIRST, not the one the
# newest stamp actually came from, so it could blame a file that had nothing to do with the
# stamp it was describing. Found 2026-09-04 by the lens on this commit.
test_start "the refusal names the care.json the newest stamp actually came from"
mkdir -p "$FIX/repo/.maude/plugin" "$FIX/.maude/plugin"
printf '{"last_redteam_iso":{}}\n' > "$FIX/repo/.maude/plugin/care.json"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{last_redteam_iso:{cccc3333:{ts:$ts, refs:["deadbeefdeadbeef"]}}}' \
  > "$FIX/.maude/plugin/care.json"
git checkout -q t3 2>/dev/null
OUT="$(bash "$SHIP" open --dry-run --review "a lens ran on the wrong thing" 2>&1)"
RC=$?
git checkout -q main
rm -rf "$FIX/repo/.maude" "$FIX/.maude"
FIXP="$(cd "$FIX" && pwd -P)"   # git resolves symlinks in the root; macOS puts TMPDIR under /var -> /private/var
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "newest stamp in $FIXP/.maude/plugin/care.json"; then
  _pass
else
  _fail "message blamed the wrong file: $(printf '%s' "$OUT" | grep 'newest stamp' | head -c 200)"
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