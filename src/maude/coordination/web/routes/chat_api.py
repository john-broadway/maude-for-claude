# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Chat API endpoints."""

import json
from collections.abc import AsyncGenerator

from fastapi import APIRouter, Depends, Request
from sse_starlette.sse import EventSourceResponse

from maude.coordination.web.state import AppState, get_state

router = APIRouter()


@router.post("/api/chat")
async def chat_endpoint(
    request: Request, state: AppState = Depends(get_state),
) -> EventSourceResponse:
    """Chat with Maude — returns SSE stream of turn-level events."""
    body = await request.json()
    message = body.get("message", "").strip()
    session_id = body.get("session_id", "")

    if not message:
        async def empty_stream() -> AsyncGenerator[dict[str, str], None]:
            err = json.dumps({"type": "error", "content": "Empty message."})
            yield {"event": "message", "data": err}
            yield {"event": "message", "data": json.dumps({"type": "done"})}
        return EventSourceResponse(empty_stream())

    session = await state.chat_store.get_or_create_async(session_id)
    state.chat_store.trim_messages(session)

    async def stream() -> AsyncGenerator[dict[str, str], None]:
        async for chunk in state.chat_agent.respond(session, message):
            yield {"event": "message", "data": chunk}
        # Write-through to Redis after response completes.
        await state.chat_store.persist(session)

    return EventSourceResponse(stream())


@router.post("/api/chat/reset")
async def chat_reset(
    request: Request, state: AppState = Depends(get_state),
) -> dict[str, str]:
    """Reset a chat session."""
    body = await request.json()
    session_id = body.get("session_id", "")
    if session_id:
        state.chat_store.clear(session_id)
    return {"status": "ok"}
