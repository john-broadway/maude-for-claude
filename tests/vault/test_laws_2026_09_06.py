"""The laws of memory applied to the vault mirror (the memory lens, 2026-09-06).

DEFECT-9: the index stored every note body twice, in `notes` and again inside a plain FTS5
table, 35.8 MB for 16.5 MB of markdown, and `notes.body` had no reader. DEFECT-11: the mirror
served a body 849 s behind the file on disk with no signal, on every prompt, until the next
SessionStart rebuild.
"""
import pathlib
import shutil
import sqlite3
import time

from maude_vault import ingest, page

FIX = pathlib.Path(__file__).parent / "fixtures" / "mem"


def _copy_fixture(tmp_path):
    mem = tmp_path / "mem"
    shutil.copytree(FIX, mem)
    return mem


def test_the_body_is_stored_once(tmp_path):
    mem = _copy_fixture(tmp_path)
    dbp = tmp_path / "vault.db"
    ingest.build(mem, dbp)
    conn = sqlite3.connect(dbp)
    shadow = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE name LIKE 'notes_fts_%'")]
    # A plain FTS5 table keeps its own copy of every column in notes_fts_content; an
    # external-content table keeps only the index.
    assert "notes_fts_content" not in shadow, shadow
    # And the index still answers with a snippet drawn from the one copy.
    hits = page.page(dbp, "john pictures metaphors")
    assert hits and hits[0]["snippet"]
    conn.close()


def test_a_hit_whose_file_changed_since_the_build_is_marked_stale(tmp_path):
    mem = _copy_fixture(tmp_path)
    dbp = tmp_path / "vault.db"
    ingest.build(mem, dbp)
    fresh = page.page(dbp, "john pictures metaphors", mem_dir=mem)
    assert fresh and not fresh[0].get("stale")
    target = mem / fresh[0]["path"]
    target.write_text(target.read_text() + "\n\nedited after the build\n")
    future = time.time() + 5
    import os
    os.utime(target, (future, future))
    stale = page.page(dbp, "john pictures metaphors", mem_dir=mem)
    assert stale[0]["path"] == fresh[0]["path"]
    assert stale[0].get("stale") is True
    rendered = page.format_hits(stale)
    assert "changed since the index was built" in rendered


def test_a_hit_whose_file_was_deleted_since_the_build_says_deleted(tmp_path):
    """A missing file was marked stale with the wording for a changed one: he was shown
    a note, told it changed, and found nothing when he opened it (the 23rd lens, MINOR-6).
    A missing file gets its own word."""
    mem = _copy_fixture(tmp_path)
    dbp = tmp_path / "vault.db"
    ingest.build(mem, dbp)
    fresh = page.page(dbp, "john pictures metaphors", mem_dir=mem)
    assert fresh
    (mem / fresh[0]["path"]).unlink()
    gone = page.page(dbp, "john pictures metaphors", mem_dir=mem)
    assert gone[0]["path"] == fresh[0]["path"]
    assert gone[0].get("missing") is True
    rendered = page.format_hits(gone)
    assert "deleted since the index was built" in rendered
    assert "changed since" not in rendered
