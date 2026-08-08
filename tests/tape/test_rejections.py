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


def test_hits_come_back_in_the_order_recorded_not_the_order_they_appear(tmp_path):
    """check_draft's docstring promises "in order recorded". Nothing enforced it.

    The guarantee rests entirely on ORDER BY id, so a future query rewrite or a set-based
    collection would break the contract silently. The draft below deliberately puts the
    SECOND-recorded phrase FIRST in the text, so appearance-order and record-order disagree.
    """
    from maude_tape.tape import Tape
    tape = Tape(tmp_path / "t.db")
    tape.reject("zebra phrasing", reason="first recorded", source="test")
    tape.reject("alpha phrasing", reason="second recorded", source="test")

    hits = tape.check_draft("alpha phrasing comes first in the text, zebra phrasing second")
    assert [h.phrase for h in hits] == ["zebra phrasing", "alpha phrasing"]
