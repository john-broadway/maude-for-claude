"""The short-term buffer + the forget loop. Raw work lands in the buffer with an importance
tag; rest either consolidates the salient or forgets the noise. Forgetting ARCHIVES (status
change) — it never deletes, because a memory that deletes can't prove what it dropped.
Generic example data.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def test_capture_lands_in_the_buffer(tmp_path):
    tape = Tape(tmp_path / "t.db")
    eid = tape.capture("keep it small", topic="scope", source="user-2026", importance=0.9)
    buffered = tape.buffered()
    assert [e.id for e in buffered] == [eid]
    assert buffered[0].status == "buffered"


def test_forget_archives_low_value_but_deletes_nothing(tmp_path):
    tape = Tape(tmp_path / "t.db")
    keep = tape.capture("keep it small", topic="scope", source="user", importance=0.9)
    drop = tape.capture("ok next", topic="misc", source="session", importance=0.1)

    forgotten = tape.forget(min_importance=0.3)

    assert drop in forgotten and keep not in forgotten          # noise goes, signal stays
    assert [e.id for e in tape.buffered()] == [keep]            # buffer holds only the survivor
    assert tape.event(drop).status == "forgotten"              # archived, not gone
    assert tape.event(drop).text == "ok next"                  # still fully retrievable
