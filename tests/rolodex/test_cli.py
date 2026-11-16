"""The CLI layer: no traceback, one signed line. Houses under tmp_path."""
from maude_rolodex.__main__ import main


def test_a_nul_byte_in_home_is_one_signed_line_not_a_traceback(tmp_path, capsys):
    rc = main(["live", "--home", "/a\0b", "--project", str(tmp_path)])
    err = capsys.readouterr().err
    assert rc == 2
    assert err.startswith("**Maude:** the Rolodex could not do that: ") and err.count("\n") == 1
    assert "Traceback" not in err and "embedded" not in err      # class name only, no message text


def test_a_store_refusal_is_one_signed_line(tmp_path, capsys):
    (tmp_path / "home").mkdir()
    rc = main(["approve", "../x@" + "a" * 64, "--home", str(tmp_path / "home"), "--project", str(tmp_path)])
    err = capsys.readouterr().err
    assert rc == 2 and err.startswith("**Maude:** ") and "not a trade name" in err and err.count("\n") == 1


def test_a_full_hash_is_needed_on_the_command_line(tmp_path, capsys):
    (tmp_path / "home").mkdir()
    rc = main(["approve", "mending", "--home", str(tmp_path / "home"), "--project", str(tmp_path)])
    assert rc == 2 and "needs the hash" in capsys.readouterr().err


# --- fix round 2 -------------------------------------------------------------------

import hashlib

from .test_page import GOOD


def _house(tmp_path, *slugs):
    """A home with a personal skill `diary` and approved trades (same page) under each slug."""
    from maude_rolodex import store
    home, proj = tmp_path / "home", tmp_path / "proj"
    proj.mkdir()
    skill = home / ".claude/skills/diary"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: diary\ndescription: d\n---\nbody\n")
    page = GOOD.replace(b"handyman:mend", b"diary").replace(b"handyman@mk@1.0.0", b"personal")
    for s in slugs:
        p = home / ".claude/maude/rolodex/pending" / f"{s}.md"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(page)
        store.approve(home, [(s, hashlib.sha256(page).hexdigest())], "2026-11-10T10:00:00Z")
    return home, proj


def _live_slugs(home, proj):
    from maude_rolodex import store
    return [slug for slug, _ in store.live_pages(home, proj)]


def _db_bytes(home):
    p = home / ".claude/maude/rolodex/rolodex.db"
    return p.read_bytes() if p.exists() else None


def test_approve_and_revoke_through_the_cli(tmp_path, capsys):
    home, proj = _house(tmp_path)
    args = ["--home", str(home), "--project", str(proj)]
    page = GOOD.replace(b"handyman:mend", b"diary").replace(b"handyman@mk@1.0.0", b"personal")
    p = home / ".claude/maude/rolodex/pending/a.md"
    p.parent.mkdir(parents=True)
    p.write_bytes(page)
    assert main(["approve", f"a@{hashlib.sha256(page).hexdigest()}"] + args) == 0
    assert "approved a" in capsys.readouterr().out
    assert _live_slugs(home, proj) == ["a"]          # on call here at once: approve re-derived
    assert main(["revoke", "a"] + args) == 0
    assert _live_slugs(home, proj) == []


def test_a_revoke_is_off_call_in_another_project_without_a_rebuild(tmp_path, capsys):
    home, proj = _house(tmp_path, "a", "b")
    other = tmp_path / "other"
    other.mkdir()
    for pr in (proj, other):
        assert main(["live", "--home", str(home), "--project", str(pr)]) == 0
        assert _live_slugs(home, pr) == ["a", "b"]
    assert main(["revoke", "a", "--home", str(home), "--project", str(proj)]) == 0
    assert _live_slugs(home, other) == ["b"] and _live_slugs(home, proj) == ["b"]


def test_a_refused_approve_writes_nothing_at_all(tmp_path, capsys):
    home, proj = _house(tmp_path, "a")
    before = sorted(str(p) for p in tmp_path.rglob("*")), _db_bytes(home)
    rc = main(["approve", "nope@" + "a" * 64, "--home", str(home), "--project", str(proj)])
    assert rc == 2 and (sorted(str(p) for p in tmp_path.rglob("*")), _db_bytes(home)) == before


def test_an_approve_whose_rebuild_fails_is_committed_and_says_not_yet_on_call(tmp_path, capsys, monkeypatch):
    from maude_rolodex import index, store
    home, proj = _house(tmp_path)
    page = GOOD.replace(b"handyman:mend", b"diary").replace(b"handyman@mk@1.0.0", b"personal")
    p = home / ".claude/maude/rolodex/pending/a.md"
    p.parent.mkdir(parents=True)
    p.write_bytes(page)
    monkeypatch.setattr(index, "build", lambda *a: (_ for _ in ()).throw(OSError("x")))
    rc = main(["approve", f"a@{hashlib.sha256(page).hexdigest()}", "--home", str(home), "--project", str(proj)])
    cap = capsys.readouterr()
    assert rc == 2
    assert cap.err.startswith("**Maude:** ") and cap.err.count("\n") == 1 and "not yet on call" in cap.err
    assert "approved a" in cap.out
    assert store.status(home) == {"a": hashlib.sha256(page).hexdigest()}
    assert _live_slugs(home, proj) == []
