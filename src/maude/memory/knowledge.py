# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Knowledge file management for Room Agents.

Manages Tier 1 knowledge: markdown files in git that form the Room Agent's
baseline brain. Handles loading files into a system prompt, updating memory
files after incidents, and syncing with Gitea via git pull/push.

File structure expected:
    knowledge/
    ├── skills/          # Domain knowledge (static, rarely changes)
    │   ├── health.md
    │   ├── dashboards.md
    │   └── ...
    ├── memory/          # Learned knowledge (grows over time)
    │   ├── incidents.md
    │   ├── patterns.md
    │   └── preferences.md
    └── identity.md      # Persona, constraints, escalation rules

Runbook RAG (Phase 3E):
    reindex_knowledge() chunks .md files by ## headings and embeds into Qdrant
    ``room_runbooks`` collection. retrieve_relevant() fetches top-3 chunks
    for a given query, used when context would exceed the token threshold.

Usage:
    km = KnowledgeManager(knowledge_dir=Path("knowledge/"), repo_dir=Path("."))
    system_prompt = await km.load_knowledge()
    chunks = await km.retrieve_relevant("datasource timeout")
    await km.update_memory("incidents", "Resolved datasource timeout by restarting PG")
    await km.git_commit_push("Updated incident memory")
"""

import asyncio
import logging
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Qdrant collection for runbook chunks
RUNBOOK_COLLECTION = "room_runbooks"
# Embedding config — defaults match vLLM serving BAAI/bge-large-en-v1.5 (1024-dim).
# Override via MAUDE_EMBEDDING_MODEL / MAUDE_EMBEDDING_DIM env vars.
EMBEDDING_DIM = int(os.environ.get("MAUDE_EMBEDDING_DIM", "1024"))
EMBEDDING_MODEL = os.environ.get("MAUDE_EMBEDDING_MODEL", "BAAI/bge-large-en-v1.5")


class KnowledgeManager:
    """Manages Tier 1 knowledge files for a Room Agent.

    Args:
        knowledge_dir: Path to the knowledge/ directory.
        repo_dir: Path to the git repository root.
        git_config: Git configuration dict (enabled, remote, branch, auto_pull, auto_push).
    """

    def __init__(
        self,
        knowledge_dir: Path,
        repo_dir: Path,
        git_config: dict[str, Any] | None = None,
    ) -> None:
        self.knowledge_dir = knowledge_dir
        self.repo_dir = repo_dir
        self.git_config = git_config or {}

    async def load_knowledge(self) -> str:
        """Load all knowledge files and compose into a system prompt.

        Reads identity.md first, then skills/*.md, then memory/*.md.
        Returns the concatenated content as one string.
        """
        sections: list[str] = []

        # Identity first
        identity = self.knowledge_dir / "identity.md"
        if identity.exists():
            sections.append(f"# Identity\n\n{identity.read_text()}")

        # Skills
        skills_dir = self.knowledge_dir / "skills"
        if skills_dir.is_dir():
            for md_file in sorted(skills_dir.rglob("*.md")):
                content = md_file.read_text().strip()
                if content:
                    sections.append(f"# Skill: {md_file.stem}\n\n{content}")

        # Memory (learned knowledge)
        memory_dir = self.knowledge_dir / "memory"
        if memory_dir.is_dir():
            for md_file in sorted(memory_dir.glob("*.md")):
                content = md_file.read_text().strip()
                if content:
                    sections.append(f"# Memory: {md_file.stem}\n\n{content}")

        return "\n\n---\n\n".join(sections)

    async def update_memory(
        self,
        category: str,
        entry: str,
        max_entries: int = 50,
    ) -> bool:
        """Append an entry to a memory file.

        Args:
            category: Memory category (e.g., "incidents", "patterns").
            entry: Text to append.
            max_entries: Max entries to keep (trims oldest). 0 = unlimited.

        Returns:
            True if update succeeded.
        """
        memory_dir = self.knowledge_dir / "memory"
        memory_dir.mkdir(parents=True, exist_ok=True)
        filepath = memory_dir / f"{category}.md"

        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        # Cap entry length to prevent memory files from bloating context windows
        capped = entry[:500] if len(entry) > 500 else entry
        new_entry = f"\n- [{timestamp}] {capped}\n"

        try:
            if filepath.exists():
                content = filepath.read_text()
            else:
                content = f"---\ntype: memory\ncategory: {category}\n---\n\n# {category.title()}\n"

            content += new_entry

            # Trim to max_entries if needed (count lines starting with "- [")
            if max_entries > 0:
                lines = content.splitlines()
                entry_lines = [
                    (idx, line) for idx, line in enumerate(lines) if line.strip().startswith("- [")
                ]
                if len(entry_lines) > max_entries:
                    # Remove oldest entries (keep the last max_entries)
                    to_remove = len(entry_lines) - max_entries
                    remove_indices = {entry_lines[j][0] for j in range(to_remove)}
                    lines = [line for idx, line in enumerate(lines) if idx not in remove_indices]
                    content = "\n".join(lines)

            filepath.write_text(content)
            logger.info("KnowledgeManager: Updated memory/%s.md", category)
            return True
        except Exception:
            logger.warning("KnowledgeManager: Failed to update memory", exc_info=True)
            return False

    async def git_pull(self) -> bool:
        """Pull latest knowledge from Gitea.

        Returns True if pull succeeded or git is disabled.
        """
        if not self.git_config.get("enabled") or not self.git_config.get("auto_pull"):
            return True

        if not (self.repo_dir / ".git").is_dir():
            logger.debug("KnowledgeManager: No .git directory in %s, skipping pull", self.repo_dir)
            return True

        remote = self.git_config.get("remote", "origin")
        branch = self.git_config.get("branch", "main")

        try:
            proc = await asyncio.create_subprocess_exec(
                "git",
                "pull",
                "--rebase",
                remote,
                branch,
                cwd=str(self.repo_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, stderr = await asyncio.wait_for(
                    proc.communicate(),
                    timeout=15.0,
                )
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                logger.warning("KnowledgeManager: git pull timed out after 15s")
                return False
            if proc.returncode == 0:
                logger.info("KnowledgeManager: git pull succeeded")
                return True
            logger.warning(
                "KnowledgeManager: git pull failed (rc=%d): %s",
                proc.returncode,
                stderr.decode()[:200],
            )
            return False
        except Exception:
            logger.warning("KnowledgeManager: git pull error", exc_info=True)
            return False

    async def git_commit_push(self, message: str) -> bool:
        """Commit knowledge changes and push to Gitea.

        Only commits files under the knowledge/ directory.
        Returns True if push succeeded or git is disabled.
        """
        if not self.git_config.get("enabled") or not self.git_config.get("auto_push"):
            return True

        if not (self.repo_dir / ".git").is_dir():
            logger.debug("KnowledgeManager: No .git directory in %s, skipping push", self.repo_dir)
            return True

        remote = self.git_config.get("remote", "origin")
        branch = self.git_config.get("branch", "main")

        try:
            # Stage only knowledge files
            knowledge_rel = self.knowledge_dir.relative_to(self.repo_dir)
            add_proc = await asyncio.create_subprocess_exec(
                "git",
                "add",
                str(knowledge_rel),
                cwd=str(self.repo_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(add_proc.communicate(), timeout=10.0)

            # Check if there are staged changes
            diff_proc = await asyncio.create_subprocess_exec(
                "git",
                "diff",
                "--cached",
                "--quiet",
                cwd=str(self.repo_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(diff_proc.communicate(), timeout=10.0)
            if diff_proc.returncode == 0:
                logger.debug("KnowledgeManager: No knowledge changes to commit")
                return True

            # Commit
            commit_msg = f"room-agent: {message}"
            commit_proc = await asyncio.create_subprocess_exec(
                "git",
                "commit",
                "-m",
                commit_msg,
                cwd=str(self.repo_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(
                commit_proc.communicate(),
                timeout=10.0,
            )
            if commit_proc.returncode != 0:
                logger.warning("KnowledgeManager: git commit failed: %s", stderr.decode()[:200])
                return False

            # Push
            push_proc = await asyncio.create_subprocess_exec(
                "git",
                "push",
                remote,
                branch,
                cwd=str(self.repo_dir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, stderr = await asyncio.wait_for(
                    push_proc.communicate(),
                    timeout=30.0,
                )
            except asyncio.TimeoutError:
                push_proc.kill()
                await push_proc.wait()
                logger.warning("KnowledgeManager: git push timed out after 30s")
                return False
            if push_proc.returncode != 0:
                logger.warning("KnowledgeManager: git push failed: %s", stderr.decode()[:200])
                return False

            logger.info("KnowledgeManager: Committed and pushed knowledge update")
            return True
        except asyncio.TimeoutError:
            logger.warning("KnowledgeManager: git operation timed out")
            return False
        except Exception:
            logger.warning("KnowledgeManager: git commit/push error", exc_info=True)
            return False

    # ── Runbook RAG (Phase 3E) ────────────────────────────────────

    def chunk_knowledge(self) -> list[dict[str, str]]:
        """Split knowledge .md files into chunks by ``##`` headings.

        Returns a list of dicts with keys ``source``, ``heading``, ``content``.
        Each chunk is one ``##`` section (or the preamble before any heading).
        """
        chunks: list[dict[str, str]] = []

        md_files: list[Path] = []
        if self.knowledge_dir.is_dir():
            md_files = sorted(self.knowledge_dir.rglob("*.md"))

        for md_file in md_files:
            try:
                text = md_file.read_text()
            except Exception:
                continue
            if not text.strip():
                continue

            rel_path = str(md_file.relative_to(self.knowledge_dir))
            # Split on ## headings (level 2)
            sections = re.split(r"(?m)^(## .+)$", text)

            # sections[0] is preamble before first ##
            preamble = sections[0].strip()
            if preamble:
                chunks.append(
                    {
                        "source": rel_path,
                        "heading": "(preamble)",
                        "content": preamble,
                    }
                )

            # Pairs: (heading, content)
            for i in range(1, len(sections), 2):
                heading = sections[i].strip()
                content = sections[i + 1].strip() if i + 1 < len(sections) else ""
                if heading or content:
                    chunks.append(
                        {
                            "source": rel_path,
                            "heading": heading.lstrip("# ").strip(),
                            "content": f"{heading}\n\n{content}" if content else heading,
                        }
                    )

        return chunks

    async def reindex_knowledge(self, project: str) -> int:
        """Chunk knowledge files and embed into Qdrant ``room_runbooks`` collection.

        Args:
            project: Room project name (used as Qdrant payload filter).

        Returns:
            Number of chunks indexed. 0 on failure.
        """
        try:
            from qdrant_client import AsyncQdrantClient
            from qdrant_client.models import Distance, PointStruct, VectorParams

            from maude.daemon.common import resolve_infra_hosts
            from maude.llm.vllm import VLLMClient
        except ImportError:
            logger.warning("KnowledgeManager: qdrant/vllm dependencies not available")
            return 0

        chunks = self.chunk_knowledge()
        if not chunks:
            return 0

        infra = resolve_infra_hosts()
        qdrant_host = infra.get("qdrant", "localhost")
        client = AsyncQdrantClient(host=qdrant_host, port=6333, timeout=30)
        vllm = VLLMClient()

        try:
            # Ensure collection exists
            exists = await client.collection_exists(RUNBOOK_COLLECTION)
            if not exists:
                await client.create_collection(
                    collection_name=RUNBOOK_COLLECTION,
                    vectors_config=VectorParams(
                        size=EMBEDDING_DIM,
                        distance=Distance.COSINE,
                    ),
                    on_disk_payload=True,
                )

            indexed = 0
            for chunk in chunks:
                text = chunk["content"][:2000]  # cap embedding input
                try:
                    resp = await vllm.embed(model=EMBEDDING_MODEL, input=text)
                    embeddings = resp.embeddings or []
                    if not embeddings or len(embeddings[0]) != EMBEDDING_DIM:
                        continue
                    vector = list(embeddings[0])
                except Exception:
                    logger.debug(
                        "KnowledgeManager: Embedding failed for chunk %s",
                        chunk["heading"],
                    )
                    continue

                point_id = str(
                    uuid.uuid5(
                        uuid.NAMESPACE_DNS,
                        f"maude.runbook.{project}.{chunk['source']}.{chunk['heading']}",
                    )
                )
                await client.upsert(
                    collection_name=RUNBOOK_COLLECTION,
                    points=[
                        PointStruct(
                            id=point_id,
                            vector=vector,
                            payload={
                                "project": project,
                                "source": chunk["source"],
                                "heading": chunk["heading"],
                                "content": chunk["content"],
                            },
                        )
                    ],
                )
                indexed += 1

            logger.info(
                "KnowledgeManager: Indexed %d/%d knowledge chunks for %s",
                indexed,
                len(chunks),
                project,
            )
            return indexed
        except Exception:
            logger.warning("KnowledgeManager: reindex_knowledge failed", exc_info=True)
            return 0
        finally:
            await client.close()
            await vllm.close()

    async def retrieve_relevant(
        self,
        query: str,
        project: str,
        limit: int = 3,
    ) -> list[dict[str, str]]:
        """Retrieve top-N relevant knowledge chunks from Qdrant.

        Args:
            query: The trigger or question to search for.
            project: Room project name to filter results.
            limit: Number of chunks to return.

        Returns:
            List of dicts with ``source``, ``heading``, ``content``, ``score``.
            Empty list on failure.
        """
        try:
            from qdrant_client import AsyncQdrantClient
            from qdrant_client.models import FieldCondition, Filter, MatchValue

            from maude.daemon.common import resolve_infra_hosts
            from maude.llm.vllm import VLLMClient
        except ImportError:
            return []

        infra = resolve_infra_hosts()
        qdrant_host = infra.get("qdrant", "localhost")
        client = AsyncQdrantClient(host=qdrant_host, port=6333, timeout=30)
        vllm = VLLMClient()

        try:
            # Check collection exists
            if not await client.collection_exists(RUNBOOK_COLLECTION):
                return []

            # Embed query
            resp = await vllm.embed(model=EMBEDDING_MODEL, input=query[:1000])
            embeddings = resp.embeddings or []
            if not embeddings or len(embeddings[0]) != EMBEDDING_DIM:
                return []
            vector = list(embeddings[0])

            result = await client.query_points(
                collection_name=RUNBOOK_COLLECTION,
                query=vector,
                query_filter=Filter(
                    must=[FieldCondition(key="project", match=MatchValue(value=project))],
                ),
                limit=limit,
            )

            chunks: list[dict[str, str]] = []
            for point in result.points:
                payload = point.payload or {}
                chunks.append(
                    {
                        "source": payload.get("source", ""),
                        "heading": payload.get("heading", ""),
                        "content": payload.get("content", ""),
                        "score": str(point.score),
                    }
                )
            return chunks
        except Exception:
            logger.debug("KnowledgeManager: retrieve_relevant failed", exc_info=True)
            return []
        finally:
            await client.close()
            await vllm.close()
