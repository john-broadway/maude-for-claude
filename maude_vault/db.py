"""SQLite connection + schema for Maude's memory vault. Stdlib only."""
from __future__ import annotations

import os
import sqlite3

_SCHEMA_VERSION = 2

_SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    path        TEXT PRIMARY KEY,
    name        TEXT,
    description TEXT,
    type        TEXT,
    body        TEXT,
    mtime       REAL,
    links       TEXT,
    superseded  TEXT DEFAULT ''
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
    # The DB is a disposable index (locked decision #5): on any schema-version
    # mismatch, drop and recreate rather than migrate — the markdown is canon.
    (version,) = conn.execute("PRAGMA user_version").fetchone()
    if version != _SCHEMA_VERSION:
        conn.execute("DROP TABLE IF EXISTS notes")
        conn.execute("DROP TABLE IF EXISTS notes_fts")
        conn.execute(f"PRAGMA user_version = {_SCHEMA_VERSION}")
    conn.executescript(_SCHEMA)
    conn.commit()
    return conn
