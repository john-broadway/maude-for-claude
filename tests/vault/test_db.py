from maude_vault import db


def test_connect_creates_schema(tmp_path):
    conn = db.connect(tmp_path / "vault.db")
    tables = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
    )}
    assert "notes" in tables
    assert "notes_fts" in tables


def test_connect_is_idempotent(tmp_path):
    p = tmp_path / "vault.db"
    db.connect(p).close()
    conn = db.connect(p)  # must not raise on second open
    assert conn.execute("SELECT count(*) FROM notes").fetchone()[0] == 0
