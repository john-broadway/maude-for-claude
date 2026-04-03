# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Safety guard decorators for MCP tool functions.

Three layers of protection:
- @requires_confirm — Mutating tools must receive confirm=True + reason
- @rate_limited — Prevent rapid-fire mutations (e.g., restart spam)
- @audit_logged — Every call is recorded to the audit trail

Usage:
    audit = AuditLogger("my-service")
    kill_switch = KillSwitch("my-service")

    @mcp.tool()
    @audit_logged(audit)
    @requires_confirm(kill_switch)
    async def my_service_restart(confirm: bool = False, reason: str = "") -> str:
        ...
"""

import asyncio
import functools
import json
import logging
import time
from collections.abc import Callable
from typing import Any

from maude.daemon.kill_switch import KillSwitch
from maude.memory.audit import AuditLogger, elapsed

logger = logging.getLogger(__name__)


def requires_confirm(kill_switch: KillSwitch) -> Callable:
    """Decorator: require confirm=True and reason for mutating tools.

    Also checks the kill switch before allowing execution.

    The wrapped function MUST accept `confirm: bool` and `reason: str` parameters.
    """

    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        async def wrapper(*args: Any, **kwargs: Any) -> str:
            confirm = kwargs.get("confirm", False)
            reason = kwargs.get("reason", "")

            # Check kill switch first
            try:
                kill_switch.check_or_raise()
            except PermissionError as e:
                return json.dumps({"error": str(e), "kill_switch": True})

            # Require explicit confirmation
            if not confirm:
                return json.dumps(
                    {
                        "error": f"Tool '{func.__name__}' requires confirm=True",
                        "hint": (
                            "I need you to confirm this one, dear. "
                            "Pass confirm=True and tell me why."
                        ),
                        "tool": func.__name__,
                    }
                )

            # Require a reason for audit trail
            if not reason.strip():
                return json.dumps(
                    {
                        "error": f"Tool '{func.__name__}' requires a reason",
                        "hint": (
                            "I'm not letting you do this without telling me why. "
                            "Provide reason='...' so we have it on the record."
                        ),
                        "tool": func.__name__,
                    }
                )

            logger.info("CONFIRMED: %s (reason: %s)", func.__name__, reason)
            return await func(*args, **kwargs)

        return wrapper

    return decorator


# Rate limit state: {func_name: last_call_time}
_rate_limit_state: dict[str, float] = {}
_rate_limit_locks: dict[str, asyncio.Lock] = {}

# Optional Redis client for distributed rate limiting
_redis_client: Any = None


def set_redis_for_rate_limiting(redis_client: Any) -> None:
    """Set a MaudeRedis instance for distributed rate limiting.

    When set, @rate_limited uses Redis SET NX EX for fleet-wide enforcement.
    Falls back to in-memory if Redis is unavailable.
    """
    global _redis_client
    _redis_client = redis_client


def rate_limited(min_interval_seconds: float = 60.0) -> Callable:
    """Decorator: prevent calling a mutating tool too frequently.

    If a Redis client is configured (via :func:`set_redis_for_rate_limiting`),
    uses distributed rate limiting. Otherwise falls back to in-memory.

    Args:
        min_interval_seconds: Minimum seconds between calls. Defaults to 60.
    """

    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        async def wrapper(*args: Any, **kwargs: Any) -> str:
            key = func.__name__

            # Try Redis-backed rate limiting
            if _redis_client and _redis_client.available:
                result = await _redis_client.rate_check(f"rate:{key}", 1, int(min_interval_seconds))
                if not result["allowed"]:
                    return json.dumps(
                        {
                            "error": f"Rate limited: {func.__name__}",
                            "hint": (
                                f"You just did this. Take a breath. "
                                f"Wait {result['remaining']}s before trying again."
                            ),
                            "min_interval": min_interval_seconds,
                        }
                    )
                return await func(*args, **kwargs)

            # Fallback: in-memory rate limiting
            lock = _rate_limit_locks.setdefault(key, asyncio.Lock())

            async with lock:
                now = time.monotonic()
                last = _rate_limit_state.get(key, 0.0)
                delta = now - last

                if delta < min_interval_seconds:
                    remaining = min_interval_seconds - delta
                    return json.dumps(
                        {
                            "error": f"Rate limited: {func.__name__}",
                            "hint": (
                                f"You just did this {delta:.0f} seconds ago. "
                                f"Wait {remaining:.0f}s. I'm not letting you rush this."
                            ),
                            "min_interval": min_interval_seconds,
                        }
                    )

                _rate_limit_state[key] = now

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def audit_logged(audit: AuditLogger, caller: str = "unknown") -> Callable:
    """Decorator: log every tool call to the audit trail.

    Args:
        audit: AuditLogger instance.
        caller: Identifier for who's calling (e.g., "claude", "my-service-agent").
    """

    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        async def wrapper(*args: Any, **kwargs: Any) -> str:
            start = time.monotonic()
            success = True
            result = ""

            try:
                result = await func(*args, **kwargs)
                return result
            except Exception as e:
                success = False
                result = str(e)
                raise
            finally:
                duration = elapsed(start)
                # Fire-and-forget audit (don't block tool response)
                try:
                    from maude.memory.audit import active_caller

                    effective_caller = active_caller.get() or kwargs.get("_caller", "") or caller
                    await audit.log_tool_call(
                        tool=func.__name__,
                        caller=effective_caller,
                        params={k: v for k, v in kwargs.items() if k != "_caller"},
                        result=result[:500] if result else "",
                        success=success,
                        duration_ms=duration,
                        reason=kwargs.get("reason", ""),
                    )
                except Exception as e:
                    logger.error("Audit logging failed: %s", e)

        return wrapper

    return decorator
