# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Tests for AdminRegistry — autonomous actions and guardrails
#          Claude (Anthropic) <noreply@anthropic.com>
"""Tests for AdminRegistry — autonomous actions and guardrails."""

from maude.healing.admin_registry import AdminRegistry, AdminRegistryConfig

# ── AdminRegistryConfig ─────────────────────────────────────────


def test_config_from_dict_defaults():
    """from_dict with None returns disabled defaults."""
    cfg = AdminRegistryConfig.from_dict(None)
    assert cfg.enabled is False
    assert cfg.allowed_actions == set()
    assert cfg.min_pattern_confidence == 0.75


def test_config_from_dict_full():
    """from_dict parses all fields."""
    cfg = AdminRegistryConfig.from_dict(
        {
            "enabled": True,
            "allowed_actions": ["restart_service", "clear_cache"],
            "guardrails": ["no_self_stop", "no_data_destruction"],
            "min_pattern_confidence": 0.8,
            "min_pattern_occurrences": 5,
            "custom_actions": [
                {"name": "vacuum_chunks", "command": "SELECT 1", "description": "Test"},
            ],
        }
    )
    assert cfg.enabled is True
    assert cfg.allowed_actions == {"restart_service", "clear_cache"}
    assert cfg.guardrails == ["no_self_stop", "no_data_destruction"]
    assert cfg.min_pattern_confidence == 0.8
    assert cfg.min_pattern_occurrences == 5
    assert len(cfg.custom_actions) == 1


def test_config_from_dict_default_guardrails():
    """from_dict without guardrails key uses all builtins."""
    cfg = AdminRegistryConfig.from_dict({"enabled": True})
    assert "no_self_stop" in cfg.guardrails
    assert "no_config_mutation" in cfg.guardrails
    assert "no_cross_room" in cfg.guardrails
    assert "no_data_destruction" in cfg.guardrails


# ── Registry basics ──────────────────────────────────────────────


def _make_registry(
    enabled: bool = True,
    allowed: list[str] | None = None,
    guardrails: list[str] | None = None,
    custom_actions: list[dict] | None = None,
) -> AdminRegistry:
    cfg = AdminRegistryConfig(
        enabled=enabled,
        allowed_actions=set(allowed or ["restart_service"]),
        guardrails=guardrails if guardrails is not None else [],
        custom_actions=custom_actions or [],
    )
    return AdminRegistry(config=cfg, service_name="monitoring-server", project="monitoring")


def test_enabled_property():
    """enabled property reflects config."""
    reg = _make_registry(enabled=True)
    assert reg.enabled is True
    reg_off = _make_registry(enabled=False)
    assert reg_off.enabled is False


def test_is_allowed_standard_action():
    """Standard actions in allowed set return True."""
    reg = _make_registry(allowed=["restart_service", "clear_cache"])
    assert reg.is_allowed("restart_service") is True
    assert reg.is_allowed("clear_cache") is True
    assert reg.is_allowed("delete_tmp") is False


def test_is_allowed_disabled():
    """Disabled registry always returns False."""
    reg = _make_registry(enabled=False, allowed=["restart_service"])
    assert reg.is_allowed("restart_service") is False


def test_is_allowed_custom_action():
    """Custom actions are also allowed."""
    reg = _make_registry(
        custom_actions=[{"name": "vacuum_chunks", "command": "SELECT 1"}],
    )
    assert reg.is_allowed("vacuum_chunks") is True


# ── Guardrails ───────────────────────────────────────────────────


def test_guardrails_disabled_registry():
    """Disabled registry returns not-allowed."""
    reg = _make_registry(enabled=False)
    result = reg.check_guardrails("restart_service")
    assert result.allowed is False
    assert result.guardrail == "disabled"


def test_guardrails_action_not_allowed():
    """Action not in allowed set is blocked."""
    reg = _make_registry(allowed=["restart_service"])
    result = reg.check_guardrails("delete_tmp")
    assert result.allowed is False
    assert result.guardrail == "not_allowed"


def test_guardrails_allowed_no_command():
    """Allowed action with no command passes all guardrails."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_self_stop", "no_config_mutation"],
    )
    result = reg.check_guardrails("restart_service")
    assert result.allowed is True


def test_guardrail_no_self_stop():
    """no_self_stop blocks stopping own service."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_self_stop"],
    )
    result = reg.check_guardrails(
        "restart_service",
        command="systemctl stop maude@monitoring",
    )
    assert result.allowed is False
    assert result.guardrail == "no_self_stop"


def test_guardrail_no_self_stop_allows_restart():
    """no_self_stop does NOT block restart (only stop/disable)."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_self_stop"],
    )
    result = reg.check_guardrails(
        "restart_service",
        command="systemctl restart monitoring-server",
    )
    assert result.allowed is True


def test_guardrail_no_config_mutation():
    """no_config_mutation blocks config file writes."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_config_mutation"],
    )
    result = reg.check_guardrails(
        "restart_service",
        command="echo 'x' > config.yaml",
    )
    assert result.allowed is False
    assert result.guardrail == "no_config_mutation"


def test_guardrail_no_cross_room():
    """no_cross_room blocks operations on other rooms."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_cross_room"],
    )
    result = reg.check_guardrails(
        "restart_service",
        command="systemctl restart maude@my-service",
    )
    assert result.allowed is False
    assert result.guardrail == "no_cross_room"


def test_guardrail_no_cross_room_allows_own():
    """no_cross_room allows operations on own room."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_cross_room"],
    )
    result = reg.check_guardrails(
        "restart_service",
        command="systemctl restart maude@monitoring",
    )
    assert result.allowed is True


def test_guardrail_no_data_destruction():
    """no_data_destruction blocks dangerous data operations."""
    reg = _make_registry(
        allowed=["vacuum_db"],
        guardrails=["no_data_destruction"],
    )
    for cmd in [
        "rm -rf /var/lib/maude/monitoring/",
        "DROP TABLE agent_memory",
        "TRUNCATE agent_memory",
    ]:
        result = reg.check_guardrails("vacuum_db", command=cmd)
        assert result.allowed is False, f"Should block: {cmd}"
        assert result.guardrail == "no_data_destruction"


def test_guardrail_no_data_destruction_allows_safe():
    """no_data_destruction allows DELETE with WHERE clause."""
    reg = _make_registry(
        allowed=["vacuum_db"],
        guardrails=["no_data_destruction"],
    )
    result = reg.check_guardrails(
        "vacuum_db",
        command="DELETE FROM agent_memory WHERE created_at < '2025-01-01'",
    )
    assert result.allowed is True


def test_multiple_guardrails():
    """Multiple guardrails are all checked."""
    reg = _make_registry(
        allowed=["restart_service"],
        guardrails=["no_self_stop", "no_config_mutation", "no_cross_room"],
    )
    result = reg.check_guardrails(
        "restart_service",
        command="systemctl stop maude@monitoring",
    )
    assert result.allowed is False


# ── should_auto_resolve() ────────────────────────────────────────


def test_should_auto_resolve_meets_thresholds():
    """Returns True when all thresholds are met."""
    cfg = AdminRegistryConfig(
        enabled=True,
        allowed_actions={"restart_service"},
        min_pattern_confidence=0.75,
        min_pattern_occurrences=3,
    )
    reg = AdminRegistry(config=cfg, service_name="monitoring-server", project="monitoring")
    assert reg.should_auto_resolve("restart_service", 0.85, 5) is True


def test_should_auto_resolve_low_confidence():
    """Returns False when success rate is below threshold."""
    cfg = AdminRegistryConfig(
        enabled=True,
        allowed_actions={"restart_service"},
        min_pattern_confidence=0.75,
        min_pattern_occurrences=3,
    )
    reg = AdminRegistry(config=cfg, service_name="monitoring-server", project="monitoring")
    assert reg.should_auto_resolve("restart_service", 0.50, 5) is False


def test_should_auto_resolve_low_occurrences():
    """Returns False when occurrences below threshold."""
    cfg = AdminRegistryConfig(
        enabled=True,
        allowed_actions={"restart_service"},
        min_pattern_confidence=0.75,
        min_pattern_occurrences=3,
    )
    reg = AdminRegistry(config=cfg, service_name="monitoring-server", project="monitoring")
    assert reg.should_auto_resolve("restart_service", 0.90, 2) is False


def test_should_auto_resolve_action_not_allowed():
    """Returns False when action isn't in allowed set."""
    cfg = AdminRegistryConfig(
        enabled=True,
        allowed_actions={"clear_cache"},
    )
    reg = AdminRegistry(config=cfg, service_name="monitoring-server", project="monitoring")
    assert reg.should_auto_resolve("restart_service", 0.90, 5) is False


def test_should_auto_resolve_disabled():
    """Returns False when registry is disabled."""
    cfg = AdminRegistryConfig(enabled=False, allowed_actions={"restart_service"})
    reg = AdminRegistry(config=cfg, service_name="monitoring-server", project="monitoring")
    assert reg.should_auto_resolve("restart_service", 0.90, 5) is False


# ── Custom actions ───────────────────────────────────────────────


def test_get_custom_action():
    """get_custom_action returns the registered action."""
    reg = _make_registry(
        custom_actions=[
            {
                "name": "vacuum_chunks",
                "command": "SELECT run_maintenance()",
                "description": "TimescaleDB maintenance",
            },
        ],
    )
    action = reg.get_custom_action("vacuum_chunks")
    assert action is not None
    assert action.name == "vacuum_chunks"
    assert "maintenance" in action.description


def test_get_custom_action_not_found():
    """get_custom_action returns None for unknown action."""
    reg = _make_registry()
    assert reg.get_custom_action("nonexistent") is None


# ── describe() ───────────────────────────────────────────────────


def test_describe_output():
    """describe() returns diagnostic summary."""
    reg = _make_registry(
        allowed=["restart_service", "clear_cache"],
        guardrails=["no_self_stop"],
    )
    desc = reg.describe()
    assert desc["enabled"] is True
    assert desc["guardrails"] == ["no_self_stop"]
    assert desc["standard_actions"]["restart_service"] is True
    assert desc["standard_actions"]["delete_tmp"] is False
