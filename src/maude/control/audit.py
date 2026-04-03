# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Audit and housekeeping — disk, venvs, and git across the fleet.

Scans project directories for cache bloat, broken virtual environments,
and repos with uncommitted or unpushed changes. Read-only — never
deletes or modifies anything.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db.formatting import format_json

logger = logging.getLogger(__name__)

STALE_EXTENSIONS = {".pyc", ".pyo"}
CACHE_DIRS = {"__pycache__", ".pytest_cache", ".mypy_cache", ".pyright", ".ruff_cache"}


def register_audit_tools(
    mcp: Any,
    executor: Any,
    audit: Any,
    *,
    projects_dir: Path | None = None,
) -> None:
    """Register audit and housekeeping tools.

    Args:
        mcp: FastMCP instance.
        executor: LocalExecutor for running commands.
        audit: AuditLogger instance.
        projects_dir: Root directory to scan. Defaults to ~/projects.
    """
    scan_dir = projects_dir or Path.home() / "projects"

    @mcp.tool()
    @audit_logged(audit)
    async def control_disk_audit() -> str:
        """Scan projects for orphan caches, stale venvs, and large files.

        Reports cache directories, stale .pyc files, and files > 100MB.
        Does NOT delete anything — informational only.

        Returns:
            JSON with cache dirs, stale files, and large files found.
        """
        cache_dirs_found: list[str] = []
        large_files: list[dict[str, Any]] = []
        stale_count = 0
        total_cache_bytes = 0

        for root, dirs, files in os.walk(scan_dir):
            if ".git" in root.split(os.sep):
                continue

            rel = os.path.relpath(root, scan_dir)

            for d in dirs:
                if d in CACHE_DIRS:
                    cache_path = os.path.join(root, d)
                    try:
                        size = sum(
                            f.stat().st_size for f in Path(cache_path).rglob("*") if f.is_file()
                        )
                        total_cache_bytes += size
                        if size > 1024 * 1024:
                            cache_dirs_found.append(f"{rel}/{d} ({size // (1024 * 1024)}MB)")
                    except OSError:
                        pass

            for f in files:
                fp = os.path.join(root, f)
                if Path(f).suffix in STALE_EXTENSIONS:
                    stale_count += 1
                try:
                    size = os.path.getsize(fp)
                    if size > 100 * 1024 * 1024:
                        large_files.append(
                            {
                                "path": f"{rel}/{f}",
                                "size_mb": round(size / (1024 * 1024), 1),
                            }
                        )
                except OSError:
                    pass

        return format_json(
            {
                "cache_dirs": cache_dirs_found[:20],
                "cache_total_mb": round(total_cache_bytes / (1024 * 1024), 1),
                "stale_pyc_count": stale_count,
                "large_files": large_files[:10],
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def control_venv_health() -> str:
        """Verify all project virtual environments are functional.

        Checks each .venv/bin/python can import successfully.

        Returns:
            JSON with venv status per project.
        """
        results: dict[str, Any] = {}

        for project_dir in sorted(scan_dir.iterdir()):
            if not project_dir.is_dir() or project_dir.name.startswith("."):
                continue

            venv_dirs = list(project_dir.rglob(".venv"))
            if not venv_dirs:
                continue

            for venv in venv_dirs:
                python = venv / "bin" / "python"
                if not python.exists():
                    rel = str(venv.relative_to(scan_dir))
                    results[rel] = {"status": "missing_python"}
                    continue

                rel = str(venv.relative_to(scan_dir))
                try:
                    r = await executor.run(f"{python} -c 'import sys; print(sys.version_info[:2])'")
                    stdout = r.stdout if hasattr(r, "stdout") else str(r)
                    rc = r.exit_code if hasattr(r, "exit_code") else (0 if r.ok else 1)
                    if rc == 0:
                        results[rel] = {"status": "ok", "python": stdout.strip()}
                    else:
                        stderr = r.stderr if hasattr(r, "stderr") else ""
                        results[rel] = {"status": "broken", "error": str(stderr).strip()[:100]}
                except Exception as e:
                    results[rel] = {"status": "error", "error": str(e)[:100]}

        return format_json(results)

    @mcp.tool()
    @audit_logged(audit)
    async def control_git_status() -> str:
        """Multi-repo git status sweep.

        Reports repos with uncommitted changes, unpushed commits,
        or that are behind the remote.

        Returns:
            JSON with git status per repository.
        """
        results: dict[str, Any] = {}

        git_dirs: list[Path] = []
        for item in sorted(scan_dir.iterdir()):
            if not item.is_dir() or item.name.startswith("."):
                continue
            if (item / ".git").exists():
                git_dirs.append(item)
            else:
                for sub in sorted(item.iterdir()):
                    if sub.is_dir() and (sub / ".git").exists():
                        git_dirs.append(sub)

        for repo in git_dirs:
            name = str(repo.relative_to(scan_dir))
            try:
                r = await executor.run(f"git -C {repo} status --porcelain")
                stdout = r.stdout if hasattr(r, "stdout") else str(r)
                changes = len([line for line in stdout.strip().splitlines() if line.strip()])

                r2 = await executor.run(f"git -C {repo} branch --show-current")
                branch = (r2.stdout if hasattr(r2, "stdout") else str(r2)).strip()

                ahead_behind = ""
                try:
                    r3 = await executor.run(
                        f"git -C {repo} rev-list --left-right --count HEAD...@{{u}} 2>/dev/null"
                    )
                    ab_out = (r3.stdout if hasattr(r3, "stdout") else str(r3)).strip()
                    rc = r3.exit_code if hasattr(r3, "exit_code") else (0 if r3.ok else 1)
                    if rc == 0 and ab_out:
                        parts = ab_out.split()
                        if len(parts) == 2:
                            ahead, behind = int(parts[0]), int(parts[1])
                            if ahead or behind:
                                ahead_behind = f"+{ahead}/-{behind}"
                except Exception:
                    pass

                if changes or ahead_behind:
                    results[name] = {
                        "branch": branch,
                        "uncommitted": changes,
                    }
                    if ahead_behind:
                        results[name]["ahead_behind"] = ahead_behind

            except Exception as e:
                results[name] = {"error": str(e)[:100]}

        return format_json(
            {
                "repos_scanned": len(git_dirs),
                "repos_with_changes": results,
            }
        )
