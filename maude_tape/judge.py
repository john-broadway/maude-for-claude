"""Optional BYO cadence judge — an OpenAI-style /v1/chat/completions client for the voice gate's
model tier (the sibling of embedder.py, same shape).

The plugin ships NO judge service and NO default endpoint. A home that already runs a model points
`MAUDE_TAPE_JUDGE_URL` at it (or passes url=); without it, the judge tier stays off and the
deterministic check_draft is the floor. The judge applies the shipped generic cadence rubric
(cadence.judge_prompt) and returns the (tell, why) pairs Tape.judge_draft wraps into CadenceFlags.
Uses stdlib urllib — brings nothing of its own. Errors propagate (fail loud): a gate that can't
reach its judge must never look like a clean pass.
"""
from __future__ import annotations

import json
import os
import urllib.request
from typing import Callable

from .cadence import judge_prompt

ENV_URL = "MAUDE_TAPE_JUDGE_URL"


def http_judge(
    url: str | None = None, model: str = "local", timeout: float = 30.0
) -> Callable[[str], list[tuple[str, str]]]:
    """Return a judge(draft)->[(tell, why), ...] bound to an OpenAI-compatible chat endpoint.

    url resolves from the argument, else $MAUDE_TAPE_JUDGE_URL. No default — the installer supplies
    their own model, or the judge tier simply isn't wired. The draft is wrapped in the shipped
    rubric before sending, and the model's strict-JSON verdict is parsed into (tell, why) pairs.
    """
    url = url or os.environ.get(ENV_URL)
    if not url:
        raise ValueError(
            f"no judge endpoint: set {ENV_URL} or pass url= (the plugin ships none by design)"
        )

    def judge(draft: str) -> list[tuple[str, str]]:
        body = json.dumps(
            {
                "model": model,
                "messages": [{"role": "user", "content": judge_prompt(draft)}],
                "temperature": 0,
            }
        ).encode()
        req = urllib.request.Request(
            url, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = json.load(resp)["choices"][0]["message"]["content"]
        verdict = json.loads(content)  # strict JSON per the rubric; a bad response fails loud
        return [(f.get("tell", ""), f.get("why", "")) for f in verdict.get("flags", [])]

    return judge
