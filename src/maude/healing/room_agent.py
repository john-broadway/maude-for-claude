"""Room Agent — LLM-powered brain inside Maude.

Layer 2 intelligence: sits between the rule-based Health Loop (Layer 1)
and interactive Claude Code (Layer 3). Triggered by events or schedule,
reasons about the situation using tools, and stores what it learns.

The agent loop:
1. Load Tier 1 knowledge (.md files) → compose system prompt
2. Query Tier 2 (PostgreSQL) for recent activity context
3. Query Tier 3 (Qdrant) for semantically similar past situations
4. Build enriched context → send to LLM with tools
5. Tool-use conversation loop: send → tool_calls → execute → feed back → repeat
6. After completion: store memory (PostgreSQL + Qdrant), update .md if significant
7. Optionally commit + push knowledge updates to Gitea

Usage:
    agent = RoomAgent(config, llm_router, tool_registry, memory_store, knowledge_manager)
    result = await agent.run("Health loop escalation: service not responding after restart")
"""

import asyncio
import json
import logging
import re
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any

from maude.healing.tool_registry import ToolRegistry
from maude.llm.quality import check_output_quality
from maude.llm.router import LLMRouter
from maude.memory.knowledge import KnowledgeManager
from maude.memory.store import MemoryStore

logger = logging.getLogger(__name__)


@dataclass
class RoomAgentConfig:
    """Configuration for a Room Agent."""

    project: str = ""
    name: str = ""
    max_iterations: int = 10
    scheduled_max_iterations: int = 10
    max_tokens: int = 4096
    token_budget: int = 0  # Cumulative completion token cap per run (0 = unlimited)
    velocity_threshold: int = 200  # Min completion tokens per iteration before diminishing flag
    tool_timeouts: dict[str, float] = field(default_factory=dict)  # Per-tool timeout overrides
    default_tool_timeout: float = 60.0  # Default timeout for tools without overrides
    memory_cache_ttl: float = 3600.0
    tools: list[str] = field(default_factory=list)
    scheduled_tools: list[str] = field(default_factory=list)
    memory: dict[str, Any] = field(default_factory=dict)
    llm: dict[str, Any] = field(default_factory=dict)
    git: dict[str, Any] = field(default_factory=dict)
    triggers: list[dict[str, Any]] = field(default_factory=list)
    enabled: bool = False
    self_healing: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "RoomAgentConfig":
        if not data:
            return cls()
        return cls(
            project=data.get("name", ""),
            name=data.get("name", ""),
            max_iterations=data.get("max_iterations", 10),
            scheduled_max_iterations=data.get("scheduled_max_iterations", 10),
            max_tokens=data.get("max_tokens", 4096),
            token_budget=data.get("token_budget", 0),
            velocity_threshold=data.get("velocity_threshold", 200),
            tool_timeouts=data.get("tool_timeouts", {}),
            default_tool_timeout=data.get("default_tool_timeout", 60.0),
            memory_cache_ttl=data.get("memory_cache_ttl", 3600.0),
            tools=data.get("tools", []),
            scheduled_tools=data.get("scheduled_tools", []),
            memory=data.get("memory", {}),
            llm=data.get("llm", {}),
            git=data.get("git", {}),
            triggers=data.get("triggers", []),
            enabled=data.get("enabled", False),
            self_healing=data.get("self_healing", {}),
        )


@dataclass
class _VelocityTracker:
    """Tracks per-iteration completion token velocity for diminishing returns detection.

    Inspired by Claude Code's tokenBudget.ts — detects when an agent is
    spinning without producing meaningful output by tracking output token
    deltas across iterations.
    """

    iteration_completions: list[int] = field(default_factory=list)
    cumulative_completions: int = 0

    def record(self, completion_tokens: int) -> None:
        """Record completion tokens from one iteration."""
        tokens = completion_tokens if isinstance(completion_tokens, int) else 0
        self.iteration_completions.append(tokens)
        self.cumulative_completions += tokens

    def is_diminishing(self, threshold: int, min_iterations: int = 3) -> bool:
        """True if last 2 iterations both produced below-threshold output.

        Only activates after ``min_iterations`` to let the agent ramp up.
        Skips check when the backend doesn't report completion tokens
        (all zeros means no data, not zero output).
        """
        if len(self.iteration_completions) < min_iterations:
            return False
        # If no backend reports completion tokens, we have no velocity data
        if self.cumulative_completions == 0:
            return False
        return (
            self.iteration_completions[-1] < threshold
            and self.iteration_completions[-2] < threshold
        )

    def exceeds_budget(self, budget: int) -> bool:
        """True if cumulative completion tokens exceed the budget (0 = unlimited)."""
        return budget > 0 and self.cumulative_completions >= budget


@dataclass
class AgentResult:
    """Result of a Room Agent run."""

    success: bool = False
    summary: str = ""
    actions: list[dict[str, Any]] = field(default_factory=list)
    iterations: int = 0
    tokens_used: int = 0
    completion_tokens: int = 0  # Output tokens only (for velocity analysis)
    model: str = ""
    outcome: str = ""  # "resolved", "escalated", "failed", "no_action", "diminishing_returns"
    escalated: bool = False  # True if T4 escalation to Claude was used
    diminishing_returns: bool = False  # True if stopped due to low token velocity


class RoomAgent:
    """LLM-powered agent that runs inside a Maude MCP daemon.

    Args:
        config: Agent configuration.
        llm: LLM router for sending messages.
        tools: Tool registry for invoking MCP tools.
        memory: Memory store for PostgreSQL + Qdrant.
        knowledge: Knowledge manager for .md files + git.
    """

    def __init__(
        self,
        config: RoomAgentConfig,
        llm: LLMRouter,
        tools: ToolRegistry,
        memory: MemoryStore,
        knowledge: KnowledgeManager,
        event_publisher: Any | None = None,
    ) -> None:
        self.config = config
        self.llm = llm
        self.tools = tools
        self.memory = memory
        self.knowledge = knowledge
        self._event_publisher = event_publisher
        self._progress_tracker: Any = None  # Optional ProgressTracker

        # Memory cache for scheduled checks — avoids redundant PG queries
        self._memory_cache: str = ""
        self._memory_cache_expires: float = 0.0
        # Relevance filter cache: LRU bounded, trigger_hash → (expires, relevant IDs)
        self._relevance_cache: OrderedDict[str, tuple[float, set[int | None]]] = OrderedDict()
        self._relevance_cache_max = 20

    def set_progress_tracker(self, tracker: Any) -> None:
        """Attach a ProgressTracker for tool execution observability."""
        self._progress_tracker = tracker

    # ── Iteration threshold for upgrading to complex model ──────
    _COMPLEX_ITERATION_THRESHOLD = 3

    # ── Context size threshold for switching to RAG retrieval ──
    _RAG_CONTEXT_THRESHOLD = 12000  # characters

    # ── Relevance filter settings ──
    _RELEVANCE_FILTER_MAX_CANDIDATES = 15  # Don't filter if fewer candidates
    _RELEVANCE_FILTER_MAX_KEEP = 5  # Keep at most this many relevant memories
    _RELEVANCE_CACHE_TTL = 3600.0  # 1 hour cache

    async def consult_room(self, room: str, query: str) -> str:
        """Query another Room's memory via its memory_recall_similar MCP endpoint.

        Read-only: retrieves semantically similar memories from the target room
        but never takes action on it. Used for cross-room knowledge sharing.

        Args:
            room: Target room project name (e.g., "example-scada", "postgresql").
            query: The situation to search for in the target room's memory.

        Returns:
            Formatted context string from the target room, or empty string on failure.
        """
        try:
            result = await self.tools.call(
                "memory_recall_similar",
                project=room,
                query=query,
                limit=3,
            )
            if not result:
                return ""

            # Format the consultation result
            lines = [f"## Consultation: {room}"]
            # result may be JSON string from MCP tool
            if isinstance(result, str):
                try:
                    memories = json.loads(result)
                    if isinstance(memories, list):
                        for m in memories[:3]:
                            summary = m.get("summary", str(m))
                            outcome = m.get("outcome", "")
                            lines.append(f"- {summary} (outcome={outcome})")
                    else:
                        lines.append(f"- {result[:500]}")
                except (json.JSONDecodeError, TypeError):
                    lines.append(f"- {result[:500]}")
            return "\n".join(lines)
        except Exception:
            logger.debug(
                "RoomAgent[%s]: consult_room(%s) failed (non-fatal)",
                self.config.project,
                room,
            )
            return ""

    async def run(self, trigger: str, context: dict[str, Any] | None = None) -> AgentResult:
        """Execute the agent loop for a given trigger.

        Args:
            trigger: What triggered this run (e.g., "health_loop_escalation").
            context: Optional additional context (e.g., health status dict).

        Returns:
            AgentResult with summary, actions taken, and outcome.
        """
        try:
            is_scheduled = trigger == "scheduled_check"
            full_system, tool_schemas = await self._prepare_context(
                trigger,
                is_scheduled,
                context,
            )
            result, messages = await self._run_llm_loop(
                trigger,
                context,
                full_system,
                tool_schemas,
                is_scheduled,
            )
            # Invalidate caches BEFORE persist — state is about to change.
            # Placed here (not in _persist_memory) so caches clear even if
            # persist fails.
            self._memory_cache = ""
            self._memory_cache_expires = 0.0
            self._relevance_cache.clear()
            await self._store_result(trigger, result, context, messages=messages)
            return result
        except Exception:
            logger.exception("RoomAgent[%s]: Unhandled error during run", self.config.project)
            return AgentResult(
                outcome="failed",
                summary="Unhandled exception during agent run",
            )

    # ── Context preparation ────────────────────────────────────────

    async def _prepare_context(
        self,
        trigger: str,
        is_scheduled: bool,
        context: dict[str, Any] | None = None,
    ) -> tuple[str, list[dict[str, Any]]]:
        """Prepare system prompt and tool schemas for the agent loop.

        For scheduled checks: builds a slim prompt with optional cached memory.
        For interactive runs: loads full knowledge (or RAG), enriches with
        Tier 2 + Tier 3 context, and composes the full system prompt.

        Returns:
            Tuple of (full_system_prompt, tool_schemas).
        """
        tool_schemas: list[dict[str, Any]] = []

        # Pull latest knowledge from git
        await self.knowledge.git_pull()

        if is_scheduled:
            sched_tools = self.config.scheduled_tools or self.config.tools
            tool_schemas = await self.tools.get_tool_schemas(
                allowed_tools=sched_tools if sched_tools else None,
            )
            tool_names = [t["name"] for t in tool_schemas] if tool_schemas else []

            run_reason = (context or {}).get("run_reason", "")

            # Custom models (e.g., example-agent) have identity + instructions
            # baked into the Modelfile SYSTEM. Only send the tool list supplement.
            if self._is_custom_model():
                full_system = self._compose_custom_scheduled_system(
                    tool_names,
                    run_reason,
                )
            else:
                full_system = self._compose_scheduled_system(tool_names, run_reason)

            # Memory enrichment: escalations get fresh Tier 2, routine checks
            # use cached context (zero I/O if warm)
            is_escalation = "escalation" in trigger or "rate_limited" in trigger
            if is_escalation:
                recent_context = await self._build_recent_context()
                self._update_memory_cache(recent_context)
            else:
                recent_context = self._get_cached_memory()

            if recent_context:
                full_system = f"{full_system}\n\n{recent_context}"
        else:
            # Compose system prompt from Tier 1 (.md files)
            system_prompt = await self.knowledge.load_knowledge()

            # Phase 3E: If full knowledge exceeds RAG threshold, switch to
            # retrieval-based context instead of loading all files.
            if len(system_prompt) > self._RAG_CONTEXT_THRESHOLD:
                rag_chunks = await self.knowledge.retrieve_relevant(
                    trigger,
                    self.config.project,
                    limit=3,
                )
                if rag_chunks:
                    # Use identity.md + relevant chunks instead of full knowledge
                    identity_path = self.knowledge.knowledge_dir / "identity.md"
                    identity = identity_path.read_text() if identity_path.exists() else ""
                    chunk_text = "\n\n".join(
                        f"### {c['heading']} ({c['source']})\n{c['content']}" for c in rag_chunks
                    )
                    system_prompt = (
                        f"# Identity\n\n{identity}\n\n"
                        f"# Relevant Knowledge (RAG top-{len(rag_chunks)})\n\n{chunk_text}"
                    )

            # Enrich with Tier 2 (recent memories from PostgreSQL)
            recent_memories = await self._recall_recent_memories()
            # Enrich with Tier 3 (similar memories from Qdrant)
            similar_memories, similar_unavailable = await self._recall_similar_memories(trigger)

            # LLM-driven relevance filtering (inspired by Claude Code's
            # findRelevantMemories.ts — uses a sidequery to select which
            # memories are worth injecting into the agent's context)
            all_candidates = recent_memories + similar_memories
            if len(all_candidates) > self._RELEVANCE_FILTER_MAX_CANDIDATES:
                relevant_ids = await self._select_relevant_memories(trigger, all_candidates)
                if relevant_ids is not None:
                    recent_memories = [m for m in recent_memories if m.id in relevant_ids]
                    similar_memories = [m for m in similar_memories if m.id in relevant_ids]

            recent_context = self._format_recent_context(recent_memories)
            similar_context = self._format_similar_context(
                similar_memories,
                similar_unavailable,
                trigger,
            )

            # Cross-room pattern library (separate from per-room similar memories)
            pattern_context = await self._fetch_pattern_library(trigger)
            if pattern_context:
                similar_context = (
                    f"{similar_context}\n\n{pattern_context}"
                    if similar_context
                    else pattern_context
                )

            # Warm the cache for subsequent scheduled checks
            self._update_memory_cache(recent_context)

            # Build the full system prompt
            full_system = self._compose_system(system_prompt, recent_context, similar_context)

            tool_schemas = await self.tools.get_tool_schemas(
                allowed_tools=self.config.tools if self.config.tools else None,
            )

        return full_system, tool_schemas

    # ── LLM conversation loop ──────────────────────────────────────

    async def _run_llm_loop(
        self,
        trigger: str,
        context: dict[str, Any] | None,
        full_system: str,
        tool_schemas: list[dict[str, Any]],
        is_scheduled: bool,
    ) -> tuple[AgentResult, list[dict[str, Any]]]:
        """Run the LLM conversation loop with tool execution.

        Sends messages to the LLM, processes tool calls, handles T4 escalation,
        and enforces scheduled check constraints.

        Returns:
            Tuple of (result, messages).
        """
        result = AgentResult()
        actions: list[dict[str, Any]] = []
        total_tokens = 0
        velocity = _VelocityTracker()

        if is_scheduled:
            run_reason = (context or {}).get("run_reason", "")
            if run_reason == "layer1_issues":
                max_tokens = 2048
            elif run_reason == "deep_check":
                max_tokens = 1024
            else:
                max_tokens = 512
        else:
            max_tokens = self.config.max_tokens
        max_iters = (
            self.config.scheduled_max_iterations if is_scheduled else self.config.max_iterations
        )
        user_msg = self._compose_trigger_message(trigger, context)
        messages: list[dict[str, Any]] = [{"role": "user", "content": user_msg}]
        escalated = False

        for iteration in range(max_iters):
            result.iterations = iteration + 1

            if escalated:
                response = await self.llm.send_to_fallback(
                    messages=messages,
                    tools=tool_schemas if tool_schemas else None,
                    max_tokens=max_tokens,
                    system=full_system,
                )
            elif not is_scheduled and iteration >= self._COMPLEX_ITERATION_THRESHOLD:
                # Phase 3A: Upgrade to complex tier when stuck
                response = await self.llm.send_complex(
                    messages=messages,
                    tools=tool_schemas if tool_schemas else None,
                    max_tokens=max_tokens,
                    system=full_system,
                )
            else:
                # Force tool call on first iteration of scheduled checks
                tool_choice = (
                    "required" if is_scheduled and iteration == 0 and tool_schemas else None
                )
                response = await self.llm.send(
                    messages=messages,
                    tools=tool_schemas if tool_schemas else None,
                    max_tokens=max_tokens,
                    system=full_system,
                    tool_choice=tool_choice,
                )

            if response is None:
                logger.error("RoomAgent: LLM returned None — all backends failed")
                result.outcome = "failed"
                result.summary = "All LLM backends unavailable"
                break

            total_tokens += response.tokens_used
            velocity.record(response.completion_tokens)
            result.model = response.model

            # No tool calls — agent is done
            if not response.tool_calls:
                # Strip think tags before parsing structured response
                clean_content = self._strip_think_tags(response.content or "")

                # Quality gate — reject degenerate LLM output
                quality = check_output_quality(clean_content)
                if not quality.passed:
                    logger.warning(
                        "RoomAgent[%s]: Quality gate rejected LLM output "
                        "(flags=%s, score=%.2f, model=%s)",
                        self.config.project,
                        quality.flags,
                        quality.score,
                        response.model,
                    )
                    try:
                        from maude.daemon.metrics import get_metrics

                        get_metrics().quality_rejections.labels(
                            project=self.config.project, model=response.model
                        ).inc()
                    except Exception:
                        pass
                    result.outcome = "failed"
                    result.summary = f"LLM output failed quality gate: {quality.detail}"
                    result.model = response.model
                    break

                # Try structured tags first
                parsed_summary, parsed_outcome = self._parse_structured_response(clean_content)

                # T4 Escalation: vLLM says it needs help → hand off to Claude
                if parsed_outcome == "escalated" and not escalated and self.llm.can_escalate:
                    escalated = True
                    logger.info(
                        "RoomAgent[%s]: T4 escalation — handing off to Claude",
                        self.config.project,
                    )
                    messages.append(
                        {
                            "role": "assistant",
                            "content": response.content,
                        }
                    )
                    messages.append(
                        {
                            "role": "user",
                            "content": (
                                "The local model could not resolve this and has escalated to you. "
                                "Review what was tried above, then use the available tools to "
                                "diagnose and fix the issue. End with <summary> and <outcome> tags."
                            ),
                        }
                    )
                    continue  # next iteration uses Claude

                raw_content = clean_content[:2000]
                result.summary = parsed_summary or raw_content

                if parsed_outcome:
                    result.outcome = parsed_outcome
                elif actions:
                    # Tools were called in earlier iterations — trust the flow
                    result.outcome = "resolved"
                elif response.content:
                    # No tools ever called — cannot claim "resolved"
                    result.outcome = "no_action"
                else:
                    result.outcome = "no_action"
                break

            # Process tool calls
            # Add assistant message with tool calls to conversation
            assistant_msg: dict[str, Any] = {
                "role": "assistant",
                "content": response.content,
                "tool_calls": [
                    {"id": tc.id, "name": tc.name, "arguments": tc.arguments}
                    for tc in response.tool_calls
                ],
            }
            messages.append(assistant_msg)

            # Execute tool calls — read-only tools run concurrently,
            # write tools run sequentially (inspired by Claude Code's
            # StreamingToolExecutor concurrency safety classification)
            read_only_calls = [tc for tc in response.tool_calls if self.tools.is_read_only(tc.name)]
            write_calls = [tc for tc in response.tool_calls if not self.tools.is_read_only(tc.name)]

            # Phase 1: concurrent read-only tools
            if read_only_calls:
                read_results = await asyncio.gather(
                    *(self._execute_tool(tc) for tc in read_only_calls),
                )
                for tc, tool_result in zip(read_only_calls, read_results):
                    actions.append(
                        {
                            "tool": tc.name,
                            "arguments": tc.arguments,
                            "result": tool_result[:500] if tool_result else "",
                        }
                    )
                    messages.append(
                        {
                            "role": "user",
                            "content": [
                                {
                                    "type": "tool_result",
                                    "tool_use_id": tc.id,
                                    "content": tool_result or "",
                                },
                            ],
                        }
                    )

            # Phase 2: sequential write tools
            for tc in write_calls:
                tool_result = await self._execute_tool(tc)
                actions.append(
                    {
                        "tool": tc.name,
                        "arguments": tc.arguments,
                        "result": tool_result[:500] if tool_result else "",
                    }
                )
                messages.append(
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": tc.id,
                                "content": tool_result or "",
                            },
                        ],
                    }
                )

            # Velocity checks — detect spinning before hitting max iterations
            if velocity.exceeds_budget(self.config.token_budget):
                logger.info(
                    "RoomAgent[%s]: Token budget exhausted (%d/%d completion tokens)",
                    self.config.project,
                    velocity.cumulative_completions,
                    self.config.token_budget,
                )
                result.outcome = "diminishing_returns"
                result.diminishing_returns = True
                result.summary = (
                    f"Token budget exhausted ({velocity.cumulative_completions} "
                    f"completion tokens used, budget={self.config.token_budget})"
                )
                break

            if velocity.is_diminishing(self.config.velocity_threshold):
                last_two = velocity.iteration_completions[-2:]
                logger.info(
                    "RoomAgent[%s]: Diminishing returns — last 2 iterations "
                    "produced %d and %d tokens (threshold=%d)",
                    self.config.project,
                    last_two[0],
                    last_two[1],
                    self.config.velocity_threshold,
                )
                result.outcome = "diminishing_returns"
                result.diminishing_returns = True
                result.summary = (
                    f"Diminishing returns after {iteration + 1} iterations "
                    f"(last outputs: {last_two[0]}, {last_two[1]} tokens)"
                )
                break

            # Check if we've hit max iterations
            if iteration == max_iters - 1:
                logger.warning(
                    "RoomAgent[%s]: Hit max iterations (%d)",
                    self.config.project,
                    max_iters,
                )
                result.outcome = "escalated"
                result.summary = f"Max iterations reached ({max_iters})"

        result.actions = actions
        result.tokens_used = total_tokens
        result.completion_tokens = velocity.cumulative_completions
        result.escalated = escalated

        # Enforce tool use on scheduled checks — text-only "no_action" is suspicious
        if is_scheduled and len(actions) == 0 and result.outcome == "no_action":
            logger.warning(
                "RoomAgent[%s]: Scheduled check completed with no tool calls — marking failed",
                self.config.project,
            )
            result.outcome = "failed"
            result.summary = "No diagnostic tools called during scheduled check"

        result.success = result.outcome in (
            "resolved",
            "no_action",
            "remediated",
            "trend_warning",
        )

        return result, messages

    # ── Tool execution ─────────────────────────────────────────────

    async def _execute_tool(self, tc: Any) -> str:
        """Execute a single tool call with per-tool timeout and progress tracking.

        Timeout resolution: tool_timeouts[name] > default_tool_timeout > 60s.
        Progress tracking: emits start/running/complete events via the
        optional ProgressTracker (set via ``set_progress_tracker``).
        """
        timeout = self.config.tool_timeouts.get(tc.name, self.config.default_tool_timeout)
        logger.info(
            "RoomAgent[%s]: Calling %s(%s)",
            self.config.project,
            tc.name,
            json.dumps(tc.arguments, default=str)[:200],
        )
        try:
            if self._progress_tracker:
                async with self._progress_tracker.track(tc.name):
                    return await asyncio.wait_for(
                        self.tools.call(tc.name, **tc.arguments),
                        timeout=timeout,
                    )
            else:
                return await asyncio.wait_for(
                    self.tools.call(tc.name, **tc.arguments),
                    timeout=timeout,
                )
        except asyncio.TimeoutError:
            logger.warning(
                "RoomAgent[%s]: Tool %s timed out after %.0fs",
                self.config.project,
                tc.name,
                timeout,
            )
            return json.dumps({"error": f"Tool '{tc.name}' timed out after {timeout:.0f}s"})

    # ── Prompt composition helpers ─────────────────────────────────

    def _compose_scheduled_system(
        self,
        tool_names: list[str],
        run_reason: str = "",
    ) -> str:
        """Compose a system prompt for scheduled checks.

        The prompt adapts to *why* the check is running:
        - layer1_issues: Layer 1 detected problems — investigate and fix
        - deep_check: periodic proactive scan — look for developing problems
        - startup / other: baseline health check
        """
        tools_list = ", ".join(tool_names) if tool_names else "none"
        header = (
            f"You are a health-check agent for {self.config.project}. "
            f"Service: {self.config.name}.\n"
            f"Available tools: {tools_list}\n\n"
        )

        if run_reason == "layer1_issues":
            instructions = (
                "Layer 1 (health loop) detected issues — see context for details.\n"
                "Your job is DEEPER ANALYSIS, not just re-checking health.\n\n"
                "1. Call service_logs to find error patterns and root cause.\n"
                "2. Call service_health to verify current state.\n"
                "3. If you can fix the issue, do it:\n"
                "   - service_restart for crashed/stuck services\n"
                "   - service_log_cleanup for disk pressure from logs\n"
                "4. After fixing, call service_health again to VERIFY the fix worked.\n\n"
                "Use 'remediated' when you fixed AND verified.\n"
                "Use 'failed' when you tried and it didn't work.\n"
                "Do NOT report 'no_action' when there are known issues."
            )
        elif run_reason == "deep_check":
            instructions = (
                "Proactive deep check — scan for developing problems.\n\n"
                "1. Call service_logs to look for warning patterns, slow queries, "
                "or recurring errors that haven't triggered alerts yet.\n"
                "2. Call service_trends to check resource trajectories "
                "(disk filling, memory climbing).\n"
                "3. If you find actionable issues, fix them now:\n"
                "   - service_log_cleanup for growing log files\n"
                "   - service_restart for degraded performance\n"
                "4. Report only actionable findings. If everything is clean, "
                "say so briefly.\n\n"
                "Use 'remediated' if you took preventive action and verified.\n"
                "Use 'no_action' only when nothing needs attention."
            )
        else:
            instructions = (
                "Baseline health check.\n\n"
                "1. Call service_health to check current state.\n"
                "2. If unhealthy, call service_logs for error patterns, "
                "then attempt to fix.\n"
                "3. If healthy, respond briefly.\n\n"
                "Use 'no_action' when healthy. "
                "Use 'remediated' if you fixed something."
            )

        return (
            f"{header}"
            f"Instructions:\n{instructions}\n\n"
            "End your response with exactly:\n"
            "<summary>one sentence</summary>\n"
            "<outcome>resolved|remediated|failed|no_action|trend_warning</outcome>\n\n"
            "Outcome guide:\n"
            "- trend_warning: Use when you detect a developing concern not yet critical "
            "but worth tracking.\n\n"
            "Always respond in English."
        )

    def _compose_custom_scheduled_system(
        self,
        tool_names: list[str],
        run_reason: str = "",
    ) -> str:
        """Scheduled prompt for custom models with baked-in identity."""
        tools_str = ", ".join(tool_names)
        if run_reason == "layer1_issues":
            task = (
                "Layer 1 detected issues. Investigate with service_logs, "
                "diagnose root cause, fix if possible, then verify."
            )
        elif run_reason == "deep_check":
            task = (
                "Proactive deep check. Scan service_logs for warnings, "
                "check service_trends for resource trajectories. "
                "Fix developing problems before they escalate."
            )
        else:
            task = "Baseline check: call service_health, report briefly."
        return (
            f"Available tools: {tools_str}\n\n"
            f"{task}\n"
            "Always respond in English. End with <summary> and <outcome> tags."
        )

    def _is_custom_model(self) -> bool:
        """Check if the configured model is a custom per-room model.

        With vLLM, custom models follow the ``{project}-agent`` naming
        convention (LoRA adapters). System prompts are now passed at runtime.
        """
        model_name = self.config.llm.get("vllm", {}).get("model", "")
        return model_name.endswith("-agent")

    def _get_cached_memory(self) -> str:
        """Return cached Tier 2 context if TTL hasn't expired, else empty."""
        if self._memory_cache and time.monotonic() < self._memory_cache_expires:
            return self._memory_cache
        return ""

    def _update_memory_cache(self, context: str) -> None:
        """Store context in the memory cache with TTL."""
        self._memory_cache = context
        self._memory_cache_expires = time.monotonic() + self.config.memory_cache_ttl

    async def _build_recent_context(self) -> str:
        """Recall + format recent memories (used by the scheduled check path)."""
        memories = await self._recall_recent_memories()
        return self._format_recent_context(memories)

    async def _build_similar_context(self, trigger: str) -> str:
        """Recall + format similar memories (convenience wrapper)."""
        memories, unavailable = await self._recall_similar_memories(trigger)
        ctx = self._format_similar_context(memories, unavailable, trigger)
        pattern_ctx = await self._fetch_pattern_library(trigger)
        if pattern_ctx:
            ctx = f"{ctx}\n\n{pattern_ctx}" if ctx else pattern_ctx
        return ctx

    # ── Memory recall (raw objects) ─────────────────────────────────

    async def _recall_recent_memories(self) -> list[Any]:
        """Query Tier 2 for recent Memory objects."""
        mem_config = self.config.memory
        if not mem_config.get("postgresql"):
            return []
        limit = mem_config.get("recent_limit", 10)
        memories = await self.memory.recall_recent(self.config.project, limit=limit)
        return memories or []

    async def _recall_similar_memories(self, trigger: str) -> tuple[list[Any], bool]:
        """Query Tier 3 for similar Memory objects.

        Returns:
            Tuple of (memories, unavailable). unavailable=True when Qdrant
            is down (allows callers to show a note in context).
        """
        mem_config = self.config.memory
        if not mem_config.get("qdrant"):
            return [], False
        limit = mem_config.get("similar_limit", 5)
        memories = await self.memory.recall_similar(self.config.project, trigger, limit=limit)
        if memories is None:
            return [], True  # Qdrant unavailable
        return memories, False

    # ── Memory formatting ────────────────────────────────────────────

    @staticmethod
    def _format_recent_context(memories: list[Any]) -> str:
        """Format recent Memory objects into a context string."""
        if not memories:
            return ""
        lines = ["## Recent Activity"]
        for m in memories:
            ts = m.created_at.isoformat() if m.created_at else "unknown"
            lines.append(f"- [{ts}] [{m.memory_type}] {m.summary} → {m.outcome}")
        return "\n".join(lines)

    @staticmethod
    def _format_similar_context(
        memories: list[Any],
        unavailable: bool,
        trigger: str,
    ) -> str:
        """Format similar Memory objects into context string."""
        parts: list[str] = []

        if unavailable:
            parts.append(
                "## Similar Past Situations\n- (Qdrant unavailable — semantic recall skipped)"
            )
        elif memories:
            lines = ["## Similar Past Situations"]
            for m in memories:
                if m.memory_type == "remediation" and m.actions_taken:
                    tools_used = ", ".join(a.get("tool", "?") for a in m.actions_taken[:3])
                    lines.append(f"- (score={m.score:.2f}) FIXED: {m.summary} [via {tools_used}]")
                else:
                    lines.append(f"- (score={m.score:.2f}) {m.summary} → {m.outcome}")
            parts.append("\n".join(lines))

        return "\n\n".join(parts)

    async def _fetch_pattern_library(self, trigger: str) -> str:
        """Fetch cross-room fix patterns from the shared Pattern Library."""
        mem_config = self.config.memory
        if not mem_config.get("qdrant"):
            return ""
        try:
            from maude.healing.pattern_library import PatternLibrary

            library = PatternLibrary()
            try:
                patterns = await library.find_pattern(trigger, room=self.config.project)
                if patterns:
                    lines = ["## Cross-Room Patterns"]
                    for p in patterns[:3]:
                        rooms_str = ", ".join(p.applicable_rooms) if p.applicable_rooms else "all"
                        lines.append(
                            f"- [{p.source_room}] {p.trigger_signature} → {p.resolution} "
                            f"(success={p.success_count}, rooms={rooms_str})"
                        )
                    return "\n".join(lines)
            finally:
                await library.close()
        except Exception:
            logger.debug("Pattern library lookup failed (non-fatal)")
        return ""

    # ── LLM-driven memory relevance filtering ────────────────────────

    _RELEVANCE_SYSTEM = (
        "You are selecting which memories are relevant to a Room Agent's "
        "current investigation. Given the trigger and a numbered list of "
        "memory summaries, return ONLY the numbers of memories that will "
        "clearly help diagnose or resolve the current situation.\n\n"
        "Rules:\n"
        "- Be selective — only include memories you are certain are relevant\n"
        "- Prefer memories with successful resolutions for similar triggers\n"
        "- Skip routine health checks unless they show a pattern\n"
        "- Return at most 5 numbers\n"
        "- If nothing is relevant, return an empty list\n\n"
        'Respond with ONLY a JSON object: {"selected": [1, 3, 5]}'
    )

    async def _select_relevant_memories(
        self,
        trigger: str,
        candidates: list[Any],
    ) -> set[int | None] | None:
        """Use a lightweight L1 LLM sidequery to filter relevant memories.

        Inspired by Claude Code's findRelevantMemories.ts — asks the LLM
        which candidate memories are worth injecting into the agent's context.

        Returns:
            Set of Memory.id values for relevant memories, or None if the
            sidequery fails (caller should use all candidates as fallback).
        """
        if not candidates:
            return set()

        # Check cache (per-entry TTL, LRU bounded)
        cache_key = trigger[:200]
        cached = self._relevance_cache.get(cache_key)
        if cached is not None:
            expires_at, ids = cached
            if time.monotonic() < expires_at:
                self._relevance_cache.move_to_end(cache_key)
                return ids
            else:
                del self._relevance_cache[cache_key]

        # Build numbered manifest
        manifest_lines: list[str] = []
        id_map: dict[int, int | None] = {}  # manifest_number → Memory.id
        for i, m in enumerate(candidates, 1):
            id_map[i] = m.id
            manifest_lines.append(f"{i}. [{m.memory_type}] {m.summary[:150]} → {m.outcome}")
        manifest = "\n".join(manifest_lines)

        try:
            response = await self.llm.send(
                messages=[
                    {
                        "role": "user",
                        "content": (f"Trigger: {trigger}\n\nCandidate memories:\n{manifest}"),
                    }
                ],
                max_tokens=128,
                system=self._RELEVANCE_SYSTEM,
            )

            if not response or not response.content:
                return None

            # Parse JSON response
            content = self._strip_think_tags(response.content)
            # Extract JSON from response (may have surrounding text)
            import re as _re

            json_match = _re.search(r"\{[^}]*\}", content)
            if not json_match:
                return None

            parsed = json.loads(json_match.group())
            selected_nums = parsed.get("selected", [])

            if not isinstance(selected_nums, list):
                return None

            relevant_ids: set[int | None] = set()
            for num in selected_nums[: self._RELEVANCE_FILTER_MAX_KEEP]:
                if isinstance(num, int) and num in id_map:
                    relevant_ids.add(id_map[num])

            # Cache the result (LRU eviction at max size)
            self._relevance_cache[cache_key] = (
                time.monotonic() + self._RELEVANCE_CACHE_TTL,
                relevant_ids,
            )
            if len(self._relevance_cache) > self._relevance_cache_max:
                self._relevance_cache.popitem(last=False)

            logger.info(
                "RoomAgent[%s]: Relevance filter — %d/%d memories selected",
                self.config.project,
                len(relevant_ids),
                len(candidates),
            )
            return relevant_ids

        except Exception:
            logger.debug(
                "RoomAgent[%s]: Relevance filter failed (non-fatal, using all candidates)",
                self.config.project,
            )
            return None

    def _compose_system(
        self,
        base_knowledge: str,
        recent_context: str,
        similar_context: str,
    ) -> str:
        """Compose the full system prompt."""
        parts = [base_knowledge]
        if recent_context:
            parts.append(recent_context)
        if similar_context:
            parts.append(similar_context)

        parts.append(
            "## Instructions\n"
            "You are a Room Agent — an autonomous LLM brain inside a Maude MCP daemon. "
            "You have access to tools for diagnosing and resolving issues. "
            "Use tools to gather information, reason about the situation, and take action. "
            "If you cannot resolve the issue, clearly state what needs human attention. "
            "Be concise. Prefer diagnostic tools before write tools. "
            "Never restart a service without first checking what's wrong.\n\n"
            "After completing your analysis, end your response with exactly:\n"
            "<summary>1-2 sentence summary of what happened and what you did</summary>\n"
            "<outcome>resolved|failed|escalated|no_action|remediated</outcome>\n\n"
            "Rules:\n"
            '- "resolved" = you diagnosed the issue AND took corrective action that succeeded\n'
            '- "remediated" = you diagnosed, took corrective action, '
            "AND verified the fix succeeded\n"
            '- "failed" = you could not diagnose or fix the issue\n'
            '- "escalated" = you cannot diagnose or fix this with your current capabilities '
            "and need a more capable model to take over. Only use this if you genuinely "
            "need help — do not escalate routine checks\n"
            '- "no_action" = everything is healthy, no action needed\n'
            "- Always try at least one diagnostic tool before concluding\n"
            '- Do not claim "resolved" if your tools returned errors\n'
            "- Always respond in English"
        )

        parts.append(
            "## Self-Healing Protocol\n"
            "You are authorized to take corrective action autonomously. "
            "Follow this cycle:\n\n"
            "1. DIAGNOSE — Use diagnostic tools to understand the problem\n"
            "2. FIX — Take the corrective action "
            "(restart service, clear state, adjust config)\n"
            "3. VERIFY — Re-run diagnostics to confirm the fix worked\n\n"
            'Use outcome "remediated" when all three steps succeed. '
            'If verification fails after fixing, report "failed" with what you tried.\n\n'
            "If you have seen a similar problem before (check Similar Past Situations above), "
            "apply the same fix that worked previously.\n\n"
            "Rules:\n"
            "- Always verify. A fix without verification is not a remediation.\n"
            "- If the kill switch is active, do not attempt fixes "
            "— report and escalate instead\n"
            "- Prefer the simplest fix first (restart > reconfigure > escalate)"
        )

        return "\n\n---\n\n".join(parts)

    def _compose_trigger_message(self, trigger: str, context: dict[str, Any] | None) -> str:
        """Build the initial user message from the trigger."""
        parts = [f"Trigger: {trigger}"]
        if context:
            parts.append(f"Context: {json.dumps(context, default=str, indent=2)}")
            if "past_fix" in context:
                parts.append(f"A similar issue was previously fixed: {context['past_fix']}")
        parts.append("Diagnose this situation and take appropriate action.")
        return "\n\n".join(parts)

    # ── Response parsing ───────────────────────────────────────────

    @staticmethod
    def _extract_root_cause(trigger: str, result: "AgentResult") -> str:
        """Extract root cause category from the agent run."""
        summary_lower = result.summary.lower()
        if "restart" in summary_lower and ("crash" in summary_lower or "down" in summary_lower):
            return "service_crash"
        if "memory" in summary_lower or "oom" in summary_lower:
            return "memory_exhaustion"
        if "disk" in summary_lower:
            return "disk_pressure"
        if "timeout" in summary_lower or "connection" in summary_lower:
            return "connectivity"
        if "upstream" in summary_lower or "dependency" in summary_lower:
            return "upstream_dependency"
        if "config" in summary_lower:
            return "misconfiguration"
        if "health_loop" in trigger:
            return "health_check_failure"
        return "unclassified"

    @staticmethod
    def _parse_structured_response(content: str) -> tuple[str, str]:
        """Extract <summary> and <outcome> tags from agent response.

        Returns:
            Tuple of (summary, outcome). Empty strings if tags not found.
        """
        summary = ""
        outcome = ""

        summary_matches = re.findall(r"<summary>(.*?)</summary>", content, re.DOTALL)
        if summary_matches:
            summary = summary_matches[-1].strip()
        elif "<summary>" in content:
            # Unclosed <summary> (token budget exhausted) — take text after tag
            tail = content.split("<summary>")[-1].strip()
            if tail:
                summary = tail.split("<outcome>")[0].strip()

        outcome_matches = re.findall(r"<outcome>(.*?)</outcome>", content, re.DOTALL)
        if outcome_matches:
            raw = outcome_matches[-1].strip().lower()
            if raw in (
                "resolved",
                "failed",
                "escalated",
                "no_action",
                "remediated",
                "trend_warning",
            ):
                outcome = raw

        return summary, outcome

    @staticmethod
    def _strip_think_tags(text: str) -> str:
        """Strip Qwen3 <think> chain-of-thought blocks from text.

        Handles three cases:
        1. Closed: <think>...</think> — full block removed
        2. Unclosed: <think>...EOF — truncated response, strip to end
        3. Orphaned: ...text...</think> — opening tag truncated away,
           strip everything before and including </think>
        """
        # Case 3: orphaned </think> without opening <think>
        if "</think>" in text and "<think>" not in text:
            text = re.sub(r"^.*?</think>\s*", "", text, flags=re.DOTALL)
            return text.strip()
        if "<think>" not in text:
            return text
        # Case 1: closed <think>...</think> blocks
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
        # Case 2: unclosed <think> (truncated response) — strip to end
        if "<think>" in text:
            text = re.sub(r"<think>.*", "", text, flags=re.DOTALL)
        return text.strip()

    # ── Memory storage ─────────────────────────────────────────────

    async def _store_result(
        self,
        trigger: str,
        result: AgentResult,
        context: dict[str, Any] | None,
        messages: list[dict[str, Any]] | None = None,
    ) -> None:
        """Store the agent run result to all memory tiers and publish events."""
        await self._persist_memory(trigger, result, context, messages)
        await self._contribute_patterns(trigger, result)

        # Publish event for cross-room coordination
        if self._event_publisher:
            try:
                event_type = (
                    "remediation_applied"
                    if result.outcome == "remediated"
                    else "agent_run_completed"
                )
                await self._event_publisher.publish(
                    event_type,
                    {
                        "trigger": trigger,
                        "outcome": result.outcome,
                        "actions": len(result.actions),
                        "escalated": result.escalated,
                        "model": result.model,
                    },
                )
            except Exception:
                logger.debug("RoomAgent: event publish failed (non-fatal)")

            # Escalation hook: publish dedicated escalation event for unresolved issues
            if result.outcome == "escalated":
                try:
                    await self._event_publisher.publish(
                        "escalation_unresolved",
                        {
                            "trigger": trigger,
                            "summary": result.summary[:500] if result.summary else "",
                            "actions_tried": len(result.actions),
                            "model": result.model or "",
                        },
                    )
                except Exception:
                    logger.debug("RoomAgent: escalation event publish failed (non-fatal)")

        if result.escalated:
            logger.info(
                "RoomAgent[%s]: T4 resolution by %s — outcome=%s, actions=%d, "
                "tokens=%d (completion=%d)",
                self.config.project,
                result.model,
                result.outcome,
                len(result.actions),
                result.tokens_used,
                result.completion_tokens,
            )
        elif result.diminishing_returns:
            logger.info(
                "RoomAgent[%s]: Stopped — diminishing returns after %d iterations, "
                "completion_tokens=%d",
                self.config.project,
                result.iterations,
                result.completion_tokens,
            )
        else:
            logger.info(
                "RoomAgent[%s]: Run complete — outcome=%s, actions=%d, tokens=%d (completion=%d)",
                self.config.project,
                result.outcome,
                len(result.actions),
                result.tokens_used,
                result.completion_tokens,
            )

    async def _persist_memory(
        self,
        trigger: str,
        result: AgentResult,
        context: dict[str, Any] | None,
        messages: list[dict[str, Any]] | None = None,
    ) -> None:
        """Store to Tiers 1 (knowledge files), 2 (PostgreSQL), and 3 (Qdrant)."""
        # Cache invalidation happens in run() before this call.
        # Determine memory type
        if result.outcome == "remediated":
            memory_type = "remediation"
        elif result.outcome == "resolved" and result.actions:
            memory_type = "incident"
        elif result.outcome == "no_action":
            memory_type = "check"
        elif result.outcome == "escalated":
            memory_type = "escalation"
        elif result.outcome == "trend_warning":
            memory_type = "trend_warning"
        elif result.outcome == "diminishing_returns":
            memory_type = "incident"  # Worth storing — agent was stuck
        else:
            memory_type = "incident"

        # Skip storing routine health loop noise — checks, escalations, and
        # incidents from scheduled triggers generate 90%+ of memory rows.
        # Only store if the agent actually remediated something or made a decision.
        _health_prefixes = ("scheduled_check", "health_check", "health_loop")
        is_health_trigger = any(trigger.startswith(p) for p in _health_prefixes)
        noise_type = memory_type in ("check", "escalation", "incident")
        _observation_tools = frozenset(
            {
                "service_health",
                "service_status",
                "service_logs",
                "service_errors",
                "service_trends",
                "service_log_patterns",
            }
        )
        _observation_suffixes = ("_health", "_status", "_models")
        mutating_actions = [
            a
            for a in (result.actions or [])
            if a.get("tool") not in _observation_tools
            and not any((a.get("tool") or "").endswith(s) for s in _observation_suffixes)
        ]
        actually_acted = result.outcome == "remediated" or (
            result.outcome == "resolved" and bool(mutating_actions)
        )
        skip_storage = is_health_trigger and noise_type and not actually_acted
        # Escalations where the agent tried tools are learning opportunities —
        # they show what the agent attempted and couldn't fix.
        if memory_type == "escalation" and result.actions:
            skip_storage = False
        # Trend warnings are early signals worth preserving even on health triggers.
        if memory_type == "trend_warning":
            skip_storage = False

        summary = result.summary[:2000] if result.summary else f"Agent run: {trigger}"
        # Strip LLM chain-of-thought leakage from summaries
        summary = self._strip_think_tags(summary)
        if not summary:
            summary = f"Agent run: {trigger}"

        # Defense-in-depth: catch degenerate text that slipped past Layer 1
        quality = check_output_quality(summary)
        if not quality.passed:
            logger.warning(
                "RoomAgent[%s]: Quality gate caught degenerate summary at persist layer (flags=%s)",
                self.config.project,
                quality.flags,
            )
            summary = f"Quality gate: degenerate output on trigger '{trigger}'"
            result.outcome = "failed"

        mem_id: int | None = None

        # Tier 2: PostgreSQL
        if not skip_storage:
            mem_id = await self.memory.store_memory(
                project=self.config.project,
                memory_type=memory_type,
                summary=summary,
                context=context or {},
                trigger=trigger,
                reasoning=result.summary,
                actions_taken=result.actions,
                outcome=result.outcome,
                tokens_used=result.tokens_used,
                model=result.model,
                conversation=messages,
            )

        # Tier 3: Qdrant (embed the summary for semantic recall)
        if mem_id and self.config.memory.get("qdrant"):
            tools_used = list({a["tool"] for a in result.actions if "tool" in a})
            actions_summary = "; ".join(
                f"{a['tool']}({a.get('result', '')[:60]})" for a in result.actions[:5]
            )
            root_cause = self._extract_root_cause(trigger, result)
            await self.memory.embed_and_store(
                memory_id=mem_id,
                summary=summary,
                memory_type=memory_type,
                outcome=result.outcome,
                actions_summary=actions_summary,
                root_cause=root_cause,
                tools_used=tools_used,
            )

        # Tier 1: Update .md files for significant events
        # Skip noise (routine healthy checks) but keep failures/remediations
        skip_tier1 = skip_storage and result.outcome not in ("failed", "remediated")
        if skip_tier1:
            pass
        elif result.outcome == "remediated" and result.actions:
            await self.knowledge.update_memory("remediations", summary)
            await self.knowledge.git_commit_push(f"{memory_type}: {summary[:80]}")
        elif result.outcome in ("resolved", "escalated") and result.actions:
            category = "incidents" if result.outcome == "resolved" else "patterns"
            await self.knowledge.update_memory(category, summary)
            await self.knowledge.git_commit_push(f"{memory_type}: {summary[:80]}")
        elif result.outcome == "failed" and result.actions:
            failed_tools = ", ".join(a["tool"] for a in result.actions[:3] if "tool" in a)
            await self.knowledge.update_memory(
                "failed_attempts",
                f"FAILED: {summary} [tools: {failed_tools}]",
            )

    async def _contribute_patterns(
        self,
        trigger: str,
        result: AgentResult,
    ) -> None:
        """Contribute successful fixes to the shared pattern library."""
        if result.outcome != "remediated" or not result.actions:
            return

        try:
            from maude.healing.pattern_library import PatternLibrary

            library = PatternLibrary()
            try:
                tools_str = ", ".join(a["tool"] for a in result.actions[:3] if "tool" in a)
                await library.contribute_pattern(
                    source_room=self.config.project,
                    trigger_signature=trigger,
                    resolution=f"{result.summary} [tools: {tools_str}]",
                )
            finally:
                await library.close()
        except Exception:
            logger.debug("Pattern library contribution failed (non-fatal)")
