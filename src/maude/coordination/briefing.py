"""Briefing generator — template-based cross-room summaries.

No LLM needed. Queries CrossRoomMemory (single site) or CrossSiteMemory
(hotel-wide / specific remote site). Fast and deterministic.

Version: 1.1
Created: 2026-03-19
Authors: John Broadway (271895126+john-broadway@users.noreply.github.com), Claude
"""

import asyncio
import logging
from datetime import datetime
from typing import TYPE_CHECKING, Any

from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.healing.dependencies import DependencyGraph

if TYPE_CHECKING:
    from maude.coordination.cross_site_memory import CrossSiteMemory

logger = logging.getLogger(__name__)


class BriefingGenerator:
    """Generate cross-room briefings from memory and dependency data.

    Args:
        memory: CrossRoomMemory instance (single-site queries).
        deps: DependencyGraph instance.
        alert_webhook_url: Optional HTTP URL for webhook alerts. When set,
            an HTTP POST is fired (fire-and-forget) if any rooms are unhealthy.
        cross_site: Optional CrossSiteMemory for hotel-wide / remote-site scopes.
    """

    def __init__(
        self,
        memory: CrossRoomMemory,
        deps: DependencyGraph,
        alert_webhook_url: str = "",
        cross_site: "CrossSiteMemory | None" = None,
        analytics: Any | None = None,
    ) -> None:
        self.memory = memory
        self.deps = deps
        self._alert_webhook_url = alert_webhook_url
        self.cross_site = cross_site
        self._analytics = analytics

    async def generate(
        self,
        scope: str = "all",
        minutes: int = 60,
    ) -> str:
        """Generate a template-based briefing.

        Args:
            scope: Controls data source and filtering:
                - "all" or "site" — current site (default, uses CrossRoomMemory)
                - "room:<name>" — single-room focus on current site
                - "hotel" — all sites aggregated (requires CrossSiteMemory)
                - "site:<name>" — specific remote site (requires CrossSiteMemory)
            minutes: Lookback window in minutes.

        Returns:
            Formatted briefing text.
        """
        if scope == "hotel":
            return await self._generate_hotel(minutes)
        if scope.startswith("site:") and len(scope) > 5:
            return await self._generate_remote_site(scope[5:], minutes)
        # "all", "site", or "room:<name>" — single-site behaviour (unchanged)
        return await self._generate_local(scope, minutes)

    async def _generate_local(self, scope: str, minutes: int) -> str:
        """Generate briefing from the local site's CrossRoomMemory."""
        summaries = await self.memory.all_rooms_summary(minutes)
        incidents = await self.memory.recent_incidents(minutes)
        escalations = await self.memory.recent_escalations(minutes)
        restarts = await self.memory.recent_restarts(minutes)
        remediations = await self.memory.recent_remediations(minutes)

        # Filter to single room if scoped
        target_room = ""
        if scope.startswith("room:"):
            target_room = scope[5:]
            summaries = [s for s in summaries if s.get("project") == target_room]
            incidents = [i for i in incidents if i.get("project") == target_room]
            escalations = [e for e in escalations if e.get("project") == target_room]
            restarts = [r for r in restarts if r.get("project") == target_room]
            remediations = [r for r in remediations if r.get("project") == target_room]

        lines: list[str] = []
        lines.append(f"=== Coordinator Briefing (last {minutes} min) ===")
        lines.append("")

        # Room status overview
        unhealthy_rooms = []
        healthy_rooms = []
        active_rooms = {s.get("project", "?") for s in summaries if s.get("project")}

        for s in summaries:
            room = s.get("project", "?")
            if not room or room == "?":
                continue
            if (s.get("failed") or 0) > 0 or (s.get("escalated") or 0) > 0:
                detail_parts = []
                if s.get("failed"):
                    detail_parts.append(f"{s['failed']} failed")
                if s.get("escalated"):
                    detail_parts.append(f"{s['escalated']} escalated")
                room_restarts = [r for r in restarts if r.get("project") == room]
                if room_restarts:
                    detail_parts.append(f"{len(room_restarts)} restart(s)")
                unhealthy_rooms.append(f"{room} ({', '.join(detail_parts)})")
            else:
                healthy_rooms.append(room)

        # Include rooms with no activity as quiet
        all_known = self.deps.all_rooms
        quiet_rooms = sorted(set(all_known) - active_rooms)

        # Fire webhook alert if unhealthy rooms exist (non-blocking)
        if unhealthy_rooms and self._alert_webhook_url:
            asyncio.create_task(self._post_webhook(unhealthy_rooms))

        if unhealthy_rooms:
            lines.append(f"UNHEALTHY ROOMS: {'; '.join(unhealthy_rooms)}")
        else:
            lines.append("UNHEALTHY ROOMS: none")

        if healthy_rooms:
            lines.append(f"ALL CLEAR: {', '.join(sorted(healthy_rooms))}")
        if quiet_rooms:
            lines.append(f"QUIET (no activity): {', '.join(quiet_rooms)}")

        lines.append("")

        # Incidents
        lines.append("INCIDENTS:")
        if incidents:
            for inc in incidents[:15]:
                ts = self._format_time(inc.get("created_at", ""))
                room = inc.get("project", "?")
                summary = (inc.get("summary") or "")[:120]
                outcome = inc.get("outcome", "")
                lines.append(f"  [{ts}] {room}: {summary} [{outcome}]")
        else:
            lines.append("  none")

        lines.append("")

        # Autonomous fixes
        lines.append("AUTONOMOUS FIXES:")
        if remediations:
            for rem in remediations[:10]:
                ts = self._format_time(rem.get("created_at", ""))
                room = rem.get("project", "?")
                summary = (rem.get("summary") or "")[:120]
                lines.append(f"  [{ts}] {room}: {summary}")
        else:
            lines.append("  none")

        lines.append("")

        # Escalations
        lines.append("ESCALATIONS:")
        if escalations:
            for esc in escalations[:10]:
                ts = self._format_time(esc.get("created_at", ""))
                room = esc.get("project", "?")
                summary = (esc.get("summary") or "")[:120]
                lines.append(f"  [{ts}] {room}: {summary}")
        else:
            lines.append("  none")

        lines.append("")

        # Dependency risk assessment
        if target_room:
            lines.append(f"DEPENDENCIES FOR {target_room}:")
            deps_on = self.deps.depends_on(target_room)
            dep_by = self.deps.depended_by(target_room)
            if deps_on:
                lines.append(f"  Depends on: {', '.join(deps_on)}")
            if dep_by:
                lines.append(f"  Depended by: {', '.join(dep_by)}")
            if not deps_on and not dep_by:
                lines.append("  No dependencies")
        else:
            lines.append("DEPENDENCIES AT RISK:")
            unhealthy_names = {
                s["project"]
                for s in summaries
                if (s.get("failed") or 0) > 0 or (s.get("escalated") or 0) > 0
            }
            if unhealthy_names:
                for room in sorted(unhealthy_names):
                    affected = self.deps.affected_by(room)
                    if affected:
                        lines.append(f"  {room} → {', '.join(affected)}")
                    else:
                        lines.append(f"  {room} → no downstream dependencies")
            else:
                lines.append("  none (all rooms healthy)")

        # Analytics insights (optional — only when BriefingAnalytics is wired)
        if self._analytics:
            try:
                insights = await self._analytics.analyze(minutes)
                if insights:
                    lines.append("")
                    lines.append("INSIGHTS:")
                    for insight in insights:
                        lines.append(f"  * {insight}")
            except Exception:
                logger.debug("Briefing analytics failed (non-fatal)")

        return "\n".join(lines)

    async def _generate_hotel(self, minutes: int) -> str:
        """Generate a hotel-wide briefing across all sites."""
        if self.cross_site is None:
            return "Cross-site federation not configured (CrossSiteMemory unavailable)"

        all_summaries = await self.cross_site.all_sites_summary(minutes)
        all_incidents = await self.cross_site.recent_incidents(minutes)
        all_escalations = await self.cross_site.recent_escalations(minutes)

        lines: list[str] = []
        lines.append(f"=== Coordinator Briefing — Hotel-wide (last {minutes} min) ===")
        lines.append("")

        for site_name in self.cross_site.site_names:
            summaries = all_summaries.get(site_name, [])
            lines.append(f"[{site_name.upper()}]")
            if not summaries:
                lines.append("  QUIET (no activity or unreachable)")
            else:
                unhealthy = [
                    f"{s['project']} ({s.get('failed', 0)} failed,"
                    f" {s.get('escalated', 0)} escalated)"
                    for s in summaries
                    if (s.get("failed") or 0) > 0 or (s.get("escalated") or 0) > 0
                ]
                healthy = [
                    s["project"]
                    for s in summaries
                    if not ((s.get("failed") or 0) > 0 or (s.get("escalated") or 0) > 0)
                ]
                if unhealthy:
                    lines.append(f"  UNHEALTHY: {'; '.join(unhealthy)}")
                if healthy:
                    lines.append(f"  OK: {', '.join(healthy)}")
            lines.append("")

        lines.append("HOTEL-WIDE INCIDENTS:")
        site_incidents = [i for i in all_incidents if i.get("outcome") in ("failed", "escalated")]
        if site_incidents:
            for inc in site_incidents[:20]:
                ts = self._format_time(inc.get("created_at", ""))
                site = inc.get("site", "?")
                room = inc.get("project", "?")
                summary = (inc.get("summary") or "")[:100]
                outcome = inc.get("outcome") or ""
                lines.append(f"  [{ts}] {site}/{room}: {summary} [{outcome}]")
        else:
            lines.append("  none")

        lines.append("")
        lines.append("HOTEL-WIDE ESCALATIONS:")
        if all_escalations:
            for esc in all_escalations[:10]:
                ts = self._format_time(esc.get("created_at", ""))
                site = esc.get("site", "?")
                room = esc.get("project", "?")
                summary = (esc.get("summary") or "")[:100]
                lines.append(f"  [{ts}] {site}/{room}: {summary}")
        else:
            lines.append("  none")

        return "\n".join(lines)

    async def _generate_remote_site(self, site_name: str, minutes: int) -> str:
        """Generate a briefing for a specific remote site."""
        if self.cross_site is None:
            return "Cross-site federation not configured (CrossSiteMemory unavailable)"

        summaries_by_site = await self.cross_site.all_sites_summary(minutes)
        summaries = summaries_by_site.get(site_name, [])
        incidents = await self.cross_site.recent_incidents(minutes, site=site_name)
        escalations = await self.cross_site.recent_escalations(minutes, site=site_name)

        lines: list[str] = []
        lines.append(f"=== Coordinator Briefing — {site_name.upper()} (last {minutes} min) ===")
        lines.append("")

        if not summaries:
            lines.append("QUIET (no activity or site unreachable)")
            return "\n".join(lines)

        unhealthy_rooms = []
        healthy_rooms = []
        for s in summaries:
            room = s["project"]
            if (s.get("failed") or 0) > 0 or (s.get("escalated") or 0) > 0:
                detail_parts = []
                if s.get("failed"):
                    detail_parts.append(f"{s['failed']} failed")
                if s.get("escalated"):
                    detail_parts.append(f"{s['escalated']} escalated")
                unhealthy_rooms.append(f"{room} ({', '.join(detail_parts)})")
            else:
                healthy_rooms.append(room)

        if unhealthy_rooms:
            lines.append(f"UNHEALTHY ROOMS: {'; '.join(unhealthy_rooms)}")
        else:
            lines.append("UNHEALTHY ROOMS: none")
        if healthy_rooms:
            lines.append(f"ALL CLEAR: {', '.join(sorted(healthy_rooms))}")

        lines.append("")
        lines.append("INCIDENTS:")
        if incidents:
            for inc in incidents[:15]:
                ts = self._format_time(inc.get("created_at", ""))
                room = inc.get("project", "?")
                summary = (inc.get("summary") or "")[:120]
                outcome = inc.get("outcome", "")
                lines.append(f"  [{ts}] {room}: {summary} [{outcome}]")
        else:
            lines.append("  none")

        lines.append("")
        lines.append("ESCALATIONS:")
        if escalations:
            for esc in escalations[:10]:
                ts = self._format_time(esc.get("created_at", ""))
                room = esc.get("project", "?")
                summary = (esc.get("summary") or "")[:120]
                lines.append(f"  [{ts}] {room}: {summary}")
        else:
            lines.append("  none")

        return "\n".join(lines)

    async def room_status(self, minutes: int = 60) -> str:
        """Quick room grid — one line per room."""
        summaries = await self.memory.all_rooms_summary(minutes)
        summary_map = {s["project"]: s for s in summaries}

        lines = ["ROOM STATUS GRID:", ""]
        for room in self.deps.all_rooms:
            # Try qualified key first, then bare name (DB stores bare names)
            bare = room.rsplit("/", 1)[-1] if "/" in room else room
            s = summary_map.get(room) or summary_map.get(bare)
            if not s:
                lines.append(f"  {room:<16} quiet")
            elif (s.get("failed") or 0) > 0 or (s.get("escalated") or 0) > 0:
                parts = [
                    f"runs={s['total_runs']} resolved={s.get('resolved', 0)} "
                    f"failed={s.get('failed', 0)} escalated={s.get('escalated', 0)}"
                ]
                if (s.get("remediated") or 0) > 0:
                    parts.append(f"remediated={s['remediated']}")
                lines.append(f"  {room:<16} ATTENTION  " + " ".join(parts))
            else:
                parts = [
                    f"runs={s['total_runs']} resolved={s.get('resolved', 0)} "
                    f"no_action={s.get('no_action', 0)}"
                ]
                if (s.get("remediated") or 0) > 0:
                    parts.append(f"remediated={s['remediated']}")
                lines.append(f"  {room:<16} ok  " + " ".join(parts))
        return "\n".join(lines)

    async def _post_webhook(self, unhealthy_rooms: list[str]) -> None:
        """POST an alert to the configured webhook URL (fire-and-forget)."""
        try:
            import httpx

            payload = {
                "text": f"Coordinator: {len(unhealthy_rooms)} room(s) unhealthy",
                "rooms": unhealthy_rooms,
            }
            async with httpx.AsyncClient(timeout=10.0) as client:
                await client.post(self._alert_webhook_url, json=payload)
        except Exception:
            logger.debug("Briefing webhook delivery failed (non-fatal)")

    @staticmethod
    def _format_time(ts: Any) -> str:
        """Format a timestamp for display."""
        if isinstance(ts, str) and ts:
            try:
                dt = datetime.fromisoformat(ts)
                return dt.strftime("%H:%M")
            except Exception:
                return ts[:5]
        if isinstance(ts, datetime):
            return ts.strftime("%H:%M")
        return "??:??"
