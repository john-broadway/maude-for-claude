# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.acl — role-based access control engine."""

import pytest

from maude.middleware.acl import ACLDecision, ACLEngine, ACLRule

# ── ACLDecision ───────────────────────────────────────────────────


def test_acl_decision_fields():
    d = ACLDecision(
        allowed=True,
        caller="claude-code",
        role="admin",
        tool="service_status",
        reason="ok",
    )
    assert d.allowed is True
    assert d.caller == "claude-code"
    assert d.role == "admin"
    assert d.tool == "service_status"
    assert d.reason == "ok"


# ── ACLRule ───────────────────────────────────────────────────────


def test_acl_rule_defaults():
    rule = ACLRule(tools=["service_*"], roles=["admin"])
    assert rule.allow is True


def test_acl_rule_deny():
    rule = ACLRule(tools=["kill_switch_*"], roles=["viewer"], allow=False)
    assert rule.allow is False


# ── ACLEngine.from_config ─────────────────────────────────────────


def test_from_config_basic():
    config = {
        "enabled": True,
        "default_allow": False,
        "roles": {"admin": ["claude-code"], "viewer": ["*"]},
        "rules": [
            {"tools": ["service_restart"], "roles": ["admin"]},
            {"tools": ["service_status"], "roles": ["admin", "viewer"]},
        ],
    }
    engine = ACLEngine.from_config(config)
    assert engine.enabled is True
    assert engine.default_allow is False
    assert len(engine.rules) == 2
    assert engine.roles["admin"] == ["claude-code"]


def test_from_config_defaults():
    engine = ACLEngine.from_config({})
    assert engine.enabled is True
    assert engine.default_allow is True
    assert engine.rules == []
    assert engine.roles == {}


def test_from_config_disabled():
    engine = ACLEngine.from_config({"enabled": False})
    assert engine.enabled is False


# ── resolve_role ──────────────────────────────────────────────────


def test_resolve_role_exact_match():
    engine = ACLEngine(roles={"admin": ["claude-code", "coordinator"], "viewer": ["monitoring"]})
    assert engine.resolve_role("claude-code") == "admin"
    assert engine.resolve_role("coordinator") == "admin"
    assert engine.resolve_role("monitoring") == "viewer"


def test_resolve_role_wildcard():
    engine = ACLEngine(roles={"admin": ["claude-code"], "viewer": ["*"]})
    assert engine.resolve_role("claude-code") == "admin"
    assert engine.resolve_role("anything-else") == "viewer"


def test_resolve_role_unknown():
    engine = ACLEngine(roles={"admin": ["claude-code"]})
    assert engine.resolve_role("unknown-caller") == "unknown"


def test_resolve_role_empty_roles():
    engine = ACLEngine(roles={})
    assert engine.resolve_role("anyone") == "unknown"


# ── check — disabled ACL ─────────────────────────────────────────


def test_check_disabled_always_allows():
    engine = ACLEngine(enabled=False)
    d = engine.check("anyone", "any_tool")
    assert d.allowed is True
    assert d.reason == "acl disabled"
    assert d.role == ""


# ── check — rule matching ────────────────────────────────────────


@pytest.fixture
def acl_engine():
    return ACLEngine(
        roles={
            "admin": ["claude-code", "coordinator"],
            "operator": ["room-agent"],
            "viewer": ["monitoring"],
        },
        rules=[
            ACLRule(tools=["service_restart", "kill_switch_*"], roles=["admin"]),
            ACLRule(
                tools=["service_status", "service_health"],
                roles=["admin", "operator", "viewer"],
            ),
            ACLRule(tools=["memory_*"], roles=["admin", "operator"]),
        ],
        default_allow=True,
    )


def test_check_admin_allowed_restart(acl_engine):
    d = acl_engine.check("claude-code", "service_restart")
    assert d.allowed is True
    assert d.role == "admin"
    assert "rule matched" in d.reason


def test_check_viewer_denied_restart(acl_engine):
    d = acl_engine.check("monitoring", "service_restart")
    assert d.allowed is False
    assert d.role == "viewer"
    assert "not in" in d.reason


def test_check_viewer_allowed_status(acl_engine):
    d = acl_engine.check("monitoring", "service_status")
    assert d.allowed is True
    assert d.role == "viewer"


def test_check_glob_pattern_kill_switch(acl_engine):
    d = acl_engine.check("claude-code", "kill_switch_activate")
    assert d.allowed is True
    assert d.role == "admin"


def test_check_glob_pattern_kill_switch_denied(acl_engine):
    d = acl_engine.check("monitoring", "kill_switch_activate")
    assert d.allowed is False


def test_check_memory_glob_admin(acl_engine):
    d = acl_engine.check("claude-code", "memory_store")
    assert d.allowed is True


def test_check_memory_glob_operator(acl_engine):
    d = acl_engine.check("room-agent", "memory_recall_recent")
    assert d.allowed is True


def test_check_memory_glob_viewer_denied(acl_engine):
    d = acl_engine.check("monitoring", "memory_store")
    assert d.allowed is False


# ── check — default policy ───────────────────────────────────────


def test_check_unmatched_tool_default_allow(acl_engine):
    """Tool not matching any rule falls to default_allow=True."""
    d = acl_engine.check("monitoring", "some_unknown_tool")
    assert d.allowed is True
    assert d.reason == "default policy"


def test_check_unmatched_tool_default_deny():
    engine = ACLEngine(
        roles={"admin": ["claude-code"]},
        rules=[ACLRule(tools=["service_restart"], roles=["admin"])],
        default_allow=False,
    )
    d = engine.check("claude-code", "unmatched_tool")
    assert d.allowed is False
    assert d.reason == "default policy"


# ── check — unknown caller ───────────────────────────────────────


def test_check_unknown_caller_denied_by_rule(acl_engine):
    """Unknown callers get role='unknown', denied by rules requiring specific roles."""
    d = acl_engine.check("unknown-system", "service_restart")
    assert d.allowed is False
    assert d.role == "unknown"


def test_check_unknown_caller_default_allow(acl_engine):
    """Unknown callers fall through to default policy for unmatched tools."""
    d = acl_engine.check("unknown-system", "some_random_tool")
    assert d.allowed is True
    assert d.role == "unknown"
    assert d.reason == "default policy"


# ── check — anonymous caller ─────────────────────────────────────


def test_check_anonymous_as_viewer():
    """Anonymous callers matched by wildcard role."""
    engine = ACLEngine(
        roles={"viewer": ["*"]},
        rules=[ACLRule(tools=["service_status"], roles=["viewer"])],
    )
    d = engine.check("anonymous", "service_status")
    assert d.allowed is True
    assert d.role == "viewer"
