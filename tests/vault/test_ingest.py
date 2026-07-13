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
