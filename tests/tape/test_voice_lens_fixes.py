"""Regression pins for the voice feature's adversarial review findings (2026-08-13).

Each test here exists because a lens PROVED the suite blind to the exact defect it pins:
lens 1's mutation run showed the p90 off-by-one and the _ratio zero-division guard
survive every prior test; lens 1 #1 proved cmd_capture's fail-open contract false at
the Tape-construction seam; lens 3 B1 proved check --voice unreachable on a fresh
install. Expectations are HAND-COMPUTED — never derived by calling the code under test.

All fixtures are SYNTHETIC. No real transcript or real corpus content is ever read.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import voice
from maude_tape.tape import Tape

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _insert_rows(tape, rows: list[tuple[str, float]]) -> None:
    for text, ts in rows:
        sha = f"sha-{hash((text, ts))}"
        tape._conn.execute(
            "INSERT INTO voice (ts, text, source, register, session, sha) "
            "VALUES (?, ?, 'synthetic', 'chat', NULL, ?)",
            (ts, text, sha),
        )
    tape._conn.commit()


def _run(*args: str, stdin: str | None = None):
    return subprocess.run(
        [sys.executable, "-m", "maude_tape", *args],
        input=stdin, capture_output=True, text=True, cwd=ROOT,
    )


# --- lens 1 finding #2: p90 off-by-one masked by small-n fixtures ---------------------

def test_p90_pinned_at_n10_where_the_off_by_one_diverges(tmp_path):
    """Ten one-sentence lines of 1..10 words (no terminal punctuation -> one sentence
    per line). Hand-computed nearest-rank p90 at n=10: ceil(0.9*10)-1 = index 8 ->
    sorted[8] = 9 words. The naive formula WITHOUT the -1 lands on index 9 -> 10 words.
    At the old fixtures' n=5 and n=7 the clamp masked that difference; n=10 is the
    smallest corpus where the mutation shows, so this test pins the exact index.
    Median of 1..10 hand-computed: (5+6)/2 = 5.5."""
    tape = Tape(str(tmp_path / "t.db"))
    rows = [(" ".join(["w"] * k), 1700000000.0 + k) for k in range(1, 11)]
    _insert_rows(tape, rows)
    profile = voice.compute_profile(tape)
    assert profile["sentence_length"]["p90"] == 9.0
    assert profile["sentence_length"]["median"] == 5.5


# --- lens 1 finding #3: zero-alpha corpus must say n/a, never 0.0 ---------------------

def test_zero_alpha_corpus_profile_says_na_not_zero(tmp_path):
    """A corpus with no alphabetic line-opener at all: lowercase_open_ratio must be
    None (n/a) — 0.0 would read 'always opens uppercase' when the truth is 'no data'.
    Also proves compute_profile survives the _ratio zero-denominator path at all
    (under lens 1's guard-removal mutation this corpus crashed with ZeroDivisionError)."""
    tape = Tape(str(tmp_path / "t.db"))
    _insert_rows(tape, [("123 !!! ...", 1700000001.0), ("42 42 42", 1700000002.0)])
    profile = voice.compute_profile(tape)
    assert profile["lowercase_open_ratio"] is None
    summary = voice._format_profile_summary(profile)
    assert any("n/a" in line for line in summary if "lowercase" in line)


def test_ratio_guard_directly():
    """After the n/a fix every caller guards the denominator, so _ratio's own guard is
    defense-in-depth on a path no caller reaches — which also means no behavioral test
    can see it. Pinned directly instead: lens 1 proved this exact guard's removal
    survived the whole suite, and a mutation nothing catches is how the crash returns."""
    assert voice._ratio(3, 4) == 0.75
    assert voice._ratio(3, 0) == 0.0


def test_report_against_na_profile_prints_na_not_crash(tmp_path):
    tape = Tape(str(tmp_path / "t.db"))
    _insert_rows(tape, [("123 !!! ...", 1700000001.0)])
    profile = voice.compute_profile(tape)
    lines = voice.voice_report_lines("hello there. all fine", profile)
    lc = [ln for ln in lines if "lowercase-open" in ln]
    assert lc and "vs profile n/a" in lc[0]


# --- lens 1 finding #1: voice-capture exits 0 even when the db cannot OPEN ------------

def test_voice_capture_exits_zero_on_corrupt_db(tmp_path):
    """The fail-open contract broke BEFORE cmd_capture ran: Tape(args.db) raised in
    main() and returned 3. An observer must never block a prompt — voice-capture (and
    only voice-capture) exits 0 even when the tape cannot be opened at all."""
    bad = tmp_path / "corrupt.db"
    bad.write_bytes(b"this is not a sqlite database, it is 41 bytes of garbage")
    res = _run("voice-capture", "--db", str(bad), stdin="hello world")
    assert res.returncode == 0
    assert res.stdout == ""          # silent, even in failure
    assert "cannot open db" in res.stderr


def test_voice_capture_fails_open_fast_on_a_locked_db(tmp_path):
    """Fix-review finding on ce6ae91: the corrupt-db fix covered the reproduction, not
    the class — a LOCKED db (routine under concurrent tape access) stalled voice-capture
    ~5s on sqlite's default busy wait before failing open. The observer now connects
    with a short busy_timeout. Bound is deliberately loose (< 3s vs the old 5.07s
    measured) so a slow box never makes this flaky; the exit code and silence are the
    hard asserts."""
    import sqlite3 as _sql
    import time as _time
    db = tmp_path / "t.db"
    Tape(str(db))  # create a real tape first
    holder = _sql.connect(str(db))
    holder.execute("BEGIN EXCLUSIVE")
    try:
        t0 = _time.monotonic()
        res = _run("voice-capture", "--db", str(db), stdin="hello while locked")
        elapsed = _time.monotonic() - t0
        assert res.returncode == 0
        assert res.stdout == ""
        assert elapsed < 3.0, f"observer stalled {elapsed:.2f}s on a locked db"
    finally:
        holder.rollback()
        holder.close()


def test_check_still_exits_three_on_corrupt_db(tmp_path):
    """The loud 3 stays for gates — only the observer got the exemption."""
    bad = tmp_path / "corrupt.db"
    bad.write_bytes(b"this is not a sqlite database, it is 41 bytes of garbage")
    res = _run("check", "--db", str(bad), stdin="some draft")
    assert res.returncode == 3


# --- lens 3 B1: check --voice reaches the user on a fresh, rejection-less tape --------

def test_check_voice_prints_report_even_with_no_rejections_seeded(tmp_path):
    """Fresh-install order of events: harvest -> profile -> check --voice, with no
    rejection ever seeded. The floor still refuses to certify (exit 3 — nothing to
    refuse means a pass would mean nothing) but the voice report, which is orthogonal
    to the floor, prints anyway. Numbers with receipts, exit code untouched."""
    db = tmp_path / "t.db"
    tape = Tape(str(db))
    _insert_rows(tape, [("we ship it fast", 1700000001.0),
                        ("no more waiting today", 1700000002.0),
                        ("short and plain words win", 1700000003.0)])
    assert voice.cmd_profile(
        __import__("types").SimpleNamespace(db=str(db)), tape) == 0
    res = _run("check", "--voice", "--db", str(db), stdin="A Draft — In Another Voice.")
    assert res.returncode == 3                       # floor law unchanged
    assert "voice report" in res.stdout              # report reached the user
    assert "NO rejected phrasings" in res.stderr     # the floor still said why


# --- lens 1 finding #4: the accepted Caveat trade-off, pinned as deliberate -----------

# --- ship-diff review: the profile must not outlive its corpus ------------------------

def test_stale_profile_is_cleared_when_corpus_is_emptied(tmp_path):
    """Ship-review BLOCK (2026-08-14): PRIVACY.md promised 'DELETE FROM voice removes
    every word' while voice_profile — a separate table holding real lexicon words and
    hammer phrases — survived the delete and kept serving them. Now: recomputing over
    an emptied corpus clears the stored profile. The derived words die with their
    source."""
    from types import SimpleNamespace
    tape = Tape(str(tmp_path / "t.db"))
    _insert_rows(tape, [("we ship it fast", 1700000001.0),
                        ("no more waiting", 1700000002.0)])
    assert voice.cmd_profile(SimpleNamespace(db="x"), tape) == 0
    assert voice.load_profile(tape) is not None
    tape._conn.execute("DELETE FROM voice")
    tape._conn.commit()
    assert voice.cmd_profile(SimpleNamespace(db="x"), tape) == 0
    assert voice.load_profile(tape) is None, "stale profile survived its corpus"


def test_secret_pattern_lists_stay_in_sync_with_the_hook():
    """The 'CHANGE ONE -> CHANGE THE OTHER' contract between voice.py SECRET_PATTERNS
    and hooks/scripts/maude-secret-scan.sh PATTERNS was a comment; comments don't trip.
    Labels and count must match exactly; regexes must match after normalizing the two
    known POSIX-vs-python dialect spellings ([[:space:]] <-> \\s classes, the shell's
    escaped backtick). A new shape added to one list now fails RED here until it lands
    in both."""
    import re as _re
    sh = (pathlib.Path(__file__).resolve().parents[2]
          / "hooks" / "scripts" / "maude-secret-scan.sh").read_text()
    body = sh[sh.index("PATTERNS=(") + len("PATTERNS=("):]
    body = body[:body.index("\n)")]
    shell_pairs = []
    for m in _re.finditer(r'"([^"|]+)\|(.+?)"\s*$', body, _re.M):
        shell_pairs.append((m.group(1), m.group(2)))
    assert shell_pairs, "could not parse the shell PATTERNS array at all"

    def norm(rx: str) -> str:
        return (rx.replace("[^[:space:]]", r"[^\s]")
                  .replace("[[:space:]]", r"\s")
                  .replace("[:space:]", r"\s")   # POSIX class inside a bracket expr
                  .replace("\\`", "`"))

    py = [(label, rx.pattern) for label, rx in voice.SECRET_PATTERNS]
    assert [l for l, _ in py] == [l for l, _ in shell_pairs], "label lists drifted"
    for (pl, pr), (sl, sr) in zip(py, shell_pairs):
        assert norm(pr) == norm(sr), f"pattern drifted for {pl!r}: {pr!r} vs {sr!r}"


# --- v1.1: the typed-prose cut (the first real corpus was two voices) -----------------

def test_profile_excludes_paste_length_lines_and_counts_them(tmp_path):
    """Hand-computed: three typed lines + one 450-char paste. The paste must not move a
    single stat — median/lowercase-open computed from the three typed lines alone —
    and the honesty block must count exactly 1 excluded line at the shipped threshold.
    Typed lines: "we ship it" (3 words, lower), "no waiting" (2, lower),
    "Go now team" (3, UPPER) -> median 3.0, lowercase-open 2/3."""
    tape = Tape(str(tmp_path / "t.db"))
    paste = ("def test_x():\n    assert 1 == 1\n" * 16)   # 480 chars of code-paste
    assert len(paste) >= voice.PASTE_CHAR_THRESHOLD
    _insert_rows(tape, [("we ship it", 1700000001.0),
                        ("no waiting", 1700000002.0),
                        ("Go now team", 1700000003.0),
                        (paste, 1700000004.0)])
    profile = voice.compute_profile(tape)
    assert profile["profile_version"] == 2
    assert profile["n_lines"] == 3                       # the paste is not a line of voice
    assert profile["sentence_length"]["median"] == 3.0
    assert profile["lowercase_open_ratio"] == round(2 / 3, 4) or \
           abs(profile["lowercase_open_ratio"] - 2 / 3) < 1e-9
    assert profile["honesty"]["lines_excluded_as_paste"] == 1
    assert profile["honesty"]["paste_threshold_chars"] == voice.PASTE_CHAR_THRESHOLD
    assert "def" not in profile["lexicon"]               # paste vocabulary never leaks in


def test_date_range_derives_from_typed_rows_only(tmp_path):
    """Post-review finding (2026-08-14): the v2 cut filtered text but read timestamps
    from the UNFILTERED rows — a paste dated months later padded date_range with a day
    holding zero typed content. Reviewer's exact repro, pinned: typed lines all on one
    date, one paste on a later date; the range must not reach the paste's date."""
    tape = Tape(str(tmp_path / "t.db"))
    day1 = 1735689600.0   # 2025-01-01 UTC
    later = 1750000000.0  # 2025-06-15 UTC
    _insert_rows(tape, [("we ship it", day1), ("no waiting", day1 + 60),
                        ("x" * 500, later)])
    profile = voice.compute_profile(tape)
    assert profile["date_range"]["oldest"] == "2025-01-01"
    assert profile["date_range"]["newest"] == "2025-01-01"   # NOT 2025-06-15


def test_all_paste_corpus_message_does_not_say_harvest_first(tmp_path):
    """Post-review finding #2: a nonempty all-paste corpus told the user 'harvest
    first' — actively wrong, harvest already ran. The two causes of a None profile
    get different sentences now."""
    from types import SimpleNamespace
    import io, contextlib
    tape = Tape(str(tmp_path / "t.db"))
    _insert_rows(tape, [("x" * 500, 1700000001.0)])
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = voice.cmd_profile(SimpleNamespace(db="ignored"), tape)
    assert rc == 0
    out = buf.getvalue()
    assert "harvest first" not in out
    assert "paste-length" in out and "1" in out


def test_profile_of_only_pastes_is_none(tmp_path):
    """A corpus holding nothing under the threshold has no typed voice to derive —
    None, same contract as an empty corpus, never a profile built from pastes."""
    tape = Tape(str(tmp_path / "t.db"))
    _insert_rows(tape, [("x" * 500, 1700000001.0)])
    assert voice.compute_profile(tape) is None


def test_boundary_line_just_under_threshold_is_voice(tmp_path):
    """399 chars of prose is voice; 400 is paste. The fence itself is pinned."""
    tape = Tape(str(tmp_path / "t.db"))
    under = "w " * 199 + "w"          # 399 chars exactly
    assert len(under) == 399
    _insert_rows(tape, [(under, 1700000001.0), ("x" * 400, 1700000002.0)])
    profile = voice.compute_profile(tape)
    assert profile["n_lines"] == 1
    assert profile["honesty"]["lines_excluded_as_paste"] == 1


def test_caveat_prefixed_human_prose_is_dropped_by_design():
    """A genuine human line that begins with the literal drop-prefix text is eaten.
    ACCEPTED trade-off (lens 1 #4): the prefix law prefers eating a vanishingly rare
    human phrasing over ever letting a system wrapper into the corpus. This test pins
    the behavior so a future change is a decision, not an accident."""
    record = {
        "type": "user", "userType": "external", "isMeta": False, "isSidechain": False,
        "message": {"role": "user",
                    "content": "Caveat: the messages below in the log look odd, check them"},
    }
    assert voice.extract_prompt_text(record) is None
