"""The derived profile (`maude_tape/voice.py` compute_profile/cmd_profile — component
of the voice feature). Every number here is HAND-COMPUTED in the test itself
from a small synthetic corpus — never asserted against a constant built by calling the
same function under test (that would prove nothing).

All fixtures are SYNTHETIC. No real transcript or real corpus content is ever read.
"""
from __future__ import annotations

import json
import pathlib
import sys
from datetime import datetime, timezone
from types import SimpleNamespace

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import voice
from maude_tape.tape import Tape


def _insert_rows(tape, rows: list[tuple[str, float]]) -> None:
    """rows: [(text, ts_epoch), ...]. Inserts directly into the voice table — the
    profile is derived from that table alone, so setup never needs harvest/capture.
    sha is derived from text+ts (not a per-call counter) so two separate _insert_rows
    calls against the same tape (growing a corpus across a test) never collide."""
    for text, ts in rows:
        sha = f"sha-{hash((text, ts))}"
        tape._conn.execute(
            "INSERT INTO voice (ts, text, source, register, session, sha) "
            "VALUES (?, ?, 'synthetic', 'chat', NULL, ?)",
            (ts, text, sha),
        )
    tape._conn.commit()


def _ts(iso: str) -> float:
    return datetime.fromisoformat(iso).replace(tzinfo=timezone.utc).timestamp()


# --- sentence length / lowercase-open / punctuation: hand-computed -------------------

def test_compute_profile_sentence_lowercase_punctuation_and_date_range_hand_computed(tmp_path):
    """Four rows, hand-computed expectations:

    A = "we ship it. we ship it fast"      -> sentences [3, 4] words, opens lowercase
    B = "wait... let's ship it fast"       -> sentences [1, 4] words, opens lowercase,
                                               one "..." (3-dot run, NOT a ".." hit)
    C = "Ship it fast — no more waiting; go" -> one sentence [8] words (no . ! ?
                                               at all), opens UPPERCASE, one em-dash,
                                               one semicolon
    D = "we ship it. done"                 -> sentences [3, 1] words, opens lowercase

    n_lines=4. n_words = 7+5+8+4 = 24 (len(line.split()) per row, matching the sum of
    that row's own sentence word counts since sentence-splitting never drops a token).
    Flattened sentence word counts in row order: [3,4, 1,4, 8, 3,1] -> sorted
    [1,1,3,3,4,4,8]. median (7 values, odd) = the 4th = 3.0. p90 = nearest-rank,
    idx = ceil(0.9*7)-1 = 6 (0-based) -> sorted[6] = 8.0.
    lowercase-open: A,B,D open lowercase, C opens uppercase -> 3/4 = 0.75.
    punctuation per 100 lines (n_lines=4): ".." -> 0/4*100=0.0, "..." -> 1/4*100=25.0,
    em-dash -> 1/4*100=25.0, ";" -> 1/4*100=25.0, "!" -> 0/4*100=0.0.
    date_range: oldest 2026-07-30, newest 2026-08-03 (ts values chosen out of row order
    on purpose, so this also proves date_range is MIN/MAX over ts, not insertion order).
    """
    tape = Tape(tmp_path / "tape.db")
    _insert_rows(tape, [
        ("we ship it. we ship it fast", _ts("2026-08-01T10:00:00")),
        ("wait... let's ship it fast", _ts("2026-08-02T10:00:00")),
        ("Ship it fast — no more waiting; go", _ts("2026-08-03T10:00:00")),
        ("we ship it. done", _ts("2026-07-30T10:00:00")),
    ])

    profile = voice.compute_profile(tape)

    assert profile["profile_version"] == 2
    assert profile["n_lines"] == 4
    assert profile["n_words"] == 24
    assert profile["date_range"] == {"oldest": "2026-07-30", "newest": "2026-08-03"}
    assert profile["sentence_length"] == {"median": 3.0, "p90": 8.0}
    assert profile["lowercase_open_ratio"] == 0.75
    assert profile["punctuation_per_100_lines"] == {
        "..": 0.0, "...": 25.0, "—": 25.0, ";": 25.0, "!": 0.0,
    }


def test_compute_profile_accepts_a_raw_sqlite_connection_too(tmp_path):
    """compute_profile(conn or tape) per the C2 contract: a bare sqlite3.Connection
    must work identically to handing it a Tape."""
    tape = Tape(tmp_path / "tape.db")
    _insert_rows(tape, [("hello there. how are you", _ts("2026-08-01T00:00:00"))])

    via_tape = voice.compute_profile(tape)
    via_conn = voice.compute_profile(tape._conn)
    assert via_tape == via_conn


# --- hammers: min-freq, all-stopword exclusion, containment prune --------------------

def test_compute_profile_hammers_min_freq_stopword_exclusion_and_containment_prune(tmp_path):
    """Corpus built to exercise all three hammer rules at once:

    - "let's ship it now" x3  -> the 4-gram survives at freq 3. Its 3-gram prefix
      ("let's ship it") occurs ONLY inside this 4-gram (same count, 3) -> PRUNED.
    - "we ship it fast" x3    -> makes the bigram ("ship","it") occur 3+3=6 times
      total, which does NOT equal any single longer gram's count (each longer gram
      containing it sits at 3) -> ("ship","it") is NOT entirely contained in one
      longer form, so it SURVIVES as its own hammer ("ship it": 6).
    - "it is the plan" x3     -> the 3-gram "it is the" is ALL STOPWORDS (it/is/the
      all in STOPWORDS) -> excluded regardless of freq. The 3-gram "is the plan" is
      NOT all-stopword but sits entirely inside the 4-gram "it is the plan" at the
      same count (3) -> PRUNED by containment, same rule as above.
    """
    tape = Tape(tmp_path / "tape.db")
    rows = []
    t = _ts("2026-08-01T00:00:00")
    for i in range(3):
        rows.append((f"let's ship it now", t + i))
    for i in range(3):
        rows.append((f"we ship it fast", t + 10 + i))
    for i in range(3):
        rows.append((f"it is the plan", t + 20 + i))
    _insert_rows(tape, rows)

    profile = voice.compute_profile(tape)
    hammers = profile["hammers"]

    # survives at the longest form
    assert hammers.get("let's ship it now") == 3
    assert hammers.get("it is the plan") == 3
    # a bigram that occurs OUTSIDE any single longer container too: not pruned
    assert hammers.get("ship it") == 6

    # pruned: entirely contained in ONE longer surviving gram at the same count
    assert "let's ship it" not in hammers
    assert "is the plan" not in hammers

    # excluded: every token is a stopword, regardless of frequency
    assert "it is the" not in hammers
    assert "it is" not in hammers   # both tokens are stopwords
    assert "is the" not in hammers  # both tokens are stopwords


def test_compute_profile_hammers_respect_min_frequency_of_three(tmp_path):
    """A phrase repeated only twice must never appear in hammers (min_freq=3)."""
    tape = Tape(tmp_path / "tape.db")
    t = _ts("2026-08-01T00:00:00")
    _insert_rows(tape, [
        ("build the widget carefully", t),
        ("build the widget carefully", t + 1),   # only 2 repeats
    ])

    profile = voice.compute_profile(tape)
    assert "build the widget" not in profile["hammers"]
    assert "build the widget carefully" not in profile["hammers"]


# --- shadow words: whole-word, case-insensitive ---------------------------------------

def test_compute_profile_shadow_hits_are_whole_word_and_case_insensitive(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    t = _ts("2026-08-01T00:00:00")
    _insert_rows(tape, [
        ("we should leverage this fully", t),
        ("please delve into that", t + 1),
        ("he delved deeply into it", t + 2),   # decoy: must NOT count toward "delve"
        ("LEVERAGE it again please", t + 3),   # case-insensitive
        ("no tells here at all", t + 4),
    ])

    profile = voice.compute_profile(tape)
    shadow = profile["shadow_hits"]

    assert set(shadow.keys()) == set(voice.AI_TELL_WORDS)
    assert shadow["leverage"] == 2
    assert shadow["delve"] == 1          # "delved" must not match "delve"
    assert shadow["robust"] == 0
    assert shadow["seamless"] == 0


# --- honesty field ----------------------------------------------------------------------

def test_compute_profile_honesty_field_is_present_and_exact(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    _insert_rows(tape, [("one line is enough", _ts("2026-08-01T00:00:00"))])

    profile = voice.compute_profile(tape)
    assert profile["honesty"] == {
        "scope": "typed plain-text prose prompts only; bang-commands, pasted/array "
                 "content, and command wrappers excluded at harvest",
        "date_floor_note": "transcripts prune ~30d; corpus depth = date_range, not "
                            "account age",
        "paste_threshold_chars": voice.PASTE_CHAR_THRESHOLD,
        "lines_excluded_as_paste": 0,
        "paste_note": "a threshold, not a classifier: lines >= the threshold are "
                      "treated as pasted material, not typed voice",
    }


# --- empty corpus ------------------------------------------------------------------------

def test_compute_profile_returns_none_on_an_empty_corpus(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    assert voice.compute_profile(tape) is None


def test_cmd_profile_on_empty_corpus_prints_exact_message_stores_nothing_exits_zero(
    tmp_path, capsys
):
    tape = Tape(tmp_path / "tape.db")
    rc = voice.cmd_profile(SimpleNamespace(), tape)

    assert rc == 0
    out = capsys.readouterr().out.strip()
    assert out == "profile: voice corpus is empty — harvest first"

    (count,) = tape._conn.execute("SELECT COUNT(*) FROM voice_profile").fetchone()
    assert count == 0


# --- cmd_profile: storage + idempotent recompute ---------------------------------------

def test_cmd_profile_stores_json_in_voice_profile_row_id_1(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    _insert_rows(tape, [("hello there. how are you", _ts("2026-08-01T00:00:00"))])

    rc = voice.cmd_profile(SimpleNamespace(), tape)
    assert rc == 0

    row = tape._conn.execute("SELECT id, ts, json FROM voice_profile").fetchone()
    assert row is not None
    rid, ts, payload = row
    assert rid == 1
    assert ts is not None
    stored = json.loads(payload)
    assert stored == voice.compute_profile(tape)


def test_cmd_profile_recompute_is_idempotent_insert_or_replace_never_duplicates(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    _insert_rows(tape, [("first pass through the corpus", _ts("2026-08-01T00:00:00"))])
    voice.cmd_profile(SimpleNamespace(), tape)

    (count_after_first,) = tape._conn.execute("SELECT COUNT(*) FROM voice_profile").fetchone()
    assert count_after_first == 1

    # a second row lands, then recompute: still exactly one voice_profile row, and its
    # JSON reflects the WIDER corpus, not the first snapshot.
    _insert_rows(tape, [("a second line joins the corpus", _ts("2026-08-02T00:00:00"))])
    voice.cmd_profile(SimpleNamespace(), tape)

    (count_after_second,) = tape._conn.execute("SELECT COUNT(*) FROM voice_profile").fetchone()
    assert count_after_second == 1

    (payload,) = tape._conn.execute("SELECT json FROM voice_profile WHERE id = 1").fetchone()
    stored = json.loads(payload)
    assert stored["n_lines"] == 2


def test_cmd_profile_prints_a_short_human_summary(tmp_path, capsys):
    tape = Tape(tmp_path / "tape.db")
    _insert_rows(tape, [("hello there. how are you doing today", _ts("2026-08-01T00:00:00"))])

    voice.cmd_profile(SimpleNamespace(), tape)
    out_lines = [l for l in capsys.readouterr().out.splitlines() if l.strip()]

    assert 1 <= len(out_lines) <= 8   # "a handful of lines", not a page
    assert out_lines[0].startswith("profile:")


# --- CLI end-to-end: proves the __main__.py `profile` wiring is real -------------------

def test_profile_end_to_end_via_the_real_cli(tmp_path):
    import subprocess

    root = pathlib.Path(__file__).resolve().parents[2]
    db = tmp_path / "tape.db"

    # empty-corpus path over the real CLI
    r_empty = subprocess.run(
        [sys.executable, "-m", "maude_tape", "profile", "--db", str(db)],
        cwd=root, capture_output=True, text=True,
    )
    assert r_empty.returncode == 0
    assert "voice corpus is empty" in r_empty.stdout

    tape = Tape(db)
    _insert_rows(tape, [("hello there. how are you doing today", _ts("2026-08-01T00:00:00"))])

    r = subprocess.run(
        [sys.executable, "-m", "maude_tape", "profile", "--db", str(db)],
        cwd=root, capture_output=True, text=True,
    )
    assert r.returncode == 0
    assert r.stdout.startswith("profile:")

    (count,) = tape._conn.execute("SELECT COUNT(*) FROM voice_profile").fetchone()
    assert count == 1
