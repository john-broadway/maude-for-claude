"""The matcher: pick the one approved trade whose phrase is in the prompt. Stdlib only.

Rows are built from approved pages that were re-hashed, parsed and validated by the
store (store.live_pages); nothing here reads a file. A phrase matches only as a
contiguous run of whole words; the prompt is read to its first 2,000 characters.
"""
from __future__ import annotations

from dataclasses import dataclass

from maude_rolodex.page import Page, words

_PROMPT_MAX = 2000
_PHRASE_MIN = 2


@dataclass
class LiveRow:
    slug: str
    trade: str
    kind: str
    name: str
    cue: str
    phrases: list[list[str]]


def row(slug: str, page: Page) -> LiveRow:
    """The match index of one validated page."""
    return LiveRow(slug, page.trade, page.pick_kind, page.pick_name, page.cue, list(page.phrases))


def _contains(hay: list[str], needle: list[str]) -> bool:
    n = len(needle)
    return any(hay[i:i + n] == needle for i in range(len(hay) - n + 1))


def match(prompt: str, rows: list[LiveRow]) -> LiveRow | None:
    """The row with the longest matching phrase; ties go to the first slug."""
    hay = words(prompt[:_PROMPT_MAX])
    best: tuple[int, str] | None = None
    winner: LiveRow | None = None
    for row in rows:
        for phrase in row.phrases:
            if len(phrase) < _PHRASE_MIN or not _contains(hay, phrase):
                continue
            key = (-len(phrase), row.slug)
            if best is None or key < best:
                best, winner = key, row
    return winner
