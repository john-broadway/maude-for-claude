"""The wake fits where it is read (2026-09-25).

The tape's wake printed every live canon row: 31 KB on this workspace, 223 lines of his
words. Hook output past the harness's inline size is parked in a file and only a ~2 KB
preview reaches the session, so the tape that exists to bring Claude back was cut to its
first screen every wake, silently. 3.6 KB is the largest SessionStart output measured
landing inline here, so the wake keeps a byte budget (default 3,000).

What goes first is what must never be cut: NEVER RENDER (the gate's list) and WHO I AM.
His words follow, the ones he seeded first, then the newest session words, WHOLE rows only (a quote cut mid-sentence and labelled
verbatim is a re-rendering of him), then Claude's approved wording, then a footer that
counts what stayed on the tape and names the command that plays all of it.
"""
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE_TS = 1783814400.0  # 2026-07-12


def _wake(db, *extra, env_extra=None):
    env = {"PYTHONPATH": str(ROOT), "PATH": "/usr/bin:/bin"}
    env.update(env_extra or {})
    return subprocess.run([sys.executable, "-m", "maude_tape", "wake", "--db", str(db), *extra],
                          capture_output=True, text=True, cwd=str(ROOT), env=env).stdout


def _paid(db, base=3000):
    # The wake footer names the plugin root and the db path, and the budget reserves it, so
    # at the bare default the room left for ROWS shrinks as the paths grow: two tests that
    # fit from a short checkout path went red from a longer checkout or TMPDIR (2026-10-04).
    # A test about room for rows takes the default plus the BYTES its paths cost (a
    # multi-byte path counted in characters still fell short), so its rows meet the same
    # room on any machine. Tests of the default itself (the overrun line) keep the bare 3000.
    return {"MAUDE_TAPE_WAKE_BUDGET":
            str(base + len(str(ROOT).encode()) + len(str(db).encode()))}


def _big_tape(db, n=60):
    t = Tape(db)
    for i in range(n):
        t.remember(f"HISROW{i:03d} " + "word " * 55, topic=f"t{i}", source="john",
                   ts=BASE_TS + i * 3600)
    t.reject("a phrase he cut", reason="he said never", source="john")
    t.remember("I am the tape", topic="maude-identity", source="john", ts=BASE_TS)
    return t


def _section(out, header):
    lines = out.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith(header))
    body = []
    for l in lines[start + 1:]:
        if not l.startswith("  "):
            break
        body.append(l)
    return body


def test_a_big_tape_wakes_under_budget_with_the_newest_words(tmp_path):
    db = tmp_path / "t.db"
    _big_tape(db)
    out = _wake(db)
    assert len(out.encode()) <= 3000, len(out.encode())
    assert "HISROW059" in out, "the newest of his words plays"
    assert "HISROW000" not in out, "the oldest stays on the tape"


def test_the_gate_list_and_identity_always_play(tmp_path):
    db = tmp_path / "t.db"
    _big_tape(db)
    out = _wake(db, env_extra={"MAUDE_TAPE_WAKE_BUDGET": "200"})
    assert "a phrase he cut" in out, "NEVER RENDER is never cut for his words"
    assert "I am the tape" in out, "WHO I AM is never cut"


def test_his_words_are_whole_rows_never_cut(tmp_path):
    db = tmp_path / "t.db"
    t = _big_tape(db)
    stored = {r[0] for r in t._conn.execute("SELECT text FROM canon")}
    out = _wake(db)
    shown = _section(out, "HIS WORDS")
    assert shown, "some of his words play"
    for line in shown:
        text = line.strip()[2:]  # drop the bullet
        text = text.split("  [")[0]  # drop the date / unverified tags
        assert text in stored, f"a row was cut or altered: {text[:60]!r}"


def test_the_footer_counts_what_stayed_and_names_the_full_command(tmp_path):
    db = tmp_path / "t.db"
    t = _big_tape(db)
    total = t._conn.execute("SELECT COUNT(*) FROM canon WHERE superseded_by IS NULL "
                            "AND topic != 'maude-identity'").fetchone()[0]   # identity plays once, above
    out = _wake(db)
    shown = len(_section(out, "HIS WORDS"))
    assert f"{total - shown} more of his words" in out
    assert "wake --full" in out


def test_full_plays_everything(tmp_path):
    db = tmp_path / "t.db"
    _big_tape(db)
    out = _wake(db, "--full")
    for i in range(60):
        assert f"HISROW{i:03d}" in out
    assert "more of his words" not in out


def test_the_budget_is_an_env_knob(tmp_path):
    db = tmp_path / "t.db"
    _big_tape(db)
    knob = _paid(db, 1200)
    small = _wake(db, env_extra=knob)
    # the gate list and identity may run past
    assert len(small.encode()) <= int(knob["MAUDE_TAPE_WAKE_BUDGET"]) + 400
    assert len(_section(small, "HIS WORDS")) < len(_section(_wake(db, env_extra=_paid(db)),
                                                            "HIS WORDS"))


def test_a_small_tape_plays_whole_with_no_footer(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("keep it small", topic="scope", source="john", ts=BASE_TS)
    out = _wake(db)
    assert "keep it small" in out
    assert "more of his words" not in out


def test_his_seeded_words_outrank_newer_session_captures(tmp_path):
    # Live, 2026-09-25: newest-first played "2 go" and cut "ridden like a horse". His
    # deliberately seeded words (a source that is not a session capture) are the foundation;
    # session captures fill what the budget leaves.
    db = tmp_path / "t.db"
    t = Tape(db)
    # Long enough that it cannot slip into the space the session rows leave: a short seeded
    # row passed with the ranking deleted (the mutation survived until this was 300 bytes).
    t.remember("ridden like a horse " + "and the rest of it " * 15, topic="the-horse",
               source="john-2026-07-12", ts=BASE_TS)
    for i in range(80):
        t.remember(f"SESSIONROW{i:03d} " + "word " * 40, topic=f"s{i}",
                   source="session-2026-09-2x", ts=BASE_TS + 86400 + i * 60)
    out = _wake(db)
    assert "ridden like a horse" in out
    assert "SESSIONROW079" in out, "the newest capture still plays in what is left"


def test_an_identity_row_plays_once(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("I am the tape", topic="maude-identity", source="john", ts=BASE_TS)
    out = _wake(db)
    assert out.count("I am the tape") == 1


def test_the_pending_line_counts_against_the_budget(tmp_path):
    db = tmp_path / "t.db"
    t = _big_tape(db)
    for i in range(3):
        t.capture(f"pending thing {i}", topic="p", source="agent", importance=0.5)
    out = _wake(db)
    assert "awaiting your word" in out
    assert len(out.encode()) <= 3000, len(out.encode())


# ── the tape lens, 2026-09-25 ────────────────────────────────────────────

def test_an_identity_inference_keeps_its_label(tmp_path):
    # Deduping by TEXT printed identity rows as bare bullets: an inference played as if his.
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("Maude is a sword", topic="maude-identity", source="agent",
               authority="agent-inference", ts=BASE_TS)
    out = _wake(db)
    assert "◦ Maude is a sword  [agent-inference]" in out
    assert "  • Maude is a sword" not in out


def test_his_row_with_an_identity_rows_text_still_plays_as_his(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("I am the tape", topic="maude-identity", source="john", ts=BASE_TS)
    t.remember("I am the tape", topic="other", source="session-x", ts=BASE_TS + 60)
    out = _wake(db)
    assert "I am the tape" in "\n".join(_section(out, "HIS WORDS"))


def test_the_same_text_plays_once(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(4):
        t.remember("fix as you find", topic=f"d{i}", source="session-x", ts=BASE_TS + i)
    assert _wake(db).count("fix as you find") == 1


def test_never_render_is_bounded_and_says_the_gate_still_holds(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(60):
        t.reject(f"rejected phrase number {i:03d}", reason="he said never, a long reason " * 2,
                 source="john")
    out = _wake(db)
    assert len(out.encode()) <= 3000, len(out.encode())
    assert "NEVER RENDER (60):" in out
    assert "the gate still refuses every one" in out


def test_a_shorter_older_row_still_fits_after_a_long_one_is_skipped(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("SHORTOLD", topic="a", source="session-x", ts=BASE_TS)
    t.remember("LONGNEW " + "w" * 4000, topic="b", source="session-x", ts=BASE_TS + 60)
    out = _wake(db)
    assert "SHORTOLD" in out and "LONGNEW" not in out


def test_his_words_take_the_space_before_claudes_wording(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(40):
        t.remember(f"OURS{i:02d} " + "o" * 60, topic=f"o{i}", source="session-x",
                   authority="agent-inference", ts=BASE_TS + 10_000 + i)
    for i in range(40):
        t.remember(f"HIS{i:02d} " + "h" * 60, topic=f"h{i}", source="session-x", ts=BASE_TS + i)
    out = _wake(db)
    his_n, ours_n = len(_section(out, "HIS WORDS")), (
        len(_section(out, "CLAUDE'S WORDING")) if "CLAUDE'S WORDING" in out else 0)
    assert his_n > ours_n
    assert f"{40 - his_n} more of his words and {40 - ours_n} more approved lines" in out


def test_the_footer_names_the_db(tmp_path):
    db = tmp_path / "t.db"
    _big_tape(db)
    assert f"wake --full --db {db}" in _wake(db)


def test_the_footer_command_runs_from_any_directory(tmp_path):
    # The hint is typed by a person at a prompt, where nothing has set PYTHONPATH and the
    # package is never installed. Run from the canonical workspace root it printed
    # "No module named maude_tape" (John, 2026-09-29). The control: the same line without
    # its PYTHONPATH prefix must fail from there, or this proves nothing.
    db = tmp_path / "t.db"
    _big_tape(db)
    line = next(l for l in _wake(db).splitlines() if "wake --full --db" in l)
    cmd = line[line.index("PYTHONPATH="):]
    env = {"PATH": "/usr/bin:/bin"}
    ran = subprocess.run(cmd, shell=True, cwd="/", env=env, capture_output=True, text=True)
    assert ran.returncode == 0, ran.stderr
    assert "THE TAPE" in ran.stdout
    bare = cmd[cmd.index("python3"):]
    control = subprocess.run(bare, shell=True, cwd="/", env=env, capture_output=True, text=True)
    assert control.returncode != 0 and "No module named maude_tape" in control.stderr


def test_every_budget_is_met_with_everything_present(tmp_path):
    # Many short rows pack tightly, so a missing reserve (headers, footer, pending line, the
    # fixed block) shows as an overrun instead of hiding in the slack of long rows.
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(3):
        t.reject(f"never {i}", reason="no", source="john")
    t.remember("I am the tape", topic="maude-identity", source="john", ts=BASE_TS)
    for i in range(300):
        t.remember(f"h{i:03d}", topic=f"h{i}", source="session-x", ts=BASE_TS + i)
        t.remember(f"o{i:03d}", topic=f"o{i}", source="session-x",
                   authority="agent-inference", ts=BASE_TS + i)
    for i in range(3):
        t.capture(f"pending {i}", topic="p", source="agent", importance=0.5)
    for b in (1200, 2000, 3000):
        out = _wake(db, env_extra={"MAUDE_TAPE_WAKE_BUDGET": str(b)})
        assert len(out.encode()) <= b, (b, len(out.encode()))
        # And it is used: the slack is at most one row that would not fit whole (~60 bytes).
        assert len(out.encode()) >= b - 70, (b, len(out.encode()))


def test_seeded_words_leave_room_for_the_newest(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(20):
        t.remember(f"SEED{i:02d} " + "s" * 200, topic=f"s{i}", source="john-seed",
                   ts=BASE_TS + i)
    # Long enough not to slip into the slack the seeded rows leave (a short one passed with
    # the cap deleted, lens round 2).
    t.remember("NEWEST session word " + "n" * 200, topic="n", source="session-x",
               ts=BASE_TS + 999_999)
    assert "NEWEST session word" in _wake(db)


# ── the tape lens, round 2 ───────────────────────────────────────────────

def test_his_seeded_words_come_before_claudes_wording_even_past_the_cap(tmp_path):
    # The 2/3 cap held six of his seeded rows while nine of Claude's lines played.
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(10):
        t.remember(f"SEED{i:02d} " + "s" * 200, topic=f"s{i}", source="john-seed",
                   ts=BASE_TS + i)
    for i in range(30):
        t.remember(f"OURS{i:02d} " + "o" * 60, topic=f"o{i}", source="session-x",
                   authority="agent-inference", ts=BASE_TS + 1000 + i)
    # All ten play in this room; without the third seeded pass, six do.
    out = _wake(db, env_extra=_paid(db))
    assert all(f"SEED{i:02d}" in out for i in range(10)), "every seeded row that fits plays"
    assert "0 more of his words" in out or "more of his words" not in out


def test_a_superseded_row_never_plays(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("OLDRULING stay", topic="r", source="john", ts=BASE_TS)
    t.remember("NEWRULING go", topic="r2", source="john", ts=BASE_TS + 1)
    t._conn.execute("UPDATE canon SET superseded_by = (SELECT id FROM canon WHERE text = "
                    "'NEWRULING go') WHERE text = 'OLDRULING stay'")
    t._conn.commit()
    out = _wake(db)
    assert "NEWRULING go" in out and "OLDRULING" not in out


def test_his_row_and_a_same_text_inference_both_play_in_their_own_sections(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("ship it", topic="a", source="john", ts=BASE_TS)
    t.remember("ship it", topic="b", source="agent", authority="agent-inference",
               ts=BASE_TS + 60)
    out = _wake(db)
    assert "ship it" in "\n".join(_section(out, "HIS WORDS"))
    assert "◦ ship it  [agent-inference]" in out


def test_the_newest_copy_plays_across_tiers(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("ride it", topic="a", source="john-seed", ts=BASE_TS)
    t.remember("ride it", topic="b", source="session-x", ts=BASE_TS + 86400 * 30)
    out = _wake(db)
    assert out.count("ride it") == 1
    assert "2026-08-11" in out, "the newer copy's date"


def test_an_overrun_of_the_fixed_block_is_said(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(10):
        t.remember(f"IDENT{i} " + "i" * 390, topic="maude-identity", source="john",
                   ts=BASE_TS + i)
    out = _wake(db)
    assert "over the 3000-byte wake budget" in out


def test_one_huge_rejection_is_counted_not_forced_in(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.reject("x" * 5000, reason="huge", source="john")
    out = _wake(db)
    assert len(out.encode()) <= 3000
    assert "1 more; the gate still refuses every one" in out


# ── the tape lens, round 3 ───────────────────────────────────────────────

def test_an_overrun_by_the_footer_is_said_too(tmp_path):
    # A fixed block just under budget plus the footer overran in silence.
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("IDENT " + "i" * 280, topic="maude-identity", source="john", ts=BASE_TS)
    for i in range(5):
        t.remember(f"row {i} " + "r" * 40, topic=f"r{i}", source="session-x", ts=BASE_TS + i)
    for b in range(300, 2001, 37):
        out = _wake(db, env_extra={"MAUDE_TAPE_WAKE_BUDGET": str(b)})
        assert len(out.encode()) <= b or "over the" in out, (b, len(out.encode()))


def test_a_text_seeded_on_purpose_ranks_seeded_though_its_newest_copy_is_a_capture(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("the horse", topic="h", source="john-seed", ts=BASE_TS)
    t.remember("the horse", topic="h2", source="session-x", ts=BASE_TS + 500)
    t.remember("NEWER capture", topic="n", source="session-x", ts=BASE_TS + 900)
    rows = _section(_wake(db), "HIS WORDS")
    assert "the horse" in rows[0] and "NEWER capture" in rows[1]


def test_a_held_seeded_row_prints_with_the_seeded_block_not_after_the_session_rows(tmp_path):
    # Pass 3 gives room back to a held seeded row; it must print in rank order.
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(8):
        t.remember(f"SEED{i} " + "s" * 300, topic=f"s{i}", source="john-seed", ts=BASE_TS + i)
    t.remember("SESSIONROW " + "x" * 50, topic="n", source="session-x", ts=BASE_TS + 999)
    rows = _section(_wake(db), "HIS WORDS")
    seeds = [i for i, r in enumerate(rows) if "SEED" in r]
    sess = [i for i, r in enumerate(rows) if "SESSIONROW" in r]
    assert seeds and sess and max(seeds) < min(sess), rows


# ── the tape lens, round 4 (2026-09-28) ──────────────────────────────────

def _bytes_said(out):
    import re
    m = re.search(r"this wake is (\d+) bytes, over the (\d+)-byte wake budget", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


def test_the_overrun_line_fires_exactly_when_the_wake_without_it_is_over(tmp_path):
    # It reserved the widest footer, which does not print when nothing is held, and left
    # out its own bytes: a 2,903-byte wake said it was over 3,000 (the note made it 3,024).
    # Swept across the window so no db path length can hide it.
    import re
    for n in range(2500, 3100, 20):
        db = tmp_path / f"t{n}.db"
        Tape(db).remember("I" * n, topic="maude-identity", source="john", ts=BASE_TS)
        out = _wake(db)
        without = re.sub(r"\n  \(this wake is \d+ bytes, over the \d+-byte wake budget[^)]*\)", "", out)
        over = len(without.encode()) > 3000
        assert ("over the 3000-byte wake budget" in out) == over, (n, len(out.encode()), len(without.encode()))


def test_the_overrun_line_states_the_true_size_of_the_wake(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(10):
        t.remember(f"IDENT{i} " + "i" * 390, topic="maude-identity", source="john",
                   ts=BASE_TS + i)
    out = _wake(db)
    said = _bytes_said(out)
    assert said is not None, out[-400:]
    assert said == (len(out.encode()), 3000)


def test_identical_identity_rows_play_once(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    for i in range(3):
        t.remember("I am Maude, Claude's partner-plugin.", topic="maude-identity",
                   source="john", ts=BASE_TS + i)
    out = _wake(db)
    assert out.count("I am Maude, Claude's partner-plugin.") == 1


# ── the tape lens, round 5: identity dedup keys on (text, authority), newest wins ──

def test_his_verbatim_identity_line_survives_an_earlier_inference_of_the_same_text(tmp_path):
    # Keyed on text alone and keeping the oldest, the dedup dropped his later verbatim
    # ratification and printed the line as Claude's inference.
    for order in ("inference_first", "his_first"):
        db = tmp_path / f"{order}.db"
        t = Tape(db)
        rows = [("agent", "agent-inference"), ("john", "user-verbatim")]
        if order == "his_first":
            rows.reverse()
        for i, (src, auth) in enumerate(rows):
            t.remember("Maude is Claude's partner-plugin.", topic="maude-identity", source=src,
                       authority=auth, ts=BASE_TS + i * 1000)
        out = _wake(db)
        ident = out.split("WHO I AM:")[1]
        assert "  • Maude is Claude's partner-plugin." in ident, (order, ident)
        assert "  ◦ Maude is Claude's partner-plugin.  [agent-inference]" in ident, (order, ident)


def test_the_newest_copy_of_one_identity_ruling_is_the_one_that_plays(tmp_path):
    db = tmp_path / "t.db"
    t = Tape(db)
    t.remember("I keep the house.", topic="maude-identity", source="john", ts=BASE_TS)
    t.remember("I keep the house.", topic="maude-identity", source="john", ts=BASE_TS + 86400 * 30)
    out = _wake(db).split("WHO I AM:")[1]
    assert out.count("I keep the house.") == 1
    assert "[2026-08-11]" in out
