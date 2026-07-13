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
