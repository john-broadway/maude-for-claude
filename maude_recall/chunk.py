"""Split text into pieces that fit an embedder's window, by paragraph, losing nothing.

Measured on kb-embed (nomic, 2,048-token window), 2026-10-25: an 8 KB note was refused and
a 2 KB note was ~500 tokens, so the default limit of 1,200 characters sits well inside.
"""
from __future__ import annotations

LIMIT = 1200


def split(text: str, limit: int = LIMIT) -> list[str]:
    """Paragraphs packed up to `limit` characters; a paragraph longer than that is cut hard.
    Every character of `text` outside the blank lines between paragraphs is kept."""
    parts: list[str] = []
    cur = ""
    for para in (p.strip() for p in text.split("\n\n")):
        if not para:
            continue
        while len(para) > limit:
            if cur:
                parts.append(cur)
                cur = ""
            parts.append(para[:limit])
            para = para[limit:]
        if cur and len(cur) + 2 + len(para) > limit:
            parts.append(cur)
            cur = para
        else:
            cur = f"{cur}\n\n{para}" if cur else para
    if cur:
        parts.append(cur)
    return parts
