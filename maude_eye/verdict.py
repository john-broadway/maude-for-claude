"""Parse the eye model's output into a contained whisper, or silence. Never raises."""
from __future__ import annotations

import json

_MAX_WHISPER = 200


def _first_json_object(text: str):
    depth = 0
    start = -1
    for i, ch in enumerate(text):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    try:
                        return json.loads(text[start:i + 1])
                    except ValueError:
                        start = -1  # keep scanning past a false positive
    return None


def _whisper_from(text: str) -> str:
    obj = _first_json_object(text or "")
    if not isinstance(obj, dict):
        return ""
    if obj.get("signal") is not True:
        return ""
    w = obj.get("whisper")
    if not isinstance(w, str):
        return ""
    w = " ".join(w.split())
    if not w:
        return ""
    if len(w) > _MAX_WHISPER:
        w = w[:_MAX_WHISPER] + "…"
    return w


def whisper_from(text: str) -> str:
    """Extract signal and whisper from model output. Never raises."""
    try:
        return _whisper_from(text)
    except Exception:
        return ""
