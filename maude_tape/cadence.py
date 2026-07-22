"""The cadence rubric — the generic robotic-AI cadence tells a voice judge pattern-matches.

The deterministic gate (tape.check_draft) catches KNOWN rejected phrasings; it cannot see
robotic *cadence*, because cadence is not a phrase. A model judge reads for it — but a judge
of the same family as the drafter is deaf to its own accent unless it is pattern-matching
EXPLICIT tells rather than judging vibe. That is what this rubric is for: it converts "does
this sound like AI?" (which a same-family judge can't hear) into "does this contain pattern X?"
(which it can). Proven 2026-07-18 — a Haiku judge given this rubric caught a 4x 'not X — it's Y'
symmetry tic in a Claude draft the drafter could not see.

Ships GENERIC (world-clean). A user's private, voice-specific tells — what makes a line sound
like *them* vs. clean-AI — live in their own seed, never in this shipped file.
"""
from __future__ import annotations

# The seven tells. Kept concrete and pattern-matchable on purpose — see module docstring.
CADENCE_RUBRIC = """\
1. CONCEDE->PIVOT->REFRAME: concedes a point, pivots on "but/however/that said/still", then
   reframes to a tidy conclusion — the hedged three-beat rhythm.
2. RULE-OF-THREE / TRIADS: three parallel items or clauses for rhythm ("X, Y, and Z"; three
   parallel sentences), ESPECIALLY when the pattern repeats across the draft.
3. SYMMETRY TICS: "not just X, but Y" / "it's not about X, it's about Y" / "X isn't the thing - Y is."
4. STACKED METAPHORS: two or more distinct metaphors piled into one passage.
5. SUMMARY-RESTATEMENT: a closing clause that restates the sentence before it in tidier words.
6. BLAND CONNECTIVES / HEDGES: "moreover", "furthermore", "it's worth noting", "at the end of
   the day", "that said".
7. OVER-BALANCED CLAUSES: em-dash-balanced or tricolon-crescendo constructions that resolve
   too neatly."""


def judge_prompt(draft: str) -> str:
    """Wrap a draft in the rubric to make the prompt a model-judge applies. Same shape whether
    the judge is a Haiku subagent (my loop) or a BYO endpoint (the shipped plugin) — one source
    of truth for the criteria. Skeptic-framed and counting-aware: a tell that repeats is itself
    the finding. Returns strict-JSON-only instructions so the caller parses, never prose-scrapes."""
    return (
        "You are a CADENCE JUDGE — a second lens on a draft. Your one job: catch the robotic-AI\n"
        "cadence tells that make text read like clean AI instead of plain human speech. You are\n"
        "PATTERN-MATCHING an explicit rubric, not judging vibe — flag concrete instances only, and\n"
        "quote them verbatim. Be a skeptic; do not invent tells to seem thorough. If a tell repeats,\n"
        "the repetition is itself the strongest finding.\n\n"
        "THE RUBRIC — flag every real instance:\n"
        f"{CADENCE_RUBRIC}\n\n"
        "Return STRICT JSON only:\n"
        '{"flags": [{"tell": "<rubric name>", "quote": "<verbatim span>", "why": "<one line>"}],\n'
        ' "worst_tell": "<the most pervasive tell, or \'none\'>",\n'
        ' "overall": "<one sentence: clean-AI or plain-human, and why>"}\n\n'
        "=== THE DRAFT TO JUDGE (verbatim) ===\n"
        f"{draft}"
    )
