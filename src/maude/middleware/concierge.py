"""Concierge Services — doorman for per-project MCP servers.

Intercepts all external MCP tool calls, enforces ACL (if configured),
and logs every call to the audit trail. The health loop (which calls
the executor directly) bypasses middleware entirely — it's internal.

Optionally logs full request/response pairs to the ``interaction_log``
table for training data capture (self-learning pipeline).

Usage:
    from maude.middleware.concierge import ConciergeServices

    middleware = ConciergeServices(audit=audit, project="grafana")
    mcp.add_middleware(middleware)
"""

import json
import logging
import time
from typing import Any

from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.tools.tool import ToolResult  # type: ignore[import-untyped]

from maude.daemon.audit import AuditLogger
from maude.db import PoolRegistry
from maude.middleware.acl import ACLEngine

logger = logging.getLogger(__name__)

_CALLER_HEADER = "x-maude-caller"
_DEFAULT_CALLER = "anonymous"


def _extract_caller(context: MiddlewareContext) -> str:
    """Extract caller identity from X-Maude-Caller HTTP header.

    Falls back to 'anonymous' if header is missing or extraction fails.
    Uses fastmcp.server.dependencies.get_http_headers() which is available
    inside middleware even before MCP session is established.
    """
    try:
        from fastmcp.server.dependencies import get_http_headers

        headers = get_http_headers()
        if headers:
            return headers.get(_CALLER_HEADER, _DEFAULT_CALLER) or _DEFAULT_CALLER
    except Exception:
        pass
    return _DEFAULT_CALLER


def _serialize_result(result: Any) -> Any:
    """Extract text content from a ToolResult for JSONB storage."""
    if isinstance(result, str):
        return {"text": result}
    try:
        if hasattr(result, "content") and isinstance(result.content, list):
            texts = []
            for item in result.content:
                if hasattr(item, "text") and isinstance(item.text, str):
                    texts.append(item.text)
            if texts:
                return {"text": "\n".join(texts)}
    except Exception:
        pass
    return {"text": str(result)[:10000]}


class ConciergeServices(Middleware):
    """Doorman middleware for per-project MCP servers.

    Logs every external tool call with caller identity. Enforces ACL
    when an ACLEngine is configured — denied calls are logged and
    short-circuited before reaching the tool.

    Optionally passes calls to a GuestBook for visit memory batching.
    """

    def __init__(
        self,
        audit: AuditLogger,
        project: str,
        guest_book: "GuestBook | None" = None,  # type: ignore[name-defined]  # noqa: F821
        acl: ACLEngine | None = None,
        interaction_log: bool = False,
    ) -> None:
        self.audit = audit
        self.project = project
        self.guest_book = guest_book
        self.acl = acl
        self._interaction_pool = (
            PoolRegistry.get(database="agent", min_size=1, max_size=2) if interaction_log else None
        )

    async def _log_interaction(
        self,
        tool_name: str,
        caller: str,
        params: dict[str, Any],
        result_data: Any,
        success: bool,
        duration_ms: float,
    ) -> None:
        """Write a full request/response pair to interaction_log for training."""
        if not self._interaction_pool:
            return
        try:
            pool = await self._interaction_pool.get()
            if not pool:
                return
            request_json = json.dumps(
                {"tool": tool_name, "params": params},
                default=str,
                ensure_ascii=False,
            )
            response_json = json.dumps(
                _serialize_result(result_data),
                default=str,
                ensure_ascii=False,
            )
            await pool.execute(
                """INSERT INTO interaction_log
                       (project, surface, caller, request, response,
                        duration_ms, success)
                   VALUES ($1, $2, $3, $4::jsonb, $5::jsonb, $6, $7)""",
                self.project,
                "mcp_tool",
                caller,
                request_json,
                response_json,
                int(duration_ms),
                success,
            )
        except Exception:
            logger.debug("Interaction log write failed (non-fatal)")

    async def on_call_tool(self, context: MiddlewareContext, call_next):  # type: ignore[override]
        tool_name = context.message.name
        params = context.message.arguments or {}
        start = time.monotonic()

        caller = _extract_caller(context)

        # ACL check
        caller_role = ""
        access_decision = ""
        if self.acl:
            decision = self.acl.check(caller, tool_name)
            caller_role = decision.role
            access_decision = "allowed" if decision.allowed else "denied"

            if not decision.allowed:
                duration_ms = (time.monotonic() - start) * 1000
                logger.warning(
                    "CONCIERGE: ACL DENIED %s (role=%s) → %s: %s",
                    caller,
                    caller_role,
                    tool_name,
                    decision.reason,
                )
                try:
                    await self.audit.log_tool_call(
                        tool=tool_name,
                        caller=caller,
                        params=params,
                        result=f"denied: {decision.reason}",
                        success=False,
                        duration_ms=duration_ms,
                        caller_role=caller_role,
                        access_decision="denied",
                    )
                except Exception:
                    logger.exception("Concierge audit write failed (non-fatal)")
                return ToolResult(
                    content=json.dumps(
                        {
                            "error": "access_denied",
                            "caller": caller,
                            "role": caller_role,
                            "tool": tool_name,
                            "reason": decision.reason,
                        }
                    )
                )

        try:
            result = await call_next(context)
            duration_ms = (time.monotonic() - start) * 1000
            logger.debug(
                "CONCIERGE: %s called %s (%.0fms, ok)",
                caller,
                tool_name,
                duration_ms,
            )
            try:
                await self.audit.log_tool_call(
                    tool=tool_name,
                    caller=caller,
                    params=params,
                    result=str(result)[:500],
                    success=True,
                    duration_ms=duration_ms,
                    caller_role=caller_role,
                    access_decision=access_decision or "allowed",
                )
            except Exception:
                logger.exception("Concierge audit write failed (non-fatal)")
            await self._log_interaction(
                tool_name,
                caller,
                params,
                result,
                True,
                duration_ms,
            )
            try:
                if self.guest_book:
                    await self.guest_book.record_call(
                        tool_name,
                        params,
                        str(result)[:500],
                        True,
                        duration_ms,
                    )
                    # Passive briefing: prepend Room context to first tool response
                    briefing = await self.guest_book.get_briefing()
                    if briefing:
                        result = _prepend_briefing(result, briefing)
            except Exception:
                logger.exception("Concierge guest book write failed (non-fatal)")
            return result
        except Exception as exc:
            duration_ms = (time.monotonic() - start) * 1000
            logger.warning(
                "CONCIERGE: %s called %s (%.0fms, FAILED: %s)",
                caller,
                tool_name,
                duration_ms,
                exc,
            )
            try:
                await self.audit.log_tool_call(
                    tool=tool_name,
                    caller=caller,
                    params=params,
                    result=str(exc)[:500],
                    success=False,
                    duration_ms=duration_ms,
                    caller_role=caller_role,
                    access_decision=access_decision or "allowed",
                )
            except Exception:
                logger.exception("Concierge audit write failed (non-fatal)")
            await self._log_interaction(
                tool_name,
                caller,
                params,
                str(exc),
                False,
                duration_ms,
            )
            try:
                if self.guest_book:
                    await self.guest_book.record_call(
                        tool_name,
                        params,
                        str(exc)[:500],
                        False,
                        duration_ms,
                    )
            except Exception:
                logger.exception("Concierge guest book write failed (non-fatal)")
            raise


def _prepend_briefing(result: Any, briefing: str) -> Any:
    """Prepend a passive briefing to a tool result.

    Handles both raw strings and FastMCP ToolResult objects with
    TextContent items. If the result type is unrecognized, returns
    it unchanged (never break a tool response for a briefing).
    """
    if isinstance(result, str):
        return f"{briefing}\n\n---\n\n{result}"
    # FastMCP ToolResult — content is list[TextContent]
    try:
        if hasattr(result, "content") and isinstance(result.content, list):
            for item in result.content:
                if hasattr(item, "text") and isinstance(item.text, str):
                    item.text = f"{briefing}\n\n---\n\n{item.text}"
                    return result
    except Exception:
        pass
    return result
