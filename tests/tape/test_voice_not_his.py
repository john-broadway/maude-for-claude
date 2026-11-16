"""Only the user's typed words are his voice (seeing-gap design, A5).

On 2026-10-25 the tape's `voice` table held 6,170 rows; 571 opened with `<agent-message`,
76 with `<cross-session-message`: other sessions and agents, captured as if he typed
them. Capture and harvest drop them now, and every reader of the table skips the ones
already stored, so nothing in the durable store has to be rewritten.
"""
from __future__ import annotations

import io
import pathlib
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import voice
from maude_tape.tape import Tape

NOT_HIS = [
    '<agent-message from="proximo">done, 0.47.0 is out</agent-message>',
    '<cross-session-message from="b00c2b8d">lens is back</cross-session-message>',
    "[SYSTEM NOTIFICATION - NOT USER INPUT] a background task finished",
    '<teammate-message from="w1">step 2 green</teammate-message>',
]


def _capture(monkeypatch, tape, text):
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))
    return voice.cmd_capture(SimpleNamespace(source="hook", register="chat", session=None), tape)


@pytest.mark.parametrize("text", NOT_HIS)
def test_capture_drops_a_message_that_is_not_the_user(tmp_path, monkeypatch, text):
    tape = Tape(tmp_path / "tape.db")
    assert _capture(monkeypatch, tape, text) == 0
    assert tape._conn.execute("SELECT COUNT(*) FROM voice").fetchone()[0] == 0


@pytest.mark.parametrize("text", NOT_HIS)
def test_is_machine_turn_names_it(text):
    assert voice.is_machine_turn(text)
    assert voice.is_machine_turn("  " + text)


@pytest.mark.parametrize("text", ["fold it, merge when the lens is clean", "agreed go",
                                  "what is <agent-message> in the hook?"])
def test_his_own_words_are_his(text):
    assert not voice.is_machine_turn(text)


def _plant(tape, text, ts=1.0, sha=None):
    voice._insert_voice_row(tape, ts=ts, text=text, source="hook", register="chat",
                            session=None, sha=sha or text)
    tape._conn.commit()


def test_a_stored_agent_row_is_not_read_as_his_voice_by_the_profile(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    for i in range(5):
        _plant(tape, f"keep going {i}", ts=float(i + 1))
    _plant(tape, NOT_HIS[0], ts=9.0)
    profile = voice.compute_profile(tape)
    assert profile["n_lines"] == 5
    assert profile["honesty"]["lines_excluded_not_his"] == 1


def test_a_stored_agent_row_is_never_the_row_that_heard_a_line(tmp_path):
    tape = Tape(tmp_path / "tape.db")
    line = "the lens is back and it is clean, merge it"  # >= 24 chars: substring match applies
    _plant(tape, f'<cross-session-message from="b00c2b8d">{line}</cross-session-message>',
           ts=5.0, sha="agent")
    assert tape._find_voice_sha(line) is None
    _plant(tape, line, ts=6.0, sha="his")
    assert tape._find_voice_sha(line) == "his"
