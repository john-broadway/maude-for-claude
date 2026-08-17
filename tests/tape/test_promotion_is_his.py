"""Promotion belongs to the user, not the agent.

The buffer takes anything. Canon does not. What the user actually said consolidates on its
own, because recording his words is not a judgement call. What the AGENT merely inferred
waits in the buffer until he says so, however sure the agent was — an importance score is
the agent's opinion of itself, and an opinion is not a mandate.

So: rest() drains the buffer of the user's own words and of noise, and leaves agent
inference PENDING. promote() is the buffer's only door into canon, and it is his hand on
it — remember() and seed write to canon directly and are not part of this flow. Generic
example data.
"""
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def test_rest_never_promotes_an_agent_inference_however_certain(tmp_path):
    t = Tape(tmp_path / "t.db")
    mine = t.capture("this is definitely the root cause", topic="diag", source="agent",
                     importance=0.99, authority="agent-inference")

    report = t.rest()

    assert mine not in report.consolidated       # certainty is not consent
    assert mine not in report.forgotten          # nor is it thrown away
    assert t.event(mine).status == "buffered"    # it waits
    assert t.recall("diag") == []                # nothing of mine reached canon


def test_rest_still_consolidates_the_users_own_words(tmp_path):
    t = Tape(tmp_path / "t.db")
    his = t.capture("keep it small", topic="scope", source="user-2026",
                    importance=0.8, authority="user-verbatim")

    report = t.rest()

    assert his in report.consolidated
    assert any("keep it small" in e.text for e in t.recall("scope"))


def test_pending_is_exactly_what_awaits_his_word(tmp_path):
    t = Tape(tmp_path / "t.db")
    mine = t.capture("a maxim I think I spotted", topic="maxims", source="agent",
                     importance=0.7)
    t.capture("keep it small", topic="scope", source="user", importance=0.8,
              authority="user-verbatim")
    t.capture("ok next", topic="misc", source="s", importance=0.1)

    t.rest()

    assert [e.id for e in t.pending()] == [mine]  # his consolidated, noise archived


def test_pending_also_holds_his_words_that_fell_below_the_bar(tmp_path):
    """Nothing may sit in the tape unseen. A line captured as HIS but scored under the
    consolidate bar is one rest() will not promote and forget() will not archive — without
    this it is invisible: not canon, not pending, not gone. Pending means everything the
    buffer is holding that rest cannot resolve on its own."""
    t = Tape(tmp_path / "t.db")
    quiet = t.capture("maybe worth keeping", topic="scope", source="user",
                      importance=0.4, authority="user-verbatim")

    t.rest()

    assert [e.id for e in t.pending()] == [quiet]
    t.promote(quiet)
    assert any("maybe worth keeping" in e.text for e in t.recall("scope"))


def test_promote_is_the_only_door_from_inference_to_canon(tmp_path):
    t = Tape(tmp_path / "t.db")
    mine = t.capture("a guard that answers the easy question is worse than none",
                     topic="maxims", source="session", importance=0.7)
    t.rest()
    assert t.recall("maxims") == []              # not canon on my say-so

    t.promote(mine)

    assert any("easy question" in e.text for e in t.recall("maxims"))
    assert t.event(mine).status == "consolidated"
    assert t.pending() == []


def test_promote_keeps_the_authority_it_was_captured_with(tmp_path):
    """He approved MY wording; that does not make it his. Recall must still rank his
    verbatim above an inference he merely let through."""
    t = Tape(tmp_path / "t.db")
    mine = t.capture("the door admits, it never decides", topic="doors", source="agent",
                     importance=0.7)
    t.rest()
    t.promote(mine)
    t.remember("a door admits", topic="doors", source="user", authority="user-verbatim")

    assert [e.authority for e in t.recall("doors")][0] == "user-verbatim"


def test_capture_refuses_a_credential_shape(tmp_path):
    """The voice path has refused credential shapes at ingest since v0.28.0. Events are the
    SAME database and more dangerous: canon plays at every wake and `pending` prints the text
    back, so a captured error message carrying a token would replay it into context forever.
    One guard, both doors."""
    t = Tape(tmp_path / "t.db")

    with pytest.raises(ValueError):
        t.capture("deploy failed: pypi-" + "A" * 44, topic="ops", source="session",
                  importance=0.7)

    assert t.buffered() == []          # refused at ingest, not quarantined afterwards


def test_capture_allows_prose_that_merely_mentions_a_token(tmp_path):
    """Shapes, not words. A guard that fires on the word 'token' would train everyone to
    route around it, which is worse than not having it."""
    t = Tape(tmp_path / "t.db")
    eid = t.capture("rotate the pypi token before the release", topic="ops",
                    source="session", importance=0.7)
    assert [e.id for e in t.buffered()] == [eid]


def test_promote_refuses_anything_not_currently_pending(tmp_path):
    """The only promotable thing is one he was actually shown. Guards against promoting
    twice, and against reaching past the list into archived noise."""
    t = Tape(tmp_path / "t.db")
    noise = t.capture("ok next", topic="misc", source="s", importance=0.1)
    mine = t.capture("worth keeping", topic="maxims", source="agent", importance=0.7)
    t.rest()
    t.promote(mine)

    with pytest.raises(ValueError):
        t.promote(noise)          # archived, never on the list
    with pytest.raises(ValueError):
        t.promote(mine)           # already through the door
    with pytest.raises(ValueError):
        t.promote(999999)         # never existed
