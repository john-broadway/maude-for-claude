"""maude_recall: three rungs behind one recall() (seeing-gap design, Part A).

Rung 1 keyword (FTS5, porter), rung 2 sub-word (FTS5 trigram), rung 3 the house's own
embedder. Every hit names the rung that found it. A stub embedder stands in for the house's:
it maps words onto a few fixed meanings, so "vectorized" and "embedding" mean the same thing
and share no letters with each other's spelling.
"""
from __future__ import annotations

import json
import pathlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_recall import chunk
from maude_recall.store import Store

MEANINGS = {
    "vectorized": 0, "embedding": 0, "embedder": 0, "vectors": 0,
    "local": 1, "localized": 1, "sovereign": 1,
    "merge": 2, "ship": 2,
    "dinner": 3, "recipe": 3,
}
CALLS = []


def _vec(text):
    v = [0.0] * 5
    for w in text.lower().replace(":", " ").split():
        v[MEANINGS.get(w.strip(".,"), 4)] += 1.0
    return v


class _Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        inputs = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["input"]
        CALLS.append(list(inputs))
        body = json.dumps({"model": "stub", "data": [{"index": i, "embedding": _vec(t)}
                                                     for i, t in enumerate(inputs)]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)


@pytest.fixture
def emb():
    srv = HTTPServer(("127.0.0.1", 0), _Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    CALLS.clear()
    yield {"url": f"http://127.0.0.1:{srv.server_port}/v1/embeddings", "model": "nomic-stub", "dim": 5}
    srv.shutdown()


DOCS = [
    ("a", "he wants a sovereign embedder on the box", 3.0),
    ("b", "merge it when the lens is clean", 2.0),
    ("c", "a recipe for dinner", 1.0),
]


def _store(tmp_path):
    s = Store(tmp_path / "recall.db")
    s.sync("vault", DOCS)
    return s


def test_keyword_rung_finds_the_word(tmp_path):
    hits = _store(tmp_path).recall("lens", k=3)
    assert [(h.key, h.rung) for h in hits] == [("b", "keyword")]


def test_subword_rung_finds_part_of_a_word(tmp_path):
    hits = _store(tmp_path).recall("bedde", k=3)  # mid-word: no stem reaches it
    assert [(h.key, h.rung) for h in hits] == [("a", "subword")]


def test_semantic_rung_finds_the_meaning_with_no_shared_word(tmp_path, emb):
    s = _store(tmp_path)
    assert s.embed_pending(emb, budget=10) == 3
    hits = s.recall("localized vectorized", k=1, emb=emb)
    assert [(h.key, h.rung) for h in hits] == [("a", "semantic")]


def test_without_an_embedder_recall_still_answers_from_the_floor(tmp_path):
    hits = _store(tmp_path).recall("recipe", k=3, emb=None)
    assert [h.key for h in hits] == ["c"] and hits[0].rung != "semantic"


def test_a_down_embedder_falls_through_to_the_floor(tmp_path, emb):
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10)
    dead = dict(emb, url="http://127.0.0.1:9/v1/embeddings")
    hits = s.recall("lens", k=3, emb=dead)
    assert [(h.key, h.rung) for h in hits] == [("b", "keyword")]


def test_only_new_or_changed_text_is_embedded(tmp_path, emb):
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10)
    CALLS.clear()
    s.sync("vault", [("a", DOCS[0][1], 3.0), ("b", "merge on green", 2.0), ("c", DOCS[2][1], 1.0)])
    assert s.embed_pending(emb, budget=10) == 1
    assert CALLS == [["search_document: merge on green"]]


def test_a_new_model_re_embeds(tmp_path, emb):
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10)
    assert s.embed_pending(dict(emb, model="nomic-other"), budget=10) == 3  # same prefix: only the model differs


def test_a_dropped_source_leaves_the_store(tmp_path):
    s = _store(tmp_path)
    s.sync("vault", DOCS[:1])
    assert s.recall("lens", k=3) == [] and s.recall("dinner", k=3) == []


def test_newest_is_embedded_first(tmp_path, emb):
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10, batch=1, limit=1)
    assert CALLS == [["search_document: he wants a sovereign embedder on the box"]]


def test_a_blank_query_is_refused(tmp_path):
    with pytest.raises(ValueError):
        _store(tmp_path).recall("   ")


def test_the_query_carries_the_query_prefix(tmp_path, emb):
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10)
    CALLS.clear()
    s.recall("local", k=1, emb=emb)
    assert CALLS == [["search_query: local"]]


def test_chunks_fit_the_window_and_keep_every_word():
    text = ("word " * 50 + "\n\n") * 40
    parts = chunk.split(text, limit=600)
    assert all(len(p) <= 600 for p in parts)
    assert sum(p.count("word") for p in parts) == 2000
    assert chunk.split("x" * 1500, limit=600) == ["x" * 600, "x" * 600, "x" * 300]


def test_every_hit_names_its_best_rung_and_every_rung_that_placed_it(tmp_path, emb):
    s = Store(tmp_path / "recall.db")
    docs = ([(f"x{i}", "the sovereign embedder holds the lens", float(i)) for i in range(4)]
            + [(f"y{i}", "sovereign boxes keep quiet", float(i)) for i in range(4)] + list(DOCS)
            + [("z", "it holds", 0.0)])  # shares no query word; "holds" only ever sits beside them
    s.sync("vault", docs)
    s.embed_pending(emb, budget=10)
    s.learn_table()
    hits = s.recall("sovereign embedder lens", k=len(docs), emb=emb, min_score=0.93)
    assert all(h.rung in h.rungs for h in hits)
    assert "semantic" in hits[0].rungs  # meaning placed the best hit, and the reader can see it
    by_key = {h.key: h for h in hits}
    assert by_key["z"].rungs == ("hers",)  # found by her table alone, and labelled so
    assert len({h.key.split("#", 1)[0] for h in hits}) == len(hits)  # never the same note twice


def test_a_vector_follows_the_text_not_the_item(tmp_path, emb):
    """Content-addressed: an item dropped and put back with the same words (a rename, a replay
    cut) keeps its vector, and nothing is embedded twice."""
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10)
    s.sync("vault", [("renamed", DOCS[0][1], 3.0)] + DOCS[1:])
    CALLS.clear()
    assert s.embed_pending(emb, budget=10) == 0
    assert CALLS == []
    assert s.recall("localized vectorized", k=1, emb=emb)[0].key == "renamed"


def test_a_store_with_the_old_vector_table_is_re_embedded(tmp_path, emb):
    import sqlite3
    p = tmp_path / "old.db"
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE vectors (item_id INTEGER PRIMARY KEY, vhash TEXT NOT NULL, "
              "dim INTEGER NOT NULL, vec BLOB NOT NULL)")
    c.commit()
    c.close()
    s = Store(p)
    s.sync("vault", DOCS)
    assert s.embed_pending(emb, budget=10) == 3


def test_cards_are_embedded_before_anything_else(tmp_path, emb):
    s = _store(tmp_path)
    s.sync("card", [("a", "a card", 0.0)])
    s.embed_pending(emb, budget=10, batch=1, limit=1)
    assert CALLS == [["search_document: a card"]]


def test_a_namespace_can_be_embedded_alone(tmp_path, emb):
    s = _store(tmp_path)
    s.sync("card", [("a", "a card", 0.0)])
    assert s.embed_pending(emb, budget=10, ns="card") == 1
    assert s.pending(emb) == 3


def test_the_cache_spares_a_second_store_the_embedder(tmp_path, emb):
    cache = tmp_path / "vcache"
    s = _store(tmp_path)
    s.embed_pending(emb, budget=10, cache=cache)
    t = Store(tmp_path / "other.db")
    t.sync("vault", DOCS)
    CALLS.clear()
    assert t.embed_pending(emb, budget=10, cache=cache) == 3
    assert CALLS == []
    assert t.recall("localized vectorized", k=1, emb=emb)[0].key == "a"


def test_the_card_rung_reads_the_cards_as_the_vaults(tmp_path, emb):
    s = _store(tmp_path)
    s.sync("card", [("a", "the sovereign embedder card", 3.0)])  # key = the note's path
    s.embed_pending(emb, budget=10, ns="card")
    (hit,) = s.recall("localized vectorized", k=1, ns="vault", emb=emb)
    assert (hit.key, hit.rung) == ("a", "card")
    assert s.recall("localized vectorized", k=1, ns="tape", emb=emb) == []


def _it(key, ns="vault"):
    return (0, ns, key, key, 1.0)


def test_fusion_agreement_beats_a_lone_first_place():
    from maude_recall.store import fuse
    hits = fuse([("keyword", [_it("c"), _it("a"), _it("b")]), ("hers", [_it("a"), _it("b"), _it("c")])], 3)
    assert [h.key for h in hits] == ["a", "c", "b"]
    assert hits[0].rung == "hers" and hits[0].rungs == ("keyword", "hers")


def test_fusion_collapses_chunks_and_cards_to_one_note():
    from maude_recall.store import fuse
    hits = fuse([("card", [_it("n.md", "card")]), ("keyword", [_it("n.md#1"), _it("n.md#0")])], 5)
    assert [(h.key, h.rungs) for h in hits] == [("n.md", ("card", "keyword"))]
    one = fuse([("card", [_it("m.md", "card")]), ("keyword", [_it("m.md#0")])], 5)[0].score
    assert hits[0].score == one  # a note's chunks vote once, not once each


def test_the_keyword_rungs_first_pick_never_falls_out_of_the_top_k():
    """Six near-twins two rungs agree on would push the one note holding his ctid past k:
    words have the last word, and only words (her table's first pick gets no such slot)."""
    from maude_recall.store import fuse
    twins = [_it(f"t{i}.md") for i in range(6)]
    hits = fuse([("keyword", [_it("ctid.md")] + twins), ("hers", twins)], 5)
    assert [h.key for h in hits][:4] == ["t0.md", "t1.md", "t2.md", "t3.md"]
    assert (hits[4].key, hits[4].rung) == ("ctid.md", "keyword")
    assert fuse([("keyword", [_it("ctid.md")] + twins), ("hers", twins)], 1)[0].key == "t0.md"
    soft = fuse([("keyword", twins), ("semantic", twins[1:] + twins[:1]), ("hers", [_it("h.md")] + twins)], 5)
    assert "h.md" not in [h.key for h in soft] and len({h.key for h in soft}) == 5  # and no note twice


def test_the_cards_are_the_card_rungs_alone_whatever_the_namespace(tmp_path, emb):
    """With no namespace asked, the semantic rung, words and her table skip the cards: one
    vector, one vote (the replay measured ns="vault"; the CLI's default is none)."""
    s = _store(tmp_path)
    s.sync("card", [("a", "the sovereign embedder card", 3.0), ("q", "quiet card", 3.0)])
    s.embed_pending(emb, budget=10, ns="card")
    s.learn_table()
    hits = s.recall("localized vectorized", k=3, emb=emb)
    assert [(h.key, h.rungs) for h in hits if h.key == "a"] == [("a", ("card",))]
    by_words = s.recall("quiet card", k=5, emb=emb)  # its own words: the card rung alone may place it
    assert [h.rungs for h in by_words if h.key == "q"] == [("card",)]


def test_her_table_skips_the_cards_too_when_no_namespace_is_asked(tmp_path):
    """The namespace-less path for her table, with a corpus big enough that she has words
    (MIN_COUNT 3): the card is hers to score, and she must not (the lens's M10, 11-02)."""
    s = Store(tmp_path / "recall.db")
    s.sync("vault", [(f"d{i}", "the sovereign embedder holds the lens", float(i)) for i in range(4)])
    s.sync("card", [("c", "sovereign embedder lens card", 0.0)])  # its own key: a shared one would collapse
    s.learn_table()
    hits = s.recall("sovereign embedder lens", k=10)
    assert len(hits) == 4 and [h for h in hits if h.ns == "card"] == []
    assert [h for h in s.recall("sovereign embedder lens", k=10, ns="vault") if h.ns == "card"] == []
