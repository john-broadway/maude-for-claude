"""A suggested prompt he accepted is flagged on the tape, never deleted (John, 2026-10-30).

The harness can offer a next prompt that he accepts with a key; the transcript records it as
promptSource "suggestion_accepted". Harvest no longer takes such a record. The flag pass
marks the voice rows already on the tape that came from one: a harvested row by its exact
sha, a captured row by the same text within FLAG_WINDOW seconds. Every reader of his words
skips a flagged row; wake labels a canon line whose voice row is flagged; no voice row is
ever removed or changed.
"""
import json
import re
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from maude_tape import voice
from maude_tape.tape import Tape

TS = "2026-10-25T05:00:00.000Z"
EPOCH = 1792904400.0


def rec(text, source, ts=TS, uuid="u", session="s"):
    return {"type": "user", "userType": "external", "uuid": uuid, "timestamp": ts,
            "origin": {"kind": "human"}, "promptSource": source, "sessionId": session,
            "message": {"role": "user", "content": text}}


def transcripts(tmp_path, records, name="s"):
    d = tmp_path / "t"
    d.mkdir(exist_ok=True)
    (d / f"{name}.jsonl").write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
    return d


def run(*args):
    return subprocess.run([sys.executable, "-m", "maude_tape", *map(str, args)],
                          cwd=ROOT, capture_output=True, text=True)


def counts(out):
    """The pass's tallies, by name: a substring test reads "unflagged=0" as "flagged=0"."""
    out = getattr(out, "stdout", out)
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", out)}


def voice_rows(db):
    t = Tape(db)
    try:
        return t._conn.execute("SELECT sha, text, source FROM voice ORDER BY id").fetchall()
    finally:
        t._conn.close()


def test_harvest_no_longer_takes_a_suggestion(tmp_path):
    d = transcripts(tmp_path, [rec("i typed this one myself", "typed", uuid="a"),
                               rec("sounds good ship it", "suggestion_accepted", uuid="b")])
    db = tmp_path / "tape.db"
    assert run("harvest", "--db", db, "--transcripts", d).returncode == 0
    assert [r[1] for r in voice_rows(db)] == ["i typed this one myself"]


def _seed(db, rows):
    t = Tape(db)
    for text, source, ts, sha, *session in rows:
        # a captured row names its session; a harvested one is known by its file's stem
        sess = session[0] if session else ("s" if source == "hook" else None)
        voice._insert_voice_row(t, ts=ts, text=text, source=source, register="chat", session=sess, sha=sha)
    t._conn.commit()
    t._conn.close()


def test_the_pass_flags_and_never_deletes(tmp_path):
    d = transcripts(tmp_path, [rec("sounds good ship it", "suggestion_accepted", uuid="b"),
                               rec("i typed this one myself", "typed", ts="2026-10-25T05:01:00.000Z", uuid="a"),
                               rec("both ways line", "typed", ts="2026-10-25T05:02:00.000Z", uuid="c"),
                               rec("both ways line", "suggestion_accepted", ts="2026-10-25T05:02:30.000Z", uuid="d")])
    db = tmp_path / "tape.db"
    harvested = voice._compute_sha("sounds good ship it", TS)
    _seed(db, [("sounds good ship it", "s", EPOCH, harvested),                 # exact sha
               ("sounds good ship it", "hook", EPOCH + 3, "hook-near"),        # captured, 3 s later
               ("sounds good ship it", "hook", EPOCH + 900, "hook-far"),       # 15 min later: no record
               ("i typed this one myself", "hook", EPOCH + 61, "hook-typed"),
               ("both ways line", "hook", EPOCH + 130, "hook-both"),           # typed AND suggested near
               ("never in a transcript", "hook", EPOCH, "hook-none")])
    before = voice_rows(db)
    res = run("voice-flag", "--db", db, "--transcripts", d)
    assert res.returncode == 0, res.stderr
    assert counts(res.stdout).items() >= {"flagged": 2, "typed": 2}.items()
    t = Tape(db)
    try:
        assert voice.flagged_shas(t._conn) == {harvested, "hook-near"}
    finally:
        t._conn.close()
    assert voice_rows(db) == before  # not one voice row removed or changed
    again = run("voice-flag", "--db", db, "--transcripts", d)
    assert counts(again.stdout).items() >= {"files": 0}.items()  # read whole and unchanged: not read again
    (d / "s.jsonl").write_text((d / "s.jsonl").read_text() + "\n", encoding="utf-8")
    third = run("voice-flag", "--db", db, "--transcripts", d)
    assert counts(third.stdout).items() >= {"files": 1, "flagged": 0, "already": 2}.items()


def test_readers_skip_a_flagged_row(tmp_path):
    from maude_recall import sources
    db = tmp_path / "tape.db"
    _seed(db, [("my own words here today", "hook", EPOCH, "mine"),
               ("sounds good ship it", "hook", EPOCH, "suggested")])
    t = Tape(db)
    t._conn.execute("INSERT INTO voice_flags (sha, flag) VALUES ('suggested', 'suggestion_accepted')")
    t._conn.commit()
    try:
        assert [s for s, _ in t._heard()] == ["mine"]
        prof = voice.compute_profile(t)
        assert prof["n_lines"] == 1 and "ship" not in prof["lexicon"]  # the suggestion is not his voice
    finally:
        t._conn.close()
    assert [k for k, _, _ in sources.tape_items(db)] == ["voice:mine"]


def test_wake_labels_a_canon_line_whose_voice_row_is_flagged(tmp_path):
    db = tmp_path / "tape.db"
    _seed(db, [("strip it and ship it now", "hook", EPOCH, "suggested")])
    t = Tape(db)
    t._conn.execute("INSERT INTO canon (text, authority, source, voice_sha) "
                    "VALUES ('strip it and ship it now', 'user-verbatim', 'hook', 'suggested')")
    t._conn.execute("INSERT INTO voice_flags (sha, flag) VALUES ('suggested', 'suggestion_accepted')")
    t._conn.commit()
    t._conn.close()
    out = run("wake", "--full", "--db", db).stdout
    assert "strip it and ship it now" in out and "[flagged: a suggested prompt he accepted]" in out


def test_since_reads_only_newer_transcripts(tmp_path):
    import os
    d = transcripts(tmp_path, [rec("sounds good ship it", "suggestion_accepted")])
    os.utime(d / "s.jsonl", (100, 100))
    db = tmp_path / "tape.db"
    _seed(db, [("sounds good ship it", "s", EPOCH, voice._compute_sha("sounds good ship it", TS))])
    assert counts(run("voice-flag", "--db", db, "--transcripts", d, "--since", 200)).items() >= {"files": 0}.items()
    assert counts(run("voice-flag", "--db", db, "--transcripts", d, "--since", 50)).items() >= {"flagged": 1}.items()


def test_wake_does_not_label_words_he_also_typed(tmp_path):
    db = tmp_path / "tape.db"
    _seed(db, [("fix as you find own as you go", "hook", EPOCH, "suggested"),
               ("fix as you find own as you go", "hook", EPOCH + 9999, "typed-too")])
    t = Tape(db)
    t._conn.execute("INSERT INTO canon (text, authority, source, voice_sha) "
                    "VALUES ('fix as you find own as you go', 'user-verbatim', 'hook', 'suggested')")
    t._conn.execute("INSERT INTO voice_flags (sha, flag) VALUES ('suggested', 'suggestion_accepted')")
    t._conn.commit()
    t._conn.close()
    out = run("wake", "--full", "--db", db).stdout
    assert "fix as you find own as you go" in out and "[flagged" not in out


def test_another_sessions_suggestion_never_flags_his_line(tmp_path):
    """Lens 4's repro: he typed it in session A; session B accepted the same words 30 s later.
    Even when only B's transcript is read (--since past A's), A's row stays unflagged."""
    import os
    d = transcripts(tmp_path, [rec("keep going", "typed", ts="2026-10-25T05:00:00.400Z", session="A")], name="A")
    transcripts(tmp_path, [rec("keep going", "suggestion_accepted", ts="2026-10-25T05:00:30.000Z", session="B")],
                name="B")
    os.utime(d / "A.jsonl", (100, 100))
    db = tmp_path / "tape.db"
    _seed(db, [("keep going", "hook", EPOCH, "his", "A")])
    out = run("voice-flag", "--db", db, "--transcripts", d, "--since", 2000).stdout
    assert counts(out).items() >= {"files": 1, "flagged": 0}.items()
    assert counts(run("voice-flag", "--db", db, "--transcripts", d)).items() >= {"flagged": 0}.items()
    t = Tape(db)
    try:
        assert voice.flagged_shas(t._conn) == set()
    finally:
        t._conn.close()


def test_a_flag_his_own_session_contradicts_is_lifted(tmp_path):
    d = transcripts(tmp_path, [rec("keep going", "typed", session="s")])
    db = tmp_path / "tape.db"
    _seed(db, [("keep going", "hook", EPOCH, "row")])
    t = Tape(db)
    t._conn.execute("INSERT INTO voice_flags (sha, flag) VALUES ('row', 'suggestion_accepted')")
    t._conn.commit()
    t._conn.close()
    assert counts(run("voice-flag", "--db", db, "--transcripts", d)).items() >= {"unflagged": 1}.items()
    t = Tape(db)
    try:
        assert voice.flagged_shas(t._conn) == set()
        assert [r[0] for r in t._conn.execute("SELECT sha FROM voice")] == ["row"]
    finally:
        t._conn.close()


def test_a_spent_budget_starts_no_file_and_the_next_pass_goes_on(tmp_path):
    d = transcripts(tmp_path, [rec("sounds good ship it", "suggestion_accepted")])
    db = tmp_path / "tape.db"
    _seed(db, [("sounds good ship it", "hook", EPOCH, "row")])
    out = run("voice-flag", "--db", db, "--transcripts", d, "--budget", 0).stdout
    assert counts(out).items() >= {"files": 0, "left": 1}.items()
    assert counts(run("voice-flag", "--db", db, "--transcripts", d, "--budget", 60)).items() >= {"files": 1}.items()
