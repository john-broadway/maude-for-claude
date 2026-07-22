"""Semantic recall — the tape recalls by MEANING, not just an exact topic string. The embedder
is injected (a callable text->vector) so the loop is tested with a deterministic fake; production
wires a BYO embedding service behind the same seam. Generic example data.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def _fake_embed(text: str) -> list[float]:
    """Deterministic stand-in: 3 axes — [small/scope, own/build, care]."""
    t = text.lower()
    return [
        1.0 if any(w in t for w in ("small", "scope", "scale", "tight", "footprint")) else 0.0,
        1.0 if any(w in t for w in ("own", "build", "tools", "independent")) else 0.0,
        1.0 if "care" in t else 0.0,
    ]


def test_semantic_recall_returns_the_nearest_meaning(tmp_path):
    tape = Tape(tmp_path / "t.db", embedder=_fake_embed)
    tape.remember("keep it small", topic="scope", source="user")
    tape.remember("I own what I build", topic="own", source="user")
    tape.remember("I care about the details", topic="care", source="user")

    # a query that never uses the topic word, but means it
    hits = tape.recall_semantic("make the footprint tight", k=1)
    assert hits[0].topic == "scope"

    hits2 = tape.recall_semantic("independence and owning your tools", k=1)
    assert hits2[0].topic == "own"


def test_semantic_recall_degrades_to_empty_without_an_embedder(tmp_path):
    tape = Tape(tmp_path / "t.db")  # bare home: no embedder wired
    tape.remember("keep it small", topic="scope", source="user")

    assert tape.recall_semantic("anything") == []  # graceful: no crash, no guess
