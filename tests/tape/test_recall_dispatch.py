"""Recall dispatch — one door over the two recall engines. The tape recalls by MEANING when
the home has an embedder wired, and degrades to keyword (by-word) recall when it does not — or
when nothing is embedded yet. Rightful degradation: the appliance changes the QUALITY of recall,
never whether recall happens. A home with the answer by word never gets an empty hand. Generic
example data.
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


def test_recall_relevant_uses_meaning_when_an_embedder_is_wired(tmp_path):
    tape = Tape(tmp_path / "t.db", embedder=_fake_embed)
    tape.remember("keep it small", topic="scope", source="user")
    tape.remember("I own what I build", topic="own", source="user")

    # query shares NO words with the target — only keyword recall would miss it, so a hit
    # here proves the dispatcher went through the semantic engine.
    hits = tape.recall_relevant("make the footprint tight", k=1)

    assert hits[0].topic == "scope"


def test_recall_relevant_degrades_to_keyword_without_an_embedder(tmp_path):
    tape = Tape(tmp_path / "t.db")  # bare home: no embedder wired
    tape.remember("keep the footprint small", topic="scope", source="user")
    tape.remember("I own what I build", topic="own", source="user")

    # semantic recall alone returns [] on a bare home; the dispatcher must still find it by word.
    hits = tape.recall_relevant("footprint")

    assert len(hits) == 1
    assert hits[0].topic == "scope"


def test_recall_relevant_falls_through_to_keyword_when_nothing_is_embedded(tmp_path):
    # A home that wired the embedder AFTER canon was already written: the rows carry no
    # embedding, so semantic recall returns [] — the dispatcher must not hand back empty when
    # keyword recall can still find it.
    db = tmp_path / "t.db"
    bare = Tape(db)  # written with no embedder → rows have NULL embedding
    bare.remember("keep the footprint small", topic="scope", source="user")

    later = Tape(db, embedder=_fake_embed)  # embedder wired later; old rows still unembedded
    hits = later.recall_relevant("footprint")

    assert len(hits) == 1
    assert hits[0].topic == "scope"
