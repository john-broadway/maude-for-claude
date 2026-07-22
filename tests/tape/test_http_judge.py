"""The BYO cadence-judge client — the voice gate's model tier for an installed plugin. Ships NO
default endpoint (like the embedder): a home points MAUDE_TAPE_JUDGE_URL at its own model, or the
judge tier stays off and the deterministic check_draft is the floor. The contract that matters:
with no endpoint it must fail LOUD at build time — a gate that can't reach its judge but reports
'clean' is worse than no gate. No network is touched until the judge is actually called.
"""
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape.judge import ENV_URL, http_judge


def test_http_judge_refuses_to_build_without_an_endpoint(monkeypatch):
    monkeypatch.delenv(ENV_URL, raising=False)
    with pytest.raises(ValueError):
        http_judge()  # no default, by design — the plugin ships no judge service


def test_http_judge_builds_a_callable_from_an_explicit_url(monkeypatch):
    monkeypatch.delenv(ENV_URL, raising=False)
    # localhost:9 (discard port) — unreachable by design, and a hostname keeps
    # the ship rail's leak-audit clean (its IP-shape pattern can't tell a
    # loopback literal from an infra literal, and the guard is never overridden)
    j = http_judge(url="http://localhost:9/v1/chat/completions")
    assert callable(j)  # a judge callable is returned; no network until it's called
