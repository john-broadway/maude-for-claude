# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Static dependency graph for Maude Rooms.

Loaded from dependencies.yaml — not auto-discovered. Maude's multi-site
topology changes infrequently, so static declaration is simpler and
more reliable than runtime probing.

Room keys are qualified as "{site}/{room}" — e.g., "site-a/postgresql",
"site-b/postgresql". The resolve() method maps bare names to site-a
(flagship default) for backward compatibility.
"""

import logging
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)

_DEFAULT_YAML = Path(__file__).parent / "dependencies.yaml"


class DependencyGraph:
    """Room dependency graph for impact analysis.

    Args:
        yaml_path: Path to dependencies.yaml. Defaults to bundled file.
    """

    # Keys extracted as room-level metadata (everything except depends_on/model/web_url)
    _META_KEYS = (
        "ctid",
        "ip",
        "mcp_port",
        "service_port",
        "layer",
        "project",
        "description",
        "site",
    )

    def __init__(self, yaml_path: Path | None = None) -> None:
        path = yaml_path or _DEFAULT_YAML
        data = yaml.safe_load(path.read_text())
        self._rooms: dict[str, list[str]] = {}
        self._reverse: dict[str, list[str]] = {}
        self._models: dict[str, dict[str, Any]] = {}
        self._web_urls: dict[str, str] = {}
        self._room_meta: dict[str, dict[str, Any]] = {}

        for site, site_rooms in (data.get("rooms") or {}).items():
            if not isinstance(site_rooms, dict):
                continue
            for room, cfg in site_rooms.items():
                key = f"{site}/{room}"
                if not isinstance(cfg, dict):
                    continue
                # Inject site from structure
                cfg.setdefault("site", site)
                # Resolve depends_on: bare names -> same site
                raw_deps = cfg.get("depends_on", [])
                deps = [d if "/" in d else f"{site}/{d}" for d in raw_deps]
                self._rooms[key] = deps
                model = cfg.get("model")
                if model and isinstance(model, dict):
                    self._models[key] = model
                url = cfg.get("web_url")
                if url:
                    self._web_urls[key] = url
                # Extract infrastructure metadata
                meta = {k: cfg[k] for k in self._META_KEYS if k in cfg}
                if meta:
                    self._room_meta[key] = meta

        # Build reverse map (depended_by)
        for room in self._rooms:
            self._reverse[room] = []
        for room, deps in self._rooms.items():
            for dep in deps:
                if dep in self._reverse:
                    self._reverse[dep].append(room)

        # Infrastructure and layers
        self._infrastructure: dict[str, Any] = data.get("infrastructure") or {}
        self._layers_raw: dict[str, dict[str, Any]] = data.get("layers") or {}

    def resolve(self, name: str) -> str | None:
        """Resolve a room name to its qualified key.

        'postgresql' -> 'site-a/postgresql' (flagship default)
        'site-b/postgresql' -> 'site-b/postgresql' (already qualified)
        """
        if name in self._rooms:
            return name
        # Try site-a (default site)
        slc_key = f"site-a/{name}"
        if slc_key in self._rooms:
            return slc_key
        return None

    @property
    def all_rooms(self) -> list[str]:
        """All known room names (qualified: site/room)."""
        return sorted(self._rooms.keys())

    def depends_on(self, room: str) -> list[str]:
        """Direct upstream dependencies of a room."""
        key = self.resolve(room) or room
        return list(self._rooms.get(key, []))

    def depended_by(self, room: str) -> list[str]:
        """Rooms that directly depend on this room."""
        key = self.resolve(room) or room
        return list(self._reverse.get(key, []))

    def affected_by(self, room: str) -> list[str]:
        """Transitive downstream: all rooms affected if this room goes down."""
        key = self.resolve(room) or room
        affected: set[str] = set()
        queue = list(self._reverse.get(key, []))
        while queue:
            current = queue.pop(0)
            if current not in affected:
                affected.add(current)
                queue.extend(r for r in self._reverse.get(current, []) if r not in affected)
        return sorted(affected)

    def model_for(self, room: str) -> dict[str, Any]:
        """Model configuration for a room. Empty dict if not configured."""
        key = self.resolve(room) or room
        return dict(self._models.get(key, {}))

    def web_url(self, room: str) -> str | None:
        """Browser-accessible URL for a room, or None."""
        key = self.resolve(room) or room
        return self._web_urls.get(key)

    def room_info(self, room: str) -> dict[str, Any]:
        """Full metadata for a room (ctid, ip, ports, layer, description)."""
        key = self.resolve(room) or room
        meta = dict(self._room_meta.get(key, {}))
        meta["depends_on"] = self._rooms.get(key, [])
        meta["depended_by"] = self._reverse.get(key, [])
        url = self._web_urls.get(key)
        if url:
            meta["web_url"] = url
        return meta

    def rooms_by_site(self, site: str) -> list[str]:
        """Room names filtered by site code (e.g. 'site-a', 'site-b')."""
        return sorted(room for room, meta in self._room_meta.items() if meta.get("site") == site)

    def infrastructure(self) -> dict[str, Any]:
        """Sites, storage, PLCs, off-limits VMs."""
        return dict(self._infrastructure)

    def layers(self) -> list[dict[str, Any]]:
        """Ordered layer definitions with their rooms."""
        result = []
        for key, layer_cfg in self._layers_raw.items():
            rooms_val = layer_cfg.get("rooms", [])
            if isinstance(rooms_val, dict):
                # Nested by site: {"site-a": ["my-service"], "site-b": ["my-service"]}
                flat = [f"{site}/{r}" for site, rlist in rooms_val.items() for r in rlist]
            else:
                flat = list(rooms_val)
            entry: dict[str, Any] = {
                "key": key,
                "label": layer_cfg.get("label", key),
                "description": layer_cfg.get("description", ""),
                "rooms": sorted(flat),
            }
            result.append(entry)
        return result

    def to_ecosystem_dict(self) -> dict[str, Any]:
        """Full ecosystem as serializable dict — rooms + infra + layers."""
        rooms = {}
        for room in sorted(self._rooms):
            rooms[room] = self.room_info(room)
            model = self._models.get(room)
            if model:
                rooms[room]["model"] = model
        return {
            "rooms": rooms,
            "infrastructure": self.infrastructure(),
            "layers": self.layers(),
        }

    def to_dict(self) -> dict[str, Any]:
        """Full graph as a serializable dict."""
        result = {}
        for room in sorted(self._rooms):
            result[room] = {
                "depends_on": self._rooms[room],
                "depended_by": self._reverse.get(room, []),
            }
        return result
