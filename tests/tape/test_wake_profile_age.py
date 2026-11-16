"""Wake names a stale voice profile (seeing-gap design A5).

Rest recomputes the profile at every SessionEnd now. If rest stops running, nothing else
would say so: the profile sat ten weeks stale (2026-08-14 to 2026-10-25) with no line
anywhere. Wake says it once it is over 7 days old, and says nothing while it is fresh.
"""
import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _wake(db):
    env = {"PYTHONPATH": str(ROOT), "PATH": "/usr/bin:/bin"}
    return subprocess.run([sys.executable, "-m", "maude_tape", "wake", "--db", str(db)],
                          capture_output=True, text=True, cwd=str(ROOT), env=env).stdout


def _tape_with_profile(tmp_path, age_days):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("keep going", topic="t", source="john", ts=time.time())
    t._conn.execute("INSERT OR REPLACE INTO voice_profile (id, ts, json) VALUES (1, ?, ?)",
                    (time.time() - age_days * 86400, json.dumps({"n_lines": 1})))
    t._conn.commit()
    return db


def test_a_profile_ten_weeks_old_is_named_at_wake(tmp_path):
    out = _wake(_tape_with_profile(tmp_path, 71))
    assert "voice profile is 71 days old" in out


def test_a_fresh_profile_says_nothing(tmp_path):
    out = _wake(_tape_with_profile(tmp_path, 1))
    assert "voice profile" not in out
