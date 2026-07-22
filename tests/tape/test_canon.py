"""The canon: the user's verbatim words are primary. Corrections supersede — they never duplicate,
and they never erase history (bi-temporal supersession). Generic example data.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def test_verbatim_is_recalled_for_its_topic(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    tape.remember("keep it small", topic="scope", source="user-2026")

    entries = tape.recall("scope")

    assert len(entries) == 1
    assert "keep it small" in entries[0].text
    assert entries[0].authority == "user-verbatim"  # default authority for the user's words


def test_correction_supersedes_old_wording_but_keeps_history(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    old = tape.remember(
        "we heroically slashed scope against all odds", topic="scope",
        source="agent-draft", authority="agent-inference",
    )
    tape.remember("keep it small", topic="scope", source="user-2026", supersedes=old)

    current = tape.recall("scope")
    assert [e.text for e in current] == ["keep it small"]  # only the current truth

    history = tape.recall("scope", include_superseded=True)
    assert len(history) == 2  # nothing is thrown away


def test_current_truth_outranks_by_authority(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    tape.remember("own the market", topic="own",
                  source="agent-draft", authority="agent-inference")
    tape.remember("I own what I build", topic="own",
                  source="user", authority="user-verbatim")

    entries = tape.recall("own")

    assert entries[0].authority == "user-verbatim"  # the user's words lead, always
