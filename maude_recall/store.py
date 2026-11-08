"""The recall store: one sqlite file in the locked house, rebuilt from the sources.

Rung keyword: FTS5, porter. Rung subword: FTS5 trigram (absent on a sqlite older than
3.34; the rung is then simply off). Rung semantic: the house's own embedder over every item,
vectors as float32 blobs, cosine in pure python. Rung card: the same embedder over the vault's
cards alone (one per note: slug, name, description; namespace "card", keyed by the note's
path), answering as the vault's. Rung hers: her own word table (maude_recall/table.py),
learned here at build time, no model at all. Each rung ranks on its own and the lists are
fused by reciprocal rank (fuse(), K = 60), by NOTE: a note two rungs agree on outranks one a
single rung puts first, and no rung can crowd the others out (meaning-first filled every slot
on 2026-10-25; words-first never let a meaning rung speak on 2026-10-31). Disposable: delete
the file and the next build makes it again. Every hit names the rung that placed it best and
every rung that placed it, so a reader can tell meaning from words.

Vectors are content-addressed (model + document prefix + text hash), not tied to an item:
an item dropped and put back with the same words (a rename, a replay cut) keeps its vector.

Lessons carried from Proximo's search tiers (src/proximo/{lexical,vectors}.py at b74f1ce):
content-hashed sync with the model in the hash, so a new model re-embeds instead of
comparing two spaces; a down embedder costs one failed request and a fall-through, never a
slow or empty answer; a blank query raises, it never means "everything".
"""
from __future__ import annotations

import array
import hashlib
import operator
import os
import sqlite3
import time
from dataclasses import dataclass

from maude_recall import table as htable
from maude_tape.embedder import EmbedError, embed_batch

_SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
  id    INTEGER PRIMARY KEY,
  ns    TEXT NOT NULL,
  key   TEXT NOT NULL,
  text  TEXT NOT NULL,
  ts    REAL NOT NULL DEFAULT 0,
  hash  TEXT NOT NULL,
  UNIQUE (ns, key)
);
CREATE INDEX IF NOT EXISTS items_hash ON items (hash);
CREATE TABLE IF NOT EXISTS vectors (
  model TEXT NOT NULL,
  hash  TEXT NOT NULL,
  dim   INTEGER NOT NULL,
  vec   BLOB NOT NULL,
  PRIMARY KEY (model, hash)
);
CREATE TABLE IF NOT EXISTS hwords (
  word  TEXT PRIMARY KEY,
  n     INTEGER NOT NULL,
  vec   BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS hvecs (
  item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
  vec     BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS kw USING fts5(text, content='items', content_rowid='id',
  tokenize='porter unicode61');
"""
_TRIGRAM = """CREATE VIRTUAL TABLE IF NOT EXISTS sub USING fts5(text, content='items',
  content_rowid='id', tokenize='trigram');"""


def _prefixes(model: str) -> tuple[str, str]:
    """(query, document) prefixes. nomic-embed is asymmetric and was trained with these; other
    models get none. The document prefix is part of what is hashed."""
    if "nomic" in model.lower():
        return "search_query: ", "search_document: "
    return "", ""


def _model_key(emb: dict) -> str:
    _, dprefix = _prefixes(emb["model"])
    return f"{emb['model']}\x00{dprefix}"


K = 60  # reciprocal rank fusion's constant (Cormack, Clarke, Buettcher 2009); not tuned here
RUNGS = ("semantic", "card", "keyword", "subword", "hers")  # the tie-break order, nothing more
DEPTH = 20  # how deep each rung ranks for a small k, so two rungs can still agree below it
_NOT_CARD = " AND i.ns != 'card'"  # the cards are the card rung's alone: one vector, one vote


@dataclass(frozen=True)
class Hit:
    ns: str
    key: str
    text: str
    score: float
    rung: str  # the rung that placed this note best
    rungs: tuple[str, ...] = ()  # every rung that placed it, in RUNGS order


def _note(key: str) -> str:
    return key.split("#", 1)[0]


def fuse(lists: list[tuple[str, list[tuple]]], k: int) -> list[Hit]:
    """Reciprocal rank fusion of the rungs' lists, by note. Each list is (rung, items) with
    items ordered best first as (item_id, ns, key, text, score); a note's rank in a list is
    its first item's. Ties: more rungs, then the earlier rung in RUNGS. The hit carries the
    item of the rung that placed the note best. One rule on top of the fusion: words have
    the last word. The keyword rung's first pick never falls out of the top k (k > 1): when
    fusion ranks it lower (six near-twins two rungs agree on outscore the one note that holds
    the ctid he typed) it takes the last slot, so an exact identifier is still found (lens 1,
    2026-10-30) and the agreed notes above it are untouched. No other rung's first pick is
    guaranteed: meaning and her table score nearly everything, and their firsts are soft."""
    order = {r: i for i, r in enumerate(RUNGS)}
    notes: dict[str, dict] = {}
    for rung, items in lists:
        rank = 0
        placed: set[str] = set()
        for it in items:
            note = _note(it[2])
            if note in placed:
                continue
            placed.add(note)
            rank += 1
            n = notes.setdefault(note, {"score": 0.0, "placed": [], "best": None, "ranks": {}})
            n["score"] += 1.0 / (K + rank)
            n["placed"].append(rung)
            n["ranks"][rung] = rank
            if n["best"] is None or (rank, order.get(rung, 99)) < (n["best"][0], order.get(n["best"][1], 99)):
                n["best"] = (rank, rung, it)
    def key(kv):
        return (-kv[1]["score"], -len(kv[1]["placed"]), order.get(kv[1]["best"][1], 99), kv[0])
    ranked = sorted(notes.items(), key=key)
    if len(ranked) > k > 1:
        for i in range(k, len(ranked)):
            if ranked[i][1]["ranks"].get("keyword") == 1:
                ranked = ranked[:k - 1] + [ranked[i]] + ranked[k - 1:i] + ranked[i + 1:]
                break
    out = []
    for note, n in ranked[:k]:
        _, rung, (_, ns, key, text, _) = n["best"]
        out.append(Hit(ns, key, text, round(n["score"], 6), rung,
                       tuple(sorted(set(n["placed"]), key=lambda r: order.get(r, 99)))))
    return out


class Store:
    def __init__(self, path: str | os.PathLike):
        path = os.fspath(path)
        if os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)  # owner-only: it holds his words
        os.close(fd)
        self._db = sqlite3.connect(path, timeout=5.0)
        self._db.execute("PRAGMA foreign_keys = ON")
        cols = {r[1] for r in self._db.execute("PRAGMA table_info(vectors)")}
        if cols and "hash" not in cols:  # a store from before content-addressed vectors: re-embed
            self._db.execute("DROP TABLE vectors")
        self._db.executescript(_SCHEMA)
        try:
            self._db.execute(_TRIGRAM)
            self.subword = True
        except sqlite3.OperationalError:
            self.subword = False  # sqlite before 3.34: no trigram tokenizer, rung 2 is off
        self._db.commit()

    def close(self) -> None:
        self._db.close()

    # --- sources in --------------------------------------------------------------------

    def sync(self, ns: str, items: list[tuple[str, str, float]]) -> int:
        """Make namespace `ns` hold exactly `items` (key, text, ts). Returns rows changed.
        Words only: nothing is embedded here, so a sync is fast enough for any hook."""
        have = {k: (h, t) for k, h, t in self._db.execute("SELECT key, hash, ts FROM items WHERE ns = ?", (ns,))}
        want = {k: (t, ts) for k, t, ts in items}
        changed = 0
        for key in [k for k in have if k not in want]:
            self._drop(ns, key)
            changed += 1
        for key, (text, ts) in want.items():
            h = hashlib.sha256(text.encode()).hexdigest()
            if key in have and have[key][0] == h:
                # same words, maybe another time: a replay syncs the vault as it stood at a cut,
                # and an item that kept today's time would be cut as born later (2026-10-31)
                if have[key][1] != ts:
                    self._db.execute("UPDATE items SET ts = ? WHERE ns = ? AND key = ?", (ts, ns, key))
                    changed += 1
                continue
            if key in have:
                self._drop(ns, key)
            cur = self._db.execute("INSERT INTO items (ns, key, text, ts, hash) VALUES (?,?,?,?,?)",
                                   (ns, key, text, ts, h))
            self._fts("insert", cur.lastrowid, text)
            changed += 1
        self._db.commit()
        return changed

    def _drop(self, ns: str, key: str) -> None:
        row = self._db.execute("SELECT id, text FROM items WHERE ns = ? AND key = ?", (ns, key)).fetchone()
        if row:
            self._fts("delete", row[0], row[1])
            self._db.execute("DELETE FROM items WHERE id = ?", (row[0],))

    def _fts(self, op: str, rowid: int, text: str) -> None:
        for table in ("kw", "sub") if self.subword else ("kw",):
            if op == "insert":
                self._db.execute(f"INSERT INTO {table} (rowid, text) VALUES (?, ?)", (rowid, text))
            else:
                self._db.execute(f"INSERT INTO {table} ({table}, rowid, text) VALUES ('delete', ?, ?)",
                                 (rowid, text))

    # --- meaning in ----------------------------------------------------------------------

    def pending(self, emb: dict, ns: str | None = None) -> int:
        return sum(1 for _ in self._todo(_model_key(emb), ns))

    def _todo(self, model_key: str, ns: str | None = None):
        """(item_id, text, hash) with no vector under this model: cards first (the cheapest
        and most telling vector a note has), then newest first; one row per distinct text."""
        rows = self._db.execute(
            "SELECT i.id, i.text, i.hash FROM items i LEFT JOIN vectors v ON v.hash = i.hash AND v.model = ? "
            "WHERE v.hash IS NULL" + (" AND i.ns = ?" if ns else "") +
            " ORDER BY (i.ns = 'card') DESC, i.ts DESC, i.id", (model_key, ns) if ns else (model_key,))
        seen: set[str] = set()
        for item_id, text, h in rows:
            if h not in seen:
                seen.add(h)
                yield item_id, text, h

    def embed_pending(self, emb: dict, *, budget: float, batch: int = 16,
                      limit: int | None = None, ns: str | None = None,
                      cache: str | os.PathLike | None = None) -> int:
        """Give a vector to what has none under this model, cards first then newest, until
        `budget` seconds or `limit` texts; `ns` limits it to one namespace. With `cache`, a
        sqlite file of the same vectors table, a text the cache holds costs no request and a
        text embedded here is written there (a replay's cuts share one). Returns how many
        texts got a vector. Resumable: a killed build loses at most one batch."""
        model_key = _model_key(emb)
        _, dprefix = _prefixes(emb["model"])
        todo = list(self._todo(model_key, ns))
        if limit is not None:
            todo = todo[:limit]
        cdb = None
        if cache is not None:
            cpath = os.fspath(cache)
            os.close(os.open(cpath, os.O_CREAT | os.O_RDWR, 0o600))
            cdb = sqlite3.connect(cpath, timeout=5.0)
            cdb.execute("CREATE TABLE IF NOT EXISTS vectors (model TEXT NOT NULL, hash TEXT NOT NULL, "
                        "dim INTEGER NOT NULL, vec BLOB NOT NULL, PRIMARY KEY (model, hash))")
        done = 0
        try:
            if cdb is not None:
                rest = []
                for item_id, text, h in todo:
                    row = cdb.execute("SELECT dim, vec FROM vectors WHERE model = ? AND hash = ?",
                                      (model_key, h)).fetchone()
                    if row and row[0] == emb["dim"]:
                        self._db.execute("INSERT OR REPLACE INTO vectors (model, hash, dim, vec) VALUES (?,?,?,?)",
                                         (model_key, h, row[0], row[1]))
                        done += 1
                    else:
                        rest.append((item_id, text, h))
                self._db.commit()
                todo = rest
            stop = time.monotonic() + budget
            for i in range(0, len(todo), batch):
                if time.monotonic() >= stop:
                    break
                part = todo[i:i + batch]
                vecs = embed_batch(emb["url"], [t for _, t, _ in part], prefix=dprefix, timeout=60.0)
                for (_, _, h), vec in zip(part, vecs):
                    if len(vec) != emb["dim"]:
                        raise EmbedError(f"embedder answered {len(vec)} dims, the probe recorded {emb['dim']}")
                    blob = array.array("f", vec).tobytes()
                    self._db.execute("INSERT OR REPLACE INTO vectors (model, hash, dim, vec) VALUES (?,?,?,?)",
                                     (model_key, h, len(vec), blob))
                    if cdb is not None:
                        cdb.execute("INSERT OR REPLACE INTO vectors (model, hash, dim, vec) VALUES (?,?,?,?)",
                                    (model_key, h, len(vec), blob))
                self._db.commit()
                if cdb is not None:
                    cdb.commit()
                done += len(part)
        finally:
            if cdb is not None:
                cdb.close()
        return done

    def sweep_vectors(self) -> int:
        """Drop vectors no item's text needs any more (a build-time chore, never a replay's:
        a cut may bring a text back)."""
        n = self._db.execute("DELETE FROM vectors WHERE hash NOT IN (SELECT hash FROM items)").rowcount
        self._db.commit()
        return n

    # --- her table -----------------------------------------------------------------------

    def _meta(self, k: str) -> str | None:
        row = self._db.execute("SELECT v FROM meta WHERE k = ?", (k,)).fetchone()
        return row[0] if row else None

    def learn_table(self) -> bool:
        """Learn her word table from every item and give each item its vector. Skipped when
        the recipe and the items are what the last learn saw. Returns True when it learned."""
        # Keys, not ids, with the text hash: a rename keeps the text, and renaming the newest
        # item can even reuse its id (no AUTOINCREMENT), so only the key tells (lenses 1, 2).
        corpus = hashlib.sha256()
        for ns, key, h in self._db.execute("SELECT ns, key, hash FROM items ORDER BY ns, key"):
            corpus.update(f"{ns}\x00{key}\x00{h}\x00".encode())
        stamp = f"{htable.RECIPE}:{corpus.hexdigest()}"
        if self._meta("table") == stamp:
            return False
        rows = self._db.execute("SELECT id, text FROM items ORDER BY ns, key").fetchall()
        total, counts, tab = htable.learn(t for _, t in rows)
        self._db.execute("DELETE FROM hwords")
        self._db.execute("DELETE FROM hvecs")
        self._db.executemany("INSERT INTO hwords (word, n, vec) VALUES (?,?,?)",
                             ((w, counts[w], array.array("f", v).tobytes()) for w, v in tab.items()))
        held = {w: (counts[w], v) for w, v in tab.items()}
        lookup = lambda ws: {w: held[w] for w in ws if w in held}
        for item_id, text in rows:
            vec = htable.embed(text, lookup, total)
            if vec:
                self._db.execute("INSERT INTO hvecs (item_id, vec) VALUES (?,?)",
                                 (item_id, array.array("f", vec).tobytes()))
        self._db.execute("INSERT OR REPLACE INTO meta (k, v) VALUES ('total', ?)", (str(total),))
        self._db.execute("INSERT OR REPLACE INTO meta (k, v) VALUES ('table', ?)", (stamp,))
        self._db.commit()
        return True

    def _lookup(self, ws: list[str]) -> dict[str, tuple[int, list[float]]]:
        out = {}
        for w in ws:
            row = self._db.execute("SELECT n, vec FROM hwords WHERE word = ?", (w,)).fetchone()
            if row:
                va = array.array("f")
                va.frombytes(row[1])
                out[w] = (row[0], list(va))
        return out

    # --- recall --------------------------------------------------------------------------

    def recall(self, query: str, k: int = 5, *, ns: str | None = None, emb: dict | None = None,
               min_score: float = 0.0) -> list[Hit]:
        """Up to `k` notes: every rung ranks on its own (meaning over every item and over the
        vault's cards when the house has an embedder and a build has embedded; words; parts
        of words; her table when a build has learned it) and fuse() merges the lists by
        reciprocal rank. The cards are read by the card rung alone, whatever `ns` asks: with
        no namespace the other rungs skip them, or one card vector would vote twice and her
        table a third time, a path the replay (always `ns="vault"`) never measured. A note is
        never given twice. A blank query raises."""
        if not query or not query.strip():
            raise ValueError("recall needs a query; a blank one never means everything")
        depth = max(k, DEPTH)
        lists: list[tuple[str, list[tuple]]] = []
        if emb:
            try:
                q = self._query_vector(query, emb)
                lists.append(("semantic", self._semantic(q, depth, ns, emb, min_score)))
                if ns in (None, "vault"):
                    lists.append(("card", self._semantic(q, depth, "card", emb, min_score)))
            except EmbedError:
                pass  # a down embedder costs its rungs, never the answer
        lists.append(("keyword", self._words("kw", query, depth, ns)))
        if self.subword:
            lists.append(("subword", self._words("sub", query, depth, ns)))
        lists.append(("hers", self._hers(query, depth, ns)))
        return fuse(lists, k)

    def _query_vector(self, query: str, emb: dict) -> array.array:
        qprefix, _ = _prefixes(emb["model"])
        q = embed_batch(emb["url"], [query], prefix=qprefix, timeout=2.0)[0]
        if len(q) != emb["dim"]:
            raise EmbedError("query vector dimension does not match the store")
        return array.array("f", q)

    def _semantic(self, qa, depth, ns, emb, min_score):
        sql = ("SELECT i.id, i.ns, i.key, i.text, v.vec FROM items i JOIN vectors v ON v.hash = i.hash "
               "WHERE v.model = ?" + (" AND i.ns = ?" if ns else _NOT_CARD))
        scored = []
        for item_id, ins, key, text, blob in self._db.execute(sql, (_model_key(emb), ns) if ns else (_model_key(emb),)):
            va = array.array("f")
            va.frombytes(blob)
            if len(va) != len(qa):
                continue
            score = sum(map(operator.mul, qa, va))  # 0.51 s per 15k x 768 here; fsum was 1.07 s
            if score > min_score:
                scored.append((-score, item_id, ins, key, text))
        scored.sort()
        return [(item_id, ins, key, text, round(-neg, 4)) for neg, item_id, ins, key, text in scored[:depth]]

    def _hers(self, query, depth, ns):
        stamp = self._meta("table")
        if not stamp or not stamp.startswith(htable.RECIPE + ":"):
            return []  # never learned, or learned by another recipe: the rung is off until a build
        q = htable.embed(query, self._lookup, int(self._meta("total") or 0))
        if q is None:
            return []
        qa = array.array("f", q)
        sql = ("SELECT i.id, i.ns, i.key, i.text, h.vec FROM hvecs h JOIN items i ON i.id = h.item_id"
               + (" WHERE i.ns = ?" if ns else " WHERE" + _NOT_CARD[4:]))
        scored = []
        for item_id, ins, key, text, blob in self._db.execute(sql, (ns,) if ns else ()):
            va = array.array("f")
            va.frombytes(blob)
            score = sum(map(operator.mul, qa, va))
            if score > 0:
                scored.append((-score, item_id, ins, key, text))
        scored.sort()
        return [(item_id, ins, key, text, round(-neg, 4)) for neg, item_id, ins, key, text in scored[:depth]]

    def _words(self, table, query, depth, ns):
        terms = [t for t in "".join(c if c.isalnum() else " " for c in query.lower()).split() if len(t) >= 3]
        if not terms:
            return []
        match = " OR ".join(f'"{t}"' for t in terms)
        sql = (f"SELECT i.id, i.ns, i.key, i.text, bm25({table}) FROM {table} JOIN items i ON i.id = {table}.rowid "
               f"WHERE {table} MATCH ?" + (" AND i.ns = ?" if ns else _NOT_CARD) + f" ORDER BY bm25({table}) LIMIT ?")
        try:
            rows = self._db.execute(sql, (match, ns, depth) if ns else (match, depth)).fetchall()
        except sqlite3.OperationalError:
            return []
        return [(item_id, ins, key, text, round(-rank, 4)) for item_id, ins, key, text, rank in rows]
