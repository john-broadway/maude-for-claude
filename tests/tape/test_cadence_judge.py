"""The cadence judge — the model tier of the voice gate. The deterministic gate (check_draft)
catches KNOWN rejected phrasings; it cannot see robotic *cadence* — the concede→pivot→reframe
rhythm, the rule-of-three, the essay-bot connective — because cadence is not a phrase. A wired
judge (a model, BYO like the embedder) reads the draft for that tell. Without one, the judge tier
degrades to empty and the deterministic floor still runs. Generic example data.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def _fake_judge(text: str) -> list[tuple[str, str]]:
    """Deterministic stand-in for a model reading cadence — flags one essay-bot connective.
    The real judge is a wired model; this proves the seam, not the cadence science."""
    if "moreover" in text.lower():
        return [("connective-tell", "'moreover' reads as essay-bot, not plain speech")]
    return []


def test_judge_draft_flags_robotic_cadence_when_a_judge_is_wired(tmp_path):
    tape = Tape(tmp_path / "t.db", judge=_fake_judge)

    flags = tape.judge_draft("The build is done. Moreover, the tests pass.")

    assert len(flags) == 1
    assert flags[0].tell == "connective-tell"
    assert "essay-bot" in flags[0].why  # the flag carries WHY, so Claude learns, not just blocks


def test_judge_draft_passes_a_clean_draft(tmp_path):
    tape = Tape(tmp_path / "t.db", judge=_fake_judge)

    flags = tape.judge_draft("The build is done. The tests pass.")

    assert flags == []  # no false positive on a plain draft


def test_judge_draft_degrades_to_empty_without_a_judge(tmp_path):
    tape = Tape(tmp_path / "t.db")  # bare home: no judge wired

    # a draft the judge WOULD flag — but with no model tier, the judge returns nothing rather
    # than guess. The deterministic check_draft remains the floor (tested separately).
    flags = tape.judge_draft("The build is done. Moreover, the tests pass.")

    assert flags == []
