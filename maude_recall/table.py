"""Her own word table: a vector per word, learned from this house's words, stdlib only.

No model and no dependency. A word's vector is built from the words it sits beside here:
its positive PMI row (window WIN, context counts smoothed by ^0.75, the TOPC strongest
contexts kept), random-projected to DIM by sparse index vectors that a hash of the word
fixes, so the same corpus always gives the same table. Each index vector also carries the
word's 4- and 5-letter pieces (fastText's idea), so "localized" shares part of itself with
"local" and "vectorized" with "vectors". A text's vector is the mean of its words' vectors,
each weighted A / (A + its frequency), so common words weigh little.

Measured 2026-10-30, honestly: on a corpus cut before his questions were asked (one cut at
2026-10-24 00:00 UTC), the table alone ranked the note he meant 132, 132, miss, miss, and
words alone 51, 162, miss, 139: it does not yet beat words. An earlier 12 and 7 were learned
from the record of the conversation being replayed. Learning the vault and the tape takes ~58 s and peaks
near 825 MB on a 16k-item corpus: a build cost, never a recall cost. A query embeds in
~0.1 ms.
"""
from __future__ import annotations

import collections
import hashlib
import json
import math
import re

DIM = 256
WIN = 5
TOPC = 64
NNZ = 8
GRAMS = (4, 5)
GRAM_WEIGHT = 0.5
MIN_COUNT = 3
SELF_WEIGHT = 2.0
A = 1e-3
STOP = frozenset(
    "a an the and or of for to in on at by with from is are was were be been this that these "
    "those it its as if then than so how what when where which who do does did have has had can "
    "could should would will not no all any my your our their his her i you he she we they me "
    "him us them just like get got also one two into out up about there here very only more most "
    "some such why im am see seeing thought".split())
_WORD = re.compile(r"[a-z0-9][a-z0-9_-]{1,30}")
RECIPE = hashlib.sha256(json.dumps(
    ["table-1", DIM, WIN, TOPC, NNZ, GRAMS, GRAM_WEIGHT, MIN_COUNT, SELF_WEIGHT, A, sorted(STOP),
     _WORD.pattern]).encode()).hexdigest()


def words(text: str) -> list[str]:
    return [w for w in _WORD.findall(text.lower()) if w not in STOP]


def _index(token: str) -> list[tuple[int, float]]:
    h = hashlib.blake2b(token.encode(), digest_size=2 * NNZ).digest()
    return [((h[2 * i] << 8 | h[2 * i + 1]) % DIM, 1.0 if h[2 * i] & 1 else -1.0) for i in range(NNZ)]


def _pieces(word: str) -> list[tuple[int, float]]:
    out = _index(word)
    b = f"<{word}>"
    for n in GRAMS:
        for i in range(len(b) - n + 1):
            out += [(d, s * GRAM_WEIGHT) for d, s in _index("#" + b[i:i + n])]
    return out


def _unit(vec: list[float]) -> list[float] | None:
    n = math.sqrt(sum(x * x for x in vec))
    return [x / n for x in vec] if n else None


def learn(texts) -> tuple[int, dict[str, int], dict[str, list[float]]]:
    """(total, counts, table) from an iterable of texts: total is every word counted. Words seen fewer than MIN_COUNT times get
    no vector; a text made only of those has no vector either."""
    docs = [words(t) for t in texts]
    counts = collections.Counter(w for d in docs for w in d)
    vocab = {w for w, c in counts.items() if c >= MIN_COUNT}
    co: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for d in docs:
        d = [w for w in d if w in vocab]
        for i, w in enumerate(d):
            for v in d[max(0, i - WIN):i]:
                if v != w:
                    co[w][v] += 1
                    co[v][w] += 1
    rowsum = {w: sum(c.values()) for w, c in co.items()}
    ctx = {w: s ** 0.75 for w, s in rowsum.items()}
    z, t = sum(ctx.values()) or 1.0, sum(rowsum.values()) or 1.0
    cache: dict[str, list[tuple[int, float]]] = {}

    def pieces(w):
        p = cache.get(w)
        if p is None:
            p = cache[w] = _pieces(w)
        return p

    table = {}
    for w in sorted(vocab):
        vec = [0.0] * DIM
        for d, s in pieces(w):  # a word always means itself too
            vec[d] += s * SELF_WEIGHT
        scored = []
        for v, k in co.get(w, {}).items():
            pmi = math.log((k / t) / ((rowsum[w] / t) * (ctx[v] / z)))
            if pmi > 0:
                scored.append((pmi, v))
        scored.sort(reverse=True)
        scored = scored[:TOPC]
        norm = math.sqrt(sum(p * p for p, _ in scored)) or 1.0
        for p, v in scored:
            for d, s in pieces(v):
                vec[d] += s * SELF_WEIGHT * p / norm
        unit = _unit(vec)
        if unit:
            table[w] = unit
    return sum(counts.values()), {w: counts[w] for w in vocab}, table


def embed(text: str, lookup, total: int) -> list[float] | None:
    """The text's vector, or None when none of its words is in the table. `lookup(words)`
    returns {word: (count, vector)} for the words it holds; `total` is the corpus word count."""
    ws = words(text)
    if not ws or total <= 0:
        return None
    held = lookup(sorted(set(ws)))
    vec = [0.0] * DIM
    for w in ws:
        got = held.get(w)
        if got is None:
            continue
        count, e = got
        wt = A / (A + count / total)
        for i, x in enumerate(e):
            vec[i] += wt * x
    return _unit(vec)
