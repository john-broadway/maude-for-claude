"""The whole system as a loop: WAKE plays the tape -> WORK captures -> REST consolidates+forgets
-> WAKE plays the now-complete tape. Plus the self-* properties: autonomous (rest runs the cycle),
autolearning (rest promotes signal to canon), autohealing (audit catches a rejected phrasing loose
on a real surface). Generic example data — no personal words in the public plugin.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.tape import Tape


def _seed(t):
    t.remember("we heroically slashed scope against all odds", topic="scope",
               source="agent", authority="agent-inference")
    t.consolidate_correction(rejected="heroically slashed scope", reason="dramatization",
                             corrected_to="keep it small", topic="scope", source="user")
    t.remember("the tape brings the amnesiac back, nothing cut",
               topic="maude-identity", source="design")


def test_rest_consolidates_signal_and_forgets_noise(tmp_path):
    t = Tape(tmp_path / "t.db")
    sig = t.capture("I own what I build", topic="own", source="user", importance=0.8)
    noise = t.capture("ok next", topic="misc", source="s", importance=0.1)

    report = t.rest()

    assert sig in report.consolidated      # autolearning: signal became canon
    assert noise in report.forgotten       # forget: noise archived
    assert any("own what I build" in e.text for e in t.recall("own"))
    assert t.buffered() == []              # the buffer is drained


def test_wake_plays_current_truth_not_the_cut_scene(tmp_path):
    t = Tape(tmp_path / "t.db")
    _seed(t)

    b = t.wake()

    assert any("keep it small" in x for x in b.canon_texts)
    assert all("heroically slashed scope" not in x for x in b.canon_texts)
    assert b.rejection_count >= 1
    assert any("nothing cut" in x for x in b.identity)


def test_audit_catches_a_rejected_phrasing_live_on_a_surface(tmp_path):
    t = Tape(tmp_path / "t.db")
    _seed(t)

    surfaces = {
        "page.html": "intro ... we heroically slashed scope ... outro",
        "clean.md": "nothing here",
    }
    breaches = t.audit(surfaces)

    hit_surfaces = {b.surface for b in breaches}
    assert "page.html" in hit_surfaces
    assert "clean.md" not in hit_surfaces
    assert any(b.phrase == "heroically slashed scope" for b in breaches)
