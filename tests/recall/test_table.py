"""Her own word table (maude_recall/table.py) and its rung in the store.

Pinned: a word learns what it sits beside here (an association no spelling shares); the
4/5-letter pieces tie a word to its stem; learning is deterministic; the store relearns
only when the items or the recipe change; a table learned by another recipe is never read;
the rung is named "hers" and runs fused by rank with the others (it ran after the house's embedder and before words until 2026-11-02).
"""
from __future__ import annotations

import math
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_recall import table
from maude_recall.store import Store

CORPUS = (
    ["the localized store keeps sqlite on the box"] * 6
    + ["sqlite holds the vault file, nothing leaves"] * 4
    + ["dinner tonight is a recipe with basil"] * 6
    + ["the recipe wants basil and garlic for dinner"] * 4
    + ["vectorized notes ride along with boats"] * 3
    + ["vectors live in blobs beside the notes"] * 3
    + ["boats and garlic and blobs"] * 3
)


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def test_a_word_learns_what_it_sits_beside():
    _, _, tab = table.learn(CORPUS)
    # "localized" and "sqlite" share no spelling: only the corpus ties them
    assert cos(tab["localized"], tab["sqlite"]) > cos(tab["localized"], tab["dinner"]) + 0.1


def test_pieces_tie_a_word_to_its_stem():
    _, _, tab = table.learn(CORPUS)
    # neither sits beside the other; the shared pieces "<vec", "vect", "ecto" are the tie
    assert cos(tab["vectorized"], tab["vectors"]) > cos(tab["vectorized"], tab["garlic"]) + 0.1


def test_learning_is_deterministic():
    a, b = table.learn(CORPUS), table.learn(list(CORPUS))
    assert a == b


def test_rare_and_stop_words_get_no_vector():
    total, counts, tab = table.learn(CORPUS + ["zebra once"])
    assert "zebra" not in tab and "the" not in tab and "the" not in counts
    assert total == sum(len(table.words(t)) for t in CORPUS + ["zebra once"])
    assert table.embed("zebra the", lambda ws: {}, total) is None
    assert table.embed("anything", lambda ws: {}, 0) is None


def test_vectors_are_unit_length():
    _, _, tab = table.learn(CORPUS)
    assert all(abs(math.sqrt(sum(x * x for x in v)) - 1.0) < 1e-9 for v in tab.values())


@pytest.fixture
def store(tmp_path):
    s = Store(tmp_path / "recall.db")
    s.sync("vault", [(f"n{i}.md#0", t, float(i)) for i, t in enumerate(CORPUS)]
           + [("keep.md#0", "the vault file: sqlite on the box", 99.0),
              ("food.md#0", "a dinner recipe with basil", 99.0)])
    yield s
    s.close()


def test_the_rung_finds_what_words_miss(store):
    store.learn_table()
    hits = store.recall("localized", 60, ns="vault")
    by_key = {h.key: h for h in hits}
    # keep.md never says "localized": words cannot reach it, her table can
    assert by_key["keep.md#0"].rung == "hers"
    keys = [h.key for h in hits]
    assert keys.index("keep.md#0") < keys.index("food.md#0")


def test_words_come_before_hers_so_an_exact_identifier_is_found(store):
    store.sync("vault", [("rare.md#0", "ctid 1971 xylophonic", 1.0)]
               + [(f"n{i}.md#0", t, float(i)) for i, t in enumerate(CORPUS)])
    store.learn_table()
    hits = store.recall("localized xylophonic", 5, ns="vault")
    assert ("rare.md#0", "keyword") in [(h.key, h.rung) for h in hits]


def test_no_item_twice_across_rungs(store):
    store.learn_table()
    hits = store.recall("localized sqlite basil", 200, ns="vault")
    assert len({h.key for h in hits}) == len(hits)


def test_a_rename_relearns(store):
    store.learn_table()
    store.sync("vault", [(k.replace("keep", "keeq"), t, ts) for k, t, ts in
                         [(f"n{i}.md#0", t, float(i)) for i, t in enumerate(CORPUS)]
                         + [("keep.md#0", "the vault file: sqlite on the box", 99.0),
                            ("food.md#0", "a dinner recipe with basil", 99.0)]])
    assert store.learn_table() is True
    assert "keeq.md#0" in [h.key for h in store.recall("localized", 60, ns="vault") if h.rung == "hers"]


def test_a_learn_killed_midway_leaves_no_current_stamp(store, monkeypatch):
    store.learn_table()
    store.sync("vault", [("only.md#0", "sqlite sqlite sqlite localized localized localized", 1.0)])
    calls = []

    def boom(*a, **kw):
        calls.append(1)
        if len(calls) > 0:
            raise RuntimeError("killed")
    monkeypatch.setattr(table, "embed", boom)
    with pytest.raises(RuntimeError):
        store.learn_table()
    store._db.rollback()
    monkeypatch.undo()
    assert store.learn_table() is True  # the stamp never claimed the half-done learn


def test_learning_does_not_depend_on_the_hash_seed(tmp_path):
    import hashlib, subprocess
    code = ("import sys, json, hashlib; sys.path.insert(0, %r); from maude_recall import table; "
            "from tests.recall.test_table import CORPUS; t, c, tab = table.learn(CORPUS); "
            "print(hashlib.sha256(json.dumps([t, sorted(c.items()), sorted(tab.items())]).encode()).hexdigest())"
            % str(pathlib.Path(__file__).resolve().parents[2]))
    root = pathlib.Path(__file__).resolve().parents[2]
    out = {subprocess.run([sys.executable, "-c", code], cwd=root, capture_output=True, text=True,
                          env={"PYTHONHASHSEED": seed, "PATH": "/usr/bin:/bin"}).stdout for seed in ("0", "4242")}
    assert len(out) == 1 and len(next(iter(out)).strip()) == 64


def test_relearns_only_on_change(store, monkeypatch):
    assert store.learn_table() is True
    assert store.learn_table() is False
    store.sync("vault", [("only.md#0", "sqlite sqlite sqlite localized localized localized", 1.0)])
    assert store.learn_table() is True
    monkeypatch.setattr(table, "RECIPE", "another-recipe")
    assert store.learn_table() is True


def test_another_recipes_table_is_never_read(store, monkeypatch):
    store.learn_table()
    monkeypatch.setattr(table, "RECIPE", "another-recipe")
    assert all(h.rung != "hers" for h in store.recall("localized", 10, ns="vault"))


def test_never_learned_means_the_rung_is_off(store):
    assert all(h.rung != "hers" for h in store.recall("localized", 10, ns="vault"))


def test_a_dropped_item_takes_its_vector(store):
    store.learn_table()
    n = store._db.execute("SELECT count(*) FROM hvecs").fetchone()[0]
    store.sync("vault", [("keep.md#0", "the vault file: sqlite on the box", 99.0)])
    assert store._db.execute("SELECT count(*) FROM hvecs").fetchone()[0] == 1 < n


def test_renaming_the_newest_item_relearns(store):
    store.sync("vault", [(f"n{i}.md#0", t, float(i)) for i, t in enumerate(CORPUS)]
               + [("last.md#0", "sqlite localized box", 100.0)])
    store.learn_table()
    store.sync("vault", [(f"n{i}.md#0", t, float(i)) for i, t in enumerate(CORPUS)]
               + [("renamed.md#0", "sqlite localized box", 100.0)])  # sync drops, then inserts: the id is reused
    assert store.learn_table() is True
    assert store._db.execute("SELECT count(*) FROM hvecs h JOIN items i ON i.id = h.item_id "
                             "WHERE i.key = 'renamed.md#0'").fetchone()[0] == 1
