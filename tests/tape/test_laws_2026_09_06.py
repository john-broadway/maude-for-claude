"""The laws of memory applied to the tape (the memory lens, 2026-09-06).

DEFECT-7: canon had no time and promotion threw the event's time away. DEFECT-6: the
pending list was unranked, his own words buried among the agent's. DEFECT-8: a verbatim
row carried no pointer to the utterance that could falsify the label. N-1: the voice
report never said how old the profile was.
"""
import pathlib
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import voice
from maude_tape.tape import Tape

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _say(t, text, ts=None):
    """He typed it: a row in the voice table, the way the prompt hook records one."""
    ts = time.time() if ts is None else ts
    sha = voice._compute_sha(text.rstrip(), str(ts))
    voice._insert_voice_row(t, ts=ts, text=text, source="test", register="chat",
                            session="s", sha=sha)
    t._conn.commit()
    return sha


def _wake(db):
    return subprocess.run([sys.executable, "-m", "maude_tape", "wake", "--db", str(db)],
                          capture_output=True, text=True, cwd=str(ROOT),
                          env={"PYTHONPATH": str(ROOT), "PATH": "/usr/bin:/bin"}).stdout


def test_canon_carries_the_events_time_through_rest_and_promote(tmp_path):
    t = Tape(tmp_path / "t.db")
    his = t.capture("keep it small", topic="scope", source="user", importance=0.8,
                    authority="user-verbatim")
    his_ts = t.event(his).ts
    mine = t.capture("the same for the next one", topic="scope", source="agent", importance=0.5)
    mine_ts = t.event(mine).ts
    t.rest()
    t.promote(mine)
    rows = dict(t._conn.execute("SELECT text, ts FROM canon").fetchall())
    assert rows["keep it small"] == his_ts
    assert rows["the same for the next one"] == mine_ts


def test_wake_prints_each_rows_date(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("ridden like a horse", topic="maude-vision", source="john", ts=1783814400.0)
    brief = t.wake()
    assert brief.canon_entries[0][2] == 1783814400.0
    out = _wake(db)
    assert "ridden like a horse" in out
    assert "2026-07-12" in out


def test_an_old_tape_gains_ts_by_migration_and_backfills_it_from_the_event(tmp_path):
    db = tmp_path / "old.db"
    conn = sqlite3.connect(db)
    conn.executescript("""
        CREATE TABLE canon (id INTEGER PRIMARY KEY, topic TEXT, text TEXT NOT NULL,
            source TEXT, authority TEXT DEFAULT 'user-verbatim', superseded_by INTEGER);
        CREATE TABLE events (id INTEGER PRIMARY KEY, ts REAL, topic TEXT, text TEXT NOT NULL,
            source TEXT, authority TEXT DEFAULT 'agent-inference', importance REAL DEFAULT 0.5,
            status TEXT DEFAULT 'buffered');
        INSERT INTO events (ts, topic, text, source, authority, status)
            VALUES (1234.5, 'x', 'an old ruling', 'user', 'user-verbatim', 'consolidated');
        INSERT INTO canon (topic, text, source, authority) VALUES ('x', 'an old ruling', 'user', 'user-verbatim');
        INSERT INTO canon (topic, text, source, authority) VALUES ('x', 'a seeded line', 'seed', 'user-verbatim');
    """)
    conn.commit(); conn.close()
    t = Tape(db)
    rows = dict(t._conn.execute("SELECT text, ts FROM canon").fetchall())
    assert rows["an old ruling"] == 1234.5
    assert rows["a seeded line"] is None


def test_pending_lists_his_words_first_newest_first(tmp_path):
    t = Tape(tmp_path / "t.db")
    a = t.capture("agent guess one", topic="x", source="agent", importance=0.9)
    h1 = t.capture("his old low line", topic="x", source="user", importance=0.4,
                   authority="user-verbatim")
    b = t.capture("agent guess two", topic="x", source="agent", importance=0.9)
    h2 = t.capture("his newer low line", topic="x", source="user", importance=0.4,
                   authority="user-verbatim")
    ids = [e.id for e in t.pending()]
    assert ids[:2] == [h2, h1]
    assert ids[2:] == [b, a]


def test_a_verbatim_capture_points_at_the_utterance_when_the_tape_heard_it(tmp_path):
    t = Tape(tmp_path / "t.db")
    sha = _say(t, "fix as you find own as you go")
    e = t.capture("fix as you find own as you go", topic="mode", source="user",
                  importance=0.8, authority="user-verbatim")
    assert t.event(e).voice_sha == sha
    t.rest()
    (row,) = t._conn.execute(
        "SELECT voice_sha FROM canon WHERE text = 'fix as you find own as you go'").fetchone()
    assert row == sha


def test_a_verbatim_capture_the_tape_never_heard_carries_no_pointer_and_wake_says_so(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    e = t.capture("words relayed from another box", topic="mode", source="user",
                  importance=0.8, authority="user-verbatim")
    assert t.event(e).voice_sha is None
    t.rest()
    out = _wake(db)
    line = [l for l in out.splitlines() if "words relayed from another box" in l][0]
    assert "unverified" in line


def test_the_voice_report_says_how_old_the_profile_is():
    lines = voice.voice_report_lines("a draft line.",
                                     {"sentence_length": {"median": 5.0, "p90": 9.0}},
                                     profile_ts=1786670454.0, newer_rows=879)
    joined = "\n".join(lines)
    assert "2026-08-14" in joined
    assert "879" in joined


def test_a_short_verbatim_line_points_only_at_an_exact_utterance(tmp_path):
    """A bare substring made "go" point at the newest prompt that merely contained the
    letters. Exact match first; substring only for a line long enough to be its own
    fingerprint."""
    t = Tape(tmp_path / "t.db")
    _say(t, "go, walk all three then the vision")
    e = t.capture("go", topic="mode", source="user", importance=0.8, authority="user-verbatim")
    assert t.event(e).voice_sha is None
    exact = _say(t, "go")
    e2 = t.capture("go", topic="mode", source="user", importance=0.8, authority="user-verbatim")
    assert t.event(e2).voice_sha == exact
    long_sha = _say(t, "the last thing i remember asking you over 4 sessions ago was have we applied the laws")
    e3 = t.capture("have we applied the laws", topic="mode", source="user", importance=0.8,
                   authority="user-verbatim")
    assert t.event(e3).voice_sha == long_sha


# ── the migration lands whole, retries when it did not, and is one scan ───────────────
# (the 23rd lens, BLOCKING-1/2: ALTER TABLE autocommits under python's sqlite3 while its
# backfill waits for the commit at the end of __init__, 56 s later, because the voice
# lookup re-scanned and re-normalised every voice row once per canon row; a hook killed
# at the 10 s SessionStart budget left the live tape with `ts` on all 163 rows and every
# one NULL, and the guard on the column's absence never retried.)
import pytest


def _old_tape(db):
    conn = sqlite3.connect(db)
    conn.executescript("""
        CREATE TABLE canon (id INTEGER PRIMARY KEY, topic TEXT, text TEXT NOT NULL,
            source TEXT, authority TEXT DEFAULT 'user-verbatim', superseded_by INTEGER);
        CREATE TABLE events (id INTEGER PRIMARY KEY, ts REAL, topic TEXT, text TEXT NOT NULL,
            source TEXT, authority TEXT DEFAULT 'agent-inference', importance REAL DEFAULT 0.5,
            status TEXT DEFAULT 'buffered');
        CREATE TABLE voice (id INTEGER PRIMARY KEY, ts REAL, text TEXT NOT NULL, source TEXT,
            register TEXT DEFAULT 'chat', session TEXT, sha TEXT UNIQUE);
        INSERT INTO events (ts, topic, text, source, authority, status)
            VALUES (1234.5, 'x', 'an old ruling', 'user', 'user-verbatim', 'consolidated');
        INSERT INTO canon (topic, text, source, authority) VALUES ('x', 'an old ruling', 'user', 'user-verbatim');
        INSERT INTO canon (topic, text, source, authority) VALUES ('x', 'a seeded line', 'seed', 'user-verbatim');
    """)
    conn.commit()
    conn.close()


def test_a_migration_interrupted_after_the_column_landed_finishes_on_the_next_open(tmp_path):
    """The live tape's shape: ts present on every canon row and NULL on every one."""
    db = tmp_path / "half.db"
    _old_tape(db)
    c = sqlite3.connect(db)
    c.execute("ALTER TABLE canon ADD COLUMN ts REAL")
    c.commit()
    c.close()
    t = Tape(db)
    rows = dict(t._conn.execute("SELECT text, ts FROM canon").fetchall())
    assert rows["an old ruling"] == 1234.5
    assert rows["a seeded line"] is None


def test_the_column_and_its_backfill_land_together_or_not_at_all(tmp_path, monkeypatch):
    db = tmp_path / "kill.db"
    _old_tape(db)

    def boom(self, *a, **k):
        raise RuntimeError("killed mid-migration")

    monkeypatch.setattr(Tape, "_find_voice_sha", boom)
    with pytest.raises(RuntimeError):
        Tape(db)
    c = sqlite3.connect(db)
    cols = {r[1] for r in c.execute("PRAGMA table_info(canon)")}
    c.close()
    assert "ts" not in cols, "the column outlived its backfill"
    monkeypatch.undo()
    t = Tape(db)
    assert dict(t._conn.execute("SELECT text, ts FROM canon").fetchall())["an old ruling"] == 1234.5


def test_the_voice_lookup_is_one_scan_not_one_per_row(tmp_path):
    db = tmp_path / "big.db"
    _old_tape(db)
    c = sqlite3.connect(db)
    c.executemany("INSERT INTO voice (ts, text, sha) VALUES (?,?,?)",
                  [(float(i), f"prompt number {i} with a few more words in it so it is a line", f"sha{i:06d}")
                   for i in range(3000)])
    c.executemany("INSERT INTO canon (topic, text, source, authority) VALUES ('x', ?, 'user', 'user-verbatim')",
                  [(f"a ruling that no prompt on this tape contains, number {i}",) for i in range(150)])
    c.commit()
    c.close()
    t0 = time.monotonic()
    Tape(db)
    dt = time.monotonic() - t0
    assert dt < 2.0, f"migration took {dt:.1f} s on 150 x 3000 rows"


def test_a_store_that_claims_the_version_but_lacks_the_column_still_gets_its_backfill(tmp_path):
    """A restore from a partial backup, a hand repair, a later ALTER without a version bump:
    user_version says done and the column is missing. The ALTER ran and the backfill did
    not, the original bug's exact end state, by design (the 24th lens, IMPORTANT-7). Each
    backfill keys on its column's absence as well as the version."""
    db = tmp_path / "claims.db"
    _old_tape(db)
    c = sqlite3.connect(db)
    c.execute("INSERT INTO voice (ts, text, source, sha) VALUES (1.0, 'an old ruling', 'chat', ?)", ("ab" * 20,))
    c.execute("PRAGMA user_version = 1")
    c.commit()
    c.close()
    t = Tape(db)
    rows = {text: (ts, sha) for text, ts, sha in t._conn.execute("SELECT text, ts, voice_sha FROM canon")}
    assert rows["an old ruling"] == (1234.5, "ab" * 20)
    assert rows["a seeded line"] == (None, None)


def test_a_store_whose_header_is_ahead_of_this_build_is_never_downgraded(tmp_path):
    """The header is the file's only version statement, and a migration must never write it
    backwards: a downgrade re-runs every later migration's backfills as if they had never
    happened (the 25th lens, MINOR-4)."""
    db = tmp_path / "ahead.db"
    _old_tape(db)
    c = sqlite3.connect(db)
    c.execute("PRAGMA user_version = 2")
    c.commit()
    c.close()
    t = Tape(db)
    (uv,) = t._conn.execute("PRAGMA user_version").fetchone()
    assert uv == 2, "a newer store's header was written backwards"
    rows = dict(t._conn.execute("SELECT text, ts FROM canon").fetchall())
    assert rows["an old ruling"] == 1234.5, "and the column-absence backfill still ran"
