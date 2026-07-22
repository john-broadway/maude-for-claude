"""The cadence rubric — the generic robotic-AI cadence tells the voice judge pattern-matches
against. It ships GENERIC (world-clean); a user's private voice-specific tells never live here.
The judge prompt must carry BOTH the rubric and the draft — a prompt that drops the draft
judges nothing, and a rubric that lost its tells judges by vibe (the failure this is built to
avoid). Proven 2026-07-18: a Haiku judge, given this rubric, caught a 4x 'not X — it's Y'
symmetry tic in a Claude draft the drafter could not see.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.cadence import CADENCE_RUBRIC, judge_prompt


def test_the_rubric_names_the_core_ai_tells():
    low = CADENCE_RUBRIC.lower()
    for tell in ("concede", "three", "symmetry", "metaphor"):
        assert tell in low  # a rubric that lost its tells would judge by vibe, not pattern


def test_judge_prompt_carries_both_the_rubric_and_the_draft():
    draft = "the tank is not low — the move needs your call."
    prompt = judge_prompt(draft)

    assert draft in prompt              # a prompt that drops the draft judges nothing
    assert "concede" in prompt.lower()  # the rubric rode along
    assert "json" in prompt.lower()     # a structured verdict is asked for, not prose
