"""A rest cut short must not double a line of canon (2026-11-16).

SessionEnd hooks are cancelled when a session exits under them (a design session's tape rest
was, that day). rest() walked the buffer and called remember() for each of his lines, and
remember() COMMITTED, while the event's 'consolidated' mark waited for rest's own commit at
the end. A kill between the two left the line in canon and its event still buffered, so the
next rest wrote it to canon again, and canon replays at every wake. The crash is proven the
only way a crash is: a real process, SIGKILLed after the first canon commit, and the real
store reopened.
"""
import os
import pathlib
import signal
import subprocess
import sys
import textwrap

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from maude_tape.tape import Tape

LINES = ["I own what I build", "keep it small and say why"]

_KILLER = textwrap.dedent(
    """
    import os, signal, sys
    sys.path.insert(0, sys.argv[1])
    from maude_tape.tape import Tape
    real = Tape.remember
    def remember_then_die(self, *a, **k):
        real(self, *a, **k)              # the canon row is written and committed here
        os.kill(os.getpid(), signal.SIGKILL)
    Tape.remember = remember_then_die
    Tape(sys.argv[2]).rest()
    """
)


def _canon_count(db, text):
    t = Tape(db)
    return sum(1 for row in t._conn.execute("SELECT text FROM canon") if row[0] == text)


def test_a_rest_killed_after_a_canon_write_does_not_write_that_line_twice(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for line in LINES:
        t.capture(line, topic="own", source="user", importance=0.8, authority="user-verbatim")
    t._conn.close()

    proc = subprocess.run([sys.executable, "-I", "-c", _KILLER, str(ROOT), str(db)],
                          capture_output=True, timeout=60)
    assert proc.returncode == -signal.SIGKILL, (proc.returncode, proc.stderr[-400:])

    Tape(db).rest()                      # the next rest picks up where the cut one stopped

    assert [_canon_count(db, line) for line in LINES] == [1, 1]
    assert Tape(db).buffered() == []     # nothing of his left waiting


def test_two_rests_at_once_write_each_line_once(tmp_path):
    """Two sessions can rest one tape at once (two SessionEnds, or a wake finishing a cut
    rest while another session's is still running). The second rest to mark a line must
    find it already consolidated and write nothing (the lens on 50abbd9: a rest that slept
    after reading the buffer while another ran wrote the line twice)."""
    db = tmp_path / "t.db"
    Tape(db).capture(LINES[0], topic="own", source="user", importance=0.8,
                     authority="user-verbatim")
    slow = Tape(db)
    stale = slow.buffered()          # A reads the buffer ...
    Tape(db).rest()                  # ... B runs a whole rest meanwhile ...
    slow.buffered = lambda: stale    # ... and A goes on from what it read
    report = slow.rest()
    assert _canon_count(db, LINES[0]) == 1
    assert report.consolidated == []


_PROMOTE_KILLER = textwrap.dedent(
    """
    import os, signal, sys
    sys.path.insert(0, sys.argv[1])
    from maude_tape.tape import Tape
    real = Tape.remember
    def remember_then_die(self, *a, **k):
        real(self, *a, **k)
        os.kill(os.getpid(), signal.SIGKILL)
    Tape.remember = remember_then_die
    Tape(sys.argv[2]).promote(int(sys.argv[3]))
    """
)


def test_a_promote_killed_after_its_canon_write_can_be_promoted_once(tmp_path):
    """promote() had rest's split too: canon committed, then the event's mark. Killed between,
    the event stayed on his list and promoting it again doubled the line."""
    db = tmp_path / "t.db"
    eid = Tape(db).capture("an agent's read of him", topic="own", source="agent",
                           importance=0.8)
    proc = subprocess.run([sys.executable, "-I", "-c", _PROMOTE_KILLER, str(ROOT), str(db),
                           str(eid)], capture_output=True, timeout=60)
    assert proc.returncode == -signal.SIGKILL, (proc.returncode, proc.stderr[-400:])
    Tape(db).promote(eid)
    assert _canon_count(db, "an agent's read of him") == 1


_CORRECTION_KILLER = textwrap.dedent(
    """
    import os, signal, sys
    sys.path.insert(0, sys.argv[1])
    from maude_tape.tape import Tape
    real = Tape.remember
    def remember_then_die(self, *a, **k):
        real(self, *a, **k)
        os.kill(os.getpid(), signal.SIGKILL)
    Tape.remember = remember_then_die
    Tape(sys.argv[2]).consolidate_correction(rejected="slashed scope", reason="drama",
                                             corrected_to="keep it small", topic="scope",
                                             source="user")
    """
)


def test_a_correction_cut_short_lands_whole_or_not_at_all(tmp_path):
    """consolidate_correction() says one transaction and committed three times: the rejection,
    the new line, then the supersede. Cut after the new line, both the old and the new line
    stood as current truth. Now a cut leaves none of it."""
    db = tmp_path / "t.db"
    Tape(db).remember("we heroically slashed scope", topic="scope", source="agent",
                      authority="agent-inference")
    proc = subprocess.run([sys.executable, "-I", "-c", _CORRECTION_KILLER, str(ROOT), str(db)],
                          capture_output=True, timeout=60)
    assert proc.returncode == -signal.SIGKILL, (proc.returncode, proc.stderr[-400:])
    t = Tape(db)
    current = [e.text for e in t.recall("scope")]
    rejected = t._conn.execute("SELECT count(*) FROM rejections").fetchone()[0]
    assert (current, rejected) == (["we heroically slashed scope"], 0)


def test_two_refusals_in_one_rest_both_stay_refused(tmp_path):
    """A refusal at the canon door marks its event refused. The next refusal's rollback undid
    the first mark (uncommitted), so the report said refused and the store said buffered."""
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(2):
        t.capture(f"line {i}", topic="own", source="user", importance=0.8,
                  authority="user-verbatim")
    t._conn.execute("UPDATE events SET topic = ?", ("ghp_" + "A" * 36,))
    t._conn.commit()
    report = Tape(db).rest()
    statuses = [r[0] for r in Tape(db)._conn.execute("SELECT status FROM events ORDER BY id")]
    assert (len(report.refused), statuses) == (2, ["refused", "refused"])


def test_a_dismiss_that_lost_the_race_leaves_the_rest_s_canon_line_whole(tmp_path):
    """dismiss() read the event, then set it forgotten by id alone: a rest that consolidated
    the line in between left a canon row whose event read forgotten."""
    db = tmp_path / "t.db"
    eid = Tape(db).capture("a line on his list", topic="own", source="agent", importance=0.8)
    slow = Tape(db)
    stale = slow.event(eid)              # dismiss reads it as buffered ...
    Tape(db).promote(eid)                # ... his promote lands meanwhile ...
    slow.event = lambda _i: stale
    try:
        slow.dismiss(eid)
        raised = False
    except ValueError:
        raised = True
    status = Tape(db).event(eid).status
    assert (raised, status, _canon_count(db, "a line on his list")) == (True, "consolidated", 1)


def test_a_correction_that_raises_leaves_nothing_open_on_the_connection(tmp_path):
    """A failure inside consolidate_correction left the uncommitted rejection on the
    connection, for the caller's next commit to write as an orphan."""
    db = tmp_path / "t.db"
    t = Tape(db)
    real = t.remember
    def boom(*a, **k):
        raise RuntimeError("embedder down")
    t.remember = boom
    try:
        t.consolidate_correction(rejected="slashed scope", reason="drama",
                                 corrected_to="keep it small", topic="scope", source="user")
    except RuntimeError:
        pass
    t.remember = real
    t.remember("an unrelated line", topic="x", source="user")   # commits whatever is open
    assert Tape(db)._conn.execute("SELECT count(*) FROM rejections").fetchone()[0] == 0
