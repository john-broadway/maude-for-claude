"""The Rolodex's one store: rolodex.db under the home Rolodex dir. Stdlib sqlite3 only.

Three tables, third normal form:

  pages   digest -> body          an approved page's bytes, keyed by their own sha256
  ledger  id, slug, verb, digest  append-only; the last row for a slug wins
  live    project, slug, digest, flag
                                  which approved pages are on call in which project

Nothing derivable is stored twice: a live row names a page by its digest, and the
trade, pick, cue and phrases are read from that page whenever they are needed, so the
words Maude speaks always come from the approved bytes, never from an index row.

Every command is one transaction (`with conn:`), so an approve of five trades writes
five ledger rows or none, whatever stops it, and a revoke takes its trades off call in
every project in the same commit. Triggers refuse an UPDATE or DELETE on the pages and
the ledger: they guard against an accident, not against someone who can run sqlite.

The db and its directory are never symlinks; readers open it read-only by URI.
"""
from __future__ import annotations

import hashlib
import os
import sqlite3
import stat
from pathlib import Path

DB_NAME = "rolodex.db"
_BUSY_MS = 3000

_SCHEMA = """
CREATE TABLE IF NOT EXISTS pages (
  digest TEXT PRIMARY KEY CHECK (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
  body   BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS ledger (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  slug   TEXT NOT NULL,
  verb   TEXT NOT NULL CHECK (verb IN ('approve', 'revoke')),
  digest TEXT REFERENCES pages (digest),
  at     TEXT NOT NULL,
  CHECK ((verb = 'approve') = (digest IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS ledger_slug ON ledger (slug, id);
CREATE TABLE IF NOT EXISTS live (
  project TEXT NOT NULL,
  slug    TEXT NOT NULL,
  digest  TEXT NOT NULL REFERENCES pages (digest),
  flag    TEXT NOT NULL CHECK (flag IN ('same', 'moved')),
  PRIMARY KEY (project, slug)
);
CREATE TRIGGER IF NOT EXISTS pages_keep_u BEFORE UPDATE ON pages
  BEGIN SELECT RAISE(ABORT, 'pages are append-only'); END;
CREATE TRIGGER IF NOT EXISTS pages_keep_d BEFORE DELETE ON pages
  BEGIN SELECT RAISE(ABORT, 'pages are append-only'); END;
CREATE TRIGGER IF NOT EXISTS ledger_keep_u BEFORE UPDATE ON ledger
  BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END;
CREATE TRIGGER IF NOT EXISTS ledger_keep_d BEFORE DELETE ON ledger
  BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END;
"""

# The last ledger row per slug, as (slug, verb, digest).
_LAST = """
SELECT l.slug, l.verb, l.digest FROM ledger l
 WHERE l.id = (SELECT max(id) FROM ledger WHERE slug = l.slug)
"""


class DbError(Exception):
    """The store cannot be trusted or reached; nothing was written."""


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def path(rolodex_dir: Path) -> Path:
    return rolodex_dir / DB_NAME


def _not_a_link(p: Path) -> None:
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        return
    except OSError as e:
        raise DbError(f"{p.name} cannot be checked ({e.__class__.__name__})") from None
    if stat.S_ISLNK(st.st_mode):
        raise DbError(f"{p.name} is a symbolic link; Maude will not use it")
    if p.name == DB_NAME and not stat.S_ISREG(st.st_mode):
        raise DbError(f"{p.name} is not a regular file")


def open_rw(rolodex_dir: Path) -> sqlite3.Connection:
    """The store, created if absent, for a command that writes."""
    for p in (rolodex_dir.parent, rolodex_dir, path(rolodex_dir)):
        _not_a_link(p)
    try:
        rolodex_dir.mkdir(parents=True, exist_ok=True)
        _not_a_link(rolodex_dir)
        conn = sqlite3.connect(str(path(rolodex_dir)), timeout=_BUSY_MS / 1000, isolation_level=None)
    except (OSError, sqlite3.Error) as e:
        raise DbError(f"the Rolodex store cannot be opened ({e.__class__.__name__})") from None
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        conn.executescript(_SCHEMA)
    except sqlite3.Error as e:
        conn.close()
        raise DbError(f"the Rolodex store cannot be read ({e.__class__.__name__})") from None
    return conn


def open_ro(rolodex_dir: Path) -> sqlite3.Connection | None:
    """The store read-only, or None when it is absent or in doubt (the cue stays quiet)."""
    p = path(rolodex_dir)
    try:
        for q in (rolodex_dir.parent, rolodex_dir, p):
            _not_a_link(q)
        if not p.is_file():
            return None
        uri = "file:" + str(p).replace("%", "%25").replace("?", "%3f").replace("#", "%23") + "?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=_BUSY_MS / 1000, isolation_level=None)
        conn.execute("SELECT 1 FROM ledger LIMIT 1")
        return conn
    except (DbError, OSError, sqlite3.Error):
        return None


def begin(conn: sqlite3.Connection) -> None:
    conn.execute("BEGIN IMMEDIATE")


def last(conn: sqlite3.Connection) -> dict[str, tuple[str, str | None]]:
    """slug -> (verb, digest) of its last ledger row."""
    return {s: (v, d) for s, v, d in conn.execute(_LAST)}


def approved(conn: sqlite3.Connection) -> dict[str, str]:
    """slug -> digest, for slugs whose last row is an approve."""
    return {s: d for s, (v, d) in last(conn).items() if v == "approve" and d}


def page(conn: sqlite3.Connection, digest: str) -> bytes | None:
    """An approved page's bytes, only if they still hash to their key."""
    row = conn.execute("SELECT body FROM pages WHERE digest = ?", (digest,)).fetchone()
    if row is None or not isinstance(row[0], (bytes, bytearray)):
        return None
    body = bytes(row[0])
    return body if sha(body) == digest else None


def add_approve(conn: sqlite3.Connection, slug: str, body: bytes, at: str) -> str:
    """Inside the caller's transaction: the page (once per digest) and its approve row."""
    digest = sha(body)
    conn.execute("INSERT OR IGNORE INTO pages (digest, body) VALUES (?, ?)", (digest, body))
    conn.execute("INSERT INTO ledger (slug, verb, digest, at) VALUES (?, 'approve', ?, ?)",
                 (slug, digest, at))
    return digest


def add_revoke(conn: sqlite3.Connection, slug: str, at: str) -> None:
    """Inside the caller's transaction: the revoke row, and the slug off call everywhere."""
    conn.execute("INSERT INTO ledger (slug, verb, digest, at) VALUES (?, 'revoke', NULL, ?)", (slug, at))
    conn.execute("DELETE FROM live WHERE slug = ?", (slug,))


def set_live(conn: sqlite3.Connection, project: str, rows: list[tuple[str, str, str]]) -> None:
    """Inside the caller's transaction: this project's live rows, replaced whole.

    rows are (slug, digest, flag)."""
    conn.execute("DELETE FROM live WHERE project = ?", (project,))
    conn.executemany("INSERT INTO live (project, slug, digest, flag) VALUES (?, ?, ?, ?)",
                     [(project, s, d, f) for s, d, f in rows])


def live(conn: sqlite3.Connection, project: str) -> list[tuple[str, bytes]]:
    """(slug, page bytes) on call in this project, whose digest is still the slug's last
    approve and whose bytes still hash to it. Sorted by slug."""
    out = []
    current = approved(conn)
    for slug, digest in conn.execute(
            "SELECT slug, digest FROM live WHERE project = ? ORDER BY slug", (project,)):
        if current.get(slug) != digest:
            continue
        body = page(conn, digest)
        if body is not None:
            out.append((slug, body))
    return out
