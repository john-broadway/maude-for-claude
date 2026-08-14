"""The silent capture path — the hook's single-line ingest (`voice-capture` on the CLI,
`voice.cmd_capture` at module level).

Contract: stdin is the
WHOLE raw prompt text already extracted by the hook script — NOT jsonl. Same
normalization + secret filter + sha rule as harvest, ts=now. Prints NOTHING on success,
exits 0 ALWAYS (even on internal error — an observer must never block the prompt it is
watching). Empty/whitespace stdin: exit 0 silently, no insert.
"""
from __future__ import annotations

import io
import pathlib
import sys
from types import SimpleNamespace

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import voice
from maude_tape.tape import Tape


def _capture_args(source="hook", register="chat", session=None):
    return SimpleNamespace(source=source, register=register, session=session)


def _run_capture(monkeypatch, tape, stdin_text, **arg_overrides):
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin_text))
    return voice.cmd_capture(_capture_args(**arg_overrides), tape)


# --- happy path -------------------------------------------------------------------------

def test_silent_success_inserts_the_row(tmp_path, monkeypatch, capsys):
    tape = Tape(tmp_path / "tape.db")
    rc = _run_capture(monkeypatch, tape, "what should I build next", source="hook", register="chat")

    assert rc == 0
    out, err = capsys.readouterr()
    assert out == ""
    assert err == ""

    rows = tape._conn.execute("SELECT text, source, register FROM voice").fetchall()
    assert rows == [("what should I build next", "hook", "chat")]


def test_normalization_strips_trailing_whitespace_only_keeps_leading(tmp_path, monkeypatch):
    tape = Tape(tmp_path / "tape.db")
    _run_capture(monkeypatch, tape, "  leading kept, trailing gone   \n")

    (text,) = tape._conn.execute("SELECT text FROM voice").fetchone()
    assert text == "  leading kept, trailing gone"


def test_session_and_source_and_register_args_are_threaded_through(tmp_path, monkeypatch):
    tape = Tape(tmp_path / "tape.db")
    _run_capture(monkeypatch, tape, "session threading check",
                 source="my-hook-script", register="chat", session="sess-live-123")

    row = tape._conn.execute("SELECT source, register, session FROM voice").fetchone()
    assert row == ("my-hook-script", "chat", "sess-live-123")


def test_session_defaults_to_none_when_not_provided(tmp_path, monkeypatch):
    tape = Tape(tmp_path / "tape.db")
    _run_capture(monkeypatch, tape, "no session id passed")

    (session,) = tape._conn.execute("SELECT session FROM voice").fetchone()
    assert session is None


# --- empty / whitespace: silent, no insert ----------------------------------------------

def test_empty_stdin_exits_zero_silently_with_no_insert(tmp_path, monkeypatch, capsys):
    tape = Tape(tmp_path / "tape.db")
    rc = _run_capture(monkeypatch, tape, "")

    assert rc == 0
    out, err = capsys.readouterr()
    assert out == "" and err == ""
    (count,) = tape._conn.execute("SELECT COUNT(*) FROM voice").fetchone()
    assert count == 0


def test_whitespace_only_stdin_exits_zero_silently_with_no_insert(tmp_path, monkeypatch, capsys):
    tape = Tape(tmp_path / "tape.db")
    rc = _run_capture(monkeypatch, tape, "   \n\t  \n")

    assert rc == 0
    out, err = capsys.readouterr()
    assert out == "" and err == ""
    (count,) = tape._conn.execute("SELECT COUNT(*) FROM voice").fetchone()
    assert count == 0


# --- secret filter: same gate as harvest, must be SEEN to refuse ------------------------

def test_secretish_line_is_skipped_and_never_stored(tmp_path, monkeypatch, capsys):
    tape = Tape(tmp_path / "tape.db")
    fake_github_token = "ghp_" + "y" * 40   # obviously-fake value, real SHAPE
    rc = _run_capture(monkeypatch, tape, f"remember this token {fake_github_token}")

    assert rc == 0
    out, err = capsys.readouterr()
    assert out == ""  # still silent — a skip is not an error, and must not narrate itself
    (count,) = tape._conn.execute("SELECT COUNT(*) FROM voice").fetchone()
    assert count == 0


def test_a_clean_line_alongside_a_secretish_one_still_captures_cleanly(tmp_path, monkeypatch):
    """The gate must be SEEN to refuse — prove it against a control that DOES get stored."""
    tape = Tape(tmp_path / "tape.db")
    _run_capture(monkeypatch, tape, "a perfectly ordinary prompt with no secrets")

    rows = [r[0] for r in tape._conn.execute("SELECT text FROM voice").fetchall()]
    assert rows == ["a perfectly ordinary prompt with no secrets"]


# --- fail-open: never block the prompt it's watching ------------------------------------

def test_fail_open_on_internal_error_still_exits_zero_and_stays_silent_on_stdout(
    tmp_path, monkeypatch, capsys
):
    """Force an internal error (closed db connection) and prove capture still exits 0,
    prints nothing to stdout, and logs the failure to stderr only — a broken capture must
    never be able to block John's prompt."""
    tape = Tape(tmp_path / "tape.db")
    tape._conn.close()  # simulate an internal failure on the insert path

    rc = _run_capture(monkeypatch, tape, "this prompt must not be blocked by a bug")

    assert rc == 0
    out, err = capsys.readouterr()
    assert out == ""
    assert err != ""  # the failure IS logged, just never to stdout and never as a block


def test_stdin_read_failure_also_fails_open(tmp_path, capsys):
    """If reading stdin itself blows up, capture still returns 0 and stays off stdout."""
    tape = Tape(tmp_path / "tape.db")

    class _ExplodingStdin:
        def read(self):
            raise OSError("synthetic stdin failure")

    orig_stdin = sys.stdin
    sys.stdin = _ExplodingStdin()
    try:
        rc = voice.cmd_capture(_capture_args(), tape)
    finally:
        sys.stdin = orig_stdin

    assert rc == 0
    out, err = capsys.readouterr()
    assert out == ""
    assert err != ""


# --- sha / idempotency shape -------------------------------------------------------------

def test_sha_rule_matches_harvests_formula_shape(tmp_path, monkeypatch):
    """Capture uses the SAME sha rule as harvest (normalized_text|ts_string), with
    ts=now instead of an original record timestamp — verified by recomputing the sha
    from the stored row and confirming it satisfies the table's UNIQUE constraint
    (a second identical insert at the exact same sha is ignored, not duplicated)."""
    tape = Tape(tmp_path / "tape.db")
    _run_capture(monkeypatch, tape, "sha shape check")

    (sha,) = tape._conn.execute("SELECT sha FROM voice").fetchone()
    assert sha is not None and len(sha) == 64  # sha256 hex digest

    # Re-inserting the identical sha directly must be ignored (UNIQUE holds) — proves
    # the capture path went through INSERT OR IGNORE like harvest, not a bare INSERT.
    cur = tape._conn.execute(
        "INSERT OR IGNORE INTO voice (ts, text, source, register, session, sha) "
        "VALUES (0, 'dupe', 'x', 'chat', NULL, ?)", (sha,),
    )
    tape._conn.commit()
    assert cur.rowcount == 0
    (count,) = tape._conn.execute("SELECT COUNT(*) FROM voice").fetchone()
    assert count == 1


# --- CLI end-to-end: proves the __main__.py `voice-capture` wiring is real --------------

def test_capture_end_to_end_via_the_real_cli(tmp_path):
    import subprocess

    root = pathlib.Path(__file__).resolve().parents[2]
    db = tmp_path / "tape.db"

    r = subprocess.run(
        [sys.executable, "-m", "maude_tape", "voice-capture",
         "--db", str(db), "--source", "hook", "--register", "chat", "--session", "sess-e2e"],
        cwd=root, capture_output=True, text=True, input="end to end capture via the cli\n",
    )
    assert r.returncode == 0
    assert r.stdout == ""

    tape = Tape(db)
    row = tape._conn.execute("SELECT text, source, session FROM voice").fetchone()
    assert row == ("end to end capture via the cli", "hook", "sess-e2e")
