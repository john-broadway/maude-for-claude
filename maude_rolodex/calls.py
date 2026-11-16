"""Cued and called: read the trace, count the Rolodex's cues and whether the pick was called.

A cue row is `{"kind": "rolodex", "payload": "trade=<slug> pick=<kind>:<name>", "sid": ...}`.
It counts as CALLED when a later row in the same session (`sid`) calls that pick:
  skill:X / agent:X   a Skill, Agent or Task row whose target is exactly X
  mcp:S               a row whose tool is mcp__S__* or mcp__plugin_<anything>_S__*
  recipe:P            a Read row whose target is P, or P with a leading ~/ expanded
A cue with no such row is a miss. The count is a reading, not a verdict. Unparseable
lines are skipped. Stdlib only; reads nothing but the trace files it is given.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

_DAY = re.compile(r"today-(\d{4}-\d{2}-\d{2})\.jsonl")
_CUE = re.compile(r"trade=([a-z0-9][a-z0-9-]{0,47}) pick=(skill|agent|mcp|recipe):(\S.*)")
_LINE_MAX = 64 * 1024


def _events(trace_dir, since: str | None = None):
    """Trace rows in order: day files by date, lines as written. Bad lines are skipped."""
    try:
        names = sorted(p.name for p in Path(trace_dir).iterdir())
    except OSError:
        return
    for name in names:
        m = _DAY.fullmatch(name)
        if not m or (since and m.group(1) < since):
            continue
        try:
            with open(Path(trace_dir) / name, "rb") as fh:
                for raw in fh:
                    if len(raw) > _LINE_MAX:            # a raw NUL is invalid JSON below
                        continue
                    try:
                        row = json.loads(raw.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        continue
                    if isinstance(row, dict):
                        yield row
        except OSError:
            continue


def _calls(row: dict, kind: str, name: str, home: str | None) -> bool:
    tool, target = row.get("tool"), row.get("target")
    if not isinstance(tool, str):
        return False
    if kind in ("skill", "agent"):
        return tool in ("Skill", "Agent", "Task") and target == name
    if kind == "mcp":
        return tool.startswith(f"mcp__{name}__") or re.fullmatch(
            rf"mcp__plugin_.+_{re.escape(name)}__.*", tool) is not None
    if kind == "recipe":
        if tool != "Read" or not isinstance(target, str):
            return False
        if target == name:
            return True
        return bool(home) and name.startswith("~/") and target == home.rstrip("/") + "/" + name[2:]
    return False


def cues(trace_dir, since: str | None = None, home: str | None = None,
         known: set | None = None) -> list[dict]:
    """Every cue in order: {slug, sid, called}. With `known`, a cue row naming a trade the
    ledger never held is skipped: the trace sits in the project, and a cloned repo can
    plant rows."""
    out: list[dict] = []
    open_cues: list[tuple[dict, str, str]] = []           # (cue record, kind, name) not yet called
    for row in _events(trace_dir, since):
        sid = row.get("sid")
        if not isinstance(sid, str) or not sid:
            continue
        if row.get("kind") == "rolodex":
            m = _CUE.fullmatch(row.get("payload") or "")
            if not m or (known is not None and m.group(1) not in known):
                continue
            rec = {"slug": m.group(1), "sid": sid, "called": False}
            out.append(rec)
            open_cues.append((rec, m.group(2), m.group(3)))
            continue
        for rec, kind, name in open_cues:
            if not rec["called"] and rec["sid"] == sid and _calls(row, kind, name, home):
                rec["called"] = True
    return out


def tally(trace_dir, since: str | None = None, home: str | None = None,
          known: set | None = None) -> tuple[int, int]:
    """(cued, called)."""
    got = cues(trace_dir, since, home, known)
    return len(got), sum(1 for c in got if c["called"])


def missed_streaks(trace_dir, n: int = 3, home: str | None = None,
                   known: set | None = None) -> list[str]:
    """Slugs whose last n cued sessions (by first cue) were all misses."""
    per: dict[str, dict[str, bool]] = {}
    for c in cues(trace_dir, None, home, known):
        sessions = per.setdefault(c["slug"], {})
        sessions[c["sid"]] = sessions.get(c["sid"], False) or c["called"]
    out = []
    for slug, sessions in per.items():
        last = list(sessions.values())[-n:]                # dicts keep first-seen order
        if len(last) == n and not any(last):
            out.append(slug)
    return sorted(out)
