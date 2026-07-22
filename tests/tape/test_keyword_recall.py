"""Keyword recall — the FLOOR of recall. A bare home (no embedder wired) still finds a
memory by a word in its text. Rightful degradation: an embedder gives meaning-recall;
without one, recall degrades to keyword — real recall, never empty. Generic example data.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def test_keyword_recall_finds_by_a_word_in_the_text_without_an_embedder(tmp_path):
    tape = Tape(tmp_path / "t.db")  # bare home: no embedder
    tape.remember("keep the footprint small", topic="scope", source="user")
    tape.remember("I own what I build", topic="own", source="user")

    hits = tape.recall_keyword("footprint")

    assert len(hits) == 1
    assert hits[0].topic == "scope"


def test_keyword_recall_returns_only_current_truth_not_superseded(tmp_path):
    tape = Tape(tmp_path / "t.db")  # bare home
    old = tape.remember("early wording here", topic="t", source="user")
    tape.remember("final wording here", topic="t", source="user", supersedes=old)

    hits = tape.recall_keyword("wording")

    assert [h.text for h in hits] == ["final wording here"]
