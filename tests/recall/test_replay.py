"""The replay set (design B5): his questions, the note that should come up, scored by rank.

The real set holds his words and lives in the locked house; these rows are synthetic. What is
pinned: rank is by note, never chunk; a broken set (empty, a target the store lacks, a sha the
tape lacks) raises instead of scoring as a miss; the CLI exits 2 on one.
"""
from __future__ import annotations

import json
import pathlib
import sqlite3
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from maude_recall import replay
from maude_recall.store import Store

NOTES = [
    ("garden.md#0", "garden: tomatoes and basil in the raised bed", 1.0),
    ("garden.md#1", "garden: the raised bed gets water at dawn", 1.0),
    ("garden.md#2", "garden: tomatoes again, raised bed, tomatoes", 1.0),
    ("boat.md#0", "boat: the hull wants paint before spring", 2.0),
    ("tomatoes.md#0", "tomatoes ripen late here", 3.0),
]


@pytest.fixture
def store(tmp_path):
    s = Store(tmp_path / "recall.db")
    s.sync("vault", NOTES)
    yield s
    s.close()


def _set(tmp_path, *rows):
    p = tmp_path / "set.jsonl"
    p.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return p


def test_rank_is_by_note_not_chunk(store, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "tomatoes raised bed", "target": "tomatoes.md"}))
    (r,) = replay.run(store, rows)
    # garden.md has three chunks above it; counted once, tomatoes.md is second, not fourth
    assert r.top[:2] == ("garden.md", "tomatoes.md")
    assert r.rank == 2 and r.rung == "keyword"


def test_best_of_several_targets(store, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "tomatoes raised bed", "target": ["tomatoes.md", "garden.md"]}))
    assert replay.run(store, rows)[0].rank == 1


def test_a_held_note_that_never_comes_up_is_a_miss(store, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "tomatoes raised bed", "target": "boat.md"}))
    (r,) = replay.run(store, rows)
    assert r.rank is None and r.rung is None
    assert replay.summary([r]) == {"rows": 1, "unanswerable": 0, "at1": 0, "at5": 0, "missed": 1, "mrr": 0.0}


def test_a_target_the_store_lacks_is_a_broken_set(store, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "tomatoes", "target": "renamed.md"}))
    with pytest.raises(replay.ReplayError, match="renamed.md"):
        replay.run(store, rows)


def test_an_empty_set_is_broken(tmp_path):
    with pytest.raises(replay.ReplayError, match="empty"):
        replay.load(_set(tmp_path))
    (tmp_path / "blank.jsonl").write_text("\n\n", encoding="utf-8")
    with pytest.raises(replay.ReplayError, match="empty"):
        replay.load(tmp_path / "blank.jsonl")


@pytest.mark.parametrize("row,words", [
    ({"text": "x"}, "no target"),
    ({"text": "x", "target": []}, "no target"),
    ({"target": "a.md"}, "neither sha nor text"),
    ({"text": "   ", "target": "a.md"}, "blank"),
    ({"sha": "abc", "target": "a.md"}, "needs --tape-db"),
])
def test_malformed_rows_raise(tmp_path, row, words):
    with pytest.raises(replay.ReplayError, match=words):
        replay.load(_set(tmp_path, row))


def test_sha_reads_his_line_from_the_tape(tmp_path):
    tape = tmp_path / "tape.db"
    with sqlite3.connect(tape) as c:
        c.execute("CREATE TABLE voice (id INTEGER PRIMARY KEY, ts REAL, text TEXT NOT NULL, sha TEXT UNIQUE)")
        c.execute("INSERT INTO voice (ts, text, sha) VALUES (1, 'tomatoes soemthing', 'aa11')")
    rows = replay.load(_set(tmp_path, {"sha": "aa11", "target": "tomatoes.md"}), tape)
    assert rows[0].query == "tomatoes soemthing"  # his spelling, never cleaned up
    with pytest.raises(replay.ReplayError, match="not on the tape"):
        replay.load(_set(tmp_path, {"sha": "bb22", "target": "tomatoes.md"}), tape)


def _cli(*args):
    return subprocess.run([sys.executable, "-m", "maude_recall", "replay", *map(str, args)],
                          cwd=ROOT, capture_output=True, text=True)


def test_cli_prints_ranks_then_totals(store, tmp_path):
    p = _set(tmp_path, {"text": "tomatoes raised bed", "target": "tomatoes.md", "why": "w"})
    res = _cli("--db", tmp_path / "recall.db", "--set", p, "--whole")
    assert res.returncode == 0, res.stderr
    lines = [json.loads(x) for x in res.stdout.splitlines()]
    assert lines[0]["rank"] == 2 and lines[0]["why"] == "w"
    assert lines[-1]["rows"] == 1 and lines[-1]["at5"] == 1


def test_cli_exits_2_on_a_broken_set(store, tmp_path):
    res = _cli("--db", tmp_path / "recall.db", "--set", _set(tmp_path))
    assert res.returncode == 2 and "empty" in res.stderr
    res = _cli("--db", tmp_path / "none.db", "--set", _set(tmp_path, {"text": "x", "target": "a.md"}))
    assert res.returncode == 2 and "build it first" in res.stderr


DAY = 86400.0
DATED = [
    ("old.md#0", "the localized vault keeps sqlite", 1 * DAY),
    ("late.md#0", "localized localized localized sqlite, the answer written down later", 5 * DAY),
    ("new.md#0", "a note born after the question", 6 * DAY),
]


@pytest.fixture
def dated(tmp_path):
    path = tmp_path / "dated.db"
    s = Store(path)
    s.sync("vault", DATED)
    s.close()
    return path


def _sha(path):
    import hashlib
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def test_fair_scores_each_row_on_the_store_before_the_day_he_asked(dated, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "localized sqlite", "target": "old.md", "asked": 3 * DAY + 50}))
    s = Store(dated)
    try:
        assert replay.run(s, rows)[0].rank == 2  # the later note outranks it in hindsight
    finally:
        s.close()
    before = _sha(dated)
    (r,) = replay.run_fair(dated, rows)
    assert r.rank == 1 and r.cut == 3 * DAY and "late.md" not in r.top
    assert _sha(dated) == before  # the house's store is never touched


def test_a_target_newer_than_the_question_is_unanswerable_not_a_miss(dated, tmp_path):
    rows = replay.load(_set(tmp_path,
                            {"text": "localized", "target": "new.md", "asked": 3 * DAY},
                            {"text": "localized", "target": "old.md", "asked": 3 * DAY}))
    res = replay.run_fair(dated, rows)
    assert res[0].unanswerable and res[0].rank is None
    assert replay.summary(res) == {"rows": 1, "unanswerable": 1, "at1": 1, "at5": 1, "missed": 0, "mrr": 1.0}
    with pytest.raises(replay.ReplayError, match="every row is unanswerable"):
        replay.summary(res[:1])


def test_fair_needs_when_he_asked(dated, tmp_path):
    with pytest.raises(replay.ReplayError, match="when he asked"):
        replay.run_fair(dated, replay.load(_set(tmp_path, {"text": "x", "target": "old.md"})))
    with pytest.raises(replay.ReplayError, match="epoch"):
        replay.load(_set(tmp_path, {"text": "x", "target": "old.md", "asked": "yesterday"}))


def test_fair_relearns_her_table_on_the_cut(dated, tmp_path, monkeypatch):
    s = Store(dated)
    s.learn_table()
    s.close()
    seen_counts = []
    real = Store.learn_table

    def spy(self):
        out = real(self)
        seen_counts.append((out, self._db.execute("SELECT count(*) FROM items").fetchone()[0]))
        return out
    monkeypatch.setattr(Store, "learn_table", spy)
    replay.run_fair(dated, replay.load(_set(tmp_path, {"text": "localized", "target": "old.md", "asked": 3 * DAY})))
    assert seen_counts == [(True, 1)]  # it really learned, on the one item that existed, never the later two


def test_cli_is_fair_by_default(dated, tmp_path):
    p = _set(tmp_path, {"text": "localized sqlite", "target": "old.md", "asked": 3 * DAY + 50})
    lines = [json.loads(x) for x in _cli("--db", dated, "--set", p).stdout.splitlines()]
    assert lines[0]["rank"] == 1 and lines[0]["cut"] == 3 * DAY
    lines = [json.loads(x) for x in _cli("--db", dated, "--set", p, "--whole").stdout.splitlines()]
    assert lines[0]["rank"] == 2 and lines[0]["cut"] is None


def test_rows_come_back_in_their_order_across_days(dated, tmp_path):
    rows = replay.load(_set(tmp_path,
                            {"text": "localized", "target": "late.md", "asked": 5 * DAY + 9, "why": "second day"},
                            {"text": "localized", "target": "old.md", "asked": 3 * DAY, "why": "first day"}))
    res = replay.run_fair(dated, rows)
    assert [r.row.why for r in res] == ["second day", "first day"]
    assert [r.cut for r in res] == [5 * DAY, 3 * DAY]


def test_partial_targets_say_which_were_held(dated, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "localized", "target": ["new.md", "old.md"], "asked": 3 * DAY}))
    (r,) = replay.run_fair(dated, rows)
    assert r.held == ("old.md",) and r.rank == 1


def test_the_copy_lives_in_the_house_owner_only_and_a_stale_one_is_swept(dated, tmp_path, monkeypatch):
    import os, stat
    house = pathlib.Path(dated).parent
    stale = house / ".replay-killed"
    stale.mkdir()
    (stale / "cut.db").write_bytes(b"his words")
    modes = []
    real = replay.run

    def spy(store, rows, **kw):
        path = store._db.execute("PRAGMA database_list").fetchone()[2]
        modes.append((pathlib.Path(path).parent.parent == house, stat.S_IMODE(os.stat(path).st_mode),
                      stat.S_IMODE(os.stat(pathlib.Path(path).parent).st_mode)))
        return real(store, rows, **kw)
    monkeypatch.setattr(replay, "run", spy)
    replay.run_fair(dated, replay.load(_set(tmp_path, {"text": "localized", "target": "old.md", "asked": 3 * DAY})))
    assert modes == [(True, 0o600, 0o700)]
    assert not stale.exists() and not list(house.glob(".replay-*"))


def test_an_older_store_is_never_written(tmp_path):
    import sqlite3
    path = tmp_path / "old.db"
    s = Store(path)
    s.sync("vault", DATED)
    s.close()
    with sqlite3.connect(path) as c:  # the schema before her table existed
        c.executescript("DROP TABLE hwords; DROP TABLE hvecs; DROP TABLE meta;")
    before = _sha(path)
    replay.run_fair(path, replay.load(_set(tmp_path, {"text": "localized", "target": "old.md", "asked": 3 * DAY})))
    assert _sha(path) == before


def test_fair_refuses_a_missing_store(tmp_path):
    with pytest.raises(replay.ReplayError, match="no store"):
        replay.run_fair(tmp_path / "none.db", [replay.Row("q", ("a.md",), "", 1.0)])
    assert not (tmp_path / "none.db").exists()


def test_cli_exits_2_when_every_row_is_unanswerable(dated, tmp_path):
    p = _set(tmp_path, {"text": "localized", "target": "new.md", "asked": 3 * DAY})
    res = _cli("--db", dated, "--set", p)
    assert res.returncode == 2 and "every row is unanswerable" in res.stderr


def _git(repo, *args, when=None):
    import os, subprocess
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
    if when is not None:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"@{int(when)} +0000"
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=env)


@pytest.fixture
def mem(tmp_path):
    import shutil
    if not shutil.which("git"):
        pytest.skip("no git")
    repo = tmp_path / "mem"
    repo.mkdir()
    _git(repo, "init", "-q")
    (repo / "a.md").write_text("---\nname: a\n---\nthe localized vault keeps sqlite\n", encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "one", when=1 * DAY)
    (repo / "a.md").write_text("---\nname: a\n---\nthe localized vault keeps sqlite\n"
                               "he said: why am i seeing vectorized\n", encoding="utf-8")
    (repo / "b.md").write_text("---\nname: b\n---\nborn later\n", encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "two", when=4 * DAY)
    return repo


@pytest.fixture
def now_store(tmp_path, mem):
    from maude_recall import sources
    from maude_vault import ingest
    vdb = tmp_path / "vault.db"
    ingest.build(mem, vdb)
    path = tmp_path / "now.db"
    s = Store(path)
    s.sync("vault", sources.vault_items(vdb))
    s.close()
    return path


def test_vault_git_scores_the_note_as_it_stood_before_he_spoke(now_store, mem, tmp_path, monkeypatch):
    texts = []
    real = replay.run

    def spy(store, rows, **kw):
        texts.append(" ".join(t for (t,) in store._db.execute("SELECT text FROM items WHERE ns = 'vault'")))
        return real(store, rows, **kw)
    monkeypatch.setattr(replay, "run", spy)
    rows = replay.load(_set(tmp_path, {"text": "why am i seeing vectorized", "target": "a.md", "asked": 3 * DAY}))
    (r,) = replay.run_fair(now_store, rows, vault_git=mem)
    assert "vectorized" not in texts[0] and "localized vault" in texts[0]  # the later quote is not there
    assert r.rank is None and not r.unanswerable  # the note existed; its words then do not match


def test_vault_git_a_note_born_later_is_unanswerable(now_store, mem, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "born", "target": "b.md", "asked": 3 * DAY},
                            {"text": "localized", "target": "a.md", "asked": 3 * DAY}))
    res = replay.run_fair(now_store, rows, vault_git=mem)
    assert res[0].unanswerable and res[1].rank == 1


def test_vault_git_no_commit_before_the_cut(now_store, mem, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "localized", "target": "a.md", "asked": 0.5 * DAY}))
    with pytest.raises(replay.ReplayError, match="every row is unanswerable"):
        replay.summary(replay.run_fair(now_store, rows, vault_git=mem))


def test_vault_git_refuses_a_non_repository(now_store, tmp_path):
    rows = replay.load(_set(tmp_path, {"text": "localized", "target": "a.md", "asked": 3 * DAY}))
    with pytest.raises(replay.ReplayError, match="not a git repository"):
        replay.run_fair(now_store, rows, vault_git=tmp_path)


def test_totals_per_kind(dated, tmp_path):
    rows = replay.load(_set(tmp_path,
                            {"text": "localized", "target": "old.md", "asked": 3 * DAY, "kind": "lesson"},
                            {"text": "nothing matches zebra", "target": "old.md", "asked": 3 * DAY, "kind": "context"},
                            {"text": "localized", "target": "new.md", "asked": 3 * DAY, "kind": "context"}))
    s = replay.summary(replay.run_fair(dated, rows))
    assert s["rows"] == 2 and s["unanswerable"] == 1
    assert s["by_kind"]["lesson"] == {"unanswerable": 0, "rows": 1, "at1": 1, "at5": 1, "missed": 0, "mrr": 1.0}
    assert s["by_kind"]["context"] == {"unanswerable": 1, "rows": 1, "at1": 0, "at5": 0, "missed": 1, "mrr": 0.0}


def test_a_flagged_line_is_never_a_row(tmp_path):
    from maude_tape.tape import Tape
    from maude_tape import voice
    tape = tmp_path / "tape.db"
    t = Tape(tape)
    voice._insert_voice_row(t, ts=1.0, text="sounds good ship it", source="hook", register="chat",
                            session=None, sha="sugg")
    t._conn.execute("INSERT INTO voice_flags (sha, flag) VALUES ('sugg', 'suggestion_accepted')")
    t._conn.commit()
    t._conn.close()
    with pytest.raises(replay.ReplayError, match="flagged suggestion_accepted"):
        replay.load(_set(tmp_path, {"sha": "sugg", "target": "a.md"}), tape)


def test_vault_git_keeps_a_note_unchanged_since_the_cut(tmp_path):
    """A note whose text is the same then and now still exists at the cut. The store holds it
    with today's mtime; sync must take the cut's time, or the cut drops the note as born later
    (found 2026-10-31: 7 of the 23 mined lesson rows read unanswerable, every one wrongly)."""
    import shutil
    from maude_recall import sources
    from maude_vault import ingest
    if not shutil.which("git"):
        pytest.skip("no git")
    repo = tmp_path / "mem"
    repo.mkdir()
    _git(repo, "init", "-q")
    (repo / "c.md").write_text("---\nname: c\n---\nwick stays agnostic of the substrate\n", encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "one", when=1 * DAY)
    vdb = tmp_path / "vault.db"
    ingest.build(repo, vdb)  # the working file's mtime is now, long after the cut
    path = tmp_path / "now.db"
    s = Store(path)
    s.sync("vault", sources.vault_items(vdb))
    s.close()
    rows = replay.load(_set(tmp_path, {"text": "agnostic substrate", "target": "c.md", "asked": 3 * DAY}))
    (r,) = replay.run_fair(path, rows, vault_git=repo)
    assert not r.unanswerable and r.rank == 1


def test_sync_takes_the_new_time_of_an_unchanged_item(tmp_path):
    s = Store(tmp_path / "s.db")
    try:
        s.sync("vault", [("a.md#0", "same words", 900.0)])
        assert s.sync("vault", [("a.md#0", "same words", 100.0)]) == 1
        assert s._db.execute("SELECT ts FROM items WHERE key = 'a.md#0'").fetchone() == (100.0,)
        assert s.sync("vault", [("a.md#0", "same words", 100.0)]) == 0
    finally:
        s.close()


# --- the cut's cards are embedded, so meaning sees the note as it stood -------------------

import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

MEANINGS = {"vectorized": 0, "embedder": 0, "localized": 1, "sovereign": 1}
CALLS = []


class _Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        inputs = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["input"]
        CALLS.extend(inputs)

        def vec(t):
            v = [0.0, 0.0]
            for w in t.lower().replace(",", " ").split():
                if w in MEANINGS:
                    v[MEANINGS[w]] += 1.0
            return v
        body = json.dumps({"data": [{"index": i, "embedding": vec(t)} for i, t in enumerate(inputs)]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)


@pytest.fixture
def emb():
    srv = HTTPServer(("127.0.0.1", 0), _Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    CALLS.clear()
    yield {"url": f"http://127.0.0.1:{srv.server_port}/v1/embeddings", "model": "nomic-stub", "dim": 2}
    srv.shutdown()


@pytest.fixture
def carded(tmp_path):
    """c.md's description at commit one means one thing; at commit two another. Today's store
    holds (and embeds) only today's card."""
    import shutil
    from maude_recall import sources
    from maude_vault import ingest
    if not shutil.which("git"):
        pytest.skip("no git")
    repo = tmp_path / "mem"
    repo.mkdir()
    _git(repo, "init", "-q")
    (repo / "c.md").write_text("---\nname: c\ndescription: a sovereign embedder for the box\n---\nplain body\n",
                               encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "one", when=1 * DAY)
    (repo / "c.md").write_text("---\nname: c\ndescription: the vectorized one\n---\nplain body\n", encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "two", when=4 * DAY)
    vdb = tmp_path / "vault.db"
    ingest.build(repo, vdb)
    path = tmp_path / "now.db"
    s = Store(path)
    s.sync("vault", sources.vault_items(vdb))
    s.sync("card", sources.vault_cards(vdb))
    s.close()
    return path, repo


def test_fair_embeds_the_cards_as_they_stood_at_the_cut(carded, tmp_path, emb):
    path, repo = carded
    s = Store(path)
    s.embed_pending(emb, budget=10)
    s.close()
    rows = replay.load(_set(tmp_path, {"text": "localized sovereign", "target": "c.md", "asked": 3 * DAY}))
    (r,) = replay.run_fair(path, rows, emb=emb, vault_git=repo)
    assert (r.rank, r.rung) == (1, "card")  # the day-1 card means it; today's does not (words also place
    # the note first through its chunk head; "card" is the tie-break's label, and M14 shows the embed is what is pinned)


def test_fair_fails_closed_when_the_embedder_is_down_or_the_budget_runs_out(carded, tmp_path, emb):
    """A cut scored on a partial card vault is the artifact the embed step removes: no number."""
    path, repo = carded
    rows = replay.load(_set(tmp_path, {"text": "localized sovereign", "target": "c.md", "asked": 3 * DAY}))
    dead = dict(emb, url="http://127.0.0.1:9/v1/embeddings")
    with pytest.raises(replay.ReplayError, match="embedder failed"):
        replay.run_fair(path, rows, emb=dead, vault_git=repo)
    with pytest.raises(replay.ReplayError, match="unembedded"):
        replay.run_fair(path, rows, emb=emb, vault_git=repo, embed_budget=0.0)


def test_fair_keeps_the_cut_vectors_in_a_cache_beside_the_store(carded, tmp_path, emb):
    path, repo = carded
    rows = replay.load(_set(tmp_path, {"text": "localized sovereign", "target": "c.md", "asked": 3 * DAY}))
    replay.run_fair(path, rows, emb=emb, vault_git=repo)
    cache = pathlib.Path(str(path) + ".vcache")
    assert cache.is_file() and (cache.stat().st_mode & 0o777) == 0o600
    CALLS.clear()
    (r,) = replay.run_fair(path, rows, emb=emb, vault_git=repo)
    assert r.rank == 1 and not any(c.startswith("search_document") for c in CALLS)
