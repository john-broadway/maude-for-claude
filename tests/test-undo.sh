#!/usr/bin/env bash
# Tests for hooks/scripts/maude-undo.sh — the UNDO pillar.
#
# WHY THIS FILE EXISTS
# --------------------
# UNDO was the last of the six trust-spine pillars (PLAN · CONSENT · PROVE · UNDO ·
# DIAGNOSE · CONTAIN) with nothing behind it. The doctrine's definition is narrow and
# stays narrow: UNDO reverses ONE action. Halting in flight is CONTAIN's job.
#
# The loss that motivates it: on 2026-07-23 three irreplaceable photos died to
#   rm -f <workspace>/*.png <workspace>/*.jpeg
# and the workspace root is NOT a git repository, so nothing local could bring them
# back. v0.25.0's target table now BLOCKS that shape — but a gate must let ordinary
# work through or it gets switched off, and UNDO is what makes letting it through
# survivable. The gate blocks the catastrophic; UNDO catches what it deliberately
# allows.
#
# THE RULE THIS FILE ENFORCES HARDEST
# -----------------------------------
# UNDO is the one pillar that can LIE BY EXISTING. A gate that fails is loud — you
# are blocked and you know it. An UNDO that quietly missed a file is silent until the
# night you reach for it and it is not there. So every skip must be RECORDED and must
# SURFACE in the listing, and these tests assert the skip REASON, never just that
# nothing was captured: several different paths produce "no snapshot", and an exit
# code cannot tell them apart.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

UNDO="$HOOKS_DIR/maude-undo.sh"

# The store registry is user-global ($HOME/.claude/maude). Pin HOME inside the test
# sandbox so this suite cannot write to the real one.
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

undo_dir() { printf '%s' "$CLAUDE_PROJECT_DIR/.maude/plugin/undo"; }
ledger()   { printf '%s' "$(undo_dir)/ledger.jsonl"; }

reset_undo() { rm -rf "$(undo_dir)"; }

# Nth ledger line (1-based), field via jq path.
# NOT `$2 // "null"` — jq's // treats FALSE as empty, so a genuine `existed:false`
# came back as the string "null" and the test failed against correct code. The bug
# was in the helper, not the rail.
ledger_field() { sed -n "$1p" "$(ledger)" 2>/dev/null | jq -r "$2 | if . == null then \"null\" else . end" 2>/dev/null; }
ledger_count() { [ -f "$(ledger)" ] && grep -c . "$(ledger)" 2>/dev/null || printf '0'; }
blob_count()   { find "$(undo_dir)/blobs" -type f 2>/dev/null | wc -l | tr -d ' '; }

write_input() {  # $1 = file_path
  jq -nc --arg p "$1" '{tool_name:"Write", tool_input:{file_path:$p}, hook_event_name:"PreToolUse"}'
}
bash_input() {   # $1 = command
  jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}, hook_event_name:"PreToolUse"}'
}

# ── TIER 1 — Write/Edit/MultiEdit. file_path is IN the payload: no parsing. ──

test_start "capture-write stores the CURRENT bytes, before the edit lands"
reset_undo
printf 'original\n' > "$TEST_TMP/f.txt"
write_input "$TEST_TMP/f.txt" | bash "$UNDO" capture-write
assert_eq "$(cat "$(undo_dir)/blobs/$(ledger_field 1 '.blob')" 2>/dev/null)" "original" "blob holds pre-edit bytes"

test_start "capture-write records the absolute path it captured"
assert_eq "$(ledger_field 1 '.path')" "$TEST_TMP/f.txt" "path recorded"

test_start "capture-write on a file that does not exist records existed:false"
reset_undo
write_input "$TEST_TMP/brand-new.txt" | bash "$UNDO" capture-write
assert_eq "$(ledger_field 1 '.existed')" "false" "new file marked existed:false"

test_start "a non-existent file leaves no blob"
assert_eq "$(blob_count)" "0" "nothing stored for a file with no bytes yet"

test_start "capture-write never blocks (exit 0) even with no target"
printf '{"tool_name":"Write","tool_input":{}}' | bash "$UNDO" capture-write >/dev/null 2>&1
assert_exit "$?" "0" "capture never blocks the tool call"

# ── SKIPS ARE RECORDED, NOT SILENT ──────────────────────────────────────────
# Asserting the REASON, not merely that no blob appeared. too-large, secret-path and
# no-target all produce "no blob"; a test that only checked blob_count would pass for
# the wrong reason under any of them.

test_start "a file over the size cap is skipped, with the reason recorded"
reset_undo
head -c 2000000 /dev/zero > "$TEST_TMP/big.bin"
write_input "$TEST_TMP/big.bin" | bash "$UNDO" capture-write
assert_eq "$(ledger_field 1 '.skip')" "too-large" "skip reason is too-large"

test_start "an over-cap file leaves no blob"
assert_eq "$(blob_count)" "0" "oversized content not stored"

test_start "a secret-shaped path is skipped, with the reason recorded"
reset_undo
printf 'API_KEY=hunter2\n' > "$TEST_TMP/prod.env"
write_input "$TEST_TMP/prod.env" | bash "$UNDO" capture-write
assert_eq "$(ledger_field 1 '.skip')" "secret-path" "skip reason is secret-path"

test_start "a skipped secret leaves NO second copy at rest"
assert_eq "$(blob_count)" "0" "no blob written for a secret path"

test_start "a key file is treated as a secret path too"
reset_undo
printf 'PRIVATE\n' > "$TEST_TMP/id_rsa"
write_input "$TEST_TMP/id_rsa" | bash "$UNDO" capture-write
assert_eq "$(ledger_field 1 '.skip')" "secret-path" "id_rsa skipped"

# ── TIER 2 — Bash. Best-effort, and the reason the pillar exists at all. ─────

test_start "capture-bash snapshots an rm target"
reset_undo
printf 'doomed\n' > "$TEST_TMP/gone.txt"
bash_input "rm -f $TEST_TMP/gone.txt" | bash "$UNDO" capture-bash
assert_eq "$(cat "$(undo_dir)/blobs/$(ledger_field 1 '.blob')" 2>/dev/null)" "doomed" "rm target captured"

test_start "capture-bash marks its lines tier 2"
assert_eq "$(ledger_field 1 '.tier')" "2" "bash capture is tier 2"

# PreToolUse runs BEFORE the shell, so the hook sees a literal asterisk. Expanding it
# here is the only way the 2026-07-23 shape is covered at all.
test_start "capture-bash EXPANDS a glob — the shape that destroyed three photos"
reset_undo
printf 'a\n' > "$TEST_TMP/one.png"; printf 'b\n' > "$TEST_TMP/two.png"
bash_input "rm -f $TEST_TMP/*.png" | bash "$UNDO" capture-bash
assert_eq "$(ledger_count)" "2" "both glob matches captured"

test_start "capture-bash handles mv as well as rm"
reset_undo
printf 'moved\n' > "$TEST_TMP/m.txt"
bash_input "mv $TEST_TMP/m.txt /tmp/elsewhere" | bash "$UNDO" capture-bash
assert_eq "$(ledger_field 1 '.path')" "$TEST_TMP/m.txt" "mv source captured"

test_start "a read-only command captures nothing"
reset_undo
printf 'safe\n' > "$TEST_TMP/keep.txt"
bash_input "ls $TEST_TMP/keep.txt" | bash "$UNDO" capture-bash
assert_eq "$(ledger_count)" "0" "ls is not destructive"

test_start "capture-bash never snapshots the undo store itself"
reset_undo
printf 'x\n' > "$TEST_TMP/seed.txt"
write_input "$TEST_TMP/seed.txt" | bash "$UNDO" capture-write   # make the store exist
BEFORE="$(ledger_count)"
bash_input "rm -rf $(undo_dir)" | bash "$UNDO" capture-bash
assert_eq "$(ledger_count)" "$BEFORE" "store does not snapshot itself"

# ── RESTORE ─────────────────────────────────────────────────────────────────

test_start "restore returns the exact pre-edit bytes"
reset_undo
printf 'original\n' > "$TEST_TMP/r.txt"
write_input "$TEST_TMP/r.txt" | bash "$UNDO" capture-write
printf 'clobbered\n' > "$TEST_TMP/r.txt"
bash "$UNDO" restore 1 >/dev/null 2>&1
assert_eq "$(cat "$TEST_TMP/r.txt")" "original" "bytes restored"

test_start "restore is ITSELF undoable — it snapshots current bytes first"
assert_eq "$(cat "$(undo_dir)/blobs/$(ledger_field 2 '.blob')" 2>/dev/null)" "clobbered" "pre-restore state kept"

test_start "undoing a CREATE deletes the file rather than writing an empty one"
reset_undo
write_input "$TEST_TMP/created.txt" | bash "$UNDO" capture-write
printf 'now here\n' > "$TEST_TMP/created.txt"
bash "$UNDO" restore 1 >/dev/null 2>&1
assert_file_absent "$TEST_TMP/created.txt" "create undone by deletion"

test_start "restore of an unknown seq fails loudly and changes nothing"
reset_undo
printf 'intact\n' > "$TEST_TMP/u.txt"
write_input "$TEST_TMP/u.txt" | bash "$UNDO" capture-write
bash "$UNDO" restore 99 >/dev/null 2>&1
assert_exit "$?" "1" "unknown seq is an error"

test_start "a failed restore left the file untouched"
assert_eq "$(cat "$TEST_TMP/u.txt")" "intact" "no partial write"

# ── LIST — the gaps must be visible ─────────────────────────────────────────

test_start "list shows a captured entry"
reset_undo
printf 'listed\n' > "$TEST_TMP/l.txt"
write_input "$TEST_TMP/l.txt" | bash "$UNDO" capture-write
assert_contains "$(bash "$UNDO" list 2>&1)" "l.txt" "entry surfaced"

test_start "list SURFACES a skip, so the gap is visible rather than assumed"
head -c 2000000 /dev/zero > "$TEST_TMP/big2.bin"
write_input "$TEST_TMP/big2.bin" | bash "$UNDO" capture-write
assert_contains "$(bash "$UNDO" list 2>&1)" "too-large" "skip surfaced in the listing"

test_start "list on an empty store says so instead of erroring"
reset_undo
assert_exit "$(bash "$UNDO" list >/dev/null 2>&1; echo $?)" "0" "empty list exits 0"

# ── CONTENT ADDRESSING ──────────────────────────────────────────────────────

test_start "identical content across two files is stored once"
reset_undo
printf 'same\n' > "$TEST_TMP/a.txt"; printf 'same\n' > "$TEST_TMP/b.txt"
write_input "$TEST_TMP/a.txt" | bash "$UNDO" capture-write
write_input "$TEST_TMP/b.txt" | bash "$UNDO" capture-write
assert_eq "$(blob_count)" "1" "one blob for identical bytes"

test_start "…and both ledger lines still point at it"
assert_eq "$(ledger_count)" "2" "two ledger entries, one blob"

# ── THE WIRING ──────────────────────────────────────────────────────────────
# A rail nothing calls is not a rail. The mission-hold rail was correctly registered
# AND correctly matched and still did nothing for twenty days, so "the script works"
# is not the claim that matters — "the hook that fires actually invokes it" is.
# These drive the REGISTERED hook scripts, not maude-undo.sh directly.

test_start "the registered Write hook actually invokes the undo rail"
reset_undo
printf 'before\n' > "$TEST_TMP/wired.txt"
write_input "$TEST_TMP/wired.txt" | bash "$HOOKS_DIR/maude-pre-tool-use.sh" >/dev/null 2>&1
assert_eq "$(cat "$(undo_dir)/blobs/$(ledger_field 1 '.blob')" 2>/dev/null)" "before" "captured via the real Write hook"

test_start "the registered Bash hook actually invokes the undo rail"
reset_undo
printf 'before\n' > "$TEST_TMP/wired2.txt"
bash_input "rm -f $TEST_TMP/wired2.txt" | bash "$HOOKS_DIR/maude-bash-watch.sh" >/dev/null 2>&1
assert_eq "$(cat "$(undo_dir)/blobs/$(ledger_field 1 '.blob')" 2>/dev/null)" "before" "captured via the real Bash hook"

test_start "reading stdin twice did not break the Write hook's own job"
reset_undo
printf 'x\n' > "$TEST_TMP/still.txt"
write_input "$TEST_TMP/still.txt" | bash "$HOOKS_DIR/maude-pre-tool-use.sh" >/dev/null 2>&1
assert_exit "$?" "0" "pre-tool-use still exits 0"

test_start "reading stdin twice did not break the Bash hook's own gate warning"
OUT="$(bash_input "git push origin main" | bash "$HOOKS_DIR/maude-bash-watch.sh" 2>&1)"
assert_contains "$OUT$(printf '\n')ok" "ok" "bash-watch still runs to completion"

# ── RETENTION ───────────────────────────────────────────────────────────────
# A pruned blob must turn its ledger line into a skip. Otherwise `list` keeps offering
# a restore that would fail at the last step — the listing would be lying about what
# it can put back, which is the exact failure this pillar is most prone to.

test_start "retention prunes an aged blob"
reset_undo
printf 'aged\n' > "$TEST_TMP/old.txt"
write_input "$TEST_TMP/old.txt" | bash "$UNDO" capture-write
touch_ago $((90*86400)) "$(undo_dir)/blobs/$(ledger_field 1 '.blob')"
bash -c ". $HOOKS_DIR/_maude-common.sh; maude_retention_sweep" >/dev/null 2>&1
assert_eq "$(blob_count)" "0" "aged blob removed"

test_start "…and its ledger line becomes a skip, so list stops promising it"
assert_eq "$(ledger_field 1 '.skip')" "pruned" "line rewritten as pruned"

test_start "restore of a pruned entry refuses instead of half-working"
bash "$UNDO" restore 1 >/dev/null 2>&1
assert_exit "$?" "1" "pruned restore is an error"

test_start "a FRESH blob survives the sweep"
reset_undo
printf 'fresh\n' > "$TEST_TMP/new2.txt"
write_input "$TEST_TMP/new2.txt" | bash "$UNDO" capture-write
bash -c ". $HOOKS_DIR/_maude-common.sh; maude_retention_sweep" >/dev/null 2>&1
assert_eq "$(blob_count)" "1" "recent blob kept"

# ── FINDING THE STORE FROM A COMMAND ────────────────────────────────────────
# Hooks get CLAUDE_PROJECT_DIR; the Bash tool does NOT. Measured on the live box:
# the hooks resolved <workspace> and wrote 9 entries, while the same script invoked
# from a Bash call resolved ~ and reported "nothing captured yet". A user whose
# file WAS recoverable would have been told it wasn't — the precise lie this pillar
# is most prone to. So a capture registers its store user-globally, and list/restore
# fall back to that registry rather than claiming an empty store they never found.

test_start "a capture registers its store user-globally"
reset_undo
printf 'registered\n' > "$TEST_TMP/reg.txt"
write_input "$TEST_TMP/reg.txt" | bash "$UNDO" capture-write
assert_contains "$(cat "$HOME/.claude/maude/undo-stores.txt" 2>/dev/null)" "$(undo_dir)" "store path registered"

test_start "list finds the real store when the project dir resolves ELSEWHERE"
OUT="$(MAUDE_PROJECT_DIR_OVERRIDE="$TEST_TMP/nowhere-at-all" bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "reg.txt" "recovered the entry via the registry"

test_start "…and it says WHICH store it read, so the answer is checkable"
assert_contains "$OUT" "$(undo_dir)" "names the store it used"

test_start "with no store anywhere, list says where it looked instead of 'empty'"
OUT2="$(HOME="$TEST_TMP/home-empty" MAUDE_PROJECT_DIR_OVERRIDE="$TEST_TMP/nowhere-at-all" bash "$UNDO" list 2>&1)"
assert_contains "$OUT2" "nowhere-at-all" "names the path it resolved"

# A manual (non-hook) invocation must not mint a store wherever it happens to land.
# On the live box a probe created ~/.maude/plugin/undo, and because the resolver
# walks the filesystem for a .maude/plugin dir, that empty phantom then SHADOWED the
# real store for every later call. The store must only be created where the project
# is actually known.
test_start "a capture with no known project dir creates NO phantom store"
PHANTOM="$TEST_TMP/phantomhome"
mkdir -p "$PHANTOM"
printf 'x\n' > "$PHANTOM/f.txt"
( unset CLAUDE_PROJECT_DIR MAUDE_PROJECT_DIR_OVERRIDE
  cd "$PHANTOM" && write_input "$PHANTOM/f.txt" | bash "$UNDO" capture-write >/dev/null 2>&1 )
assert_file_absent "$PHANTOM/.maude/plugin/undo/ledger.jsonl" "no store minted without a known project"

test_start "a stale/empty local store does not shadow the real one"
# UNDO_DIR for this process points at the sandbox store; the registry holds the same.
# Resolution must pick by freshness, not by mere local presence.
assert_contains "$(MAUDE_PROJECT_DIR_OVERRIDE="$TEST_TMP/nowhere-at-all" bash "$UNDO" list 2>&1)" "reg.txt" "freshest store wins"

test_start "restore also reaches the registered store"
printf 'clobber\n' > "$TEST_TMP/reg.txt"
MAUDE_PROJECT_DIR_OVERRIDE="$TEST_TMP/nowhere-at-all" bash "$UNDO" restore 1 >/dev/null 2>&1
assert_eq "$(cat "$TEST_TMP/reg.txt")" "registered" "restored across the resolution gap"

# ── The listing is newest-first and bounded; the entry a person needs is the first line
# (the UX lens, 2026-09-06, D7: sixty lines oldest-first put the one he wanted last, off
# the top of his scrollback, and he had to read all sixty to find its index). ──
test_start "list prints the newest ten, newest at the top, and says how many more"
reset_undo
for i in $(seq 1 15); do printf 'v%d\n' "$i" > "$TEST_TMP/seq-$i.txt"; write_input "$TEST_TMP/seq-$i.txt" | bash "$UNDO" capture-write >/dev/null 2>&1; done
LIST="$(bash "$UNDO" list 2>&1)"
assert_eq "$(printf '%s\n' "$LIST" | grep -c '^  \[')" "10" "ten entries shown"
assert_contains "$(printf '%s\n' "$LIST" | grep '^  \[' | head -1)" "[15]" "the newest is the first line"
assert_not_contains "$LIST" "[1] " "the oldest is not in the default listing"
assert_contains "$LIST" "+5 more" "the rest are counted"
assert_contains "$LIST" "list --all" "and the way to see them is named"

test_start "list --all shows every entry, still newest first"
LISTALL="$(bash "$UNDO" list --all 2>&1)"
assert_eq "$(printf '%s\n' "$LISTALL" | grep -c '^  \[')" "15" "all fifteen"
assert_contains "$(printf '%s\n' "$LISTALL" | grep '^  \[' | tail -1)" "[1] " "the oldest is last"

test_start "restore last puts back the newest recoverable entry without an index"
printf 'changed\n' > "$TEST_TMP/seq-15.txt"
bash "$UNDO" restore last >/dev/null 2>&1
assert_eq "$(cat "$TEST_TMP/seq-15.txt")" "v15" "the newest capture is back"

# ── the listing and the restore must agree on what "[N]" means, and a bad line must not
# blind either (the 23rd lens, IMPORTANT-1/2: one unparseable line made `list` print the
# header and nothing else at rc 0 and `restore last` say "nothing recoverable"; and
# `list` numbered by jq position while `restore` read by physical line, so a blank line
# made `restore 3` overwrite the file the listing had called [2]). The index IS the
# physical line number, on both sides; an unreadable line is listed as such.
seed_three() {  # three captured files, then an extra line ($1) after the first entry
  reset_undo
  for i in 1 2 3; do printf 'v%s\n' "$i" > "$TEST_TMP/u$i.txt"; write_input "$TEST_TMP/u$i.txt" | bash "$UNDO" capture-write >/dev/null 2>&1; done
  python3 - "$(ledger)" "$1" <<'PY'
import sys
p, extra = sys.argv[1], sys.argv[2]
lines = open(p, encoding="utf-8").read().splitlines()
lines.insert(1, extra)
open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
}

test_start "a MALFORMED ledger line: the other entries are still listed, and the bad one says so"
seed_three "NOT JSON AT ALL"
OUT="$(bash "$UNDO" list 2>&1)"; LRC=$?
assert_exit "$LRC" "0" "list exits 0"
assert_contains "$OUT" "[1] " "the first entry is listed"
assert_contains "$OUT" "[4] " "the last entry is listed"
assert_contains "$OUT" "[2] " "the bad physical line keeps its number"
assert_contains "$OUT" "UNREADABLE" "and is named as unreadable"

test_start "…and restore last puts back the newest READABLE entry"
printf 'clobbered\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore last >/dev/null 2>&1; RRC=$?
assert_exit "$RRC" "0" "restore last succeeds"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "the newest captured file is back"

test_start "…and restore of the unreadable line says so instead of erroring"
ERR="$(bash "$UNDO" restore 2 2>&1 >/dev/null)"; RRC=$?
assert_exit "$RRC" "1" "refused"
assert_contains "$ERR" "not readable" "and says why"

# `try fromjson catch null` catches a PARSE failure, not a line that parses to a non-object:
# `$v.ts` on a number aborted the whole jq stream at rc 0 and the listing lost its oldest
# entries (the 24th lens, IMPORTANT-4: the 23rd's IMPORTANT-1 surviving under a narrower trigger).
test_start "a ledger line that is JSON but NOT AN OBJECT (a bare number): listed as unreadable in place, the rest stand"
seed_three "42"
OUT="$(bash "$UNDO" list 2>&1)"; LRC=$?
assert_exit "$LRC" "0" "list exits 0"
assert_contains "$OUT" "[1] " "the first entry is listed"
assert_contains "$OUT" "[4] " "the last entry is listed"
assert_contains "$OUT" "UNREADABLE" "the number line is named as unreadable"

test_start "…and restore last puts back the newest READABLE entry past the number line"
printf 'clobbered\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore last >/dev/null 2>&1; RRC=$?
assert_exit "$RRC" "0" "restore last succeeds"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "the newest captured file is back"

test_start "…and restore of the number line says not readable"
ERR="$(bash "$UNDO" restore 2 2>&1 >/dev/null)"; RRC=$?
assert_exit "$RRC" "1" "refused"
assert_contains "$ERR" "not readable" "and says why"

# The row is built by string concatenation, so a FIELD of the wrong type raised inside the
# jq program, aborted [inputs] at rc 0 with stderr silenced, and silently dropped the OLDEST
# entries — the 23rd lens's IMPORTANT-1 and the 24th's IMPORTANT-4 for a third round, under
# a narrower trigger each time (the 25th lens, IMPORTANT-4). Make the ROW total, not the
# trigger narrower.
test_start "a ledger object whose path is a NUMBER: listed in place, the entries around it stand"
seed_three '{"ts":"2026-09-06T02:00:00Z","tool":"Write","path":42,"existed":true,"bytes":9}'
OUT="$(bash "$UNDO" list 2>&1)"; LRC=$?
assert_exit "$LRC" "0" "list exits 0"
assert_contains "$OUT" "[1] " "the OLDEST entry survives"
assert_contains "$OUT" "[4] " "the newest entry is listed"
assert_contains "$OUT" "[2] " "the malformed line keeps its number"

test_start "…and restore last still puts back the newest recoverable entry"
printf 'clobbered\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore last >/dev/null 2>&1; RRC=$?
assert_exit "$RRC" "0" "restore last succeeds"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "the newest captured file is back"

test_start "…and restore of the malformed line refuses instead of blaming a pruned blob"
ERR="$(bash "$UNDO" restore 2 2>&1 >/dev/null)"; RRC=$?
assert_exit "$RRC" "1" "refused"
assert_contains "$ERR" "not readable" "and says the entry is not readable"
assert_not_contains "$ERR" "pruned" "never points at a pruned blob"

test_start "a ledger object whose ts is a NUMBER: same, the listing is total"
seed_three '{"ts":1234,"tool":"Write","path":"/tmp/x","existed":true,"bytes":9}'
OUT="$(bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "[1] " "the oldest entry survives a numeric ts"
assert_contains "$OUT" "[4] " "and the newest"

test_start "an EMPTY object at the tail does not capture restore last"
reset_undo
for i in 1 2 3; do printf 'v%s\n' "$i" > "$TEST_TMP/u$i.txt"; write_input "$TEST_TMP/u$i.txt" | bash "$UNDO" capture-write >/dev/null 2>&1; done
printf '{}\n' >> "$(ledger)"
printf 'clobbered\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore last >/dev/null 2>&1; RRC=$?
assert_exit "$RRC" "0" "restore last succeeds past the junk line"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "it put back the real entry, not the {}"

# "" is a string, so the type guard let an empty path through and `restore last` captured
# it and then blamed a pruned blob — the reader who was just clobbered is told the content
# is gone while the row above holds their file (the 26th lens, MINOR-1).
test_start "a row whose path is an EMPTY STRING does not capture restore last (26th lens, MINOR-1)"
reset_undo
for i in 1 2 3; do printf 'v%s\n' "$i" > "$TEST_TMP/u$i.txt"; write_input "$TEST_TMP/u$i.txt" | bash "$UNDO" capture-write >/dev/null 2>&1; done
printf '{"ts":"2026-09-06T05:00:00Z","tool":"Write","path":"","existed":true,"bytes":3}\n' >> "$(ledger)"
printf 'clobbered\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore last >/dev/null 2>&1; RRC=$?
assert_exit "$RRC" "0" "restore last succeeds past the empty-path row"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "it put back the real entry"

test_start "…and the empty-path row is listed as unreadable, not as an entry"
OUT="$(bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "UNREADABLE" "named unreadable"
assert_contains "$OUT" "[1] " "and the entries around it stand"

test_start "a row whose skip is NOT a string still reads as not recoverable (26th lens, MINOR-2)"
reset_undo
printf 'v1\n' > "$TEST_TMP/u1.txt"; write_input "$TEST_TMP/u1.txt" | bash "$UNDO" capture-write >/dev/null 2>&1
printf '{"ts":"2026-09-06T04:00:00Z","tool":"Write","path":"/x/q","skip":{"why":"too big"},"existed":true,"bytes":3}\n' >> "$(ledger)"
OUT="$(bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "NOT RECOVERABLE" "the listing says so"
assert_not_contains "$OUT" "(created" "it does not invite a delete"

test_start "…and one whose skip is an array, on a row that claims it was created"
reset_undo
printf 'v1\n' > "$TEST_TMP/u1.txt"; write_input "$TEST_TMP/u1.txt" | bash "$UNDO" capture-write >/dev/null 2>&1
printf '{"ts":"2026-09-06T04:00:00Z","tool":"Write","path":"/x/q","skip":["too big"],"existed":false,"bytes":3}\n' >> "$(ledger)"
OUT="$(bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "NOT RECOVERABLE" "still not recoverable"

# jq's `//` treats `false` as absent, so the listing said NOT RECOVERABLE while the reader
# that ACTS saw no skip and deleted the file (the 27th lens, IMPORTANT-5).
test_start "a row whose skip is FALSE is refused by restore, not acted on (27th lens, IMPORTANT-5)"
reset_undo
printf 'v1\n' > "$TEST_TMP/u1.txt"; write_input "$TEST_TMP/u1.txt" | bash "$UNDO" capture-write >/dev/null 2>&1
printf 'REAL\n' > "$TEST_TMP/uskip.txt"
printf '{"ts":"2026-09-06T04:00:00Z","tool":"Write","path":"%s","skip":false,"existed":false,"bytes":5}\n' "$TEST_TMP/uskip.txt" >> "$(ledger)"
ERR="$(bash "$UNDO" restore 2 2>&1 >/dev/null)"; RRC=$?
assert_exit "$RRC" "1" "refused"
assert_contains "$ERR" "never captured" "and says it was never captured"
assert_file_exists "$TEST_TMP/uskip.txt" "the file is NOT deleted"

# A path that is only whitespace names no file. The 25th lens found `{}`, the 26th found "",
# this is the third round on the same three lines (the 27th lens, IMPORTANT-8).
test_start "a path that is ONLY WHITESPACE does not capture restore last (27th lens, IMPORTANT-8)"
reset_undo
for i in 1 2 3; do printf 'v%s\n' "$i" > "$TEST_TMP/u$i.txt"; write_input "$TEST_TMP/u$i.txt" | bash "$UNDO" capture-write >/dev/null 2>&1; done
printf '{"ts":"2026-09-06T05:00:00Z","tool":"Write","path":"   ","existed":true,"bytes":3}\n' >> "$(ledger)"
printf 'clobbered\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore last >/dev/null 2>&1; RRC=$?
assert_exit "$RRC" "0" "restore last succeeds past the whitespace row"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "it put back the real entry"

test_start "…and the whitespace row is listed as unreadable"
OUT="$(bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "UNREADABLE" "named unreadable"

# THREE readers of `.skip` used three tests and agreed on every value but one: `""` is
# `!= null` so the listing calls it a skip, and `tostring` of it is empty so the actor proceeds
# and overwrites (or deletes) the file (the 28th lens, IMPORTANT-5). The class-correct test is
# presence, which two of the three already used.
test_start "a row whose skip is an EMPTY STRING is refused by restore, not acted on (28th lens, IMPORTANT-5)"
reset_undo
printf 'v1\n' > "$TEST_TMP/u1.txt"; write_input "$TEST_TMP/u1.txt" | bash "$UNDO" capture-write >/dev/null 2>&1
printf 'REAL\n' > "$TEST_TMP/uskip2.txt"
printf '{"ts":"2026-09-06T04:00:00Z","tool":"Write","path":"%s","skip":"","existed":true,"bytes":5}\n' "$TEST_TMP/uskip2.txt" >> "$(ledger)"
ERR="$(bash "$UNDO" restore 2 2>&1 >/dev/null)"; RRC=$?
assert_exit "$RRC" "1" "refused"
assert_eq "$(cat "$TEST_TMP/uskip2.txt")" "REAL" "the file is untouched"

test_start "…and one that was recorded as created is not deleted either"
reset_undo
printf 'v1\n' > "$TEST_TMP/u1.txt"; write_input "$TEST_TMP/u1.txt" | bash "$UNDO" capture-write >/dev/null 2>&1
printf 'REAL\n' > "$TEST_TMP/ucre.txt"
printf '{"ts":"2026-09-06T04:00:00Z","tool":"Write","path":"%s","skip":"","existed":false,"bytes":5}\n' "$TEST_TMP/ucre.txt" >> "$(ledger)"
bash "$UNDO" restore 2 >/dev/null 2>&1
assert_file_exists "$TEST_TMP/ucre.txt" "the file is NOT deleted"

test_start "a path named with a non-breaking space is a real path, not whitespace (28th lens, MINOR-10)"
reset_undo
NBSP="$TEST_TMP/$(printf 'nb\xc2\xa0sp').txt"
printf 'REAL\n' > "$NBSP"
printf 'v1\n' > "$TEST_TMP/u1.txt"; write_input "$TEST_TMP/u1.txt" | bash "$UNDO" capture-write >/dev/null 2>&1
jq -nc --arg p "$NBSP" '{ts:"2026-09-06T06:00:00Z",tool:"Write",path:$p,existed:true,bytes:5}' >> "$(ledger)"
OUT="$(bash "$UNDO" list 2>&1)"
assert_not_contains "$OUT" "UNREADABLE" "a non-breaking space in a filename is not an unreadable row"

test_start "a BLANK ledger line: list and restore number the same physical lines"
seed_three ""
OUT="$(bash "$UNDO" list 2>&1)"
assert_contains "$OUT" "[3] " "the second entry is physical line 3"
assert_not_contains "$OUT" "[2] " "the blank line is not an entry"
printf 'clobbered\n' > "$TEST_TMP/u2.txt"; printf 'v3\n' > "$TEST_TMP/u3.txt"
bash "$UNDO" restore 3 >/dev/null 2>&1
assert_eq "$(cat "$TEST_TMP/u2.txt")" "v2" "restore 3 put back the file the listing called [3]"
assert_eq "$(cat "$TEST_TMP/u3.txt")" "v3" "and touched nothing else"

print_summary
teardown_test_env
exit $FAILED
