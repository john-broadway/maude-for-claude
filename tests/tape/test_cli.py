"""The CLI bridge — what Maude's bash hooks call to make the tape fire on its own.
`wake` plays the tape into context; `check` is the gate and fails CLOSED on a rejected line.
Uses a generic example seed — the public plugin ships no personal data.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = pathlib.Path(__file__).parent / "fixtures" / "seed.json"


def _run(*args, stdin=None):
    return subprocess.run(
        [sys.executable, "-m", "maude_tape", *args],
        cwd=ROOT, capture_output=True, text=True, input=stdin,
    )


def test_seed_is_idempotent_and_wake_plays_the_tape(tmp_path):
    db = tmp_path / "tape.db"
    assert _run("seed", "--db", str(db), "--from", str(FIX)).returncode == 0
    assert _run("seed", "--db", str(db), "--from", str(FIX)).returncode == 0  # no double-seed

    w = _run("wake", "--db", str(db))
    assert w.returncode == 0
    assert "keep it small" in w.stdout                # current truth, played
    assert "heroically slashed scope" in w.stdout     # named as never-render
    assert "nothing cut" in w.stdout                  # the tape knows what it is


def test_check_gate_fails_closed_on_a_rejected_phrasing(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    dirty = _run("check", "--db", str(db), stdin="we kept it small but heroically slashed scope")
    assert dirty.returncode != 0            # the gate BLOCKS
    assert "heroically slashed scope" in dirty.stdout


def test_check_gate_passes_a_clean_draft(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    clean = _run("check", "--db", str(db), stdin="we kept it small.")
    assert clean.returncode == 0            # clean passes


def test_wake_is_silent_on_an_empty_tape(tmp_path):
    db = tmp_path / "tape.db"
    w = _run("wake", "--db", str(db))
    assert w.returncode == 0
    assert w.stdout.strip() == ""
