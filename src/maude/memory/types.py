# Maude Memory Type System — policies for retention, embedding, and sharing.
# Version: 1.0.0
# Created: 2026-04-02 15:00 MST
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>, Claude (Anthropic)
"""Structured memory type system — policies for retention, embedding, and sharing.

Each memory type has explicit policies for:
- retention: how long to keep (None = forever)
- embed: whether to push to Qdrant for semantic search
- share_scope: minimum privacy scope that includes this type
- consolidate: how to group during consolidation

Soft validation: unknown types get default policies and a log warning.
Existing data with arbitrary type strings is never rejected.

Inspired by Claude Code's structured type system (user, feedback, project,
reference) but adapted for Maude's infrastructure monitoring domain.
"""

from __future__ import annotations

import enum
import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class MemoryTypePolicy:
    """Policy governing how a memory type is stored, recalled, and shared.

    Attributes:
        retention_days: Days before pruning (None = never prune).
        embed: Whether to auto-embed to Qdrant for semantic recall.
        share_scope: Minimum privacy scope: "patterns", "incidents", or "all".
        consolidate: Consolidation strategy: "similarity", "time_window", or "none".
        sync_to_pg: Whether to sync from SQLite to PostgreSQL.
    """

    retention_days: int | None
    embed: bool
    share_scope: str
    consolidate: str
    sync_to_pg: bool


class MemoryType(str, enum.Enum):
    """Known memory types with associated policies.

    The string value matches what's stored in the database, so
    ``MemoryType.CHECK.value == "check"`` etc.
    """

    # ── Core types (health loop + room agent) ────────────────────────
    CHECK = "check"
    INCIDENT = "incident"
    ESCALATION = "escalation"
    REMEDIATION = "remediation"
    PATTERN = "pattern"
    DECISION = "decision"
    TREND_WARNING = "trend_warning"

    # ── Interaction types ────────────────────────────────────────────
    VISIT = "visit"
    CONCIERGE = "concierge"

    # ── Inter-room types ─────────────────────────────────────────────
    RELAY_INCOMING = "relay_incoming"

    # ── Proactive investigation ──────────────────────────────────────
    ESCALATION_INVESTIGATION = "escalation_investigation"

    # ── Session / archival ────────────────────────────────────────────
    SESSION = "session"
    SESSION_ARCHIVE = "session_archive"
    SYNTHETIC = "synthetic"


# ── Policy registry ──────────────────────────────────────────────────
# Policies are defined once here, consumed by store.py, sync.py, and
# memory_tools.py instead of scattered hardcoded checks.

_POLICIES: dict[MemoryType, MemoryTypePolicy] = {
    # Health checks: short retention, no embedding (noise), no sharing
    MemoryType.CHECK: MemoryTypePolicy(
        retention_days=14,
        embed=False,
        share_scope="all",
        consolidate="none",
        sync_to_pg=False,  # check/no_action stays local
    ),
    # Incidents: long retention, always embed, shared at incidents scope
    MemoryType.INCIDENT: MemoryTypePolicy(
        retention_days=180,
        embed=True,
        share_scope="incidents",
        consolidate="similarity",
        sync_to_pg=True,
    ),
    # Escalations: long retention, embed for pattern matching
    MemoryType.ESCALATION: MemoryTypePolicy(
        retention_days=180,
        embed=True,
        share_scope="incidents",
        consolidate="time_window",
        sync_to_pg=True,
    ),
    # Remediations: permanent, always embed (most valuable for learning)
    MemoryType.REMEDIATION: MemoryTypePolicy(
        retention_days=None,
        embed=True,
        share_scope="patterns",
        consolidate="similarity",
        sync_to_pg=True,
    ),
    # Patterns: permanent, always embed, always share
    MemoryType.PATTERN: MemoryTypePolicy(
        retention_days=None,
        embed=True,
        share_scope="patterns",
        consolidate="none",  # patterns are the OUTPUT of consolidation
        sync_to_pg=True,
    ),
    # Decisions: permanent, always embed, always share
    MemoryType.DECISION: MemoryTypePolicy(
        retention_days=None,
        embed=True,
        share_scope="patterns",
        consolidate="none",
        sync_to_pg=True,
    ),
    # Trend warnings: medium retention, embed for correlation
    MemoryType.TREND_WARNING: MemoryTypePolicy(
        retention_days=90,
        embed=True,
        share_scope="incidents",
        consolidate="time_window",
        sync_to_pg=True,
    ),
    # Visits: short retention, no embedding (Claude Code interaction logs)
    MemoryType.VISIT: MemoryTypePolicy(
        retention_days=30,
        embed=False,
        share_scope="all",
        consolidate="none",
        sync_to_pg=True,
    ),
    # Concierge: short retention, no embedding (chat logs)
    MemoryType.CONCIERGE: MemoryTypePolicy(
        retention_days=30,
        embed=False,
        share_scope="all",
        consolidate="none",
        sync_to_pg=True,
    ),
    # Relay incoming: medium retention, embed for cross-room context
    MemoryType.RELAY_INCOMING: MemoryTypePolicy(
        retention_days=90,
        embed=True,
        share_scope="incidents",
        consolidate="none",
        sync_to_pg=True,
    ),
    # Escalation investigations: permanent, always embed
    MemoryType.ESCALATION_INVESTIGATION: MemoryTypePolicy(
        retention_days=None,
        embed=True,
        share_scope="incidents",
        consolidate="similarity",
        sync_to_pg=True,
    ),
    # Session: sidecar session saves — high volume, low value per unit.
    # Short retention, no embedding, no consolidation.
    MemoryType.SESSION: MemoryTypePolicy(
        retention_days=14,
        embed=False,
        share_scope="all",
        consolidate="none",
        sync_to_pg=True,
    ),
    # Session archives: permanent, no embedding (raw data)
    MemoryType.SESSION_ARCHIVE: MemoryTypePolicy(
        retention_days=None,
        embed=False,
        share_scope="all",
        consolidate="none",
        sync_to_pg=True,
    ),
    # Synthetic training data: permanent, no embedding
    MemoryType.SYNTHETIC: MemoryTypePolicy(
        retention_days=None,
        embed=False,
        share_scope="all",
        consolidate="none",
        sync_to_pg=True,
    ),
}

# Default policy for unknown types — embed to be safe, share at all
_DEFAULT_POLICY = MemoryTypePolicy(
    retention_days=90,
    embed=True,
    share_scope="all",
    consolidate="none",
    sync_to_pg=True,
)

# Scope hierarchy for sharing — which types are visible at each scope
SCOPE_HIERARCHY: dict[str, set[str]] = {
    "patterns": {t.value for t, p in _POLICIES.items() if p.share_scope == "patterns"},
    "incidents": {
        t.value for t, p in _POLICIES.items() if p.share_scope in ("patterns", "incidents")
    },
    "all": {t.value for t in MemoryType},
}


def get_policy(memory_type: str) -> MemoryTypePolicy:
    """Look up the policy for a memory type.

    Returns the default policy for unknown types (with a debug log).
    Never raises — unknown types are tolerated, not rejected.
    """
    try:
        mt = MemoryType(memory_type)
        return _POLICIES[mt]
    except ValueError:
        logger.debug("Unknown memory type %r — using default policy", memory_type)
        return _DEFAULT_POLICY


def should_embed(memory_type: str, outcome: str = "") -> bool:
    """Whether a memory should be embedded in Qdrant.

    Special case: check/no_action never embeds regardless of policy,
    because the signal-to-noise ratio is too low.
    """
    if memory_type == "check" and outcome == "no_action":
        return False
    return get_policy(memory_type).embed


def should_sync_to_pg(memory_type: str, outcome: str = "") -> bool:
    """Whether a memory should be synced from SQLite to PostgreSQL.

    Check/no_action memories stay local — they're high volume and low value.
    Incidents without actions and bare escalations are also noise.
    """
    policy = get_policy(memory_type)
    if not policy.sync_to_pg:
        return False
    # Additional noise filter for known noisy combinations
    if memory_type == "check" and outcome == "no_action":
        return False
    return True


def types_for_scope(scope: str) -> set[str]:
    """Return the set of memory type values visible at a given scope.

    Falls back to "patterns" (most restrictive) for unknown scopes.
    """
    return SCOPE_HIERARCHY.get(scope, SCOPE_HIERARCHY["patterns"])


def retention_days(memory_type: str) -> int | None:
    """Return retention period in days for a memory type (None = permanent)."""
    return get_policy(memory_type).retention_days
