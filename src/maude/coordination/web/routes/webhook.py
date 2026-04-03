# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Gitea push webhook handler — signals rooms to self-deploy.

Configure in Gitea: Settings > Webhooks > Add Webhook
URL: http://localhost/webhook/gitea (SLC Maude)
Content-Type: application/json
Events: Push Events only
"""

import logging

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from maude.coordination.dependencies import DependencyGraph
from maude.infra.events import EventPublisher

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/webhook", tags=["webhook"])


@router.post("/gitea")
async def gitea_webhook(request: Request):
    """Handle Gitea push webhook — signals rooms to self-deploy."""
    try:
        payload = await request.json()
    except Exception:
        return JSONResponse({"error": "invalid JSON"}, status_code=400)

    # Extract repo info
    repo = payload.get("repository", {})
    repo_name = repo.get("name", "")
    ref = payload.get("ref", "")
    pusher = payload.get("pusher", {}).get("login", "unknown")

    if not repo_name:
        return JSONResponse({"error": "no repository name"}, status_code=400)

    # Only trigger on main branch
    if ref not in ("refs/heads/main", "refs/heads/master"):
        return {"status": "skipped", "reason": f"branch {ref} is not main"}

    # Map repo to rooms via dependency graph
    deps = DependencyGraph()

    # Search for rooms whose project field matches this repo name
    target_rooms = []
    for room_key, meta in deps._room_meta.items():
        project = meta.get("project", "")
        # Match by leaf name: "infrastructure/postgresql" matches repo "postgresql"
        # Also match full path if someone uses it
        if project.split("/")[-1] == repo_name or project == repo_name:
            site = room_key.split("/")[0] if "/" in room_key else ""
            room = room_key.split("/")[-1] if "/" in room_key else room_key
            target_rooms.append(
                {
                    "room": room,
                    "site": site,
                    "ip": meta.get("ip", ""),
                    "mcp_port": meta.get("mcp_port", 0),
                }
            )

    if not target_rooms:
        return {"status": "no_targets", "repo": repo_name}

    # Determine action — maude updates itself, everything else deploys
    action = "self_update" if repo_name == "maude" else "self_deploy"

    # Signal via EventPublisher (fire-and-forget)
    publisher = EventPublisher(project="coordinator")
    try:
        await publisher.connect()
        signals = []
        for target in target_rooms:
            ok = await publisher.publish(
                "deploy_requested",
                {
                    "repo": repo_name,
                    "target_room": target["room"],
                    "site": target["site"],
                    "action": action,
                    "pusher": pusher,
                },
            )
            signals.append(
                {
                    "room": target["room"],
                    "site": target["site"],
                    "signaled": ok,
                }
            )
    finally:
        await publisher.close()

    logger.info(
        "Webhook: %s pushed %s -> signaled %d rooms (%s)",
        pusher,
        repo_name,
        len(signals),
        action,
    )

    return {
        "status": "ok",
        "repo": repo_name,
        "action": action,
        "pusher": pusher,
        "rooms_signaled": signals,
    }


@router.get("/status")
async def webhook_status():
    """Webhook endpoint health check."""
    return {"status": "ready", "endpoints": ["/webhook/gitea"]}
