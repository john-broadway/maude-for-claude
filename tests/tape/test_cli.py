"""The CLI bridge — what Maude's bash hooks call to make the tape fire on its own.
`wake` plays the tape into context; `check` is the gate and fails CLOSED on a rejected line.
Uses a generic example seed — the public plugin ships no personal data.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = pathlib.Path(__file__).parent / "fixtures" / "seed.json"


def _run(*args, stdin=None):
    return subprocess.run(
        [sys.executable, "-m", "maude_tape", *args],
        cwd=ROOT, capture_output=True, text=True, input=stdin,
    )


def test_seed_is_idempotent_and_wake_plays_the_tape(tmp_path):
    db = tmp_path / "tape.db"
    assert _run("seed", "--db", str(db), "--from", str(FIX)).returncode == 0
    assert _run("seed", "--db", str(db), "--from", str(FIX)).returncode == 0  # no double-seed

    w = _run("wake", "--db", str(db))
    assert w.returncode == 0
    assert "keep it small" in w.stdout                # current truth, played
    assert "heroically slashed scope" in w.stdout     # named as never-render
    assert "nothing cut" in w.stdout                  # the tape knows what it is


def test_check_gate_fails_closed_on_a_rejected_phrasing(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    dirty = _run("check", "--db", str(db), stdin="we kept it small but heroically slashed scope")
    assert dirty.returncode != 0            # the gate BLOCKS
    assert "heroically slashed scope" in dirty.stdout


def test_check_gate_passes_a_clean_draft(tmp_path):
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    clean = _run("check", "--db", str(db), stdin="we kept it small.")
    assert clean.returncode == 0            # clean passes


def test_wake_is_silent_on_an_empty_tape(tmp_path):
    db = tmp_path / "tape.db"
    w = _run("wake", "--db", str(db))
    assert w.returncode == 0
    assert w.stdout.strip() == ""


def test_check_refuses_empty_input_instead_of_passing_it(tmp_path):
    """The gate said 'fail closed' but returned 0 on empty stdin — a vacuous pass.

    A gate that approves nothing-at-all approves anything the caller forgot to feed it.
    Empty or whitespace-only input is a CALLER error, not a clean draft.
    """
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    for blank in ("", "   \n  \t "):
        r = _run("check", "--db", str(db), stdin=blank)
        assert r.returncode != 0, f"empty input passed the gate (rc=0) for {blank!r}"
        assert "empty" in (r.stdout + r.stderr).lower()


def test_check_refuses_a_file_path_argument_instead_of_checking_its_name(tmp_path):
    """`check /path/to/draft.md` checked the PATH STRING, not the draft — always clean, always rc 0.

    Silently grading a filename is the same vacuous pass wearing a different costume.
    """
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    draft = tmp_path / "draft.md"
    draft.write_text("we kept it small but heroically slashed scope\n", encoding="utf-8")

    r = _run("check", str(draft), "--db", str(db))
    assert r.returncode != 0, "a path argument passed the gate without its contents being read"


def test_check_refuses_when_the_TAPE_is_missing_not_just_the_draft(tmp_path):
    """A typo'd --db builds an EMPTY tape and clears a dirty draft with no error at all.

    sqlite3.connect() creates a missing file, so the gate finds zero rejections and reports
    clean. The redteam of the empty-draft fix found the same vacuous pass one layer down:
    it is not enough that a draft was read, the tape must be able to REFUSE.
    """
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    dirty = "we kept it small but heroically slashed scope"

    assert _run("check", "--db", str(db), stdin=dirty).returncode == 2   # control: it CAN refuse

    typo = tmp_path / "taep.db"                                          # one transposition
    r = _run("check", "--db", str(typo), stdin=dirty)
    assert r.returncode != 0, "a dirty draft passed against an auto-created empty tape"
    assert r.returncode != 2, "should refuse as UNUSABLE TAPE, not report a phrase hit"


def test_check_refuses_a_path_argument_of_ANY_kind_not_only_a_regular_file(tmp_path):
    """os.path.isfile() is False for a directory and for a dangling symlink, so both fell

    through and got graded as literal text. Same silent pass the file guard exists to stop.
    """
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))

    a_dir = tmp_path / "drafts"; a_dir.mkdir()
    dangling = tmp_path / "gone.md"; dangling.symlink_to(tmp_path / "nope.md")

    for target in (a_dir, dangling):
        r = _run("check", str(target), "--db", str(db))
        assert r.returncode == 3, f"{target.name} was graded as text instead of refused"


def test_check_path_refusal_fires_on_a_CLEAN_file_too(tmp_path):
    """The first path test asserted only `!= 0` against a DIRTY fixture, so a wrong fix that

    silently read and graded the file's CONTENTS would return 2 and still pass it. A clean
    file separates the two: refusing gives 3, grading-the-contents gives 0.
    """
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    clean = tmp_path / "clean.md"
    clean.write_text("nothing objectionable here.\n", encoding="utf-8")

    r = _run("check", str(clean), "--db", str(db))
    assert r.returncode == 3, "refusal must be content-independent, not a lucky phrase hit"


def test_check_exits_on_contract_when_the_db_cannot_be_opened(tmp_path):
    """An unopenable db raised an uncaught sqlite3.OperationalError and exited 1, outside the

    documented {0,2,3}. It fails closed, but a caller cannot tell 'blocked' from 'crashed'.
    """
    r = _run("check", "--db", str(tmp_path / "no" / "such" / "dir" / "t.db"), stdin="hello")
    assert r.returncode == 3
    assert "traceback" not in (r.stdout + r.stderr).lower()


def test_an_empty_rejected_phrase_cannot_block_every_draft(tmp_path):
    """'' is a substring of every string, so one empty phrase makes the gate refuse all text."""
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))
    _run("reject", "--db", str(db), "--phrase", "", "--reason", "x", "--source", "x")

    assert _run("check", "--db", str(db), stdin="a perfectly clean sentence.").returncode == 0


def test_a_rejected_phrase_is_caught_across_any_whitespace_including_a_line_break(tmp_path):
    """Matching was a literal substring test, so only ONE space shape was ever caught.

    A rejected phrase wrapped across a newline, or pasted with a non-breaking space, sailed
    through with exit 0. Line-wrapped prose is the common case, which made this the way bad
    text actually shipped. Normalising both sides can only ever catch MORE of what the owner
    already rejected, never fewer.
    """
    db = tmp_path / "tape.db"
    _run("seed", "--db", str(db), "--from", str(FIX))          # holds 'heroically slashed scope'

    variants = {
        "single space": "we heroically slashed scope",
        "double space": "we heroically  slashed scope",
        "tab":          "we heroically\tslashed scope",
        "newline":      "we heroically\nslashed scope",
        "nbsp":         "we heroically slashed scope",
        "em space":     "we heroically slashed scope",
    }
    for label, draft in variants.items():
        assert _run("check", "--db", str(db), stdin=draft).returncode == 2, f"{label} bypassed"

    # and it must not start blocking text that merely shares words
    assert _run("check", "--db", str(db), stdin="we slashed the scope heroically").returncode == 0
