# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Agency tools — department knowledge, cross-functional routing, standards lookup.

Consolidated from agency_mcp.tools.{department,routing,standards} into the
Coordinator so all organizational intelligence is served from one endpoint.

Knowledge source:
  ${MAUDE_AGENCY_PATH:-./agency/}corporate/{dept}/agent.md  (9 corporate departments)
  ${MAUDE_AGENCY_PATH:-./agency/}{company}/{dept}/agent.md  (13 per subsidiary × 4 companies)

Companies are loaded from the agency path (one primary + N subsidiaries)
"""

import logging
import re
from pathlib import Path
from typing import Any

from maude.daemon.guards import audit_logged
from maude.db import format_json as _format
from maude.llm.vllm import VLLMClient

logger = logging.getLogger(__name__)


_vllm_client: VLLMClient | None = None


def _get_vllm_client() -> VLLMClient:
    """Lazy-init module-level VLLMClient."""
    global _vllm_client
    if _vllm_client is None:
        _vllm_client = VLLMClient()
    return _vllm_client


async def _chat(model: str, question: str) -> str:
    """Call vLLM chat with failover across GPU hosts."""
    try:
        client = _get_vllm_client()
        response = await client.chat(
            model=model,
            messages=[{"role": "user", "content": question}],
            stream=False,
        )
        return response.message.content or ""
    except Exception as e:
        return f"[Error: All vLLM hosts failed. Last error: {e}]"


def _discover_agents(agency_root: Path) -> dict[str, dict]:
    """Scan agency_root for **/agent.md files and extract metadata.

    Returns dict keyed by path-based keys like "corporate/admin", "hp/production".
    """
    agents: dict[str, dict] = {}
    if not agency_root.is_dir():
        logger.error("Agency root does not exist: %s", agency_root)
        return agents

    for agent_md in sorted(agency_root.glob("**/agent.md")):
        rel = agent_md.relative_to(agency_root)
        parts = rel.parts
        if len(parts) < 3:  # Must be {group}/{dept}/agent.md
            continue

        company = parts[0]  # "hp", "aim", "sbm", "do", "corporate"
        dept = parts[1]  # "production", "admin", etc.
        key = f"{company}/{dept}"

        content = agent_md.read_text(encoding="utf-8")

        name = ""
        role = ""
        for line in content.splitlines():
            if line.startswith("- **Name:**"):
                name = line.split("**Name:**")[1].strip()
            elif line.startswith("- **Role:**"):
                role = line.split("**Role:**")[1].strip()
            if name and role:
                break

        # Parse cross-functional relationships table
        relationships = _parse_cross_functional(content)

        # Parse specific sections
        responsibilities = _parse_section(content, "Core Responsibilities")
        standards = _parse_section(content, "Key Standards & Regulations")

        agents[key] = {
            "key": key,
            "company": company,
            "department": dept,
            "agent_name": name,
            "role": role,
            "path": str(agent_md),
            "content": content,
            "relationships": relationships,
            "responsibilities": responsibilities,
            "standards": standards,
        }

    logger.info("Discovered %d department agents under %s", len(agents), agency_root)
    return agents


def _model_name(company: str, dept: str) -> str:
    """Model name: corporate → {dept}-agent, subsidiary → {company}-{dept}-agent."""
    if company == "corporate":
        return f"{dept}-agent"
    return f"{company}-{dept}-agent"


def _resolve_agent(
    agents: dict[str, dict],
    department: str,
    company: str = "",
) -> tuple[str, dict] | tuple[None, None]:
    """Resolve a department + optional company to an agent key and info dict.

    Returns (key, info) or (None, None) if not found.
    """
    dept_lower = department.lower().strip()
    company_lower = company.lower().strip() if company else ""

    # Exact key match
    if company_lower:
        key = f"{company_lower}/{dept_lower}"
        if key in agents:
            return key, agents[key]

    # Find by department name
    matches = [(k, v) for k, v in agents.items() if v["department"] == dept_lower]
    if company_lower:
        matches = [(k, v) for k, v in matches if v["company"] == company_lower]

    if len(matches) == 1:
        return matches[0]

    # For corporate departments, auto-resolve when unambiguous
    if not company_lower and matches:
        corp = [(k, v) for k, v in matches if v["company"] == "corporate"]
        if corp:
            return corp[0]

    # Fuzzy match as fallback
    if not matches:
        matches = [
            (k, v)
            for k, v in agents.items()
            if dept_lower in v["department"] or v["department"] in dept_lower
        ]
        if company_lower:
            matches = [(k, v) for k, v in matches if v["company"] == company_lower]
        if len(matches) == 1:
            return matches[0]

    return None, None


def _parse_cross_functional(content: str) -> list[dict]:
    """Parse the Cross-Functional Relationships table."""
    relationships: list[dict] = []
    in_table = False
    for line in content.splitlines():
        if "Cross-Functional Relationships" in line:
            in_table = True
            continue
        if in_table:
            if line.startswith("| **"):
                parts = line.split("|")
                if len(parts) >= 3:
                    dept = parts[1].strip().strip("*").strip()
                    interaction = parts[2].strip()
                    relationships.append(
                        {
                            "department": dept,
                            "interaction": interaction,
                        }
                    )
            elif line.startswith("##"):
                break
    return relationships


def _parse_section(content: str, heading: str) -> str:
    """Extract content of a specific ## section."""
    lines: list[str] = []
    in_section = False
    for line in content.splitlines():
        if line.startswith(f"## {heading}"):
            in_section = True
            continue
        if in_section:
            if line.startswith("## "):
                break
            lines.append(line)
    return "\n".join(lines).strip()


def _build_standards_index(agents: dict[str, dict]) -> dict[str, list[dict]]:
    """Build inverted index: standard -> agents that reference it."""
    index: dict[str, list[dict]] = {}

    for key, info in agents.items():
        content = info["content"]

        in_standards = False
        for line in content.splitlines():
            if "Key Standards" in line and line.startswith("##"):
                in_standards = True
                continue
            if in_standards:
                if line.startswith("## "):
                    break
                standards_found = re.findall(
                    r"(?:AS|ISO|NADCAP|FDA|ITAR|DFARS|NIST|IEC|SEMI|MIL|OSHA|ASTM|AMS|IPC|CMMC|EPA|NFPA|SOX)"
                    r"[\s-]*[\w./()-]+",
                    line,
                )
                for std in standards_found:
                    std_clean = std.strip().rstrip(".")
                    if std_clean not in index:
                        index[std_clean] = []
                    if not any(e["key"] == key for e in index[std_clean]):
                        index[std_clean].append(
                            {
                                "key": key,
                                "company": info["company"],
                                "department": info["department"],
                                "agent_name": info["agent_name"],
                            }
                        )

    return index


# ── Tool registration ────────────────────────────────────────────────

EXPECTED_CORPORATE = {
    "admin",
    "creative",
    "executive",
    "finance",
    "hr",
    "it",
    "legal",
    "network-infrastructure",
    "sales",
}
EXPECTED_SUBSIDIARY_DEPTS = {
    "production",
    "engineering",
    "quality",
    "lab",
    "maintenance",
    "inspection",
    "shipping",
    "purchasing",
    "ops",
    "automation",
    "ehs",
    "rnd",
    "creative",
}
EXPECTED_COMPANIES = {"hp", "aim", "sbm", "do"}


def _keyword_scores(
    topic: str,
    agents: dict[str, dict],
    company_filter: str = "",
) -> list[dict]:
    """Score agents against a topic using keyword matching.

    Extracted from agency_who_handles so agency_ask can reuse it.
    Returns sorted list of {key, company, department, agent_name, score, matches}.
    """
    topic_lower = topic.lower()
    topic_words = set(topic_lower.split())
    company_lower = company_filter.lower().strip() if company_filter else ""
    results: list[dict] = []

    for key, info in agents.items():
        if company_lower and info["company"] != company_lower:
            continue

        score = 0
        matches: list[str] = []

        resp_lower = info["responsibilities"].lower()
        resp_word_matches = len(topic_words & set(resp_lower.split()))
        if topic_lower in resp_lower:
            score += 10
            matches.append("core responsibilities (exact match)")
        elif resp_word_matches >= 2:
            score += resp_word_matches * 2
            matches.append("core responsibilities")

        for rel in info["relationships"]:
            if topic_lower in rel["interaction"].lower():
                score += 5
                matches.append(f"cross-functional: {rel['department']}")

        std_lower = info["standards"].lower()
        if topic_lower in std_lower:
            score += 8
            matches.append("standards/regulations (exact match)")
        elif len(topic_words & set(std_lower.split())) >= 2:
            score += 3
            matches.append("standards/regulations")

        content_lower = info["content"].lower()
        if topic_lower in content_lower and score == 0:
            score += 2
            matches.append("general content")

        if score > 0:
            results.append(
                {
                    "key": key,
                    "company": info["company"],
                    "department": info["department"],
                    "agent_name": info["agent_name"],
                    "score": score,
                    "matches": matches,
                }
            )

    results.sort(key=lambda x: x["score"], reverse=True)
    return results


def register_agency_tools(mcp: Any, audit: Any, agency_root: Path) -> None:
    """Register all agency tools (department, routing, standards) on the MCP."""
    agents = _discover_agents(agency_root)
    standards_index = _build_standards_index(agents)
    logger.info("Built standards index with %d unique standards", len(standards_index))

    # ── Department tools ─────────────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    async def agency_list(company: str = "") -> str:
        """List all department agents with names and roles.

        Args:
            company: Optional filter — "hp", "aim", "sbm", "do", or "corporate".
                     Empty returns all agents.

        Returns:
            JSON array of agent objects with key, company, department, agent_name, role.
        """
        company_lower = company.lower().strip() if company else ""
        result = []
        for key, info in sorted(agents.items()):
            if company_lower and info["company"] != company_lower:
                continue
            result.append(
                {
                    "key": key,
                    "company": info["company"],
                    "department": info["department"],
                    "agent_name": info["agent_name"],
                    "role": info["role"],
                }
            )
        return _format({"count": len(result), "agents": result})

    @mcp.tool()
    @audit_logged(audit)
    async def agency_query(department: str, question: str, company: str = "") -> str:
        """Query a department agent — routes to the department's custom LLM.

        Each agent has a dedicated vLLM model with system prompt passed at runtime.
        Subsidiary models are named {company}-{dept}-agent
        (e.g., hp-production-agent). Corporate models are {dept}-agent.

        Args:
            department: Department name (e.g., "production", "quality").
            question: The question to ask the department agent.
            company: Company scope — "hp", "aim", "sbm", "do", or "corporate".
                     Required for operational departments (production, quality,
                     etc.) which exist per-subsidiary. Corporate departments
                     auto-resolve without this.

        Returns:
            JSON with agent identity and the agent's reasoned response.
        """
        key, info = _resolve_agent(agents, department, company)

        if info is None:
            # Check if multiple matches exist (ambiguous department)
            dept_lower = department.lower().strip()
            matches = [
                {"key": k, "company": v["company"]}
                for k, v in agents.items()
                if v["department"] == dept_lower
            ]
            if len(matches) > 1:
                return _format(
                    {
                        "error": (
                            f"Department '{department}' exists at multiple"
                            " companies. Specify company."
                        ),
                        "matches": matches,
                    }
                )
            return _format(
                {
                    "error": f"Department '{department}' not found",
                    "available": sorted(agents.keys()),
                }
            )

        model = _model_name(info["company"], info["department"])
        answer = await _chat(model, question)

        return _format(
            {
                "key": key,
                "company": info["company"],
                "department": info["department"],
                "agent_name": info["agent_name"],
                "role": info["role"],
                "model": model,
                "question": question,
                "answer": answer,
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def agency_ask(question: str) -> str:
        """Ask the agency a question — auto-routes to the best agent.

        The single front door. Combines semantic search over agent knowledge
        with keyword routing to find the most relevant agent, then queries
        that agent's dedicated LLM model for an answer.

        Routing pipeline:
        1. Semantic search — embeds the question and searches the agents
           Qdrant collection for relevant knowledge (top 5).
        2. Keyword routing — scores all agents against the question
           text using responsibilities, standards, and cross-functional data.
        3. Merge & rank — normalizes and combines both scores (0.7 semantic +
           0.3 keyword), deduplicates, picks top 3.
        4. Auto-query — calls the top-ranked agent's LLM model.

        Args:
            question: Natural language question about Maude operations.

        Returns:
            JSON with the answer, which agent handled it, other relevant
            agents, and the routing scores.
        """
        from maude.coordination.search import AGENTS_COLLECTION, _embed, _qdrant_search

        # 1. Semantic search over agents collection
        semantic_scores: dict[str, float] = {}
        semantic_context: dict[str, str] = {}
        try:
            embedding = await _embed(question)
            hits = await _qdrant_search(AGENTS_COLLECTION, embedding, top_k=5)
            for hit in hits:
                payload = hit.get("payload", {})
                # Support both old "department" and new "key" fields
                key = payload.get("key", "") or payload.get("department", "")
                score = hit.get("score", 0.0)
                if key and key not in semantic_scores:
                    semantic_scores[key] = score
                    semantic_context[key] = payload.get("content", "")[:300]
        except Exception as e:
            logger.warning("Semantic search failed in agency_ask: %s", e)

        # 2. Keyword routing
        kw_results = _keyword_scores(question, agents)

        # 3. Merge & rank (0.7 semantic + 0.3 keyword)
        all_keys: set[str] = set(semantic_scores.keys())
        for r in kw_results:
            all_keys.add(r["key"])

        # Normalize scores to 0-1 range
        sem_max = max(semantic_scores.values()) if semantic_scores else 1.0
        kw_max = max(r["score"] for r in kw_results) if kw_results else 1.0
        kw_map = {r["key"]: r["score"] for r in kw_results}

        merged: list[dict] = []
        for key in all_keys:
            if key not in agents:
                continue
            sem_norm = (semantic_scores.get(key, 0.0) / sem_max) if sem_max else 0.0
            kw_norm = (kw_map.get(key, 0.0) / kw_max) if kw_max else 0.0
            combined = 0.7 * sem_norm + 0.3 * kw_norm
            merged.append(
                {
                    "key": key,
                    "company": agents[key]["company"],
                    "department": agents[key]["department"],
                    "combined_score": round(combined, 4),
                    "semantic_score": round(sem_norm, 4),
                    "keyword_score": round(kw_norm, 4),
                }
            )

        merged.sort(key=lambda x: x["combined_score"], reverse=True)

        if not merged:
            return _format(
                {
                    "error": "No relevant agent found for this question.",
                    "question": question,
                }
            )

        # 4. Auto-query the top-ranked agent
        top_key = merged[0]["key"]
        info = agents[top_key]
        model = _model_name(info["company"], info["department"])
        answer = await _chat(model, question)

        return _format(
            {
                "question": question,
                "routed_to": {
                    "key": top_key,
                    "company": info["company"],
                    "department": info["department"],
                    "agent_name": info["agent_name"],
                    "role": info["role"],
                    "model": model,
                },
                "answer": answer,
                "also_relevant": [
                    {
                        "key": m["key"],
                        "company": m["company"],
                        "department": m["department"],
                        "agent_name": agents[m["key"]]["agent_name"],
                        "score": m["combined_score"],
                    }
                    for m in merged[1:3]
                    if m["combined_score"] > 0.2
                ],
                "routing": merged[:5],
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def agency_health() -> str:
        """Verify all agent.md files exist and are valid.

        Expects 9 corporate + 13 per subsidiary × 4 companies = 61 agents.

        Returns:
            JSON with health status, counts by company, and any issues.
        """
        # Build expected keys
        expected_keys: set[str] = set()
        for dept in EXPECTED_CORPORATE:
            expected_keys.add(f"corporate/{dept}")
        for co in EXPECTED_COMPANIES:
            for dept in EXPECTED_SUBSIDIARY_DEPTS:
                expected_keys.add(f"{co}/{dept}")

        found = set(agents.keys())
        missing = expected_keys - found
        extra = found - expected_keys

        # Count by company
        company_counts: dict[str, int] = {}
        for key, info in agents.items():
            co = info["company"]
            company_counts[co] = company_counts.get(co, 0) + 1

        healthy = len(missing) == 0
        result: dict[str, Any] = {
            "healthy": healthy,
            "expected": len(expected_keys),
            "found": len(found),
            "by_company": company_counts,
            "agents": sorted(found),
        }
        if missing:
            result["missing"] = sorted(missing)
        if extra:
            result["extra"] = sorted(extra)

        issues: list[str] = []
        required_sections = ["Persona", "Core Responsibilities", "Cross-Functional Relationships"]
        for key, info in agents.items():
            for section in required_sections:
                if f"## {section}" not in info["content"]:
                    issues.append(f"{key}: missing '## {section}'")
        if issues:
            result["issues"] = issues
            result["healthy"] = False

        return _format(result)

    # ── Routing tools ────────────────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    async def agency_who_handles(topic: str, company: str = "") -> str:
        """Find which agents handle a given topic or responsibility.

        Searches across all agents' responsibilities, cross-functional
        relationships, and standards to find the most relevant.

        Args:
            topic: The topic to search for (e.g., "compliance qualification",
                   "ITAR compliance", "cleanroom monitoring").
            company: Optional filter — "hp", "aim", "sbm", "do", or "corporate".

        Returns:
            JSON with ranked list of agents by relevance.
        """
        results = _keyword_scores(topic, agents, company_filter=company)
        formatted = [
            {
                "key": r["key"],
                "company": r["company"],
                "department": r["department"],
                "agent_name": r["agent_name"],
                "relevance_score": r["score"],
                "match_areas": r["matches"],
            }
            for r in results
        ]

        return _format(
            {
                "topic": topic,
                "company_filter": company or "all",
                "results": formatted[:10],
                "total_matches": len(formatted),
            }
        )

    @mcp.tool()
    @audit_logged(audit)
    async def agency_cross_reference(
        department_a: str,
        department_b: str,
        company: str = "",
    ) -> str:
        """Show the interaction between two departments.

        Looks up the cross-functional relationship table in both directions.

        Args:
            department_a: First department name (e.g., "production").
            department_b: Second department name (e.g., "quality").
            company: Optional company scope to resolve both departments within
                     the same subsidiary (e.g., "hp"). Corporate departments
                     auto-resolve.

        Returns:
            JSON with the relationship from both perspectives.
        """
        key_a, info_a = _resolve_agent(agents, department_a, company)
        key_b, info_b = _resolve_agent(agents, department_b, company)

        if info_a is None:
            return _format({"error": f"Department '{department_a}' not found"})
        if info_b is None:
            return _format({"error": f"Department '{department_b}' not found"})

        dept_b_lower = info_b["department"].lower()
        a_to_b = None
        for rel in info_a["relationships"]:
            if dept_b_lower in rel["department"].lower():
                a_to_b = rel["interaction"]
                break

        dept_a_lower = info_a["department"].lower()
        b_to_a = None
        for rel in info_b["relationships"]:
            if dept_a_lower in rel["department"].lower():
                b_to_a = rel["interaction"]
                break

        return _format(
            {
                "agent_a": {
                    "key": key_a,
                    "company": info_a["company"],
                    "agent_name": info_a["agent_name"],
                },
                "agent_b": {
                    "key": key_b,
                    "company": info_b["company"],
                    "agent_name": info_b["agent_name"],
                },
                f"{info_a['department']}_perspective": a_to_b
                or "No direct relationship documented",
                f"{info_b['department']}_perspective": b_to_a
                or "No direct relationship documented",
            }
        )

    # ── Standards tools ──────────────────────────────────────────

    @mcp.tool()
    @audit_logged(audit)
    async def agency_find_by_standard(standard: str) -> str:
        """Find which agents deal with a specific standard or regulation.

        Searches the standards index for exact and partial matches.

        Args:
            standard: Standard identifier (e.g., "AS9100", "ITAR", "ISO 13485",
                      "CMMC", "FDA 21 CFR Part 11").

        Returns:
            JSON with matching agents and the standards they reference.
        """
        std_lower = standard.lower()
        exact_matches: list[dict] = []
        partial_matches: list[dict] = []

        for std_key, agent_entries in standards_index.items():
            if std_lower == std_key.lower():
                exact_matches.append(
                    {
                        "standard": std_key,
                        "agents": agent_entries,
                    }
                )
            elif std_lower in std_key.lower() or std_key.lower() in std_lower:
                partial_matches.append(
                    {
                        "standard": std_key,
                        "agents": agent_entries,
                    }
                )

        return _format(
            {
                "query": standard,
                "exact_matches": exact_matches,
                "partial_matches": partial_matches[:20],
                "total_standards_indexed": len(standards_index),
            }
        )
