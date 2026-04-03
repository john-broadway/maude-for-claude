# Tests for memory type system — policies, scoping, and helper functions.
# Version: 1.0.0
# Created: 2026-04-02 15:15 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Tests for maude.memory.types — structured memory type policies."""

from maude.memory.types import (
    _DEFAULT_POLICY,
    SCOPE_HIERARCHY,
    MemoryType,
    MemoryTypePolicy,
    get_policy,
    retention_days,
    should_embed,
    should_sync_to_pg,
    types_for_scope,
)

# ── MemoryType enum ──────────────────────────────────────────────────


def test_memory_type_values():
    """Enum string values match what's stored in the database."""
    assert MemoryType.CHECK.value == "check"
    assert MemoryType.INCIDENT.value == "incident"
    assert MemoryType.REMEDIATION.value == "remediation"
    assert MemoryType.PATTERN.value == "pattern"
    assert MemoryType.DECISION.value == "decision"
    assert MemoryType.VISIT.value == "visit"
    assert MemoryType.ESCALATION_INVESTIGATION.value == "escalation_investigation"


def test_memory_type_is_str():
    """MemoryType members can be used as plain strings."""
    assert MemoryType.CHECK == "check"
    assert isinstance(MemoryType.INCIDENT, str)


def test_all_types_have_policies():
    """Every MemoryType member has an entry in the policy registry."""
    for mt in MemoryType:
        policy = get_policy(mt.value)
        assert isinstance(policy, MemoryTypePolicy), f"Missing policy for {mt}"
        assert policy is not _DEFAULT_POLICY, f"{mt} using default policy"


# ── get_policy ───────────────────────────────────────────────────────


def test_get_policy_known_type():
    policy = get_policy("incident")
    assert policy.retention_days == 180
    assert policy.embed is True
    assert policy.share_scope == "incidents"


def test_get_policy_unknown_type():
    """Unknown types get the default policy, not an error."""
    policy = get_policy("totally_unknown_type")
    assert policy is _DEFAULT_POLICY
    assert policy.retention_days == 90
    assert policy.embed is True


def test_get_policy_empty_string():
    policy = get_policy("")
    assert policy is _DEFAULT_POLICY


# ── should_embed ─────────────────────────────────────────────────────


def test_should_embed_incident():
    assert should_embed("incident") is True


def test_should_embed_check_no_action():
    """check/no_action never embeds — special case."""
    assert should_embed("check", "no_action") is False


def test_should_embed_check_with_action():
    """check with non-no_action outcome uses policy (which says False)."""
    assert should_embed("check", "remediated") is False


def test_should_embed_visit():
    """Visit memories don't embed — low signal-to-noise."""
    assert should_embed("visit") is False


def test_should_embed_remediation():
    assert should_embed("remediation") is True


def test_should_embed_pattern():
    assert should_embed("pattern") is True


def test_should_embed_unknown():
    """Unknown types embed by default (safe fallback)."""
    assert should_embed("new_custom_type") is True


# ── should_sync_to_pg ────────────────────────────────────────────────


def test_should_sync_check_no_action():
    """check/no_action stays local — too noisy for shared PG."""
    assert should_sync_to_pg("check", "no_action") is False


def test_should_sync_check_policy():
    """Check type has sync_to_pg=False in policy."""
    assert should_sync_to_pg("check") is False


def test_should_sync_incident():
    assert should_sync_to_pg("incident") is True


def test_should_sync_pattern():
    assert should_sync_to_pg("pattern") is True


def test_should_sync_unknown():
    assert should_sync_to_pg("custom_type") is True


# ── types_for_scope ──────────────────────────────────────────────────


def test_patterns_scope():
    scope = types_for_scope("patterns")
    assert "pattern" in scope
    assert "decision" in scope
    assert "remediation" in scope
    assert "incident" not in scope
    assert "check" not in scope


def test_incidents_scope():
    scope = types_for_scope("incidents")
    # Includes patterns scope
    assert "pattern" in scope
    assert "decision" in scope
    assert "remediation" in scope
    # Plus incident-level types
    assert "incident" in scope
    assert "escalation" in scope
    assert "trend_warning" in scope
    # Not all types
    assert "check" not in scope
    assert "visit" not in scope


def test_all_scope():
    scope = types_for_scope("all")
    for mt in MemoryType:
        assert mt.value in scope, f"{mt.value} missing from 'all' scope"


def test_unknown_scope_falls_back():
    """Unknown scopes fall back to 'patterns' (most restrictive)."""
    scope = types_for_scope("nonexistent")
    assert scope == SCOPE_HIERARCHY["patterns"]


# ── retention_days ───────────────────────────────────────────────────


def test_retention_permanent_types():
    """Pattern, remediation, and decision never expire."""
    assert retention_days("pattern") is None
    assert retention_days("remediation") is None
    assert retention_days("decision") is None


def test_retention_check():
    assert retention_days("check") == 14


def test_retention_incident():
    assert retention_days("incident") == 180


def test_retention_visit():
    assert retention_days("visit") == 30


def test_retention_unknown():
    assert retention_days("unknown_type") == 90


# ── Policy consistency checks ────────────────────────────────────────


def test_scope_hierarchy_is_cumulative():
    """Each scope includes all types from more restrictive scopes."""
    patterns = SCOPE_HIERARCHY["patterns"]
    incidents = SCOPE_HIERARCHY["incidents"]
    all_types = SCOPE_HIERARCHY["all"]

    assert patterns.issubset(incidents), "patterns should be subset of incidents"
    assert incidents.issubset(all_types), "incidents should be subset of all"


def test_permanent_types_always_embed():
    """Types with no retention should embed (they're valuable enough to keep)."""
    for mt in MemoryType:
        policy = get_policy(mt.value)
        if (
            policy.retention_days is None
            and mt != MemoryType.SESSION_ARCHIVE
            and mt != MemoryType.SYNTHETIC
        ):
            assert policy.embed is True, f"{mt.value} is permanent but doesn't embed"


def test_policy_frozen():
    """Policies are immutable — frozen dataclass."""
    policy = get_policy("incident")
    try:
        policy.embed = False  # type: ignore[misc]
        raised = False
    except AttributeError:
        raised = True
    assert raised, "Policy should be frozen/immutable"
