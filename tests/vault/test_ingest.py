import os
import pathlib

from maude_vault import db, ingest

FIX = pathlib.Path(__file__).parent / "fixtures" / "mem"


def test_parse_frontmatter_note(tmp_path):
    p = tmp_path / "user_john.md"
    p.write_text(
        "---\nname: user-john\ndescription: who john is\n"
        "metadata:\n  type: user\n---\n\nHe thinks in [[pictures]] and [[metaphors]].\n"
    )
    note = ingest.parse_note(p)
    assert note["name"] == "user-john"
    assert note["description"] == "who john is"
    assert note["type"] == "user"
    assert note["links"] == "metaphors,pictures"
    assert "pictures" in note["body"]


def test_parse_note_without_frontmatter(tmp_path):
    p = tmp_path / "today-2026-07-13.md"
    p.write_text("\n## 23:34\nMaude arch gap\n")
    note = ingest.parse_note(p)
    assert note["name"] == "today-2026-07-13"
    assert note["description"] == "## 23:34"
    assert note["type"] == ""


def test_build_counts_and_indexes(tmp_path):
    dbp = tmp_path / "vault.db"
    n = ingest.build(FIX, dbp)
    assert n >= 3
    conn = db.connect(dbp)
    assert conn.execute("SELECT count(*) FROM notes").fetchone()[0] == n
    assert conn.execute("SELECT count(*) FROM notes_fts").fetchone()[0] == n


def test_build_is_idempotent(tmp_path):
    dbp = tmp_path / "vault.db"
    n1 = ingest.build(FIX, dbp)
    n2 = ingest.build(FIX, dbp)  # rebuild must not double rows
    assert n1 == n2


def test_build_skips_one_broken_file_and_keeps_going(tmp_path):
    mem = tmp_path / "mem"
    mem.mkdir()
    (mem / "good1.md").write_text("First good note.\n", encoding="utf-8")
    (mem / "good2.md").write_text("Second good note.\n", encoding="utf-8")
    os.symlink("/nonexistent/x.md", mem / "bad.md")

    dbp = tmp_path / "vault.db"
    n = ingest.build(mem, dbp)

    assert n == 2
    conn = db.connect(dbp)
    names = {r[0] for r in conn.execute("SELECT name FROM notes")}
    assert names == {"good1", "good2"}


def test_superseded_by_marks_note(tmp_path):
    mem = tmp_path / "mem"
    mem.mkdir()
    (mem / "dead.md").write_text(
        "---\nname: dead-note\ndescription: an old standing rule\n"
        "superseded_by: the-new-rule\n---\nThe old rule text.\n"
    )
    (mem / "live.md").write_text(
        "---\nname: live-note\ndescription: the current rule\n---\nStanding rule text.\n"
    )
    dbp = tmp_path / "v.db"
    ingest.build(mem, dbp)
    import sqlite3
    conn = sqlite3.connect(dbp)
    rows = dict(conn.execute("SELECT name, superseded FROM notes").fetchall())
    assert rows["dead-note"] == "the-new-rule"
    assert rows["live-note"] == ""
    fts = [r[0] for r in conn.execute("SELECT name FROM notes_fts").fetchall()]
    assert "live-note" in fts and "dead-note" not in fts
    conn.close()


def test_status_superseded_also_marks(tmp_path):
    mem = tmp_path / "mem"
    mem.mkdir()
    (mem / "dead.md").write_text(
        "---\nname: dead-note\ndescription: x\nstatus: superseded\n---\nbody\n"
    )
    dbp = tmp_path / "v.db"
    ingest.build(mem, dbp)
    import sqlite3
    conn = sqlite3.connect(dbp)
    assert conn.execute("SELECT superseded FROM notes").fetchone()[0] == "superseded"
    assert conn.execute("SELECT count(*) FROM notes_fts").fetchone()[0] == 0
    conn.close()


def test_old_schema_db_is_rebuilt_not_crashed(tmp_path):
    # Simulate a vault.db left by 0.17.0 (user_version 0, no superseded column).
    import sqlite3
    dbp = tmp_path / "v.db"
    conn = sqlite3.connect(dbp)
    conn.execute("CREATE TABLE notes (path TEXT PRIMARY KEY, name TEXT, description TEXT,"
                 " type TEXT, body TEXT, mtime REAL, links TEXT)")
    conn.execute("CREATE VIRTUAL TABLE notes_fts USING fts5(path UNINDEXED, name,"
                 " description, body, tokenize='porter unicode61')")
    conn.commit()
    conn.close()
    mem = tmp_path / "mem"
    mem.mkdir()
    (mem / "a.md").write_text("---\nname: a\ndescription: d\n---\nbody\n")
    assert ingest.build(mem, dbp) == 1  # must not raise OperationalError
