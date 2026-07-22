"""Consolidate = collect->remember. A correction must not die in a log: one call promotes it to
durable canon — rejection recorded, wrong wording superseded by the user's real words — so the
next wake plays a complete tape. Generic example data.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def test_consolidate_correction_records_rejection_and_supersedes(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    tape.remember("we heroically slashed scope against all odds", topic="scope",
                  source="agent-draft", authority="agent-inference")

    tape.consolidate_correction(
        rejected="heroically slashed scope",
        reason="dramatization; the user said 'keep it small'",
        corrected_to="keep it small",
        topic="scope",
        source="user-2026",
    )

    # the rejection is now catchable at point of use
    assert tape.check_draft("... then heroically slashed scope.")
    # the user's real words are the current truth; the wrong rendering is superseded, not lost
    assert [e.text for e in tape.recall("scope")] == ["keep it small"]
    assert len(tape.recall("scope", include_superseded=True)) == 2
