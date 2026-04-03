# Maude Room Lifecycle — Background Task Management
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.1.0
# Updated: 2026-02-13
"""Room lifecycle management for Maude MCP servers.

Manages background tasks that run alongside the MCP server:
- Health Loop: periodic health checks + auto-restart + escalation
- Room Agent: LLM-powered diagnostics, triggered by events/schedule
- Event Publisher: cross-room coordination via PG NOTIFY
- Redis: distributed caching and rate limiting

Extracted from the old BaseServiceMCP._run_with_health_loop() to work
with the v3.0.0 standalone composition pattern. Called by run_room()
when health_loop or room_agent is enabled in config.

Usage:
    # Automatically invoked by run_room() — rooms don't call this directly.
    # For custom lifecycle (e.g., Coordinator), use extra_startup/extra_shutdown:
    await run_with_lifecycle(
        mcp, config, transport, host, port,
        extra_startup=start_training_loop,
        extra_shutdown=stop_training_loop,
    )
"""

import asyncio
import logging
import random
from collections.abc import Awaitable, Callable
from contextlib import suppress
from pathlib import Path
from typing import Any, cast

from fastmcp import FastMCP

from maude.daemon.audit import AuditLogger
from maude.daemon.config import RoomConfig
from maude.daemon.executor import LocalExecutor
from maude.daemon.kill_switch import KillSwitch

logger = logging.getLogger(__name__)


async def run_with_lifecycle(
    mcp: FastMCP,
    config: RoomConfig,
    transport: str,
    host: str,
    port: int,
    *,
    domain_checks: Callable[[], Awaitable[dict[str, Any]]] | None = None,
    extra_startup: Callable[[], Awaitable[None]] | None = None,
    extra_shutdown: Callable[[], Awaitable[None]] | None = None,
) -> None:
    """Run MCP server with health loop, room agent, and background tasks.

    Replaces the old BaseServiceMCP._run_with_health_loop(). Creates its
    own executor/audit/kill_switch for background tasks — these are separate
    from the instances used by the room's MCP tools.

    Args:
        mcp: The FastMCP server instance (with tools already registered).
        config: Room configuration with health_loop/room_agent sections.
        transport: MCP transport type.
        host: Bind address.
        port: MCP port.
        domain_checks: Optional async callback for domain-specific health checks.
        extra_startup: Optional async callable for additional startup (e.g., training loop).
        extra_shutdown: Optional async callable for additional shutdown.
    """
    executor = LocalExecutor()
    audit = AuditLogger(project=config.project)
    kill_switch = KillSwitch(project=config.project)

    # ConciergeServices middleware — audit logging + ACL for external MCP calls
    _wire_middleware(mcp, config, audit)

    # Memory store — shared between health loop and room agent
    memory_store = _setup_memory_store(config)

    # Admin registry — autonomous action vocabulary + guardrails
    admin_registry = _setup_admin_registry(config)

    # Sync worker — background SQLite ↔ PG/Qdrant sync
    sync_worker = _setup_sync_worker(config, memory_store)

    # Relay outbox worker — local buffer → PG drain + P2P fallback
    relay_outbox_worker = _setup_relay_outbox_worker(config, memory_store)

    # Event publisher
    event_publisher = _setup_event_publisher(config)

    # Redis client
    redis_client = _setup_redis(config)

    # Health loop
    health_loop = _setup_health_loop(
        config,
        executor,
        audit,
        event_publisher,
        memory_store,
        admin_registry=admin_registry,
    )
    if health_loop and domain_checks:
        health_loop.set_domain_checks(domain_checks)

    # Room agent + escalation wiring
    room_agent = None
    if config.room_agent and config.room_agent.get("enabled"):
        room_agent = _build_room_agent(
            mcp,
            config,
            audit,
            kill_switch,
            memory_store,
            event_publisher,
        )
        if health_loop and room_agent:

            async def _on_escalation(trigger: str, context: dict[str, Any]) -> None:
                if room_agent:
                    logger.info("Escalation → Room Agent: %s", trigger)
                    await room_agent.run(trigger, context)

            health_loop.set_escalation_callback(_on_escalation)

    # ── Connect infrastructure ──────────────────────────────────

    if redis_client:
        try:
            connected = await redis_client.connect()
            if connected:
                from maude.daemon.guards import set_redis_for_rate_limiting

                set_redis_for_rate_limiting(redis_client)
                logger.info("Redis connected for %s", config.project)
        except Exception:
            logger.warning("Redis connection failed for %s (non-fatal)", config.project)

    if event_publisher:
        try:
            await event_publisher.connect()
            logger.info("Event publisher connected for %s", config.project)
        except Exception:
            logger.warning(
                "Event publisher connection failed for %s (non-fatal)",
                config.project,
            )

    # ── Start background tasks ──────────────────────────────────

    if health_loop:
        await health_loop.start()
        logger.info("Health loop started for %s", config.project)

        # Populate deferred ref created by register_ops_tools() so
        # service_trends can access the health loop at call time.
        deferred = getattr(mcp, "_maude_health_loop_ref", None)
        if deferred is not None:
            deferred._health_loop = health_loop

    # Register capability card with health loop reference (richer than runner.py basic card)
    try:
        from maude.daemon.card import register_card_resource

        class _HealthRef:
            _health_loop = health_loop

        register_card_resource(mcp, config, health_loop_ref=_HealthRef())
    except Exception:
        logger.debug("Card resource registration skipped for %s", config.project)

    if sync_worker:
        await sync_worker.start()
        logger.info("SyncWorker started for %s", config.project)

    if relay_outbox_worker:
        await relay_outbox_worker.start()
        logger.info("RelayOutboxWorker started for %s", config.project)

    # Signal when MCP tools are ready (Room Agent waits on this)
    tools_ready = asyncio.Event()

    async def _signal_tools_ready() -> None:
        for _ in range(60):  # poll up to 5 minutes
            await asyncio.sleep(5)
            try:
                tools = await mcp.get_tools()  # type: ignore[attr-defined]
                if tools:
                    tools_ready.set()
                    logger.info(
                        "Tools ready — %d tools for %s",
                        len(tools),
                        config.project,
                    )
                    return
            except Exception:
                pass
        logger.error("Tools never became available for %s", config.project)

    tools_ready_task = asyncio.create_task(
        _signal_tools_ready(),
        name=f"tools-ready-{config.project}",
    )

    room_agent_task = _start_room_agent_schedule(
        room_agent,
        config,
        tools_ready,
        health_loop,
    )

    # Extra startup (Coordinator uses this for training loop, event listener)
    if extra_startup:
        try:
            await extra_startup()
        except Exception:
            logger.exception("Extra startup failed for %s (non-fatal)", config.project)

    # ── Run MCP server (blocks until shutdown) ──────────────────

    try:
        await mcp.run_async(
            transport=cast(Any, transport),
            host=host,
            port=port,
            json_response=True,
        )
    finally:
        # ── Shutdown ────────────────────────────────────────────
        tools_ready_task.cancel()
        with suppress(asyncio.CancelledError):
            await tools_ready_task

        if room_agent_task:
            room_agent_task.cancel()
            with suppress(asyncio.CancelledError):
                await room_agent_task

        if extra_shutdown:
            try:
                await extra_shutdown()
            except Exception:
                logger.warning("Extra shutdown failed for %s", config.project)

        if relay_outbox_worker:
            with suppress(Exception):
                await relay_outbox_worker.stop()

        if sync_worker:
            with suppress(Exception):
                await sync_worker.stop()

        if health_loop:
            await health_loop.stop()

        if event_publisher:
            with suppress(Exception):
                await event_publisher.close()

        if redis_client:
            with suppress(Exception):
                await redis_client.close()

        if room_agent and hasattr(room_agent, "llm"):
            with suppress(Exception):
                await room_agent.llm.close()

        if memory_store:
            with suppress(Exception):
                await memory_store.close()

        # Close all shared database pools last
        with suppress(Exception):
            from maude.db import PoolRegistry

            await PoolRegistry.close_all()
            logger.info("PoolRegistry closed for %s", config.project)


# ── Setup helpers ───────────────────────────────────────────────


def _wire_middleware(mcp: FastMCP, config: RoomConfig, audit: AuditLogger) -> None:
    """Attach ConciergeServices middleware to the MCP server.

    Creates ConciergeServices (audit logging + ACL enforcement for all
    external MCP tool calls). ACLEngine is only created when the config
    has an ``acl`` section with ``enabled: true``.

    Internal calls (health loop, Room Agent) bypass middleware entirely
    because they invoke the executor directly, not the MCP tool layer.
    """
    try:
        from maude.middleware.acl import ACLEngine
        from maude.middleware.concierge import ConciergeServices

        acl = None
        if config.acl and config.acl.get("enabled"):
            acl = ACLEngine.from_config(config.acl)
            logger.info("ACL enabled for %s", config.project)

        concierge = ConciergeServices(
            audit=audit,
            project=config.project,
            acl=acl,
            interaction_log=True,
        )
        mcp.add_middleware(concierge)
        logger.info("ConciergeServices middleware wired for %s", config.project)
    except Exception:
        logger.warning(
            "ConciergeServices middleware setup failed for %s (non-fatal)",
            config.project,
        )


def _setup_memory_store(config: RoomConfig) -> Any:
    """Create MemoryStore + LocalStore for the room.

    Attaches a LocalStore (SQLite) for Tier 1.5 sovereign memory.
    LocalStore is enabled by default — disable via local_memory.enabled=false.
    """
    try:
        from maude.memory.store import MemoryStore

        memory_store = MemoryStore(project=config.project)

        # Attach local SQLite store (Tier 1.5)
        local_memory_cfg = config.raw.get("local_memory", {})
        if local_memory_cfg.get("enabled", True):
            try:
                from maude.memory.local_store import LocalStore

                local_store = LocalStore(project=config.project)
                memory_store.set_local_store(local_store)
                logger.info("LocalStore attached for %s", config.project)
            except Exception:
                logger.warning(
                    "LocalStore setup failed for %s (non-fatal)",
                    config.project,
                )

        return memory_store
    except Exception:
        logger.warning("MemoryStore setup failed for %s (non-fatal)", config.project)
        return None


def _setup_admin_registry(config: RoomConfig) -> Any:
    """Create AdminRegistry from config (if enabled)."""
    admin_cfg = config.raw.get("autonomous_admin", {})
    if not admin_cfg.get("enabled"):
        return None
    try:
        from maude.healing.admin_registry import AdminRegistry, AdminRegistryConfig

        reg_config = AdminRegistryConfig.from_dict(admin_cfg)
        registry = AdminRegistry(
            config=reg_config,
            service_name=config.service_name,
            project=config.project,
        )
        logger.info(
            "AdminRegistry enabled for %s (%d actions)",
            config.project,
            len(reg_config.allowed_actions),
        )
        return registry
    except Exception:
        logger.warning(
            "AdminRegistry setup failed for %s (non-fatal)",
            config.project,
        )
        return None


def _setup_sync_worker(config: RoomConfig, memory_store: Any) -> Any:
    """Create SyncWorker for background SQLite ↔ PG/Qdrant sync."""
    if not memory_store:
        return None
    local_store = getattr(memory_store, "_local", None)
    if not local_store:
        return None

    local_memory_cfg = config.raw.get("local_memory", {})
    try:
        from maude.memory.sync import SyncWorker

        return SyncWorker(
            local_store=local_store,
            memory_store=memory_store,
            project=config.project,
            sync_up_interval=local_memory_cfg.get("sync_up_interval", 60),
            sync_down_interval=local_memory_cfg.get("sync_down_interval", 300),
        )
    except Exception:
        logger.warning(
            "SyncWorker setup failed for %s (non-fatal)",
            config.project,
        )
        return None


def _setup_relay_outbox_worker(config: RoomConfig, memory_store: Any) -> Any:
    """Create RelayOutboxWorker for background relay buffer drain."""
    if not memory_store:
        return None
    local_store = getattr(memory_store, "_local", None)
    if not local_store:
        return None

    try:
        from maude.coordination.relay import Relay
        from maude.daemon.relay_buffer import RelayOutbox, RelayOutboxWorker

        outbox = RelayOutbox(local_store, config.project)
        relay = Relay()

        dep_graph = None
        try:
            from maude.healing.dependencies import DependencyGraph

            dep_graph = DependencyGraph()
        except Exception:
            logger.debug("DependencyGraph unavailable for P2P fallback")

        return RelayOutboxWorker(
            outbox=outbox,
            relay=relay,
            project=config.project,
            dep_graph=dep_graph,
        )
    except Exception:
        logger.warning(
            "RelayOutboxWorker setup failed for %s (non-fatal)",
            config.project,
        )
        return None


def _setup_event_publisher(config: RoomConfig) -> Any:
    """Create event publisher from config (if enabled)."""
    if not config.events or not config.events.get("enabled"):
        return None
    try:
        from maude.infra.events import EventPublisher

        backend = config.events.get("backend", "pg")
        pg_publisher = EventPublisher(
            project=config.project,
            db_host=config.events.get("db_host", ""),
            database=config.events.get("database", "agent"),
        )

        if backend == "redis":
            redis_cfg = config.redis or {}
            if redis_cfg.get("enabled"):
                from maude.daemon.common import resolve_redis_host
                from maude.infra.events import RedisEventPublisher

                redis_host = redis_cfg.get("host") or resolve_redis_host()
                from maude.infra.redis_client import MaudeRedis

                redis = MaudeRedis(
                    host=redis_host,
                    port=redis_cfg.get("port", 6379),
                    db=(redis_cfg.get("db") or 0),
                    prefix=config.project,
                )
                return RedisEventPublisher(
                    project=config.project,
                    redis_client=redis,
                    pg_fallback=pg_publisher,
                )
        return pg_publisher
    except Exception:
        logger.warning("Event publisher setup failed for %s (non-fatal)", config.project)
        return None


def _setup_redis(config: RoomConfig) -> Any:
    """Create Redis client from config (if enabled)."""
    if not config.redis or not config.redis.get("enabled"):
        return None
    try:
        from maude.daemon.common import resolve_redis_host
        from maude.infra.redis_client import MaudeRedis

        host = config.redis.get("host") or resolve_redis_host()
        return MaudeRedis(
            host=host,
            port=config.redis.get("port", 6379),
            db=(config.redis.get("db") or 0),
            password=config.redis.get("password", ""),
            prefix=config.project,
        )
    except ImportError:
        logger.info("Redis unavailable for %s (install maude-claude[cache])", config.project)
    except Exception:
        logger.warning("Redis setup failed for %s (non-fatal)", config.project)
    return None


def _setup_health_loop(
    config: RoomConfig,
    executor: LocalExecutor,
    audit: AuditLogger,
    event_publisher: Any,
    memory_store: Any,
    *,
    admin_registry: Any = None,
) -> Any:
    """Create HealthLoop from config (if enabled)."""
    if not config.health_loop or not config.health_loop.get("enabled"):
        return None
    try:
        from maude.healing.health_loop import HealthLoop, HealthLoopConfig

        hc = HealthLoopConfig.from_dict(config.health_loop)
        return HealthLoop(
            executor=executor,
            audit=audit,
            service_name=config.service_name,
            project=config.project,
            health_config=hc,
            event_publisher=event_publisher,
            memory_store=memory_store,
            admin_registry=admin_registry,
        )
    except Exception:
        logger.exception("Health loop setup failed for %s", config.project)
        return None


def _build_room_agent(
    mcp: FastMCP,
    config: RoomConfig,
    audit: AuditLogger,
    kill_switch: KillSwitch,
    memory_store: Any,
    event_publisher: Any,
) -> Any:
    """Build Room Agent from config."""
    try:
        from maude.daemon.common import load_credentials
        from maude.healing.room_agent import RoomAgent, RoomAgentConfig
        from maude.healing.tool_registry import ToolRegistry
        from maude.llm.router import LLMRouter
        from maude.memory.knowledge import KnowledgeManager

        ra_config = RoomAgentConfig.from_dict(config.room_agent or {})
        ra_config.project = config.project

        credentials = load_credentials()
        llm = LLMRouter.from_config(ra_config.llm, credentials)

        tools = ToolRegistry(
            mcp=mcp,
            audit=audit,
            project=config.project,
            kill_switch=kill_switch,
        )

        knowledge_dir_str = (config.room_agent or {}).get("knowledge_dir", "knowledge/")
        knowledge_dir = Path(knowledge_dir_str)
        if not knowledge_dir.is_absolute():
            knowledge_dir = Path.cwd() / knowledge_dir
        # Prefer .maude/ over knowledge/ (migration support)
        if knowledge_dir.name == "knowledge":
            maude_dir = knowledge_dir.parent / ".maude"
            if maude_dir.is_dir():
                knowledge_dir = maude_dir
        repo_dir = (
            knowledge_dir.parent if knowledge_dir.name in ("knowledge", ".maude") else knowledge_dir
        )
        git_config = (config.room_agent or {}).get("git", {})

        knowledge_manager = KnowledgeManager(
            knowledge_dir=knowledge_dir,
            repo_dir=repo_dir,
            git_config=git_config,
        )

        agent = RoomAgent(
            config=ra_config,
            llm=llm,
            tools=tools,
            memory=memory_store,
            knowledge=knowledge_manager,
            event_publisher=event_publisher,
        )
        logger.info("Room Agent configured for %s", config.project)
        return agent
    except Exception:
        logger.exception("Room Agent init failed for %s — continuing without it", config.project)
        return None


def _start_room_agent_schedule(
    room_agent: Any,
    config: RoomConfig,
    tools_ready: asyncio.Event,
    health_loop: Any | None = None,
) -> asyncio.Task[None] | None:
    """Start scheduled Room Agent runs as a background task.

    Gate: LLM scheduled checks only run when Layer 1 (health loop) has
    seen issues, or on a periodic deep-check cadence.  When Layer 1
    reports all-clear, the LLM is skipped — Layer 1 already monitors.
    """
    if not room_agent or not config.room_agent:
        return None

    triggers = config.room_agent.get("triggers", [])
    schedule_triggers = [t for t in triggers if t.get("type") == "schedule"]
    if not schedule_triggers:
        return None

    interval = schedule_triggers[0].get("interval_seconds", 3600)
    deep_check_every = schedule_triggers[0].get("deep_check_every", 6)

    async def _schedule_loop() -> None:
        # Wait for MCP tools to materialize
        try:
            await asyncio.wait_for(tools_ready.wait(), timeout=30.0)
        except asyncio.TimeoutError:
            logger.warning(
                "Room Agent[%s]: tools_ready timed out, polling...",
                config.project,
            )
            for _ in range(30):
                await asyncio.sleep(10)
                try:
                    schemas = await room_agent.tools.get_tool_schemas()
                    if schemas:
                        break
                except Exception:
                    pass
            else:
                logger.error(
                    "Room Agent[%s]: tools never available, aborting schedule",
                    config.project,
                )
                return

        # Stagger first run to avoid thundering herd on bulk restarts
        jitter = random.uniform(5.0, 60.0)
        logger.info(
            "Room Agent[%s]: startup jitter %.1fs before first run",
            config.project,
            jitter,
        )
        await asyncio.sleep(jitter)

        skips_since_deep = 0
        first_run = True

        while True:
            # Determine whether to run the LLM
            run_reason = ""
            layer1_issues: list[dict[str, str]] = []

            if first_run:
                run_reason = "startup"
                first_run = False
            elif health_loop and hasattr(health_loop, "has_recent_issues"):
                if health_loop.has_recent_issues(hours=2.0):
                    run_reason = "layer1_issues"
                    layer1_issues = health_loop.get_recent_issues(hours=2.0)
                elif skips_since_deep >= deep_check_every:
                    run_reason = "deep_check"
                    skips_since_deep = 0
                else:
                    # Layer 1 all-clear — skip LLM
                    skips_since_deep += 1
                    logger.debug(
                        "Room Agent[%s]: Layer 1 all clear — skipping (%d/%d until deep check)",
                        config.project,
                        skips_since_deep,
                        deep_check_every,
                    )
                    await asyncio.sleep(interval)
                    continue
            else:
                # No health loop — always run
                run_reason = "no_health_loop"

            context: dict[str, Any] = {
                "type": "scheduled",
                "interval": interval,
                "run_reason": run_reason,
            }
            if layer1_issues:
                context["layer1_issues"] = layer1_issues

            try:
                logger.info(
                    "Room Agent scheduled run for %s (reason=%s)",
                    config.project,
                    run_reason,
                )
                await room_agent.run("scheduled_check", context)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception(
                    "Room Agent scheduled run failed for %s (non-fatal)",
                    config.project,
                )
            await asyncio.sleep(interval)

    return asyncio.create_task(
        _schedule_loop(),
        name=f"room-agent-schedule-{config.project}",
    )
