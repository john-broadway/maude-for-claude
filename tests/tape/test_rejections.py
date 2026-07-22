"""The tape's most important job: never let a phrasing the user rejected reach the page again.

The rejection ledger + the deterministic draft check make re-serving a rejected line structurally
impossible. Generic example data — the public plugin ships no personal words.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def test_rejected_phrase_is_flagged_when_it_appears_in_a_draft(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    tape.reject(
        "heroically slashed scope",
        reason="dramatization; the user said 'keep it small'",
        source="user-2026",
    )

    hits = tape.check_draft("we kept it small, then heroically slashed scope.")

    assert [h.phrase for h in hits] == ["heroically slashed scope"]
    assert "keep it small" in hits[0].reason
    assert hits[0].source == "user-2026"


def test_clean_draft_has_no_hits(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    tape.reject("heroically slashed scope", reason="dramatization", source="user-2026")

    hits = tape.check_draft("we kept it small.")

    assert hits == []
