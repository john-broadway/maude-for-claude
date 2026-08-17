"""The CLI half of his-hand-on-the-door: `pending` shows him the list, `promote` is the only
way an agent inference reaches canon, and `rest` has to TELL him something is waiting or the
queue is a silent pile. Generic example data.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _run(*args, stdin=None):
    return subprocess.run(
        [sys.executable, "-m", "maude_tape", *args],
        cwd=ROOT, capture_output=True, text=True, input=stdin,
    )


def _buffer_one(db, text="a guard that answers the easy question is worse than none"):
    r = _run("capture", text, "--db", str(db), "--topic", "maxims",
             "--source", "session", "--importance", "0.7")
    assert r.returncode == 0, r.stderr
    return int(r.stdout.split()[-1])          # "captured event N"


def test_rest_reports_what_is_waiting_on_him(tmp_path):
    db = tmp_path / "t.db"
    _buffer_one(db)

    r = _run("rest", "--db", str(db))

    assert r.returncode == 0
    assert "1 awaiting your word" in r.stdout   # a silent queue is a pile


def test_pending_shows_the_list_with_ids(tmp_path):
    db = tmp_path / "t.db"
    eid = _buffer_one(db)
    _run("rest", "--db", str(db))

    r = _run("pending", "--db", str(db))

    assert r.returncode == 0
    assert str(eid) in r.stdout
    assert "easy question" in r.stdout


def test_pending_says_so_when_nothing_waits(tmp_path):
    db = tmp_path / "t.db"
    r = _run("pending", "--db", str(db))
    assert r.returncode == 0
    assert "nothing" in r.stdout.lower()


def test_promote_moves_it_into_the_played_tape(tmp_path):
    db = tmp_path / "t.db"
    eid = _buffer_one(db)
    _run("rest", "--db", str(db))
    assert "easy question" not in _run("wake", "--db", str(db)).stdout   # not on my say-so

    p = _run("promote", "--db", str(db), "--id", str(eid))

    assert p.returncode == 0
    assert "easy question" in _run("wake", "--db", str(db)).stdout       # now it plays
    assert _run("pending", "--db", str(db)).stdout.lower().count("easy question") == 0


def test_capture_can_record_his_words_as_his(tmp_path):
    """The ritual tells Claude to capture the user's own rulings with `--authority
    user-verbatim` so they consolidate without asking him to approve his own sentence.
    Without the flag every capture defaults to agent-inference and his words queue up
    behind his own permission — the exact inversion of the rule."""
    db = tmp_path / "t.db"
    r = _run("capture", "keep it small", "--db", str(db), "--topic", "scope",
             "--source", "user-2026", "--importance", "0.9",
             "--authority", "user-verbatim")
    assert r.returncode == 0, r.stderr

    rest = _run("rest", "--db", str(db))

    assert "consolidated 1" in rest.stdout          # his words went straight to canon
    assert "awaiting" not in rest.stdout            # nothing to ask him about
    assert "keep it small" in _run("wake", "--db", str(db)).stdout


def test_capture_cli_refuses_a_credential_shape_cleanly(tmp_path):
    """A hook calls this. A traceback is not a refusal — it is a crash that happens to have
    the right effect, and it reads as a broken tape rather than a guard doing its job."""
    db = tmp_path / "t.db"
    r = _run("capture", "deploy failed: pypi-" + "A" * 44, "--db", str(db),
             "--topic", "ops", "--source", "session")

    assert r.returncode == 2
    assert "Traceback" not in r.stderr
    assert "credential shape" in (r.stdout + r.stderr)


def test_promote_fails_closed_on_something_not_pending(tmp_path):
    db = tmp_path / "t.db"
    eid = _buffer_one(db)
    _run("rest", "--db", str(db))
    _run("promote", "--db", str(db), "--id", str(eid))

    again = _run("promote", "--db", str(db), "--id", str(eid))
    missing = _run("promote", "--db", str(db), "--id", "999999")

    assert again.returncode == 2 and "already" in (again.stdout + again.stderr)
    assert missing.returncode == 2
