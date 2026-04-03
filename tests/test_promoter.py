# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
#
# Version: 1.0.0
# Created: 2026-03-30 22:45 MST
# Author(s): John Broadway, Claude (Anthropic)

"""Tests for maude.healing.training.promoter — canary lifecycle, ratio stepping, rollback."""

import pytest

from maude.healing.training.promoter import (
    RATIO_LADDER,
    ROLLBACK_THRESHOLD,
    ModelPromoter,
)

# ── Fake asyncpg pool ──────────────────────────────────────────────


class FakeRow(dict):
    """Dict that also supports attribute-style access like asyncpg.Record."""

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name)


class FakePool:
    """In-memory pool that simulates model_promotions table."""

    def __init__(self):
        self._rows = []
        self._id_counter = 0
        self._table_created = False

    async def execute(self, sql, *args):
        sql_lower = sql.strip().lower()
        if sql_lower.startswith("create table") or sql_lower.startswith("create unique"):
            self._table_created = True
            return

        if "insert into model_promotions" in sql_lower:
            # Check unique constraint
            for row in self._rows:
                if row["project"] == args[0] and row["status"] in ("canary", "promoted"):
                    raise Exception("uq_active_promotion violation")
            self._id_counter += 1
            self._rows.append(
                FakeRow(
                    id=self._id_counter,
                    project=args[0],
                    training_run_id=args[1],
                    model_name=args[2],
                    status="canary",
                    challenger_ratio=args[3],
                    baseline_autonomy=args[4],
                    validation_score=args[5],
                    current_autonomy=None,
                    created_at=None,
                    promoted_at=None,
                    rolled_back_at=None,
                )
            )
            return

        if "update model_promotions set current_autonomy" in sql_lower:
            for row in self._rows:
                if row["id"] == args[1]:
                    row["current_autonomy"] = args[0]
            return

        if "update model_promotions" in sql_lower and "challenger_ratio" in sql_lower:
            if "status = 'promoted'" in sql_lower:
                for row in self._rows:
                    if row["project"] == args[0] and row["training_run_id"] == args[1]:
                        row["status"] = "promoted"
                        row["challenger_ratio"] = 1.0
            elif "status = 'rolled_back'" in sql_lower:
                for row in self._rows:
                    if row["project"] == args[0] and row["status"] in ("canary", "promoted"):
                        row["status"] = "rolled_back"
                        row["challenger_ratio"] = 0.0
            else:
                # Ratio step
                for row in self._rows:
                    if row["id"] == args[1]:
                        row["challenger_ratio"] = args[0]
            return

    async def fetchval(self, sql, *args):
        sql_lower = sql.strip().lower()
        if "insert into model_promotions" in sql_lower:
            await self.execute(sql, *args)
            return self._id_counter
        return None

    async def fetchrow(self, sql, *args):
        sql_lower = sql.strip().lower()
        if "from model_promotions" in sql_lower:
            project = args[0]
            for row in self._rows:
                if row["project"] == project and row["status"] in ("canary", "promoted"):
                    return row
        return None

    async def fetch(self, sql, *args):
        sql_lower = sql.strip().lower()
        if "status = 'canary'" in sql_lower:
            return [FakeRow(project=r["project"]) for r in self._rows if r["status"] == "canary"]
        if "status in ('canary', 'promoted')" in sql_lower.replace("'", "'"):
            return [
                FakeRow(model_name=r["model_name"])
                for r in self._rows
                if r["status"] in ("canary", "promoted")
            ]
        return []


@pytest.fixture
def pool():
    return FakePool()


@pytest.fixture
def promoter(pool):
    p = ModelPromoter(pool=pool)
    return p


# ── start_canary ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_start_canary(promoter, pool):
    """Start canary creates a record with initial ratio."""
    row_id = await promoter.start_canary(
        project="monitoring",
        training_run_id=42,
        model_name="maude-agent-v42",
        validation_score=0.85,
        baseline_autonomy=70.0,
    )
    assert row_id == 1
    assert len(pool._rows) == 1
    assert pool._rows[0]["status"] == "canary"
    assert pool._rows[0]["challenger_ratio"] == RATIO_LADDER[0]
    assert pool._rows[0]["baseline_autonomy"] == 70.0


@pytest.mark.asyncio
async def test_start_canary_blocks_duplicate(promoter, pool):
    """Cannot start a second canary while one is active."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    row_id = await promoter.start_canary("monitoring", 43, "maude-agent-v43", 0.90, 72.0)
    assert row_id == 0  # blocked by unique constraint
    assert len(pool._rows) == 1


@pytest.mark.asyncio
async def test_start_canary_different_projects(promoter, pool):
    """Different projects can have independent canaries."""
    id1 = await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    id2 = await promoter.start_canary("example-scada", 43, "maude-agent-v43", 0.90, 72.0)
    assert id1 == 1
    assert id2 == 2


# ── get_active ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_active_none(promoter):
    """No active promotion returns None."""
    result = await promoter.get_active("monitoring")
    assert result is None


@pytest.mark.asyncio
async def test_get_active_returns_canary(promoter):
    """Active canary is returned."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    active = await promoter.get_active("monitoring")
    assert active is not None
    assert active["model_name"] == "maude-agent-v42"
    assert active["status"] == "canary"


# ── evaluate_canary ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_evaluate_no_canary(promoter):
    """Evaluate with no active canary returns no_change."""
    result = await promoter.evaluate_canary("monitoring", 75.0)
    assert result["action"] == "no_change"


@pytest.mark.asyncio
async def test_evaluate_steps_ratio(promoter, pool):
    """Autonomy >= baseline steps ratio up."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    result = await promoter.evaluate_canary("monitoring", 72.0)
    assert result["action"] == "stepped"
    assert result["ratio_from"] == RATIO_LADDER[0]
    assert result["ratio_to"] == RATIO_LADDER[1]


@pytest.mark.asyncio
async def test_evaluate_holds_when_below_baseline(promoter, pool):
    """Autonomy below baseline but above rollback threshold holds ratio."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    result = await promoter.evaluate_canary("monitoring", 68.0)
    assert result["action"] == "no_change"
    assert result["reason"] == "autonomy below baseline, holding ratio"


@pytest.mark.asyncio
async def test_evaluate_rollback(promoter, pool):
    """Autonomy drops below rollback threshold triggers rollback."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    result = await promoter.evaluate_canary("monitoring", 70.0 - ROLLBACK_THRESHOLD - 1)
    assert result["action"] == "rolled_back"
    assert pool._rows[0]["status"] == "rolled_back"
    assert pool._rows[0]["challenger_ratio"] == 0.0


@pytest.mark.asyncio
async def test_evaluate_promotes_at_top(promoter, pool):
    """Stepping past the ladder promotes the model."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    # Step through the ladder
    for expected_to in RATIO_LADDER[1:]:
        result = await promoter.evaluate_canary("monitoring", 75.0)
        if expected_to < 1.0:
            assert result["action"] == "stepped"
        else:
            assert result["action"] == "promoted"

    assert pool._rows[0]["status"] == "promoted"
    assert pool._rows[0]["challenger_ratio"] == 1.0


# ── promote / rollback ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_manual_promote(promoter, pool):
    """Manual promote sets status and ratio."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    await promoter.promote("monitoring", 42)
    assert pool._rows[0]["status"] == "promoted"
    assert pool._rows[0]["challenger_ratio"] == 1.0


@pytest.mark.asyncio
async def test_manual_rollback(promoter, pool):
    """Manual rollback sets status and ratio."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    await promoter.rollback("monitoring")
    assert pool._rows[0]["status"] == "rolled_back"
    assert pool._rows[0]["challenger_ratio"] == 0.0


# ── list_active_canaries ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_list_active_canaries(promoter, pool):
    """Lists projects with active canaries."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    await promoter.start_canary("example-scada", 43, "maude-agent-v43", 0.90, 72.0)
    canaries = await promoter.list_active_canaries()
    assert set(canaries) == {"monitoring", "example-scada"}


@pytest.mark.asyncio
async def test_list_active_canaries_excludes_rolled_back(promoter, pool):
    """Rolled-back canaries are not listed."""
    await promoter.start_canary("monitoring", 42, "maude-agent-v42", 0.85, 70.0)
    await promoter.rollback("monitoring")
    canaries = await promoter.list_active_canaries()
    assert canaries == []


# ── no pool ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_no_pool_graceful():
    """All operations return gracefully when DB is unavailable."""
    promoter = ModelPromoter(pool=None)
    promoter._lazy = None  # Simulate no DB at all
    promoter._pool = None

    assert await promoter.start_canary("x", 1, "m", 0.8, 70) == 0
    assert await promoter.get_active("x") is None
    assert (await promoter.evaluate_canary("x", 75))["action"] == "no_change"
    assert await promoter.list_active_canaries() == []
    await promoter.close()  # No error
