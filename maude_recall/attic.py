"""The attic: past sessions of this project, his typed turns and Claude's user-facing text.

Design A3 (docs/specs/2026-10-24-seeing-gap-design.md). Read-only on Claude Code's own session
transcripts (`~/.claude/projects/<slug>/*.jsonl`). Typed by construction: the role comes from
the record's own fields, never from how the text looks, so Claude's words can never be filed
as his.

- **His:** a `user` record whose `origin.kind` is `human` AND whose `promptSource` is `typed`
  or `queued` (typed while Claude was busy). Not `suggestion_accepted`: that is the harness's
  suggested next prompt, text a model wrote that he accepted with a key (27% of the human
  turns here, lens 3), so it is not his phrasing. Not a slash command's expansion either
  (`<command-message>` turns are human-origin; `voice.is_machine_turn` refuses them, so that
  check does real work). A `<pasted_content …>` body is cut from the tag on: a paste is
  someone's text, not his. A `<system-reminder>` the harness appends at the END is cut; one
  anywhere else is left, so a tag he types himself never eats his words.
- **Claude's:** the text blocks of an `assistant` record. Never thinking, tool calls or tool
  results: that is where secrets and bulk live.
- **Never:** `isMeta`, `isCompactSummary` (Claude's summary, stored under the user role),
  `isSidechain` (a subagent's turns) or `isApiErrorMessage` records (API errors and usage
  notices the harness writes as assistant text).

A turn is keyed by its record uuid alone: a resumed session copies earlier records into its
new transcript, and the same turn is kept once. Only regular files are read (a FIFO named
*.jsonl would hang the build), and a line too deep to parse is skipped like a malformed one.

Every text goes through `maude_recall.redact` (the shell's maude_redact, ported) before it
leaves this module. Each item keeps its transcript time, so a replay can cut before it.
Namespaces: `attic.his` and `attic.claude`.
"""
from __future__ import annotations

import datetime
import glob
import json
import os
import re
import stat

from maude_recall import chunk
from maude_recall.redact import redact
from maude_tape.voice import is_machine_turn

HIS, CLAUDE = "attic.his", "attic.claude"
_TAIL_REMINDERS = re.compile(r"(?:\s*<system-reminder\b[^>]*>.*?</system-reminder>)+\s*\Z", re.S)
_PASTE = re.compile(r"<pasted_content\b.*\Z", re.S)
HIS_SOURCES = ("typed", "queued")


def _ts(value) -> float:
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _text_blocks(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
    return ""


def turns(path: str | os.PathLike):
    """(ns, key, text, ts) for each of his turns and each of Claude's replies in one transcript."""
    try:
        if not stat.S_ISREG(os.stat(path).st_mode):
            return
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if (not isinstance(rec, dict) or rec.get("isMeta") or rec.get("isCompactSummary")
                    or rec.get("isSidechain") or rec.get("isApiErrorMessage")):
                continue
            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            role, kind = msg.get("role"), rec.get("type")
            if kind == "user" and role == "user":
                origin = rec.get("origin")
                if not (isinstance(origin, dict) and origin.get("kind") == "human"):
                    continue
                if rec.get("promptSource") not in HIS_SOURCES:
                    continue
                content = msg.get("content")
                if isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result"
                                                     for b in content):
                    continue
                text = _PASTE.sub("", _TAIL_REMINDERS.sub("", _text_blocks(content))).strip()
                if not text or is_machine_turn(text):
                    continue
                ns = HIS
            elif kind == "assistant" and role == "assistant":
                if msg.get("model") == "<synthetic>":
                    continue
                text = _text_blocks(msg.get("content")).strip()
                if not text:
                    continue
                ns = CLAUDE
            else:
                continue
            uid = str(rec.get("uuid") or "")
            if not uid:
                continue
            yield ns, uid, redact(text), _ts(rec.get("timestamp"))


def items(transcripts_dir: str | os.PathLike) -> dict[str, list[tuple[str, str, float]]]:
    """{namespace: [(key, text, ts), …]} for every transcript in the directory, chunked to
    fit an embedder's window. A missing directory is an empty attic, never an error."""
    out: dict[str, list[tuple[str, str, float]]] = {HIS: [], CLAUDE: []}
    seen: set[str] = set()
    for path in sorted(glob.glob(os.path.join(os.fspath(transcripts_dir), "*.jsonl"))):
        for ns, key, text, ts in turns(path):
            if key in seen:  # a resumed session carries the earlier turns again
                continue
            seen.add(key)
            for i, part in enumerate(chunk.split(text)):
                out[ns].append((f"{key}#{i}", part, ts))
    return out
