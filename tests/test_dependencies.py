# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for DependencyGraph — static YAML-based room topology."""

from pathlib import Path

import pytest

from maude.healing.dependencies import DependencyGraph

_FIXTURE_YAML = Path(__file__).parent / "fixtures" / "dependencies.yaml"


@pytest.fixture
def graph() -> DependencyGraph:
    """Load the test fixture dependencies.yaml (not the empty production stub)."""
    return DependencyGraph(yaml_path=_FIXTURE_YAML)


# ── Basic structure ───────────────────────────────────────────────


def test_all_rooms(graph: DependencyGraph):
    rooms = graph.all_rooms
    assert "site-a/postgresql" in rooms
    assert "site-a/my-service" in rooms
    assert "site-a/monitoring" in rooms
    assert "site-a/workbench" in rooms
    assert "site-b/postgresql" in rooms
    assert "site-c/maude" in rooms
    assert len(rooms) == 58  # 28 SLC + 11 PA + 19 SBM


def test_rooms_by_site(graph: DependencyGraph):
    slc = graph.rooms_by_site("site-a")
    pa = graph.rooms_by_site("site-b")
    site_c = graph.rooms_by_site("site-c")
    assert len(slc) == 28
    assert len(pa) == 11
    assert len(site_c) == 19
    assert "site-a/postgresql" in slc
    assert "site-a/workbench" in slc
    assert "site-b/postgresql" in pa
    assert "site-b/maude" in pa
    assert "site-c/maude" in site_c


# ── resolve ──────────────────────────────────────────────────────


def test_resolve_bare_name_to_slc(graph: DependencyGraph):
    assert graph.resolve("postgresql") == "site-a/postgresql"
    assert graph.resolve("my-service") == "site-a/my-service"


def test_resolve_qualified_passthrough(graph: DependencyGraph):
    assert graph.resolve("site-b/postgresql") == "site-b/postgresql"
    assert graph.resolve("site-c/maude") == "site-c/maude"


def test_resolve_unknown(graph: DependencyGraph):
    assert graph.resolve("nonexistent") is None


# ── depends_on ────────────────────────────────────────────────────


def test_collector_depends_on_database(graph: DependencyGraph):
    deps = graph.depends_on("my-service")
    assert "site-a/postgresql" in deps
    assert "site-a/influxdb" in deps


def test_postgresql_depends_on_nothing(graph: DependencyGraph):
    deps = graph.depends_on("postgresql")
    assert deps == []


def test_monitoring_depends_on_three(graph: DependencyGraph):
    deps = graph.depends_on("monitoring")
    assert set(deps) == {"site-a/postgresql", "site-a/prometheus", "site-a/loki"}


def test_workbench_depends_on(graph: DependencyGraph):
    deps = graph.depends_on("site-a/workbench")
    assert set(deps) == {"site-a/postgresql", "site-a/my-service"}


def test_pa_monitoring_depends_on_pa_rooms(graph: DependencyGraph):
    deps = graph.depends_on("site-b/monitoring")
    assert set(deps) == {"site-b/postgresql", "site-b/prometheus", "site-b/loki"}


def test_pa_maude_depends_on_pa_postgresql(graph: DependencyGraph):
    deps = graph.depends_on("site-b/maude")
    assert deps == ["site-b/postgresql"]


def test_site_c_maude_depends_on_nothing(graph: DependencyGraph):
    deps = graph.depends_on("site-c/maude")
    assert deps == []


# ── depended_by ───────────────────────────────────────────────────


def test_postgresql_depended_by(graph: DependencyGraph):
    """PostgreSQL is a central dependency — many rooms depend on it."""
    dep_by = graph.depended_by("postgresql")
    assert "site-a/my-service" in dep_by
    assert "site-a/monitoring" in dep_by
    assert "site-a/panel" in dep_by
    assert "site-a/workbench" in dep_by


def test_gitea_depended_by_none(graph: DependencyGraph):
    dep_by = graph.depended_by("gitea")
    assert dep_by == []


# ── affected_by (transitive) ─────────────────────────────────────


def test_postgresql_affects_transitively(graph: DependencyGraph):
    """PostgreSQL going down should affect my-service, panel, workbench, and monitoring."""
    affected = graph.affected_by("postgresql")
    assert "site-a/my-service" in affected
    assert "site-a/monitoring" in affected
    assert "site-a/panel" in affected
    assert "site-a/workbench" in affected


def test_gitea_affects_nothing(graph: DependencyGraph):
    affected = graph.affected_by("gitea")
    assert affected == []


def test_timeseries_affects_collector(graph: DependencyGraph):
    affected = graph.affected_by("influxdb")
    assert "site-a/my-service" in affected


# ── to_dict ───────────────────────────────────────────────────────


def test_to_dict(graph: DependencyGraph):
    d = graph.to_dict()
    assert "site-a/postgresql" in d
    assert "depends_on" in d["site-a/postgresql"]
    assert "depended_by" in d["site-a/postgresql"]


# ── model_for ─────────────────────────────────────────────────────


def test_model_for_collector(graph: DependencyGraph):
    model = graph.model_for("my-service")
    assert model["name"] == "my-service-agent"
    assert model["base"] == "maude-agent"
    assert model["parameters"]["temperature"] == 0.2
    assert model["parameters"]["num_predict"] == 4096


def test_model_for_gpu_node_2(graph: DependencyGraph):
    """gpu-node-2 has its own model config."""
    model = graph.model_for("gpu-node-2")
    assert model["name"] == "Qwen/Qwen3-8B"
    assert model["base"] == "Qwen/Qwen3-8B"


def test_model_for_unknown_room(graph: DependencyGraph):
    model = graph.model_for("nonexistent")
    assert model == {}


def test_model_for_returns_copy(graph: DependencyGraph):
    """model_for returns a copy, not the internal dict."""
    model1 = graph.model_for("my-service")
    model2 = graph.model_for("my-service")
    assert model1 == model2
    model1["name"] = "mutated"
    assert graph.model_for("my-service")["name"] == "my-service-agent"


# ── Unknown room ──────────────────────────────────────────────────


def test_unknown_room_returns_empty(graph: DependencyGraph):
    assert graph.depends_on("nonexistent") == []
    assert graph.depended_by("nonexistent") == []
    assert graph.affected_by("nonexistent") == []


# ── Infrastructure & layers ───────────────────────────────────────


def test_infrastructure_has_security(graph: DependencyGraph):
    # authentik, wazuh, fleet moved from infrastructure.security to rooms.site-a
    rooms = graph.rooms_by_site("site-a")
    assert "site-a/authentik" in rooms
    assert "site-a/wazuh" in rooms
    assert "site-a/fleet" in rooms
    wazuh = graph.room_info("site-a/wazuh")
    assert wazuh["ctid"] == 144


def test_layers_example_scada_includes_workbench(graph: DependencyGraph):
    layers = graph.layers()
    scada_layer = next(ly for ly in layers if ly["key"] == "example-scada")
    assert "site-a/workbench" in scada_layer["rooms"]
    assert "site-a/my-service" in scada_layer["rooms"]
    assert "site-b/my-service" in scada_layer["rooms"]


def test_layers_maude_multisite(graph: DependencyGraph):
    layers = graph.layers()
    maude_layer = next(ly for ly in layers if ly["key"] == "maude_layer")
    assert "site-a/maude" in maude_layer["rooms"]
    assert "site-b/maude" in maude_layer["rooms"]
    assert "site-c/maude" in maude_layer["rooms"]


# ── PA corrections (no stale VLAN 10 data) ────────────────────────


def test_pa_rooms_have_correct_ips(graph: DependencyGraph):
    """Site-b rooms use TEST-NET-2 (198.51.100.x), not site-a range."""
    pa_rooms = graph.rooms_by_site("site-b")
    for room in pa_rooms:
        info = graph.room_info(room)
        assert not info["ip"].startswith("192.0.2."), f"{room} has site-a IP: {info['ip']}"


def test_pa_ctids_mirror_host(graph: DependencyGraph):
    """PA CTIDs follow {3}{host} pattern."""
    expected = {
        "site-b/maude": 380,
        "site-b/postgresql": 330,
        "site-b/redis": 333,
        "site-b/monitoring": 340,
        "site-b/prometheus": 341,
        "site-b/loki": 342,
        "site-b/uptime-kuma": 343,
        "site-b/my-service": 350,
        "site-b/panel": 351,
        "site-b/lab-service": 352,
        "site-b/gitea": 360,
    }
    for room, ctid in expected.items():
        info = graph.room_info(room)
        assert info["ctid"] == ctid, f"{room} CTID: expected {ctid}, got {info['ctid']}"


# ── Ecosystem dict ────────────────────────────────────────────────


def test_ecosystem_dict_keys(graph: DependencyGraph):
    eco = graph.to_ecosystem_dict()
    assert "rooms" in eco
    assert "infrastructure" in eco
    assert "layers" in eco
    assert "site-a/postgresql" in eco["rooms"]
    assert "site-b/postgresql" in eco["rooms"]
    assert "site-c/maude" in eco["rooms"]
