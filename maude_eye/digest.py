"""Compact digest of a session-transcript tail. Stdlib only; never raises."""
from __future__ import annotations

import json
import os
import pathlib

_LINE_CAP = 160  # chars per rendered event line


def _text_of(content) -> str:
    """Flatten a message content field (str | list | dict) to plain text."""
    if isinstance(content, str):
        return content
    if isinstance(content, dict):
        return str(content.get("text") or content.get("content") or "")
    if isinstance(content, list):
        parts = []
        for item in content:
            if not isinstance(item, dict):
                continue
            kind = item.get("type", "")
            if kind == "text":
                parts.append(str(item.get("text", "")))
            elif kind == "tool_use":
                name = item.get("name", "?")
                arg = ""
                inp = item.get("input")
                if isinstance(inp, dict):
                    arg = str(inp.get("file_path") or inp.get("command")
                              or inp.get("pattern") or "")[:60]
                parts.append(f"<tool:{name} {arg}".rstrip() + ">")
            elif kind == "tool_result":
                parts.append("<result>")
        return " ".join(p for p in parts if p)
    return ""


def _render(rec: dict) -> str:
    msg = rec.get("message")
    if not isinstance(msg, dict):
        return ""
    role = str(msg.get("role") or rec.get("type") or "?")
    text = " ".join(_text_of(msg.get("content")).split())
    if not text:
        return ""
    if len(text) > _LINE_CAP:
        text = text[:_LINE_CAP] + "…"
    return f"[{role}] {text}"


def build_digest(transcript_path: str | os.PathLike,
                 max_events: int = 30, max_chars: int = 4000) -> str:
    if max_events <= 0 or max_chars <= 0:
        return ""
    p = pathlib.Path(transcript_path)
    try:
        raw = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    lines = []
    for ln in raw.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            continue
        rendered = _render(rec) if isinstance(rec, dict) else ""
        if rendered:
            lines.append(rendered)
    tail = lines[-max_events:]
    out = "\n".join(tail)
    if len(out) > max_chars:
        out = out[-max_chars:]
    return out
