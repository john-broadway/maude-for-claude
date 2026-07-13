"""SQLite connection + schema for Maude's memory vault. Stdlib only."""
from __future__ import annotations

import os
import sqlite3

_SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    path        TEXT PRIMARY KEY,
    name        TEXT,
    description TEXT,
    type        TEXT,
    body        TEXT,
    mtime       REAL,
    links       TEXT
);
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    path UNINDEXED,
    name,
    description,
    body,
    tokenize='porter unicode61'
);
"""


def connect(db_path: str | os.PathLike) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.executescript(_SCHEMA)
    conn.commit()
    return conn
