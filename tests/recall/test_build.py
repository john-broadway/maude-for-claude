"""python3 -m maude_recall build / recall: the background build and its first sources.

Sources: the vault's notes as maude_vault parsed them (vault.db; superseded notes skipped),
and his typed lines from the tape (not the machine's, not pastes). The build syncs words
at once and embeds what it can inside its budget, under a lock so two sessions never
build at the same time.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_recall import sources
from maude_recall.store import Store
from maude_tape import voice
from maude_tape.tape import Tape
from maude_vault import db as vault_db

import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

MEANINGS = {"vectorized": 0, "embedder": 0, "localized": 1, "sovereign": 1}


class _Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        inputs = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["input"]
        def vec(t):
            v = [0.0, 0.0, 0.01]
            for w in t.lower().replace(":", " ").split():
                if w in MEANINGS:
                    v[MEANINGS[w]] += 1.0
            return v
        body = json.dumps({"data": [{"index": i, "embedding": vec(t)} for i, t in enumerate(inputs)]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)


@pytest.fixture
def emb():
    srv = HTTPServer(("127.0.0.1", 0), _Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield {"url": f"http://127.0.0.1:{srv.server_port}/v1/embeddings", "model": "nomic-stub", "dim": 3}
    srv.shutdown()

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _vault(tmp_path):
    p = tmp_path / "vault.db"
    c = vault_db.connect(p)
    rows = [("feedback_a.md", "a", "the all-local call", "feedback", "he wants a sovereign embedder on the box", 2.0, "", ""),
            ("old.md", "old", "gone", "project", "superseded lens text", 1.0, "", "feedback_a.md")]
    c.executemany("INSERT INTO notes VALUES (?,?,?,?,?,?,?,?)", rows)
    c.commit(); c.close()
    return p


def _tape(tmp_path):
    p = tmp_path / "tape.db"
    t = Tape(p)
    for i, text in enumerate(["merge it when the lens is clean",
                              '<agent-message from="x">lens done</agent-message>',
                              "x" * 500]):
        voice._insert_voice_row(t, ts=float(i + 1), text=text, source="hook", register="chat",
                                session=None, sha=f"s{i}")
    t._conn.commit()
    return p


def test_vault_items_skip_superseded_notes_and_carry_the_description(tmp_path):
    items = sources.vault_items(_vault(tmp_path))
    assert [k for k, _, _ in items] == ["feedback_a.md#0"]
    assert items[0][1].startswith("a: the all-local call")


def test_tape_items_are_his_typed_lines_only(tmp_path):
    items = sources.tape_items(_tape(tmp_path))
    assert [t for _, t, _ in items] == ["merge it when the lens is clean"]


def _cli(*args):
    return subprocess.run([sys.executable, "-m", "maude_recall", *args], capture_output=True,
                          text=True, cwd=str(ROOT), env={"PYTHONPATH": str(ROOT), "PATH": "/usr/bin:/bin"})


def test_build_then_recall_by_meaning(tmp_path, emb):
    care = tmp_path / "care.json"
    care.write_text(json.dumps({"embedder": emb}))
    rdb = tmp_path / "recall.db"
    r = _cli("build", "--db", str(rdb), "--vault-db", str(_vault(tmp_path)),
             "--tape-db", str(_tape(tmp_path)), "--care", str(care), "--budget", "20")
    assert r.returncode == 0, r.stderr
    out = _cli("recall", "--db", str(rdb), "--care", str(care), "--k", "1", "localized vectorized")
    hit = json.loads(out.stdout.splitlines()[0])
    assert (hit["key"], hit["rung"]) == ("feedback_a.md#0", "semantic")


def test_build_without_an_embedder_still_indexes_words(tmp_path):
    rdb = tmp_path / "recall.db"
    r = _cli("build", "--db", str(rdb), "--vault-db", str(_vault(tmp_path)),
             "--tape-db", str(_tape(tmp_path)), "--care", str(tmp_path / "none.json"), "--budget", "5")
    assert r.returncode == 0, r.stderr
    keys = [json.loads(l)["key"] for l in _cli("recall", "--db", str(rdb), "lens").stdout.splitlines()]
    assert keys == ["voice:s0"]


def test_a_second_build_waits_for_none_while_one_holds_the_lock(tmp_path):
    from maude_recall import __main__ as cli
    rdb = tmp_path / "recall.db"
    with cli.build_lock(rdb) as got:
        assert got
        with cli.build_lock(rdb) as again:
            assert not again


def test_vault_cards_one_per_live_note_from_slug_name_and_description(tmp_path):
    """The card: what the note is called and what it says it is. Short, so a lesson he says
    in other words can meet the note's own words for it (the seeing-gap rows, 2026-11-02)."""
    assert sources.vault_cards(_vault(tmp_path)) == [("feedback_a.md", "feedback a\na\nthe all-local call", 2.0)]
