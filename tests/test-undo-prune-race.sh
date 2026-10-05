#!/usr/bin/env bash
# The undo ledger's prune under concurrent session starts.
#
# Found 2026-09-27 on the live closet: the ledger's first 999,424 bytes were NUL (exactly
# 244 pages), a torn line after them, 3,957 survivors, and jq had failed on it in silence
# at every wake since. Five lanes share one closet and every SessionStart ran the sweep
# unlocked, each writing the SAME `ledger.jsonl.tmp`: a peer's `>` truncated the file a
# live jq was still writing at a page-aligned offset, the peer died (a hook killed at its
# budget leaves no trace), and the survivor's mv installed the hole. So: the prune runs
# under a lock (busy = another lane has it, skip), its temp names are per-process, a
# zero-filled head is healed with the damaged bytes kept, and a skip or a jq failure is
# a trace row, never `2>/dev/null` and nothing.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common
export MAUDE_SESSION_LABEL="prune-test"
command -v pgrep >/dev/null 2>&1 || { printf '%s: pgrep absent; the peer tree cannot be killed parent-first, refusing\n' "$(basename "$0")" >&2; exit 2; }

SELF="$(maude_self_dir)"; UNDO="$SELF/undo"; L="$UNDO/ledger.jsonl"
CTL="$TEST_TMP/ctl"; mkdir -p "$CTL"

plant_ledger() {  # <lines> — jq-compact lines, every blob present, so an honest prune is the identity
  local n="$1" i
  rm -rf "$UNDO"; mkdir -p "$UNDO/blobs"
  for i in $(seq 1 "$n"); do
    printf '{"ts":"2026-09-01T00:00:00Z","tool":"Edit","path":"/x/%d","tier":1,"existed":true,"bytes":1,"blob":"b%d"}\n' "$i" "$i"
    : > "$UNDO/blobs/b$i"
  done > "$L"
}
sweep_bg() {  # background sweep in its own process; pid in SWEEP_PID (a $( ) would make it nobody's child)
  bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1 &
  SWEEP_PID="$!"
}
wait_for() {  # <file> [pid] — until the file exists, or the pid is gone; bounded
  local i; for i in $(seq 1 100); do
    [ -e "$1" ] && return 0
    [ -n "${2:-}" ] && ! kill -0 "$2" 2>/dev/null && return 1
    sleep 0.05
  done; return 1
}
# The whole tree at once, PARENT FIRST: a hook killed at budget dies with its shell. Killing
# the leaf first lets the parent shell run on to its `rm -f`, which is a different failure.
tree_pids() { local c; printf '%s\n' "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$c"; done; }
kill_tree() { tree_pids "$1" | xargs kill -9 2>/dev/null; }
temp_left() {  # every per-process temp prefix the prune uses, by glob, counted
  local f n=0
  for f in "$UNDO"/.prune.[0-9]* "$UNDO"/.blobs.[0-9]* "$UNDO"/.snap.[0-9]* "$UNDO"/.out.[0-9]* "$UNDO"/.nums.[0-9]*; do  # (.nums.<pid>.p/.q probes match this glob too)
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}
nul_count() { tr -cd '\000' < "$L" | wc -c | tr -d ' '; }
trace_rows() { grep -c "\"kind\":\"undo-prune\"" "$(maude_trace_file)" 2>/dev/null || printf 0; }

# A jq that stands in only for the prune's own call (the one carrying --rawfile; every
# other call reaches real jq). First prune call: write one page of the ledger, mark, hold
# until released, write the rest — a live writer caught mid-file. Second: mark and hang
# (a peer whose shell already truncated its target and is then killed at budget), or exit
# 3 when told to (a jq failure).
REAL_JQ="$(command -v jq)"
SHIM="$(_mk_shim_dir)"
cat > "$SHIM/jq" <<SHIMEOF
#!/usr/bin/env bash
case " \$* " in *" --rawfile "*) ;; *) exec '$REAL_JQ' "\$@" ;; esac
[ -e '$CTL/fail-first' ] && { rm -f '$CTL/fail-first'; exit 3; }
if [ ! -e '$CTL/marker-a' ]; then
  for L; do :; done          # the last argument is the ledger (bash 3.2 has no negative slice)
  cat "\$L" > '$CTL/snap'   # jq reads its input to EOF before it writes: snapshot first
  [ -s '$CTL/snap' ] || { echo 'shim: empty snapshot' > '$CTL/shim-error'; exit 9; }
  : > '$CTL/marker-a'
  head -c 4096 '$CTL/snap'
  for i in \$(seq 1 200); do [ -e '$CTL/go' ] && break; sleep 0.05; done
  tail -c +4097 '$CTL/snap'
  exit 0
fi
: > '$CTL/marker-b'
sleep 60
SHIMEOF
chmod +x "$SHIM/jq"

# ── one lane mid-prune, a second lane starts ────────────────────────────────────────
plant_ledger 300
BEFORE="$(file_digest "$L")"
PATH="$SHIM:$PATH" sweep_bg; A="$SWEEP_PID"
wait_for "$CTL/marker-a" "$A"; assert_exit "$?" "0" "fixture: the first sweep is inside its prune"
PATH="$SHIM:$PATH" sweep_bg; B="$SWEEP_PID"
wait_for "$CTL/marker-b" "$B"
B_RAN="$([ -e "$CTL/marker-b" ] && echo yes || echo no)"
kill_tree "$B"; wait "$B" 2>/dev/null
: > "$CTL/go"; wait "$A"

test_start "fixture: the jq stand-in read a non-empty ledger (else every assertion below passes on nothing)"
[ ! -e "$CTL/shim-error" ]; assert_exit "$?" "0" "no shim error"

test_start "a second sweep does not enter the prune while another lane holds it"
assert_eq "$B_RAN" "no" "the peer's jq never ran (lock busy → skip)"

test_start "…and the skip is a trace row, not silence"
assert_eq "$(grep -c '"kind":"undo-prune".*busy' "$(maude_trace_file)" 2>/dev/null)" "1" "one undo-prune busy row"

test_start "a peer's truncation cannot zero-fill the ledger the survivor installs"
assert_eq "$(nul_count)" "0" "no NUL byte in the ledger"
assert_eq "$(grep -c . "$L")" "300" "every line still there"
jq -e . "$L" >/dev/null 2>&1; assert_exit "$?" "0" "the ledger parses"
assert_eq "$(file_digest "$L")" "$BEFORE" "byte-identical: the identity prune changed nothing"

# ── the prune's jq fails ───────────────────────────────────────────────────────────
test_start "a jq failure leaves the ledger as it was and writes a trace row with the rc"
plant_ledger 20; BEFORE="$(file_digest "$L")"
: > "$CTL/fail-first"
PATH="$SHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(file_digest "$L")" "$BEFORE" "ledger untouched"
assert_eq "$(grep -c '"kind":"undo-prune".*jq=3' "$(maude_trace_file)" 2>/dev/null)" "1" "one undo-prune jq=3 row"
assert_eq "$(temp_left)" "0" "no temp file of any prefix left behind"

# ── a zero-filled head is healed, the damaged bytes kept ───────────────────────────
test_start "a ledger with a NUL head and a torn line is healed by the sweep"
plant_ledger 50
{ head -c 4096 /dev/zero; printf 'ojects/torn","tier":1}\n'; cat "$L"; } > "$L.planted"
cp "$L.planted" "$L"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(nul_count)" "0" "NULs gone"
assert_eq "$(grep -c . "$L")" "50" "the torn fragment dropped, the 50 whole lines kept"
jq -e . "$L" >/dev/null 2>&1; assert_exit "$?" "0" "the ledger parses"
HOLE="$(ls "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | head -1)"
[ -n "$HOLE" ] && cmp -s "$HOLE" "$L.planted"; assert_exit "$?" "0" "the damaged bytes are kept beside the ledger, byte-exact"

# ── the heal cannot write its hole copy (lens 1: this was logged as "busy", and the partial copy stayed) ──
test_start "a heal whose hole copy cannot be written says so, leaves no partial copy, and touches nothing"
plant_ledger 50
{ head -c 4096 /dev/zero; printf 'ojects/torn","tier":1}\n'; cat "$L"; } > "$L.planted"; cp "$L.planted" "$L"
: > "$(maude_trace_file)"
# RLIMIT_FSIZE of one block: the cp of a 4 KB+ file dies on SIGXFSZ; the trace row (tens of bytes) does not.
(ulimit -f 1; bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1)
assert_eq "$(grep -c '"kind":"undo-prune".*heal=cp-failed' "$(maude_trace_file)" 2>/dev/null)" "1" "one heal=cp-failed row"
assert_eq "$(grep -c 'busy' "$(maude_trace_file)" 2>/dev/null)" "0" "not called busy"
assert_eq "$(ls "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | wc -l | tr -d ' ')" "0" "no partial hole copy left"
cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"

# ── a ledger that heals to nothing (lens 4: the empty result read as a jq failure, jq=0) ──
test_start "a ledger that is all NUL heals to empty with the copy kept and no jq row"
plant_ledger 1; head -c 8192 /dev/zero > "$L"; cp "$L" "$L.planted"
: > "$(maude_trace_file)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
SZ="$(stat -c %s "$L" 2>/dev/null)"; [ -n "$SZ" ] || SZ="$(stat -f %z "$L" 2>/dev/null)"
assert_eq "$SZ" "0" "healed to empty"
HOLE="$(ls "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | head -1)"
[ -n "$HOLE" ] && cmp -s "$HOLE" "$L.planted"; assert_exit "$?" "0" "the damaged bytes kept, byte-exact"
assert_eq "$(grep -c '"kind":"undo-prune".*healed=nul-head' "$(maude_trace_file)" 2>/dev/null)" "1" "one healed row"
assert_eq "$(grep -c '"kind":"undo-prune".*jq=' "$(maude_trace_file)" 2>/dev/null)" "0" "no jq row: nothing failed"

# ── two heals inside one second (lens round 2, A: the hole name was second-granular) ──
# A date that answers the hole-name format with one pinned stamp and hands every other call
# to the real date, so the trace's own timestamps stay real.
REAL_DATE="$(command -v date)"
DSHIM="$(_mk_shim_dir)"   # its own dir: the jq shim beside it would hang these sweeps
cat > "$DSHIM/date" <<DATEEOF
#!/usr/bin/env bash
case " \$* " in *" +%Y%m%dT%H%M%SZ "*) printf '20260927T120000Z\n'; exit 0 ;; esac
exec '$REAL_DATE' "\$@"
DATEEOF
chmod +x "$DSHIM/date"
corrupt_with() {  # <marker> — a NUL head, a torn line carrying the marker, then the planted lines
  { head -c 4096 /dev/zero; printf 'torn-%s"}\n' "$1"; cat "$L.clean"; } > "$L"
}
test_start "a second heal in the same second keeps the first heal's damaged bytes"
plant_ledger 20; cp "$L" "$L.clean"; rm -f "$UNDO"/ledger.jsonl.hole-*
corrupt_with AAAA; cp "$L" "$L.plantA"
PATH="$DSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
corrupt_with BBBB; cp "$L" "$L.plantB"
PATH="$DSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
corrupt_with EEEE   # a third: the first fold's name loop lost the stamp on the third collision
PATH="$DSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(ls "$UNDO"/ledger.jsonl.hole-20260927T120000Z* 2>/dev/null | wc -l | tr -d ' ')" "3" "three hole copies, all carrying the stamp"
assert_eq "$(cat "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | grep -c 'torn-AAAA')" "1" "the first heal's bytes survive"
assert_eq "$(cat "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | grep -c 'torn-BBBB')" "1" "the second's too"
assert_eq "$(cat "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | grep -c 'torn-EEEE')" "1" "and the third's"

test_start "a failed heal in the same second does not delete an earlier heal's copy"
rm -f "$UNDO"/ledger.jsonl.hole-*; corrupt_with CCCC; cp "$L" "$L.plantC"
PATH="$DSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
HOLE="$(ls "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | head -1)"
[ -n "$HOLE" ] && cmp -s "$HOLE" "$L.plantC"; assert_exit "$?" "0" "fixture: the first heal's copy is there"
corrupt_with DDDD
(ulimit -f 1; PATH="$DSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1)
[ -n "$HOLE" ] && cmp -s "$HOLE" "$L.plantC"; assert_exit "$?" "0" "the earlier copy is still there, byte-exact"
assert_eq "$(ls "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | wc -l | tr -d ' ')" "1" "and no partial copy beside it"

test_start "a dangling symlink at the hole name is stepped past, never written through or removed"
rm -f "$UNDO"/ledger.jsonl.hole-*; ln -s "$TEST_TMP/nowhere/victim" "$L.hole-20260927T120000Z"
corrupt_with FFFF; cp "$L" "$L.plantF"
PATH="$DSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
[ -L "$L.hole-20260927T120000Z" ]; assert_exit "$?" "0" "the symlink is still there"
[ -e "$TEST_TMP/nowhere/victim" ]; assert_exit "$?" "1" "nothing was written through it"
cmp -s "$L.hole-20260927T120000Z-2" "$L.plantF"; assert_exit "$?" "0" "the copy landed on the next free name, byte-exact"

# ── a capture lands while the prune holds the lock (residual 2, his "go" 09-27 18:50Z) ──
UNDO_SH="$HOOKS_DIR/maude-undo.sh"
write_input() { jq -nc --arg p "$1" '{tool_name:"Write", tool_input:{file_path:$p}, hook_event_name:"PreToolUse"}'; }
test_start "a capture appended while the prune holds the lock is in the ledger after the prune, and the capture did not hang"
plant_ledger 300; rm -f "$CTL/marker-a" "$CTL/marker-b" "$CTL/go" "$CTL/snap"
PATH="$SHIM:$PATH" sweep_bg; A="$SWEEP_PID"
wait_for "$CTL/marker-a" "$A"; assert_exit "$?" "0" "fixture: the prune has read the ledger and holds the lock"
printf 'captured\n' > "$TEST_TMP/cap.txt"
T0="$(date +%s)"
write_input "$TEST_TMP/cap.txt" | bash "$UNDO_SH" capture-write </dev/stdin >/dev/null 2>&1
T1="$(date +%s)"
[ $((T1 - T0)) -le 3 ]; assert_exit "$?" "0" "the capture returned within 3 s ($((T1 - T0)) s): a held prune never blocks the tool call"
: > "$CTL/go"; wait "$A"
assert_eq "$(grep -c . "$L")" "301" "300 planted + the capture, none lost"
assert_eq "$(grep -c "cap.txt" "$L")" "1" "the captured path is in the ledger"
jq -e . "$L" >/dev/null 2>&1; assert_exit "$?" "0" "the ledger parses"

# Hold locks the way THIS host's maude_locked will look for them: flock where it exists, the
# fallback's fresh lock dir where it does not (macOS). A flock holder on a host with no flock
# held nothing, and the "next lock still waits" tests read 11 ms (PR #81).
hold_locks() {
  HELD_DIRS=""; HOLD=""
  if command -v flock >/dev/null 2>&1; then
    local s="" f fd=9
    for f in "$@"; do s="$s exec $fd>\"$f\"; flock $fd;"; fd=$((fd - 1)); done
    bash -c "$s sleep 6" & HOLD=$!
    sleep 0.3
  else
    for f in "$@"; do mkdir "$f.d"; HELD_DIRS="$HELD_DIRS $f.d"; done
  fi
}
release_locks() {
  [ -n "$HOLD" ] && { kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; }
  local d; for d in $HELD_DIRS; do rmdir "$d" 2>/dev/null; done
  HOLD=""; HELD_DIRS=""
}

# ── a wait-0 busy must not silence the next lock's wait (residual 1: the process-wide latch) ──
test_start "a busy at wait 0 leaves the next lock its own wait; a busy at a real wait still latches"
LK="$TEST_TMP/lk"; mkdir -p "$LK"
hold_locks "$LK/a" "$LK/b"
read -r E1 E2 E3 < <(bash -c '
  . "'"$HOOKS_DIR"'/_maude-common.sh"; ms() { python3 -c "import time; print(int(time.time()*1000))"; }
  t0=$(ms); MAUDE_LOCK_WAIT=0 maude_locked "'"$LK"'/a" true; r1=$?; t1=$(ms)
  maude_locked "'"$LK"'/b" true; r2=$?; t2=$(ms)          # default wait 2: must still wait
  maude_locked "'"$LK"'/a" true; r3=$?; t3=$(ms)          # after a REAL busy: latched, fast
  printf "%s %s %s\n" $((t1-t0)) $((t2-t1)) $((t3-t2))
' </dev/null)
release_locks
[ "$E1" -lt 500 ]; assert_exit "$?" "0" "wait-0 busy returned at once (${E1} ms)"
[ "$E2" -ge 1500 ]; assert_exit "$?" "0" "the next lock still waited its own 2 s (${E2} ms)"
[ "$E3" -lt 500 ]; assert_exit "$?" "0" "control: after a real busy the latch makes the third fast (${E3} ms)"

test_start "a wait-0 busy on an unopenable lock path does not latch either (lens on 4b34521, M3)"
LK2="$TEST_TMP/lk2"; mkdir -p "$LK2"; : > "$LK2/notadir"
hold_locks "$LK2/held"
E="$(bash -c '
  . "'"$HOOKS_DIR"'/_maude-common.sh"; ms() { python3 -c "import time; print(int(time.time()*1000))"; }
  MAUDE_LOCK_WAIT=0 maude_locked "'"$LK2"'/notadir/lock" true
  t0=$(ms); maude_locked "'"$LK2"'/held" true; t1=$(ms)
  printf "%s" $((t1-t0))
' </dev/null)"
release_locks
[ "${E:-0}" -ge 1500 ]; assert_exit "$?" "0" "the next lock still waited its own 2 s (${E} ms)"

test_start "a heal whose size count fails says so and does not log a heal (lens on 4b34521, M2)"
WSHIM="$(_mk_shim_dir)"; REAL_WC="$(command -v wc)"
cat > "$WSHIM/wc" <<WCEOF
#!/usr/bin/env bash
case " \$* " in *" -c "*) exit 1 ;; esac
exec '$REAL_WC' "\$@"
WCEOF
chmod +x "$WSHIM/wc"
plant_ledger 20; { head -c 4096 /dev/zero; printf 'torn"}\n'; cat "$L"; } > "$L.planted"; cp "$L.planted" "$L"
: > "$(maude_trace_file)"
PATH="$WSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(grep -c 'healed=nul-head' "$(maude_trace_file)" 2>/dev/null)" "0" "no heal claimed"
assert_eq "$(grep -c 'heal=rewrite-failed' "$(maude_trace_file)" 2>/dev/null)" "1" "the failure names itself"
cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"

# ── a ledger with bytes but no lines, on an ordinary sweep (lens round 2, B) ──
test_start "a ledger holding only a newline logs no jq row on any later sweep"
plant_ledger 1; printf '\n' > "$L"; : > "$(maude_trace_file)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(grep -c '"kind":"undo-prune".*jq=' "$(maude_trace_file)" 2>/dev/null)" "0" "no jq row"

# ── a torn line (a short write: disk full, a killed writer) is quarantined, not fatal ──
# Before: jq failed on the one bad line and every later prune logged jq=5 with the ledger
# untouched, forever (lens on 4b34521, the named residual; his "merge it when the lens is
# clean" 09-28). Now the bad line moves to ledger.jsonl.torn-<utc>, byte-exact, the rest
# is pruned as usual, and the trace says how many.
torn_files() { ls "$UNDO"/ledger.jsonl.torn-* 2>/dev/null | wc -l | tr -d ' '; }
test_start "a torn LAST line is quarantined byte-exact and the rest prunes"
plant_ledger 20; rm -f "$UNDO"/ledger.jsonl.torn-*
printf '{"ts":"2026-09-01T00:00:00Z","tool":"Edit","path":"/x/torn-tail' >> "$L"
: > "$(maude_trace_file)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
jq -e . "$L" >/dev/null 2>&1; assert_exit "$?" "0" "the ledger parses"
assert_eq "$(grep -c . "$L")" "20" "the 20 whole lines kept"
assert_eq "$(torn_files)" "1" "one quarantine file"
assert_eq "$(cat "$UNDO"/ledger.jsonl.torn-* 2>/dev/null)" '{"ts":"2026-09-01T00:00:00Z","tool":"Edit","path":"/x/torn-tail' "it holds the torn bytes exactly"
assert_eq "$(grep -c '"kind":"undo-prune".*torn=1' "$(maude_trace_file)" 2>/dev/null)" "1" "a torn=1 trace row"
: > "$(maude_trace_file)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(grep -c '"kind":"undo-prune"' "$(maude_trace_file)" 2>/dev/null)" "0" "the next sweep is clean: no jq row, nothing torn"

test_start "a torn line in the MIDDLE (a short write, then a later append joined to it) is quarantined"
plant_ledger 10; rm -f "$UNDO"/ledger.jsonl.torn-*
head -5 "$L" > "$L.a"; tail -n +6 "$L" > "$L.b"
{ cat "$L.a"; printf '{"ts":"2026-09-01T00:00:00Z","path":"/x/half'; cat "$L.b"; } > "$L"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
jq -e . "$L" >/dev/null 2>&1; assert_exit "$?" "0" "the ledger parses"
assert_eq "$(grep -c . "$L")" "9" "nine whole lines kept (the joined line holds line 6)"
assert_eq "$(grep -c 'x/half' "$UNDO"/ledger.jsonl.torn-* 2>/dev/null)" "1" "the joined line is in quarantine"

test_start "a torn line with invalid UTF-8 is quarantined byte-exact (lens on d73f0cf, MAJOR)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
printf '{"path":"a\377\376b"\n' > "$CTL/u8-line"
cat "$CTL/u8-line" >> "$L"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
cmp -s "$CTL/u8-line" "$(ls "$UNDO"/ledger.jsonl.torn-* 2>/dev/null | head -1)"; assert_exit "$?" "0" "the quarantine holds the exact bytes, invalid ones included"
assert_eq "$(grep -c . "$L")" "5" "the five whole lines kept"

test_start "a failed write of the kept lines leaves the ledger untouched and says so (lens on d73f0cf, BLOCKING)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
printf '{"path":"torn-tail' >> "$L"; cp "$L" "$L.planted"
GSHIM="$(_mk_shim_dir)"; REAL_GREP="$(command -v grep)"
cat > "$GSHIM/grep" <<GEOF
#!/usr/bin/env bash
case " \$* " in *" -v "*) exit 2 ;; esac
exec '$REAL_GREP' "\$@"
GEOF
chmod +x "$GSHIM/grep"
: > "$(maude_trace_file)"
PATH="$GSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"
assert_eq "$(grep -c 'keep-failed' "$(maude_trace_file)" 2>/dev/null)" "1" "a keep-failed trace row"
assert_eq "$(grep -c '"payload":"torn=1"' "$(maude_trace_file)" 2>/dev/null)" "0" "no bare torn=1 row that reads as success"
assert_eq "$(torn_files)" "0" "no quarantine copy left for a line still in the ledger"

test_start "a kept-lines write that loses its tail but keeps the line count installs nothing (lens r2 on dbe6db9, BLOCKING 1)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*; cp "$L" "$L.planted"
TSHIM="$(_mk_shim_dir)"
cat > "$TSHIM/grep" <<TEOF
#!/usr/bin/env bash
case " \$* " in *" -v "*) '$REAL_GREP' "\$@" | head -c -10; exit 0 ;; esac
exec '$REAL_GREP' "\$@"
TEOF
chmod +x "$TSHIM/grep"
: > "$(maude_trace_file)"
PATH="$TSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"
assert_eq "$(grep -c 'keep-failed' "$(maude_trace_file)" 2>/dev/null)" "1" "a keep-failed trace row"

test_start "25,000 torn lines in one sweep are all quarantined (lens r2 on dbe6db9, BLOCKING 2: one argv string capped the sed script)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
seq 1 25000 | sed 's/^/{"path":"torn-/' >> "$L"
: > "$(maude_trace_file)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(grep -c . "$L")" "5" "the five whole lines kept"
assert_eq "$(cat "$UNDO"/ledger.jsonl.torn-* 2>/dev/null | wc -l | tr -d ' ')" "25000" "all 25,000 in quarantine"
assert_eq "$(grep -c '"payload":"torn=25000"' "$(maude_trace_file)" 2>/dev/null)" "1" "a torn=25000 row"

test_start "60,000 torn lines quarantine inside 5 s (lens r3 on e6bde20, BLOCKING: one sed address per torn line was addresses x lines, 54 s at 100,000)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
seq 1 60000 | sed 's/^/{"path":"torn-/' >> "$L"
T0="$(date +%s)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
T1="$(date +%s)"
[ $((T1 - T0)) -le 5 ]; assert_exit "$?" "0" "the sweep took $((T1 - T0)) s"
assert_eq "$(grep -c . "$L")" "5" "the five whole lines kept"
assert_eq "$(cat "$UNDO"/ledger.jsonl.torn-* 2>/dev/null | wc -l | tr -d ' ')" "60000" "all 60,000 in quarantine"
assert_eq "$(temp_left)" "0" "no temp of any prefix left behind"

test_start "a quarantine copy short of the torn count installs nothing (lens r4: copy-failed had never been driven)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
printf '{"path":"torn-A\n{"path":"torn-B\n' >> "$L"; cp "$L" "$L.planted"
ASHIM="$(_mk_shim_dir)"; REAL_AWK="$(command -v awk)"
cat > "$ASHIM/awk" <<AEOF
#!/usr/bin/env bash
'$REAL_AWK' "\$@" | sed '\$d'
AEOF
chmod +x "$ASHIM/awk"
: > "$(maude_trace_file)"
PATH="$ASHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"
assert_eq "$(grep -c 'torn=2 copy-failed' "$(maude_trace_file)" 2>/dev/null)" "1" "a copy-failed row"
assert_eq "$(torn_files)" "0" "no partial quarantine file"
assert_eq "$(temp_left)" "0" "no temp left"

# This host's awk decides which branch is right: the macOS awk drops a record after a NUL,
# so there the sweep must REFUSE and keep the ledger, not quarantine (PR #81 read the
# refusal as a failure). The probe is the product's own program.
printf '{"path":"a\000AFTER-THE-NUL\n' > "$CTL/nul-line"
printf '1\n' > "$CTL/nul.p"; printf 'a\000b\n' > "$CTL/nul.q"
NUL_SAFE=0; [ "$(LC_ALL=C awk 'NR == FNR { t[$1]; next } (FNR in t)' "$CTL/nul.p" "$CTL/nul.q" 2>/dev/null | wc -c | tr -d ' ')" = 4 ] && NUL_SAFE=1
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
cat "$CTL/nul-line" >> "$L"; cp "$L" "$L.planted"
: > "$(maude_trace_file)"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
if [ "$NUL_SAFE" = 1 ]; then
  test_start "a torn line holding a NUL byte is quarantined byte-exact with a NUL-safe awk"
  cmp -s "$CTL/nul-line" "$(ls "$UNDO"/ledger.jsonl.torn-* 2>/dev/null | head -1)"; assert_exit "$?" "0" "the quarantine holds the bytes after the NUL"
  assert_eq "$(grep -c . "$L")" "5" "the five whole lines kept"
else
  test_start "this host's awk drops bytes after a NUL: the sweep refuses, named, and keeps the ledger"
  cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"
  assert_eq "$(grep -c 'nul-unsafe-awk' "$(maude_trace_file)" 2>/dev/null)" "1" "a nul-unsafe-awk row"
  assert_eq "$(torn_files)" "0" "no short quarantine copy"
fi

if command -v busybox >/dev/null 2>&1 && busybox awk 1 </dev/null >/dev/null 2>&1; then
test_start "an awk that truncates at a NUL is refused loudly, never trusted for the copy (busybox; the BSD awk on macOS is documented the same)"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
cat "$CTL/nul-line" >> "$L"; cp "$L" "$L.planted"
BSHIM="$(_mk_shim_dir)"; BB="$(command -v busybox)"
printf '#!/usr/bin/env bash\nexec %s awk "$@"\n' "$BB" > "$BSHIM/awk"; chmod +x "$BSHIM/awk"
: > "$(maude_trace_file)"
PATH="$BSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
cmp -s "$L" "$L.planted"; assert_exit "$?" "0" "the ledger is exactly as it was"
assert_eq "$(grep -c 'nul-unsafe-awk' "$(maude_trace_file)" 2>/dev/null)" "1" "a nul-unsafe-awk row"
assert_eq "$(torn_files)" "0" "no short quarantine copy"
assert_eq "$(temp_left)" "0" "no temp left"
test_start "control: the same busybox awk quarantines a torn line with no NUL"
plant_ledger 5; rm -f "$UNDO"/ledger.jsonl.torn-*
printf '{"path":"plain-torn\n' >> "$L"
PATH="$BSHIM:$PATH" bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(torn_files)" "1" "quarantined"
assert_eq "$(grep -c . "$L")" "5" "the five whole lines kept"
else
  printf '  skip  busybox awk not present: the NUL-unsafe refusal is untested on this host\n'
fi

test_start "control: a clean ledger writes no quarantine file"
plant_ledger 10; rm -f "$UNDO"/ledger.jsonl.torn-*; BEFORE="$(file_digest "$L")"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(file_digest "$L")" "$BEFORE" "byte-identical"
assert_eq "$(torn_files)" "0" "no quarantine file"

test_start "control: a clean ledger is untouched and no hole copy appears"
plant_ledger 50; BEFORE="$(file_digest "$L")"
bash -c ". '$HOOKS_DIR/_maude-common.sh'; maude_retention_sweep" </dev/null >/dev/null 2>&1
assert_eq "$(file_digest "$L")" "$BEFORE" "byte-identical"
assert_eq "$(ls "$UNDO"/ledger.jsonl.hole-* 2>/dev/null | wc -l | tr -d ' ')" "0" "no hole copy"

print_summary
teardown_test_env
exit $FAILED
