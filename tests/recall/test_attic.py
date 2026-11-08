"""The attic (design A3): his typed turns and Claude's replies from past session transcripts.

Typed by construction: his only when the record says a human typed it (origin.kind), Claude's
only from assistant text blocks; never meta, compact summaries, subagents, thinking or tools.
Every text redacted; the transcript time kept.
"""
from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_recall import attic
from maude_recall.store import Store

TS = "2026-10-25T05:00:00.000Z"


def rec(kind, content, uuid, **extra):
    role = "assistant" if kind == "assistant" else "user"
    return {"type": kind, "uuid": uuid, "timestamp": TS, "message": {"role": role, "content": content}, **extra}


HUMAN = {"origin": {"kind": "human"}, "promptSource": "typed"}
RECORDS = [
    rec("user", "why am i seeing localized vectorized", "u1", **HUMAN),
    rec("user", "ok go<system-reminder>\nharness note, not his\n</system-reminder>", "u2", **HUMAN),
    rec("user", [{"type": "text", "text": "fold it"}], "u3", **HUMAN),
    rec("user", "<task-notification> done </task-notification>", "u4",
        origin={"kind": "task-notification"}),
    rec("user", "<bash-input>ls</bash-input>", "u5"),
    rec("user", "<cross-session-message from=x>do it</cross-session-message>", "u6", **HUMAN),
    rec("user", [{"type": "tool_result", "content": "secret output"}], "u7", **HUMAN),
    rec("user", "Summary of the earlier conversation, written by Claude", "u8", isCompactSummary=True, **HUMAN),
    rec("user", "a meta caveat", "u9", isMeta=True, **HUMAN),
    rec("user", "a subagent's prompt", "u10", isSidechain=True, **HUMAN),
    rec("assistant", [{"type": "thinking", "thinking": "private reasoning"},
                      {"type": "text", "text": "The store sits at 192.0.2.71."},
                      {"type": "tool_use", "name": "Bash", "input": {"command": "cat key"}}], "a1"),
    rec("assistant", [{"type": "tool_use", "name": "Read", "input": {}}], "a2"),
    rec("user", "no uuid here", "", **HUMAN),
    # each of these reads as a person's words; ONLY its own gate refuses it
    rec("user", "ok ship it now", "g1", origin={"kind": "task-notification"}, promptSource="typed"),
    rec("user", "sounds right merge it", "g2", origin={"kind": "human"}, promptSource="suggestion_accepted"),
    rec("user", "plain words with no source", "g3", origin={"kind": "human"}),
    rec("user", [{"type": "text", "text": "tool output that reads like prose"},
                 {"type": "tool_result", "content": "x"}], "g4", **HUMAN),
    rec("user", "typed while you were busy", "g5", origin={"kind": "human"}, promptSource="queued"),
    rec("user", "look at this <pasted_content id=1>someone else's long log line", "g6", **HUMAN),
    rec("user", "my token is sk" "-abcdefgh12345678ABCDEF ok", "g7", **HUMAN),
    rec("user", "i typed <system-reminder>this</system-reminder> myself and more", "g8", **HUMAN),
    rec("assistant", [{"type": "text", "text": "API Error: usage limit"}], "g9", isApiErrorMessage=True),
    {"type": "assistant", "uuid": "g10", "timestamp": TS,
     "message": {"role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": "Login expired"}]}},
]


def write(tmp_path, records=RECORDS, name="s1.jsonl"):
    d = tmp_path / "transcripts"
    d.mkdir(exist_ok=True)
    (d / name).write_text("\n".join(json.dumps(r) for r in records) + "\nnot json\n", encoding="utf-8")
    return d


def test_his_turns_are_only_what_a_human_typed(tmp_path):
    got = attic.items(write(tmp_path))
    assert [t for _, t, _ in got[attic.HIS]] == [
        "why am i seeing localized vectorized", "ok go", "fold it", "typed while you were busy", "look at this",
        "my token is [redacted-secret] ok", "i typed <system-reminder>this</system-reminder> myself and more"]


def test_claude_is_only_reply_text_and_it_is_redacted(tmp_path):
    got = attic.items(write(tmp_path))
    assert [t for _, t, _ in got[attic.CLAUDE]] == ["The store sits at [redacted-ip]."]


def test_nothing_private_leaks_through(tmp_path):
    blob = json.dumps(attic.items(write(tmp_path)))
    for never in ("harness note", "secret output", "Summary of the earlier", "meta caveat",
                  "subagent", "private reasoning", "cat key", "do it", "task-notification",
                  "bash-input", "192.0.2.71", "ship it now", "merge it", "no source",
                  "reads like prose", "someone else", "abcdefgh12345678", "usage limit", "Login expired"):
        assert never not in blob, never


def test_keys_and_times(tmp_path):
    got = attic.items(write(tmp_path))
    key, _, ts = got[attic.HIS][0]
    assert key == "u1#0" and ts == 1792904400.0  # 2026-10-25T05:00Z


def test_a_missing_directory_is_an_empty_attic(tmp_path):
    assert attic.items(tmp_path / "nope") == {attic.HIS: [], attic.CLAUDE: []}


def test_build_syncs_the_attic_and_recall_finds_it(tmp_path):
    import subprocess
    d = write(tmp_path)
    db = tmp_path / "recall.db"
    root = pathlib.Path(__file__).resolve().parents[2]
    res = subprocess.run([sys.executable, "-m", "maude_recall", "build", "--db", str(db), "--attic", str(d)],
                         cwd=root, capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    s = Store(db)
    try:
        hits = s.recall("localized vectorized", 3)
        assert hits and hits[0].ns == attic.HIS and hits[0].key == "u1#0"
    finally:
        s.close()


def test_a_resumed_session_keeps_a_turn_once(tmp_path):
    d = write(tmp_path, RECORDS[:1], "first.jsonl")
    write(tmp_path, RECORDS[:1], "resumed.jsonl")
    assert [k for k, _, _ in attic.items(d)[attic.HIS]] == ["u1#0"]


def test_a_line_too_deep_and_a_fifo_never_stop_the_attic(tmp_path):
    import os
    d = write(tmp_path)
    with open(d / "s1.jsonl", "a", encoding="utf-8") as fh:
        fh.write("[" * 200000 + "\n")
    if hasattr(os, "mkfifo"):
        os.mkfifo(d / "pipe.jsonl")
    (d / "dir.jsonl").mkdir()
    assert len(attic.items(d)[attic.HIS]) == 7
