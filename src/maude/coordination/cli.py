# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Coordinator CLI — system-wide briefings from the command line.

Usage:
    maude-coordinator briefing                         # Full hotel briefing
    maude-coordinator briefing --scope room:my-service  # Single room
    maude-coordinator briefing --minutes 480            # Last 8 hours
    maude-coordinator status                            # Room grid
    maude-coordinator deps my-service                   # Dependency tree
    maude-coordinator incidents                         # Recent incidents
    maude-coordinator escalations                       # Recent escalations
"""

import argparse
import asyncio
import json
import sys

from maude.coordination.briefing import BriefingGenerator
from maude.coordination.cross_room_memory import CrossRoomMemory
from maude.coordination.dependencies import DependencyGraph


async def _briefing(args: argparse.Namespace) -> None:
    memory = CrossRoomMemory()
    deps = DependencyGraph()
    gen = BriefingGenerator(memory, deps)
    try:
        output = await gen.generate(scope=args.scope, minutes=args.minutes)
        print(output)
    finally:
        await memory.close()


async def _status(args: argparse.Namespace) -> None:
    memory = CrossRoomMemory()
    deps = DependencyGraph()
    gen = BriefingGenerator(memory, deps)
    try:
        output = await gen.room_status(minutes=args.minutes)
        print(output)
    finally:
        await memory.close()


async def _deps(args: argparse.Namespace) -> None:
    deps = DependencyGraph()
    room = args.room
    if room:
        result = {
            "room": room,
            "depends_on": deps.depends_on(room),
            "depended_by": deps.depended_by(room),
            "affected_by": deps.affected_by(room),
        }
        print(json.dumps(result, indent=2))
    else:
        print(json.dumps(deps.to_dict(), indent=2))


async def _incidents(args: argparse.Namespace) -> None:
    memory = CrossRoomMemory()
    try:
        incidents = await memory.recent_incidents(minutes=args.minutes)
        if not incidents:
            print("No incidents in the last", args.minutes, "minutes")
            return
        for inc in incidents:
            ts = inc.get("created_at", "?")
            room = inc.get("project", "?")
            summary = inc.get("summary", "")[:120]
            outcome = inc.get("outcome", "")
            print(f"[{ts}] {room}: {summary} [{outcome}]")
    finally:
        await memory.close()


async def _escalations(args: argparse.Namespace) -> None:
    memory = CrossRoomMemory()
    try:
        escs = await memory.recent_escalations(minutes=args.minutes)
        if not escs:
            print("No escalations in the last", args.minutes, "minutes")
            return
        for esc in escs:
            ts = esc.get("created_at", "?")
            room = esc.get("project", "?")
            summary = esc.get("summary", "")[:120]
            print(f"[{ts}] {room}: {summary}")
    finally:
        await memory.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="maude-coordinator",
        description="Maude Coordination — system-wide coordination",
    )
    sub = parser.add_subparsers(dest="command")

    # briefing
    p_briefing = sub.add_parser("briefing", help="Cross-room briefing")
    p_briefing.add_argument("--scope", default="all", help="'all' or 'room:<name>'")
    p_briefing.add_argument("--minutes", type=int, default=60, help="Lookback window")

    # status
    p_status = sub.add_parser("status", help="Room status grid")
    p_status.add_argument("--minutes", type=int, default=60, help="Lookback window")

    # deps
    p_deps = sub.add_parser("deps", help="Show dependency graph")
    p_deps.add_argument("room", nargs="?", default="", help="Room name (omit for full graph)")

    # incidents
    p_incidents = sub.add_parser("incidents", help="Recent incidents")
    p_incidents.add_argument("--minutes", type=int, default=60, help="Lookback window")

    # escalations
    p_escalations = sub.add_parser("escalations", help="Recent escalations")
    p_escalations.add_argument("--minutes", type=int, default=60, help="Lookback window")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    dispatch = {
        "briefing": _briefing,
        "status": _status,
        "deps": _deps,
        "incidents": _incidents,
        "escalations": _escalations,
    }
    asyncio.run(dispatch[args.command](args))


if __name__ == "__main__":
    main()
