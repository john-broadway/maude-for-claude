# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Maude Runtime — Session Distiller
#          Claude (Anthropic) <noreply@anthropic.com>
"""Claude Code session transcript distiller and archiver.

Reads .jsonl transcripts from Claude Code sessions, extracts coherent
episodes (task request -> investigation -> action -> result), converts
to ChatML format, and inserts into agent_memory as synthetic training data.

Also archives full session text to PostgreSQL and deletes source files.

Transcript format (one JSON object per line):
- type=user: {message: {role: "user", content: "..."}}
- type=assistant: {message: {role: "assistant", content: [{type: "text"|...}]}}
- type=progress: tool results, hook events, etc.

Episodes are split on user messages that start a new task.
"""

import json
import logging
import os
import re
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import asyncpg

from maude.healing.training.filter import TrainingFilterConfig, filter_conversation

logger = logging.getLogger(__name__)

PROJECTS_DIR = Path(os.path.expanduser("~/.claude/projects"))
PROCESSED_FILE = Path(os.path.expanduser("~/.claude/.distilled_transcripts"))

MIN_EPISODE_MSGS = 3
MAX_EPISODE_MSGS = 20

_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


# ── Project name resolution ──────────────────────────────────────


def _project_from_dir_name(dir_name: str) -> str:
    """Extract project name from Claude Code's encoded directory name.

    Claude encodes CWD by replacing / with -. For hyphenated project names
    (availability-monitor, display-service), we reconstruct the path and check existence.
    """
    # Convert encoded dir name back to a candidate path
    raw = "/" + dir_name.lstrip("-").replace("-", "/")
    candidate = Path(raw)
    if candidate.is_dir():
        return candidate.name

    # Path doesn't exist — last segments may contain hyphens that were
    # split into separate path components. Try merging last N segments.
    segments = raw.strip("/").split("/")
    for merge_count in range(2, min(5, len(segments) + 1)):
        head = "/" + "/".join(segments[:-merge_count])
        tail = "-".join(segments[-merge_count:])
        merged = Path(head) / tail
        if merged.is_dir():
            return merged.name

    # Fallback: last segment
    return segments[-1] if segments else dir_name


# ── JSONL parsing ─────────────────────────────────────────────────


def _extract_text(content: list[dict[str, Any]]) -> str:
    """Extract plain text from assistant content blocks."""
    parts: list[str] = []
    for item in content:
        if isinstance(item, dict) and item.get("type") == "text":
            text = item.get("text", "")
            if text:
                parts.append(text)
    return "\n".join(parts)


def _extract_tool_calls(content: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Extract tool_use blocks as ChatML tool_calls."""
    calls: list[dict[str, Any]] = []
    for item in content:
        if isinstance(item, dict) and item.get("type") == "tool_use":
            calls.append(
                {
                    "id": item.get("id", ""),
                    "type": "function",
                    "function": {
                        "name": item.get("name", ""),
                        "arguments": json.dumps(
                            item.get("input", {}),
                            default=str,
                            ensure_ascii=False,
                        ),
                    },
                }
            )
    return calls


def parse_transcript(
    path: Path,
    *,
    include_tool_calls: bool = True,
) -> list[dict[str, Any]]:
    """Parse a JSONL transcript into a flat message list.

    Args:
        path: Path to the JSONL transcript file.
        include_tool_calls: If True, include tool_use blocks in assistant
            messages. Set False for archive (text-only, smaller).

    Returns list of ChatML-style messages:
    - {role: "user", content: "..."}
    - {role: "assistant", content: "...", tool_calls: [...]}
    """
    messages: list[dict[str, Any]] = []

    with path.open() as f:
        for line in f:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get("type")

            if msg_type == "user":
                msg = obj.get("message", {})
                content = msg.get("content", "")
                if isinstance(content, str) and content.strip():
                    messages.append({"role": "user", "content": content.strip()})

            elif msg_type == "assistant":
                msg = obj.get("message", {})
                content = msg.get("content", [])
                if not isinstance(content, list):
                    continue

                text = _extract_text(content)
                tool_calls = _extract_tool_calls(content) if include_tool_calls else []

                if not text and not tool_calls:
                    continue

                entry: dict[str, Any] = {"role": "assistant"}
                if text:
                    entry["content"] = text
                if tool_calls:
                    entry["tool_calls"] = tool_calls

                messages.append(entry)

    return messages


# ── Transcript discovery ──────────────────────────────────────────


def _load_processed() -> set[str]:
    """Load set of already-processed transcript paths."""
    if PROCESSED_FILE.exists():
        return set(PROCESSED_FILE.read_text().splitlines())
    return set()


def _mark_processed(path: str) -> None:
    """Append a transcript path to the processed list."""
    with PROCESSED_FILE.open("a") as f:
        f.write(path + "\n")


def _prune_processed() -> None:
    """Remove entries for files that no longer exist."""
    if not PROCESSED_FILE.exists():
        return
    existing = [p for p in PROCESSED_FILE.read_text().splitlines() if Path(p).exists()]
    PROCESSED_FILE.write_text("\n".join(existing) + "\n" if existing else "")


def discover_transcripts(
    *,
    max_age_days: int = 0,
    only_unprocessed: bool = True,
) -> list[tuple[Path, str]]:
    """Find JSONL transcripts across all projects.

    Args:
        max_age_days: Only include files older than this many days. 0 = all.
        only_unprocessed: If True, skip files already in the processed list.

    Returns:
        List of (path, project_name) tuples.
    """
    processed = _load_processed() if only_unprocessed else set()
    results: list[tuple[Path, str]] = []

    if not PROJECTS_DIR.is_dir():
        return results

    cutoff = time.time() - (max_age_days * 86400) if max_age_days > 0 else float("inf")

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue

        project_name = _project_from_dir_name(project_dir.name)

        for jsonl_file in project_dir.glob("*.jsonl"):
            if only_unprocessed and str(jsonl_file) in processed:
                continue
            if max_age_days > 0 and jsonl_file.stat().st_mtime > cutoff:
                continue
            results.append((jsonl_file, project_name))

    return results


# ── Episode splitting + ChatML ────────────────────────────────────


def split_episodes(messages: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    """Split a flat message list into episodes.

    An episode starts with a user message and includes all subsequent
    assistant messages until the next user message that starts a new task.
    """
    if not messages:
        return []

    follow_up_prefixes = {
        "yes",
        "no",
        "ok",
        "okay",
        "sure",
        "continue",
        "go ahead",
        "proceed",
        "looks good",
        "lgtm",
        "approved",
        "do it",
        "correct",
        "right",
        "exactly",
        "yeah",
        "yep",
        "nah",
    }

    episodes: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []

    for msg in messages:
        if msg["role"] == "user":
            content_lower = msg.get("content", "").lower().strip()
            is_follow_up = (
                any(content_lower.startswith(p) for p in follow_up_prefixes)
                or len(content_lower.split()) <= 2
            )

            if current and not is_follow_up:
                if len(current) >= MIN_EPISODE_MSGS:
                    episodes.append(current[:MAX_EPISODE_MSGS])
                current = []

        current.append(msg)

    if len(current) >= MIN_EPISODE_MSGS:
        episodes.append(current[:MAX_EPISODE_MSGS])

    return episodes


def episode_to_chatml(
    episode: list[dict[str, Any]],
    project: str = "my-service",
) -> dict[str, Any] | None:
    """Convert an episode to a ChatML training example."""
    system_prompt = (
        "You are an infrastructure engineer for your organization. "
        "You diagnose and resolve issues across Proxmox, PostgreSQL, "
        "UniFi, GPU infrastructure, and industrial SCADA systems. "
        "You use MCP tools to inspect, monitor, and manage services. "
        "Always respond in English."
    )

    chatml_messages = [{"role": "system", "content": system_prompt}]

    for msg in episode:
        entry: dict[str, Any] = {"role": msg["role"]}
        if msg.get("content"):
            entry["content"] = msg["content"]
        if msg.get("tool_calls"):
            entry["tool_calls"] = msg["tool_calls"]
        chatml_messages.append(entry)

    config = TrainingFilterConfig()
    cleaned = filter_conversation(chatml_messages, config)
    if cleaned is None:
        return None

    return {
        "messages": cleaned,
        "metadata": {
            "source": "claude_code_session",
            "project": project,
            "episode_length": len(episode),
        },
    }


def distill_transcript(
    path: Path,
    project: str = "my-service",
) -> list[dict[str, Any]]:
    """Distill a single transcript into training examples."""
    messages = parse_transcript(path, include_tool_calls=True)
    if not messages:
        return []

    episodes = split_episodes(messages)
    examples: list[dict[str, Any]] = []

    for episode in episodes:
        example = episode_to_chatml(episode, project=project)
        if example is not None:
            examples.append(example)

    return examples


# ── Distill and store ─────────────────────────────────────────────


async def distill_and_store(
    pool: asyncpg.Pool,
    limit: int = 500,
) -> dict[str, Any]:
    """Discover, distill, and store new transcripts.

    Args:
        pool: asyncpg pool connected to the agent database.
        limit: Max transcripts to process per run. High default ensures
            all unprocessed files are distilled before archive runs.

    Returns:
        Summary dict with counts.
    """
    transcripts = discover_transcripts(only_unprocessed=True)[:limit]
    total_examples = 0
    total_transcripts = 0
    errors = 0

    for path, project in transcripts:
        try:
            examples = distill_transcript(path, project=project)
            for ex in examples:
                conversation = json.dumps(
                    ex["messages"],
                    default=str,
                    ensure_ascii=False,
                )
                await pool.execute(
                    """INSERT INTO agent_memory
                           (project, memory_type, trigger, context,
                            outcome, summary, conversation, created_at)
                       VALUES ($1, 'synthetic', 'session_distill',
                               $2::jsonb, 'resolved',
                               'Distilled from Claude Code session',
                               $3::jsonb, NOW())""",
                    project,
                    json.dumps(ex["metadata"], default=str),
                    conversation,
                )
            total_examples += len(examples)
            total_transcripts += 1
            _mark_processed(str(path))
        except Exception:
            logger.warning("Failed to distill %s", path, exc_info=True)
            errors += 1

    return {
        "transcripts_processed": total_transcripts,
        "examples_created": total_examples,
        "transcripts_available": len(transcripts),
        "errors": errors,
    }


# ── Archive and cleanup ──────────────────────────────────────────


def _parse_transcript_metadata(path: Path) -> dict[str, Any]:
    """Extract metadata from a JSONL transcript without full parsing."""
    session_id = path.stem
    stat = path.stat()
    first_ts = None
    last_ts = None
    slug = None

    with path.open() as f:
        for line in f:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = obj.get("timestamp")
            if ts and not first_ts:
                first_ts = ts
            if ts:
                last_ts = ts
            if not slug and obj.get("message", {}).get("content"):
                content = obj["message"]["content"]
                if isinstance(content, str):
                    slug = content[:120].strip()

    return {
        "session_id": session_id,
        "project_dir": path.parent.name,
        "file_size_bytes": stat.st_size,
        "file_mtime": datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
        "first_timestamp": first_ts,
        "last_timestamp": last_ts,
        "slug": slug,
    }


async def archive_and_cleanup(
    pool: asyncpg.Pool,
    max_age_days: int = 7,
    limit: int = 200,
) -> dict[str, Any]:
    """Archive session transcripts to PostgreSQL, then delete source files.

    Only archives files that have already been through distill_and_store
    (checked via the processed tracking file). This prevents data loss —
    files are never deleted before their training examples are extracted.

    For each eligible JSONL:
    1. Parse user+assistant text messages (no tool calls)
    2. Store as memory_type='session_archive' with conversation jsonb
    3. Delete source JSONL file
    4. Clean up stale UUID session dirs and empty project dirs

    Args:
        pool: asyncpg pool connected to the agent database.
        max_age_days: Only archive files older than this. 0 = all files.
        limit: Max transcripts to archive per run.

    Returns:
        Summary dict with counts and bytes freed.
    """
    processed = _load_processed()
    transcripts = discover_transcripts(
        max_age_days=max_age_days,
        only_unprocessed=False,
    )[:limit]
    archived = 0
    deleted_bytes = 0
    skipped_undistilled = 0
    errors = 0

    for path, project in transcripts:
        # Skip files not yet distilled — their training data would be lost
        if str(path) not in processed:
            skipped_undistilled += 1
            continue

        try:
            messages = parse_transcript(path, include_tool_calls=False)
            if not messages:
                deleted_bytes += path.stat().st_size
                path.unlink()
                continue

            metadata = _parse_transcript_metadata(path)
            metadata["message_count"] = len(messages)
            user_msgs = [m for m in messages if m["role"] == "user"]
            summary = (
                f"Session {metadata['session_id'][:8]}… "
                f"({len(user_msgs)} user, {len(messages) - len(user_msgs)} assistant)"
            )
            if user_msgs:
                summary += f" — {user_msgs[0]['content'][:80]}"

            conversation = json.dumps(messages, default=str, ensure_ascii=False)

            await pool.execute(
                """INSERT INTO agent_memory
                       (project, memory_type, trigger, context,
                        outcome, summary, conversation, created_at)
                   VALUES ($1, 'session_archive', 'session_archive',
                           $2::jsonb, 'archived', $3, $4::jsonb, NOW())""",
                project,
                json.dumps(metadata, default=str),
                summary,
                conversation,
            )

            deleted_bytes += path.stat().st_size
            path.unlink()
            archived += 1

        except Exception:
            logger.warning("Failed to archive %s", path, exc_info=True)
            errors += 1

    # Clean up stale session UUID directories and empty project directories
    dirs_cleaned = _cleanup_stale_dirs(max_age_days)

    # Prune the processed tracking file (remove entries for deleted files)
    _prune_processed()

    logger.info(
        "Session archive: %d archived, %d skipped (undistilled), %d errors, "
        "%.1f MB freed, %d dirs removed",
        archived,
        skipped_undistilled,
        errors,
        deleted_bytes / 1048576,
        dirs_cleaned,
    )

    return {
        "archived": archived,
        "skipped_undistilled": skipped_undistilled,
        "errors": errors,
        "bytes_freed": deleted_bytes,
        "dirs_cleaned": dirs_cleaned,
        "available": len(transcripts),
    }


def _cleanup_stale_dirs(max_age_days: int) -> int:
    """Remove stale UUID session dirs and empty project dirs."""
    dirs_cleaned = 0
    if not PROJECTS_DIR.is_dir():
        return dirs_cleaned

    cutoff_ts = time.time() - (max_age_days * 86400) if max_age_days > 0 else 0

    for project_dir in PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue

        for child in project_dir.iterdir():
            if not child.is_dir():
                continue
            if not _UUID_RE.match(child.name):
                continue
            try:
                if cutoff_ts > 0 and child.stat().st_mtime > cutoff_ts:
                    continue
                shutil.rmtree(child)
                dirs_cleaned += 1
            except OSError:
                pass

        try:
            if not any(project_dir.iterdir()):
                project_dir.rmdir()
                dirs_cleaned += 1
        except OSError:
            pass

    return dirs_cleaned
