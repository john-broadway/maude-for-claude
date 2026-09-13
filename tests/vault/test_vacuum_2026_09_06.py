"""A rebuild that frees most of the file gives the space back (2026-09-06).

The live vault on this box sat at 35.8 MB after the schema-3 rebuild whose commit said it
took the file to 12.2 MB: 5,895 of its 8,749 pages were on the freelist. SQLite reuses free
pages but never shrinks a file on its own, so a build that wipes and reinserts every session
keeps the high-water mark forever. build() now VACUUMs when the freelist is more than a
quarter of the file. A size in a commit message is a claim about a FRESH file until the
live one says the same.
"""
import sqlite3

from maude_vault import ingest


def _corpus(d, n, words):
    d.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        (d / f"note{i}.md").write_text(
            f"---\nname: note{i}\ndescription: d\n---\n" + ("word " * words) + "\n"
        )


def _pages(dbp):
    c = sqlite3.connect(dbp)
    pages = c.execute("PRAGMA page_count").fetchone()[0]
    free = c.execute("PRAGMA freelist_count").fetchone()[0]
    c.close()
    return pages, free


def test_a_rebuild_that_frees_most_of_the_file_shrinks_it(tmp_path):
    mem = tmp_path / "mem"
    dbp = tmp_path / "vault.db"
    _corpus(mem, 200, 2000)
    ingest.build(mem, dbp)
    big = dbp.stat().st_size
    for p in sorted(mem.glob("note*.md"))[20:]:
        p.unlink()
    ingest.build(mem, dbp)
    assert dbp.stat().st_size < big // 2
    pages, free = _pages(dbp)
    assert free * 4 <= pages


def test_a_schema_version_change_does_not_keep_the_old_pages(tmp_path):
    dbp = tmp_path / "vault.db"
    c = sqlite3.connect(dbp)
    c.execute("PRAGMA user_version = 2")
    c.execute("CREATE TABLE notes(path TEXT PRIMARY KEY, body TEXT)")
    c.execute("CREATE VIRTUAL TABLE notes_fts USING fts5(path, body)")
    c.executemany("INSERT INTO notes VALUES (?,?)", [(str(i), "x" * 4000) for i in range(2000)])
    c.executemany("INSERT INTO notes_fts VALUES (?,?)", [(str(i), "x " * 2000) for i in range(2000)])
    c.commit()
    c.close()
    big = dbp.stat().st_size
    mem = tmp_path / "mem"
    _corpus(mem, 3, 10)
    ingest.build(mem, dbp)
    assert dbp.stat().st_size < big // 4
