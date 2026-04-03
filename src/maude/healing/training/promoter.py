# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
#
# Version: 1.0.0
# Created: 2026-03-30 22:30 MST
# Author(s): John Broadway, Claude (Anthropic)

"""Model promotion lifecycle — canary → promoted → rolled_back.

Manages the bridge between training pipeline output and Room Agent
model selection. When a training run passes validation, the promoter
starts a canary deployment at low traffic ratio. Over successive
evaluation cycles, the ratio steps up if autonomy metrics hold.

The ``model_promotions`` table uses a partial unique index to guarantee
at most one active promotion (canary or promoted) per project.

Usage:
    promoter = ModelPromoter()
    await promoter.start_canary("monitoring", run_id=42, ...)
    active = await promoter.get_active("monitoring")
    result = await promoter.evaluate_canary("monitoring", current_autonomy=76.0)
"""

import logging
from typing import Any

from maude.db import LazyPool

logger = logging.getLogger(__name__)

# Canary ratio ladder — each step requires autonomy >= baseline
RATIO_LADDER = [0.10, 0.25, 0.50, 1.00]

# Rollback if autonomy drops more than this below baseline
ROLLBACK_THRESHOLD = 5.0

_CREATE_TABLE = """\
CREATE TABLE IF NOT EXISTS model_promotions (
    id SERIAL PRIMARY KEY,
    project TEXT NOT NULL,
    training_run_id INT NOT NULL,
    model_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'canary',
    challenger_ratio FLOAT NOT NULL DEFAULT 0.10,
    baseline_autonomy FLOAT,
    current_autonomy FLOAT,
    validation_score FLOAT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    promoted_at TIMESTAMPTZ,
    rolled_back_at TIMESTAMPTZ
)"""

_CREATE_INDEX = """\
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_promotion
    ON model_promotions (project) WHERE status IN ('canary', 'promoted')"""


class ModelPromoter:
    """Manages model promotion lifecycle for trained LoRA adapters.

    Args:
        pool: Optional asyncpg pool. If None, creates a lazy pool to 'agent' DB.
    """

    def __init__(self, pool: Any | None = None) -> None:
        self._external_pool = pool is not None
        if pool is not None:
            self._pool = pool
            self._lazy: LazyPool | None = None
        else:
            self._pool = None
            self._lazy = LazyPool(database="agent", min_size=1, max_size=2)

    async def _ensure_pool(self) -> Any | None:
        if self._pool is not None:
            return self._pool
        if self._lazy:
            pool = await self._lazy.get()
            if pool:
                self._pool = pool
            return pool
        return None

    async def _ensure_table(self, pool: Any) -> None:
        """Create the model_promotions table if it doesn't exist."""
        try:
            await pool.execute(_CREATE_TABLE)
            await pool.execute(_CREATE_INDEX)
        except Exception:
            logger.debug("model_promotions table creation skipped (may already exist)")

    async def start_canary(
        self,
        project: str,
        training_run_id: int,
        model_name: str,
        validation_score: float,
        baseline_autonomy: float,
    ) -> int:
        """Start a canary deployment for a validated model.

        Returns the promotion record ID, or 0 on failure.
        """
        pool = await self._ensure_pool()
        if not pool:
            logger.warning("Cannot start canary — database unavailable")
            return 0

        await self._ensure_table(pool)

        try:
            row_id = await pool.fetchval(
                """INSERT INTO model_promotions
                       (project, training_run_id, model_name, status,
                        challenger_ratio, baseline_autonomy, validation_score)
                   VALUES ($1, $2, $3, 'canary', $4, $5, $6)
                   RETURNING id""",
                project,
                training_run_id,
                model_name,
                RATIO_LADDER[0],
                baseline_autonomy,
                validation_score,
            )
            logger.info(
                "Canary started: %s at %.0f%% (baseline autonomy=%.1f)",
                model_name,
                RATIO_LADDER[0] * 100,
                baseline_autonomy,
            )
            return int(row_id)
        except Exception as e:
            # Unique index violation = another active promotion exists
            if "uq_active_promotion" in str(e):
                logger.warning(
                    "Cannot start canary for %s — active promotion already exists",
                    project,
                )
            else:
                logger.error("start_canary failed: %s", e)
            return 0

    async def get_active(self, project: str) -> dict[str, Any] | None:
        """Get the currently active promotion (canary or promoted) for a project."""
        pool = await self._ensure_pool()
        if not pool:
            return None

        try:
            row = await pool.fetchrow(
                """SELECT id, project, training_run_id, model_name, status,
                          challenger_ratio, baseline_autonomy, current_autonomy,
                          validation_score, created_at, promoted_at, rolled_back_at
                   FROM model_promotions
                   WHERE project = $1 AND status IN ('canary', 'promoted')
                   LIMIT 1""",
                project,
            )
            return dict(row) if row else None
        except Exception:
            logger.debug("get_active query failed (table may not exist)")
            return None

    async def evaluate_canary(
        self,
        project: str,
        current_autonomy: float,
    ) -> dict[str, Any]:
        """Evaluate a canary deployment and step ratio or rollback.

        Args:
            project: Room project name.
            current_autonomy: Latest autonomy score (0-100).

        Returns:
            Dict with action taken: 'stepped', 'promoted', 'rolled_back', or 'no_change'.
        """
        active = await self.get_active(project)
        if not active or active["status"] != "canary":
            return {"action": "no_change", "reason": "no active canary"}

        baseline = active["baseline_autonomy"] or 0.0
        current_ratio = active["challenger_ratio"]
        model_name = active["model_name"]

        # Update current_autonomy
        pool = await self._ensure_pool()
        if pool:
            try:
                await pool.execute(
                    "UPDATE model_promotions SET current_autonomy = $1 WHERE id = $2",
                    current_autonomy,
                    active["id"],
                )
            except Exception:
                pass

        # Check rollback condition
        if current_autonomy < baseline - ROLLBACK_THRESHOLD:
            await self.rollback(project)
            return {
                "action": "rolled_back",
                "model": model_name,
                "reason": (
                    f"autonomy {current_autonomy:.1f} < "
                    f"baseline {baseline:.1f} - {ROLLBACK_THRESHOLD}"
                ),
                "baseline": baseline,
                "current": current_autonomy,
            }

        # Autonomy must hold at or above baseline to step up
        if current_autonomy < baseline:
            return {
                "action": "no_change",
                "model": model_name,
                "reason": "autonomy below baseline, holding ratio",
                "ratio": current_ratio,
                "baseline": baseline,
                "current": current_autonomy,
            }

        # Find next ratio step
        next_ratio = None
        for r in RATIO_LADDER:
            if r > current_ratio:
                next_ratio = r
                break

        if next_ratio is None or next_ratio >= 1.0:
            # Promote — ratio reaches 1.0
            await self.promote(project, active["training_run_id"])
            return {
                "action": "promoted",
                "model": model_name,
                "ratio": 1.0,
                "baseline": baseline,
                "current": current_autonomy,
            }

        # Step up ratio
        if pool:
            try:
                await pool.execute(
                    "UPDATE model_promotions SET challenger_ratio = $1 WHERE id = $2",
                    next_ratio,
                    active["id"],
                )
            except Exception:
                pass

        logger.info(
            "Canary stepped: %s %.0f%% → %.0f%% (autonomy=%.1f, baseline=%.1f)",
            model_name,
            current_ratio * 100,
            next_ratio * 100,
            current_autonomy,
            baseline,
        )
        return {
            "action": "stepped",
            "model": model_name,
            "ratio_from": current_ratio,
            "ratio_to": next_ratio,
            "baseline": baseline,
            "current": current_autonomy,
        }

    async def promote(self, project: str, training_run_id: int) -> None:
        """Promote a model to full traffic (ratio=1.0)."""
        pool = await self._ensure_pool()
        if not pool:
            return

        try:
            await pool.execute(
                """UPDATE model_promotions
                   SET status = 'promoted', challenger_ratio = 1.0,
                       promoted_at = NOW()
                   WHERE project = $1 AND training_run_id = $2
                     AND status = 'canary'""",
                project,
                training_run_id,
            )
            logger.info("Model promoted for %s (run_id=%d)", project, training_run_id)
        except Exception:
            logger.error("promote failed for %s", project)

    async def rollback(self, project: str) -> None:
        """Rollback to base model — marks active promotion as rolled_back."""
        pool = await self._ensure_pool()
        if not pool:
            return

        try:
            await pool.execute(
                """UPDATE model_promotions
                   SET status = 'rolled_back', challenger_ratio = 0.0,
                       rolled_back_at = NOW()
                   WHERE project = $1 AND status IN ('canary', 'promoted')""",
                project,
            )
            logger.info("Model rolled back for %s", project)
        except Exception:
            logger.error("rollback failed for %s", project)

    async def list_active_canaries(self) -> list[str]:
        """Return project names that have active canary deployments."""
        pool = await self._ensure_pool()
        if not pool:
            return []

        try:
            rows = await pool.fetch("SELECT project FROM model_promotions WHERE status = 'canary'")
            return [r["project"] for r in rows]
        except Exception:
            return []

    async def close(self) -> None:
        """Close the database pool if we own it."""
        if self._lazy:
            await self._lazy.close()
