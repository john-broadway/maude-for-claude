#!/usr/bin/env bash
# Tests for hooks/scripts/maude-tape-rest.sh (SessionEnd): rest consolidates the tape, and
# the voice profile is recomputed from his typed lines only (seeing-gap design A5; before
# this the profile was last recomputed 2026-08-14, by hand).
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

REST="$HOOKS_DIR/maude-tape-rest.sh"
# setup_test_env unsets every MAUDE_* variable, MAUDE_ROOT included: derive the root from
# HOOKS_DIR, or the python below imports whatever sits in the cwd (it passed from the repo
# root by luck and failed under tests/run.sh).
PLUGIN_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
DB="$CLAUDE_PROJECT_DIR/.maude/plugin/tape/tape.db"
mkdir -p "$(dirname "$DB")"

PYTHONPATH="$PLUGIN_ROOT" python3 - "$DB" <<'PY'
import sys
from maude_tape import voice
from maude_tape.tape import Tape
t = Tape(sys.argv[1])
for i, text in enumerate(["fold it", "keep going", "merge on green",
                          '<agent-message from="x">done</agent-message>']):
    voice._insert_voice_row(t, ts=float(i + 1), text=text, source="hook", register="chat",
                            session=None, sha=str(i))
t._conn.commit()
PY

test_start "rest recomputes the voice profile from his lines only"
OUT="$(bash "$REST" </dev/null 2>&1)"; RC=$?
assert_exit "$RC" "0" "rest exits 0"
assert_eq "$OUT" "" "rest is silent"
GOT="$(python3 -c "
import json,sqlite3,sys
r=sqlite3.connect(sys.argv[1]).execute('select json from voice_profile where id=1').fetchone()
p=json.loads(r[0]) if r else {}
print(p.get('n_lines'), p.get('honesty',{}).get('lines_excluded_not_his'))" "$DB")"
assert_eq "$GOT" "3 1" "three of his lines, one not his"

test_start "rest flags a suggested prompt he accepted, before the profile, and never deletes"
TEST_TMPDIR_FLAG="$(mktemp -d)"; TR="$TEST_TMPDIR_FLAG/proj"; mkdir -p "$TR/memory"
export MAUDE_MEM_DIR_OVERRIDE="$TR/memory"
PYTHONPATH="$PLUGIN_ROOT" python3 - "$DB" "$TR/s.jsonl" <<'PY'
import json, sys
from maude_tape import voice
from maude_tape.tape import Tape
t = Tape(sys.argv[1])
voice._insert_voice_row(t, ts=1792904401.0, text="sounds good ship it", source="hook",
                        register="chat", session="s", sha="sugg")
t._conn.commit()
rec = {"type": "user", "userType": "external", "sessionId": "s", "timestamp": "2026-10-25T05:00:00.000Z",
       "origin": {"kind": "human"}, "promptSource": "suggestion_accepted",
       "message": {"role": "user", "content": "sounds good ship it"}}
open(sys.argv[2], "w").write(json.dumps(rec) + "\n")
PY
OUT="$(bash "$REST" </dev/null 2>&1)"; RC=$?
assert_exit "$RC" "0" "rest exits 0"
assert_eq "$OUT" "" "rest is silent"
GOT="$(python3 -c "
import json,sqlite3,sys
c=sqlite3.connect(sys.argv[1])
p=json.loads(c.execute('select json from voice_profile where id=1').fetchone()[0])
print(c.execute('select count(*) from voice').fetchone()[0], [r[0] for r in c.execute('select sha from voice_flags')], p['n_lines'])" "$DB")"
assert_eq "$GOT" "5 ['sugg'] 3" "the row stays, flagged, out of the profile"
GOT="$(python3 -c "
import sqlite3,sys
print([r[0].rsplit('/',1)[-1] for r in sqlite3.connect(sys.argv[1]).execute('select path from voice_flag_files')])" "$DB")"
assert_eq "$GOT" "['s.jsonl']" "the transcript read whole is recorded, so the next rest skips it"
unset MAUDE_MEM_DIR_OVERRIDE
rm -rf "$TEST_TMPDIR_FLAG"

test_start "every bounded step of rest fits inside the hook's own timeout"
# lens 4: the flag pass alone took 9.9 s of a 10 s hook. The hard bounds the script sets
# must sum below what hooks.json gives it, with room left for the unbounded rest step.
GOT="$(python3 - "$REST" "$PLUGIN_ROOT/hooks/hooks.json" <<'PY'
import json, re, sys
script = open(sys.argv[1]).read()
bounds = sum(float(n) for n in re.findall(r"maude_timeout (\d+(?:\.\d+)?)", script))
hooks = json.load(open(sys.argv[2]))
limit = [h["timeout"] for e in hooks["hooks"].values() for g in e for h in g["hooks"]
         if "maude-tape-rest.sh" in h.get("command", "")][0]
# and the flag pass is told to stop starting files well before its own kill, so a kill
# lands between files, not inside the one it is committing
flag = re.search(r"maude_timeout (\d+) python3 -m maude_tape voice-flag[^\n]*\n[^\n]*--budget (\d+)", script)
soft = flag and int(flag.group(2)) < int(flag.group(1))
print("fits" if bounds and bounds + 1 <= limit and soft else f"bounds {bounds} vs hook {limit}, soft {soft}")
PY
)"
assert_eq "$GOT" "fits" "the bounds leave a second for rest itself"

test_start "a broken tape does not make rest loud or fail"
printf 'not a database' > "$DB"
OUT="$(bash "$REST" </dev/null 2>&1)"; RC=$?
assert_exit "$RC" "0" "rest exits 0"
assert_eq "$OUT" "" "rest is silent"

print_summary
teardown_test_env
exit $FAILED
