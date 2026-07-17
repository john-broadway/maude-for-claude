"""Query the vault: text -> FTS5 -> ranked top-K -> formatted. Stdlib only."""
from __future__ import annotations

import os
import pathlib
import re
import sqlite3
import time

_TOKEN_RE = re.compile(r"\w{3,}")
_MAX_INPUT_CHARS = 2000
_MAX_TOKENS = 32

# Words that carry no recall signal. The proven failure mode (2026-07-14): an
# OR-of-everything query let "the"/"with"/"what" pull letters and dailies
# into every recall. Curated small on purpose — err toward keeping a word.
_STOPWORDS = frozenset("""
about after all also and any are because been before being but can cant come
could did does doing dont down each even for from get going got had has have
her here hers him his how into its just like made make many more most much
nor not now off once only other our ours out over own said same she should
some still such than that the their theirs them then there these they this
those through too under until very was wants way well were what when where
which while who whom why will with would you your yours
""".split())

# Overfetch by BM25, then re-rank in python where mtime/type can weigh in.
_OVERFETCH = 4

_SEARCH = """
SELECT f.path, f.name, f.description,
       snippet(notes_fts, 3, '[', ']', '…', 10) AS snippet,
       bm25(notes_fts) AS rank,
       n.mtime, n.type
FROM notes_fts f JOIN notes n ON n.path = f.path
WHERE notes_fts MATCH ?
ORDER BY rank
LIMIT ?
"""

# Durable rule-notes outrank ambient prose (letters/dailies carry no type).
_TYPE_WEIGHT = {"feedback": 1.4, "user": 1.4, "reference": 1.25, "project": 1.15}


def _goodness(rank: float, mtime: float | None, note_type: str | None,
              now: float) -> float:
    """Bigger = better. bm25() is smaller-is-better, so flip its sign, then
    boost durable types and decay with age (penalty doubles at ~3 months)."""
    age_days = max(0.0, (now - (mtime or 0.0)) / 86400.0)
    recency_penalty = 1.0 + age_days / 90.0
    return (-rank) * _TYPE_WEIGHT.get(note_type or "", 1.0) / recency_penalty


def fts_query(text: str) -> str | None:
    # Bound both the input (a huge paste shouldn't be re-scanned in full —
    # this hook fires on EVERY prompt) and the token count, and dedupe with
    # dict.fromkeys instead of an `in`-list scan (that was O(n^2)).
    bounded = text[:_MAX_INPUT_CHARS]
    tokens = [
        t for t in dict.fromkeys(_TOKEN_RE.findall(bounded.lower()))
        if t not in _STOPWORDS
    ][:_MAX_TOKENS]
    if not tokens:
        return None
    return " OR ".join(f'"{t}"' for t in tokens)


def page(db_path: str | os.PathLike, query: str, k: int = 5,
         now: float | None = None) -> list[dict]:
    if not pathlib.Path(db_path).exists():
        return []
    match = fts_query(query)
    if match is None:
        return []
    if now is None:
        now = time.time()
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        rows = conn.execute(_SEARCH, (match, k * _OVERFETCH)).fetchall()
        conn.close()
    except sqlite3.Error:
        return []
    ranked = sorted(rows, key=lambda r: _goodness(r[4], r[5], r[6], now),
                    reverse=True)
    return [
        {"path": r[0], "name": r[1], "description": r[2], "snippet": r[3]}
        for r in ranked[:k]
    ]


_DESC_MAX = 200
_SNIPPET_MAX = 300


def _clean(text: str | None, cap: int) -> str:
    """Collapse all whitespace runs (incl. newlines) to single spaces and
    cap length, so embedded content (e.g. a note containing "[SYSTEM]: ..."
    lines) can never break out of its bullet/indent and masquerade as a
    top-level directive."""
    flat = " ".join((text or "").split())
    if len(flat) > cap:
        flat = flat[:cap] + "…"
    return flat


def format_hits(hits: list[dict]) -> str:
    if not hits:
        return ""
    lines = ["Maude — from the vault, relevant to what you just asked:"]
    for h in hits:
        description = _clean(h["description"], _DESC_MAX)
        snippet = _clean(h["snippet"], _SNIPPET_MAX)
        lines.append(f"- [[{h['name']}]] ({h['path']}) — {description}")
        if snippet:
            lines.append(f"    {snippet}")
    return "\n".join(lines)
