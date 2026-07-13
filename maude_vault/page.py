"""Query the vault: text -> FTS5 -> ranked top-K -> formatted. Stdlib only."""
from __future__ import annotations

import os
import pathlib
import re
import sqlite3

_TOKEN_RE = re.compile(r"\w{3,}")
_MAX_INPUT_CHARS = 2000
_MAX_TOKENS = 32

_SEARCH = """
SELECT path, name, description,
       snippet(notes_fts, 3, '[', ']', '…', 10) AS snippet,
       bm25(notes_fts) AS rank
FROM notes_fts
WHERE notes_fts MATCH ?
ORDER BY rank
LIMIT ?
"""


def fts_query(text: str) -> str | None:
    # Bound both the input (a huge paste shouldn't be re-scanned in full —
    # this hook fires on EVERY prompt) and the token count, and dedupe with
    # dict.fromkeys instead of an `in`-list scan (that was O(n^2)).
    bounded = text[:_MAX_INPUT_CHARS]
    tokens = list(dict.fromkeys(_TOKEN_RE.findall(bounded.lower())))[:_MAX_TOKENS]
    if not tokens:
        return None
    return " OR ".join(f'"{t}"' for t in tokens)


def page(db_path: str | os.PathLike, query: str, k: int = 5) -> list[dict]:
    if not pathlib.Path(db_path).exists():
        return []
    match = fts_query(query)
    if match is None:
        return []
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        rows = conn.execute(_SEARCH, (match, k)).fetchall()
        conn.close()
    except sqlite3.Error:
        return []
    return [
        {"path": r[0], "name": r[1], "description": r[2], "snippet": r[3]}
        for r in rows
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
