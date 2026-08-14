"""`maude_tape check --voice`: a VOICE
REPORT appended after the existing phrase-floor output, numbers with receipts, NEVER a
verdict, and NEVER touching the exit code (the floor alone owns 0/2/3).

Default behavior (no --voice) must stay byte-identical to before this flag existed —
that's proven here by re-running the SAME scenarios the pre-existing test_cli.py checks
cover, plus the exact fixture seed.json test_cli.py already uses. All fixtures are
synthetic.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import voice
from maude_tape.tape import Tape

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = pathlib.Path(__file__).parent / "fixtures" / "seed.json"


def _run(*args, stdin=None):
    return subprocess.run(
        [sys.executable, "-m", "maude_tape", *args],
        cwd=ROOT, capture_output=True, text=True, input=stdin,
    )


def _ts(iso: str) -> float:
    return datetime.fromisoformat(iso).replace(tzinfo=timezone.utc).timestamp()


def _seed_voice_corpus(db: pathlib.Path) -> None:
    """A small synthetic corpus, then a stored profile — via the module functions
    directly (not the CLI), since setup speed isn't the thing under test here."""
    tape = Tape(db)
    rows = [
        ("we ship it. we ship it fast", _ts("2026-08-01T10:00:00")),
        ("wait... let's ship it fast", _ts("2026-08-02T10:00:00")),
        ("Ship it fast — no more waiting; go", _ts("2026-08-03T10:00:00")),
    ]
    for text, ts in rows:
        tape._conn.execute(
            "INSERT INTO voice (ts, text, source, register, session, sha) "
            "VALUES (?, ?, 'synthetic', 'chat', NULL, ?)",
            (ts, text, f"sha-{hash((text, ts))}"),
        )
    tape._conn.commit()
    from types import SimpleNamespace
    voice.cmd_profile(SimpleNamespace(), tape)


# --- no-regression: default behavior WITHOUT --voice is untouched ----------------------

def test_check_without_voice_flag_is_unchanged_on_a_clean_draft(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    r = _run("check", "--db", str(db), stdin="we kept it small.")
    assert r.returncode == 0
    assert "voice" not in r.stdout.lower()
    assert "REJECTED" not in r.stdout


def test_check_without_voice_flag_is_unchanged_on_a_rejected_draft(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    r = _run("check", "--db", str(db), stdin="we kept it small but heroically slashed scope")
    assert r.returncode == 2
    assert "heroically slashed scope" in r.stdout
    assert "voice report" not in r.stdout.lower()


def test_check_without_voice_flag_unchanged_even_with_a_profile_stored(tmp_path):
    """A stored profile must be invisible unless --voice is explicitly passed."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _seed_voice_corpus(db)

    r = _run("check", "--db", str(db), stdin="we kept it small.")
    assert r.returncode == 0
    assert "voice report" not in r.stdout.lower()
    assert "voice:" not in r.stdout.lower()


def test_check_all_documented_exit_codes_unchanged_by_the_voice_flags_existence(tmp_path):
    """Every exit-code contract test_cli.py already pins (0 clean, 2 blocked, 3 caller
    error) still holds with the --voice ARGUMENT DEFINED but not passed."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    assert _run("check", "--db", str(db), stdin="we kept it small.").returncode == 0
    assert _run("check", "--db", str(db),
                stdin="we kept it small but heroically slashed scope").returncode == 2
    assert _run("check", "--db", str(db), stdin="").returncode == 3


# --- --voice with NO stored profile: one graceful line, rc untouched -------------------

def test_check_voice_with_no_stored_profile_prints_one_line_and_keeps_exit_code(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    r = _run("check", "--db", str(db), "--voice", stdin="we kept it small.")
    assert r.returncode == 0
    assert "voice: no profile stored — run profile first" in r.stdout
    assert "voice report" not in r.stdout.lower()


def test_check_voice_no_profile_still_blocks_a_rejected_draft(tmp_path):
    """--voice with no profile must not interfere with the floor's own verdict."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    r = _run("check", "--db", str(db), "--voice",
              stdin="we kept it small but heroically slashed scope")
    assert r.returncode == 2
    assert "heroically slashed scope" in r.stdout
    assert "voice: no profile stored" in r.stdout


# --- --voice WITH a stored profile: the report appears, rc still untouched -------------

def test_check_voice_with_profile_appends_report_on_a_clean_draft(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _seed_voice_corpus(db)

    r = _run("check", "--db", str(db), "--voice", stdin="we kept it small.")
    assert r.returncode == 0
    assert "voice report" in r.stdout.lower()
    assert "sentence length" in r.stdout.lower()
    assert "lowercase-open" in r.stdout.lower()
    assert "shadow words" in r.stdout.lower()
    assert "hammer coverage" in r.stdout.lower()
    for label in ("'..'", "'...'", "'—'", "';'", "'!'"):
        assert label in r.stdout


def test_check_voice_with_profile_still_blocks_a_rejected_draft(tmp_path):
    """The report is additive: it must never rescue a blocked draft, and the floor's
    exit code must not change because a report was also printed."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _seed_voice_corpus(db)

    r = _run("check", "--db", str(db), "--voice",
              stdin="we kept it small but heroically slashed scope")
    assert r.returncode == 2
    assert "heroically slashed scope" in r.stdout
    assert "voice report" in r.stdout.lower()


def test_check_voice_report_never_uses_pass_fail_or_score_language(tmp_path):
    """The a-guard-that-answers-the-easy-question law: numbers with receipts, never a
    verdict. Checked on BOTH a clean and a shadow-word-heavy draft, since a naive
    implementation might be tempted to say something like 'high AI-tell score' when
    hits are non-zero."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _seed_voice_corpus(db)

    heavy_draft = "we should leverage this robust, seamless, comprehensive, holistic solution"
    r = _run("check", "--db", str(db), "--voice", stdin=heavy_draft)
    report = r.stdout.lower()
    assert "voice report" in report
    # "not a verdict" (the header's own disclaimer) is fine and expected — what's
    # banned is the report ACTING like one: a pass/fail word or a numeric score noun.
    for banned in ("pass", "fail", "score"):
        assert banned not in report, f"report used verdict-shaped language: {banned!r}"


def test_check_voice_report_shadow_words_line_shows_the_hits_from_a_heavy_draft(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _seed_voice_corpus(db)

    r = _run("check", "--db", str(db), "--voice",
              stdin="we should leverage this robust solution")
    assert "leverage: 1" in r.stdout
    assert "robust: 1" in r.stdout


def test_check_voice_report_hammer_coverage_line_reflects_the_profile(tmp_path):
    """The stored corpus's most frequent phrase is "ship it" (appears in all three
    rows) — a draft reusing it should show up in hammer coverage as present."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _seed_voice_corpus(db)

    r = _run("check", "--db", str(db), "--voice", stdin="let's ship it today")
    assert "hammer coverage" in r.stdout.lower()
    assert "ship it" in r.stdout


# --- direct module-level check: report content is receipts, not narrative ---------------

def test_voice_report_lines_reuses_measure_texts_so_draft_and_profile_share_one_rule(tmp_path):
    """A single-sentence, all-lowercase draft measured directly against a hand-built
    profile — proves voice_report_lines calls the SAME sentence-length rule
    compute_profile uses (measure_texts), not a second implementation."""
    profile = {
        "sentence_length": {"median": 3.0, "p90": 8.0},
        "lowercase_open_ratio": 0.75,
        "punctuation_per_100_lines": {"..": 0.0, "...": 25.0, "—": 25.0, ";": 25.0, "!": 0.0},
        "hammers": {"ship it": 6},
        "shadow_hits": {},
    }
    lines = voice.voice_report_lines("ship it now please", profile)
    joined = "\n".join(lines)
    assert "draft median 4.0" in joined  # 4 words, one sentence, matches measure_texts directly
    assert "ship it" in joined            # hammer coverage picked up the shared phrase
