import json
import pathlib

from maude_eye import digest


def _write_transcript(tmp_path, records):
    p = tmp_path / "t.jsonl"
    p.write_text("\n".join(json.dumps(r) for r in records) + "\n")
    return p


def test_missing_file_is_empty():
    assert digest.build_digest("/nonexistent/t.jsonl") == ""


def test_renders_text_and_tool_events(tmp_path):
    p = _write_transcript(tmp_path, [
        {"type": "user", "message": {"role": "user", "content": "fix the login bug"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "Looking at auth.py now"},
            {"type": "tool_use", "name": "Read", "input": {"file_path": "/src/auth.py"}},
        ]}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "Read", "input": {"file_path": "/src/auth.py"}},
        ]}},
    ])
    out = digest.build_digest(p)
    assert "fix the login bug" in out
    assert out.count("Read") == 2          # repeated tool visible — churn is the signal
    assert "auth.py" in out


def test_garbled_lines_skipped(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text('not json\n{"type":"user","message":{"role":"user","content":"hello"}}\n')
    out = digest.build_digest(p)
    assert "hello" in out


def test_caps_events_and_chars(tmp_path):
    recs = [{"type": "user", "message": {"role": "user", "content": f"msg {i} " + "x" * 300}}
            for i in range(100)]
    p = _write_transcript(tmp_path, recs)
    out = digest.build_digest(p, max_events=10, max_chars=1000)
    assert len(out) <= 1000
    assert "msg 99" in out                  # tail kept, head dropped
    assert "msg 0 " not in out


def test_zero_caps_are_empty(tmp_path):
    p = _write_transcript(tmp_path, [
        {"type": "user", "message": {"role": "user", "content": "hello"}}])
    assert digest.build_digest(p, max_events=0) == ""
    assert digest.build_digest(p, max_chars=0) == ""


def test_tool_event_no_space_before_bracket_when_empty_arg(tmp_path):
    p = _write_transcript(tmp_path, [
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "Bash", "input": {}},  # empty input → empty arg
        ]}},
    ])
    out = digest.build_digest(p)
    assert "<tool:Bash>" in out
    assert "<tool:Bash >" not in out
