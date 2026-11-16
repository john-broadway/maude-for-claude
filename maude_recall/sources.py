"""What the recall store indexes, read from the stores that already parsed it.

The vault: notes as maude_vault parsed them into vault.db (superseded notes skipped, the same
rule paging uses), chunked to fit the embedder's window, the first chunk led by the note's
name and description. The tape: his typed lines only, through voice.is_machine_turn and
the paste threshold the profile already uses, minus rows flagged as a suggested prompt he
accepted. Read-only on both.
"""
from __future__ import annotations

import os
import re
import sqlite3

from maude_recall import chunk
from maude_tape.voice import PASTE_CHAR_THRESHOLD, is_machine_turn


def _ro(path: str | os.PathLike) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{os.fspath(path)}?mode=ro", uri=True)


def vault_items(vault_db: str | os.PathLike) -> list[tuple[str, str, float]]:
    if not os.path.exists(vault_db):
        return []
    items = []
    with _ro(vault_db) as c:
        for path, name, desc, body, mtime in c.execute(
                "SELECT path, name, description, body, mtime FROM notes "
                "WHERE coalesce(superseded, '') = '' ORDER BY path"):
            head = f"{name or path}: {desc}" if desc else (name or path)
            for i, part in enumerate(chunk.split(f"{head}\n\n{body or ''}")):
                items.append((f"{path}#{i}", part, float(mtime or 0)))
    return items


def vault_cards(vault_db: str | os.PathLike) -> list[tuple[str, str, float]]:
    """One card per live note, keyed by the note's path: the slug's words, the name and the
    description. The note's own words for what it holds, short enough that a lesson he says
    in other words can meet them by meaning (the mined lesson rows, 2026-11-02: no body
    quoted his line at the cut; the card named the lesson). Read by the card rung, which
    answers as the vault's."""
    if not os.path.exists(vault_db):
        return []
    cards = []
    with _ro(vault_db) as c:
        for path, name, desc, mtime in c.execute(
                "SELECT path, name, description, mtime FROM notes "
                "WHERE coalesce(superseded, '') = '' ORDER BY path"):
            slug = re.sub(r"[_-]+", " ", re.sub(r"\.md$", "", path))
            cards.append((path, "\n".join(x for x in (slug, name or "", desc or "") if x).strip(), float(mtime or 0)))
    return cards


def tape_items(tape_db: str | os.PathLike) -> list[tuple[str, str, float]]:
    if not os.path.exists(tape_db):
        return []
    with _ro(tape_db) as c:
        try:  # a suggestion he accepted is flagged on the tape (2026-10-30): never his words here
            rows = c.execute("SELECT sha, text, ts FROM voice WHERE sha NOT IN "
                             "(SELECT sha FROM voice_flags) ORDER BY ts").fetchall()
        except sqlite3.OperationalError:  # a tape from before the flags
            rows = c.execute("SELECT sha, text, ts FROM voice ORDER BY ts").fetchall()
    return [(f"voice:{sha}", text, float(ts or 0)) for sha, text, ts in rows
            if text and not is_machine_turn(text) and len(text) < PASTE_CHAR_THRESHOLD]
