import pathlib
import subprocess
import sys

FIX = pathlib.Path(__file__).parent / "fixtures" / "mem"
ROOT = pathlib.Path(__file__).resolve().parents[2]


def _run(*args):
    return subprocess.run(
        [sys.executable, "-m", "maude_vault", *args],
        cwd=ROOT, capture_output=True, text=True,
    )


def test_build_then_page(tmp_path):
    dbp = tmp_path / "vault.db"
    b = _run("build", "--mem-dir", str(FIX), "--db", str(dbp))
    assert b.returncode == 0
    assert "built" in b.stdout

    p = _run("page", "how do I handle john's metaphors", "--db", str(dbp), "--k", "2")
    assert p.returncode == 0
    assert "user-visual-mind" in p.stdout


def test_page_missing_db_is_silent(tmp_path):
    p = _run("page", "anything", "--db", str(tmp_path / "nope.db"))
    assert p.returncode == 0
    assert p.stdout.strip() == ""


def test_build_then_page_via_stdin(tmp_path):
    # Prompt as argv hits ARG_MAX/E2BIG for a large prompt (a 128KiB paste,
    # which the paging hook can see on every prompt submit). The query
    # positional must be optional: when omitted, read the query from stdin.
    dbp = tmp_path / "vault.db"
    b = _run("build", "--mem-dir", str(FIX), "--db", str(dbp))
    assert b.returncode == 0

    p = subprocess.run(
        [sys.executable, "-m", "maude_vault", "page", "--db", str(dbp), "--k", "2"],
        cwd=ROOT, capture_output=True, text=True,
        input="how do I handle john's metaphors",
    )
    assert p.returncode == 0
    assert "user-visual-mind" in p.stdout


def test_page_log_appends_jsonl(tmp_path):
    import json
    from maude_vault import ingest, __main__ as cli
    mem = tmp_path / "mem"
    mem.mkdir()
    (mem / "n.md").write_text("---\nname: wildebeest-note\ndescription: wildebeest\n---\nwildebeest\n")
    dbp = tmp_path / "v.db"
    ingest.build(mem, dbp)
    log = tmp_path / "recall-log.jsonl"
    cli.main(["page", "wildebeest", "--db", str(dbp), "--log", str(log)])
    cli.main(["page", "wildebeest", "--db", str(dbp), "--log", str(log)])
    lines = [json.loads(l) for l in log.read_text().splitlines()]
    assert len(lines) == 2
    assert lines[0]["hits"] == ["wildebeest-note"]
    assert isinstance(lines[0]["ts"], int)


def test_page_log_no_hits_writes_nothing(tmp_path):
    from maude_vault import ingest, __main__ as cli
    mem = tmp_path / "mem"
    mem.mkdir()
    (mem / "n.md").write_text("---\nname: n\ndescription: d\n---\nbody\n")
    dbp = tmp_path / "v.db"
    ingest.build(mem, dbp)
    log = tmp_path / "recall-log.jsonl"
    cli.main(["page", "qqqzz", "--db", str(dbp), "--log", str(log)])
    assert not log.exists()


def test_page_seen_file_never_repeats_a_note(tmp_path):
    # 2026-10-04 (John): the same three notes paged on almost every short prompt of a 17h
    # session, adding nothing after the first time. --seen holds what this session was shown.
    db = tmp_path / "v.db"
    seen = tmp_path / "seen"
    assert _run("build", "--mem-dir", str(FIX), "--db", str(db)).returncode == 0
    q = ("page", "how do I handle johns metaphors", "--db", str(db), "--seen", str(seen))
    first = _run(*q)
    assert "user-visual-mind" in first.stdout
    assert "user-visual-mind" in seen.read_text()
    assert "user-visual-mind" not in _run(*q).stdout


def test_page_snippets_flag_adds_the_snippet_line_for_the_eye(tmp_path):
    db = tmp_path / "v.db"
    assert _run("build", "--mem-dir", str(FIX), "--db", str(db)).returncode == 0
    plain = _run("page", "how do I handle johns metaphors", "--db", str(db)).stdout
    full = _run("page", "how do I handle johns metaphors", "--db", str(db), "--snippets").stdout
    assert not any(l.startswith("    ") for l in plain.splitlines())
    assert any(l.startswith("    ") for l in full.splitlines())
