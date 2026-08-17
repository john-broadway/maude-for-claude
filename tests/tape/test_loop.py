"""The whole system as a loop: WAKE plays the tape -> WORK captures -> REST consolidates+forgets
-> WAKE plays the now-complete tape. Plus the self-* properties: autonomous (rest runs the cycle),
autolearning (rest promotes the USER's words to canon; what the agent merely inferred waits for
his word — see test_promotion_is_his.py), autohealing (audit catches a rejected phrasing loose
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


def test_rest_consolidates_his_words_forgets_noise_and_holds_my_inference(tmp_path):
    """Note `authority`, not `source`. Source is where a line came from; authority is whose
    words they are. Only the second one may open the door to canon by itself."""
    t = Tape(tmp_path / "t.db")
    his = t.capture("I own what I build", topic="own", source="user",
                    importance=0.8, authority="user-verbatim")
    mine = t.capture("so he probably wants the same for the next one", topic="own",
                     source="agent", importance=0.8)
    noise = t.capture("ok next", topic="misc", source="s", importance=0.1)

    report = t.rest()

    assert his in report.consolidated              # his words became canon
    assert noise in report.forgotten               # forget: noise archived
    assert any("own what I build" in e.text for e in t.recall("own"))
    assert [e.id for e in t.pending()] == [mine]   # my read of him waits for his word
    assert mine not in report.consolidated         # equal importance, different authority


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
