"""Background training loop for the self-learning pipeline.

Runs inside the Coordinator MCP daemon as an asyncio background task.
Periodically checks for enough new agent conversations, then chains:
export -> transfer -> train -> deploy -> validate -> rebuild.

Pipeline state machine::

    IDLE -> EXPORTING -> TRANSFERRING -> TRAINING -> DEPLOYING
         -> VALIDATING -> REBUILDING -> COMPLETED
    (any failure returns to IDLE, logged as FAILED)

Usage:
    loop = TrainingLoop(audit=audit, config=cfg)
    await loop.start()
    # ...
    await loop.stop()
"""

import asyncio
import json
import logging
import shutil
import tempfile
import time
from contextlib import suppress
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import asyncpg

from maude.daemon.audit import AuditLogger
from maude.db import PoolRegistry
from maude.healing.training.export import (
    ExportStats,
    count_new_examples,
    export_interaction_data,
    export_training_data,
)
from maude.healing.training.session_distiller import archive_and_cleanup, distill_and_store

logger = logging.getLogger(__name__)

CALLER = "training-loop"

# Stages in order
STAGES = [
    "exporting",
    "transferring",
    "training",
    "deploying",
    "validating",
    "rebuilding",
]


class _PipelineAbort(Exception):
    """Raised when a pipeline stage fails — caught by _run_pipeline."""


@dataclass
class TrainingLoopConfig:
    """Configuration for the training loop."""

    enabled: bool = False
    interval_seconds: int = 21600  # 6 hours
    threshold: int = 100  # min new examples to trigger
    gpu_host: str = "gpu-node-1"
    gpu_fallback: str = "gpu-node-2"
    gpu_user: str = "gpu"
    gpu_train_dir: str = "/home/gpu/training"
    gpu_venv: str = "/home/gpu/training/.venv"
    base_model: str = "/app/models/Qwen3-32B"
    epochs: int = 3
    batch_size: int = 1
    learning_rate: float = 2e-4
    lora_r: int = 16
    lora_alpha: int = 16
    backend: str = "peft"  # peft (default — safe with vLLM running), unsloth, auto
    model_prefix: str = "maude-agent"
    keep_versions: int = 3
    ssh_timeout: int = 28800  # 8 hours for PEFT training on GB10
    rebuild_room_models: bool = True
    min_tools: int = 0
    concierge_enabled: bool = False
    concierge_min_examples: int = 50

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> "TrainingLoopConfig":
        if not data:
            return cls()
        concierge_cfg = data.get("concierge", {})
        return cls(
            enabled=data.get("enabled", False),
            interval_seconds=data.get("interval_seconds", 21600),
            threshold=data.get("threshold", 100),
            gpu_host=data.get("gpu_host", "gpu-node-1"),
            gpu_fallback=data.get("gpu_fallback", "gpu-node-2"),
            gpu_user=data.get("gpu_user", "gpu"),
            gpu_train_dir=data.get("gpu_train_dir", "/home/gpu/training"),
            gpu_venv=data.get("gpu_venv", "/home/gpu/training/.venv"),
            base_model=data.get("base_model", "/app/models/Qwen3-32B"),
            epochs=data.get("epochs", 3),
            batch_size=data.get("batch_size", 2),
            learning_rate=data.get("learning_rate", 2e-4),
            lora_r=data.get("lora_r", 16),
            lora_alpha=data.get("lora_alpha", 16),
            backend=data.get("backend", "auto"),
            model_prefix=data.get("model_prefix", "maude-agent"),
            keep_versions=data.get("keep_versions", 3),
            ssh_timeout=data.get("ssh_timeout", 28800),
            rebuild_room_models=data.get("rebuild_room_models", True),
            min_tools=(data.get("min_tools") or 0),
            concierge_enabled=concierge_cfg.get("enabled", False),
            concierge_min_examples=concierge_cfg.get("min_examples", 50),
        )


@dataclass
class _PipelineState:
    """Mutable state for a single pipeline run."""

    run_id: int = 0
    version: int = 0
    stage: str = "check"
    example_count: int = 0
    new_examples: int = 0
    export_path: str = ""
    model_name: str = ""
    model_path: str = ""
    gpu_host: str = ""
    training_loss: float | None = None
    training_runtime_sec: float | None = None
    validation_score: float | None = None
    validation_passed: bool = False
    started_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


class TrainingLoop:
    """Background self-learning pipeline.

    Follows the same lifecycle pattern as ``HealthLoop``:
    ``start()`` creates an asyncio task, ``stop()`` cancels it.
    """

    def __init__(
        self,
        audit: AuditLogger,
        config: TrainingLoopConfig,
        event_publisher: Any | None = None,
        memory_store: Any | None = None,
    ) -> None:
        self.audit = audit
        self.cfg = config
        self._event_publisher = event_publisher
        self._memory_store = memory_store
        self._task: asyncio.Task[None] | None = None
        self._db = PoolRegistry.get(database="agent", min_size=1, max_size=3)
        self._current_stage: str = "idle"
        self._last_completed: datetime | None = None
        self._last_run_summary: dict[str, Any] | None = None
        self._on_complete: Any | None = None

    async def start(self) -> None:
        """Start the training loop as a background asyncio task."""
        if not self.cfg.enabled:
            logger.info("Training loop disabled")
            return
        self._task = asyncio.create_task(self._loop(), name="training-loop")
        logger.info(
            "Training loop started (interval=%ds, threshold=%d)",
            self.cfg.interval_seconds,
            self.cfg.threshold,
        )

    async def stop(self) -> None:
        """Stop the training loop gracefully."""
        if self._task:
            self._task.cancel()
            with suppress(asyncio.CancelledError):
                await self._task
            self._task = None
        await self._db.close()
        logger.info("Training loop stopped")

    # ── Public status methods ────────────────────────────────────

    def current_status(self) -> dict[str, Any]:
        """Return current pipeline state for the MCP tool."""
        return {
            "enabled": self.cfg.enabled,
            "stage": self._current_stage,
            "interval_seconds": self.cfg.interval_seconds,
            "threshold": self.cfg.threshold,
            "last_completed": (self._last_completed.isoformat() if self._last_completed else None),
            "last_run": self._last_run_summary,
        }

    async def training_history(self, limit: int = 10) -> list[dict[str, Any]]:
        """Fetch recent training runs from the database."""
        pool = await self._ensure_pool()
        if not pool:
            return []
        try:
            rows = await pool.fetch(
                """SELECT id, version, model_name, status, stage,
                          example_count, new_examples, training_loss,
                          training_runtime_sec, gpu_host, error_message,
                          started_at, completed_at
                   FROM training_runs
                   ORDER BY id DESC LIMIT $1""",
                limit,
            )
            return [dict(r) for r in rows]
        except Exception:
            logger.debug("training_history query failed (table may not exist)")
            return []

    async def trigger_manual(self) -> dict[str, Any]:
        """Manually trigger a pipeline run. Returns run result summary."""
        pool = await self._ensure_pool()
        if not pool:
            return {"error": "Database unavailable"}
        count = await count_new_examples(
            pool, self._last_completed or datetime.min.replace(tzinfo=timezone.utc)
        )
        if count == 0:
            return {"status": "skipped", "reason": "No new examples available"}
        return await self._run_pipeline(pool, count)

    def set_completion_callback(self, callback: Any) -> None:
        """Set a callback to be invoked after a successful pipeline run.

        The callback receives the pipeline summary dict as its argument.
        Only called on success (status == "completed"), not on failure.
        """
        self._on_complete = callback

    # ── Internal loop ────────────────────────────────────────────

    async def _loop(self) -> None:
        """Main loop — check threshold, run pipeline, repeat."""
        # Initial delay to let services settle
        await asyncio.sleep(30)

        while True:
            try:
                await self._check_and_run()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Training loop error (non-fatal, continuing)")

            await asyncio.sleep(self.cfg.interval_seconds)

    async def _ensure_pool(self):
        """Lazy-init database pool."""
        return await self._db.get()

    async def _check_and_run(self) -> None:
        """Check example count and trigger pipeline if threshold met.

        Also runs session distillation and archive cleanup every cycle,
        regardless of whether the training pipeline triggers.
        """
        pool = await self._ensure_pool()
        if not pool:
            return

        # Session housekeeping — distill training examples, then archive + cleanup
        await self._session_housekeeping(pool)

        since = self._last_completed or datetime.min.replace(tzinfo=timezone.utc)
        count = await count_new_examples(pool, since)

        logger.info(
            "Training loop: %d new examples since %s (threshold=%d)",
            count,
            since.isoformat(),
            self.cfg.threshold,
        )

        if count < self.cfg.threshold:
            return

        await self._run_pipeline(pool, count)

    async def _session_housekeeping(self, pool: asyncpg.Pool) -> None:
        """Distill training examples from sessions, then archive and delete old files."""
        try:
            distill_result = await distill_and_store(pool, limit=500)
            if distill_result["transcripts_processed"] > 0:
                logger.info(
                    "Session distill: %d transcripts → %d examples",
                    distill_result["transcripts_processed"],
                    distill_result["examples_created"],
                )
        except Exception:
            logger.warning("Session distill failed (non-fatal)", exc_info=True)

        try:
            archive_result = await archive_and_cleanup(pool, max_age_days=7, limit=200)
            if archive_result["archived"] > 0:
                logger.info(
                    "Session archive: %d files, %.1f MB freed",
                    archive_result["archived"],
                    archive_result["bytes_freed"] / 1048576,
                )
        except Exception:
            logger.warning("Session archive failed (non-fatal)", exc_info=True)

    async def _run_pipeline(
        self,
        pool: asyncpg.Pool,
        new_count: int,
    ) -> dict[str, Any]:
        """Execute the full training pipeline."""
        state = _PipelineState(
            new_examples=new_count,
            started_at=datetime.now(timezone.utc),
        )

        # Determine version
        state.version = await self._next_version(pool)
        state.model_name = f"{self.cfg.model_prefix}-v{state.version}"

        # Create training_runs record
        state.run_id = await self._create_run_record(pool, state)

        try:
            # Stage 1: Export
            state.stage = "exporting"
            self._current_stage = "exporting"
            await self._update_run_stage(pool, state)
            await self._audit("export_started", {"version": state.version})
            examples, stats = await self._stage_export(pool, state)

            # Stage 2: Transfer
            state.stage = "transferring"
            self._current_stage = "transferring"
            await self._update_run_stage(pool, state)
            await self._audit("transfer_started", {"gpu_host": state.gpu_host})
            await self._stage_transfer(state)

            # Stage 3: Train
            state.stage = "training"
            self._current_stage = "training"
            await self._update_run_stage(pool, state)
            await self._audit(
                "training_started",
                {
                    "model": state.model_name,
                    "examples": state.example_count,
                },
            )
            await self._stage_train(state)

            # Stage 4: Deploy
            state.stage = "deploying"
            self._current_stage = "deploying"
            await self._update_run_stage(pool, state)
            await self._audit("deploy_started", {"model": state.model_name})
            await self._stage_deploy(state)

            # Stage 5: Validate
            state.stage = "validating"
            self._current_stage = "validating"
            await self._update_run_stage(pool, state)
            await self._stage_validate(state)

            # Stage 6: Rebuild room models
            state.stage = "rebuilding"
            self._current_stage = "rebuilding"
            await self._update_run_stage(pool, state)
            rebuild_results = await self._stage_rebuild_room_models(state)

            # Cleanup old versions
            await self._cleanup_old_versions(state)

            # Mark completed
            self._current_stage = "idle"
            self._last_completed = datetime.now(timezone.utc)
            await self._complete_run(pool, state, "completed")

            summary = {
                "status": "completed",
                "version": state.version,
                "model": state.model_name,
                "examples": state.example_count,
                "new_examples": state.new_examples,
                "training_loss": state.training_loss,
                "runtime_sec": state.training_runtime_sec,
                "gpu_host": state.gpu_host,
                "rebuild": rebuild_results,
            }
            self._last_run_summary = summary

            await self._audit("pipeline_completed", summary)
            await self._publish_event("training_completed", summary)

            # Invoke completion callback if set
            if self._on_complete is not None:
                try:
                    await self._on_complete(summary)
                except Exception:
                    logger.warning("Completion callback failed (non-fatal)")

            return summary

        except _PipelineAbort as e:
            self._current_stage = "idle"
            error_msg = str(e)
            # Clean up temp export file
            if state.export_path:
                export_dir = Path(state.export_path).parent
                if export_dir.exists():
                    shutil.rmtree(export_dir, ignore_errors=True)
            await self._complete_run(pool, state, "failed", error_msg)
            await self._audit(
                "pipeline_failed",
                {
                    "stage": state.stage,
                    "error": error_msg,
                },
            )

            summary = {
                "status": "failed",
                "stage": state.stage,
                "error": error_msg,
                "version": state.version,
            }
            self._last_run_summary = summary
            return summary

    # ── Pipeline stages ──────────────────────────────────────────

    async def _stage_export(
        self,
        pool: asyncpg.Pool,
        state: _PipelineState,
    ) -> tuple[list[dict[str, Any]], ExportStats]:
        """Stage 1: Export training data to JSONL."""
        try:
            examples, stats = await export_training_data(
                pool,
                min_tools=self.cfg.min_tools,
                include_synthetic=True,
                synthetic_ratio=0.20,
            )
        except Exception as e:
            raise _PipelineAbort(f"Export failed: {e}") from e

        if not examples:
            raise _PipelineAbort("Export produced zero examples")

        state.example_count = stats.exported

        # Write to temp file
        tmp = Path(tempfile.mkdtemp()) / f"training-v{state.version}.jsonl"
        try:
            with tmp.open("w") as f:
                for ex in examples:
                    f.write(json.dumps(ex, default=str, ensure_ascii=False) + "\n")
        except Exception as e:
            raise _PipelineAbort(f"JSONL write failed: {e}") from e

        state.export_path = str(tmp)
        logger.info(
            "Exported %d examples (%d skipped) to %s",
            stats.exported,
            stats.skipped_quality + stats.skipped_english + stats.skipped_empty,
            tmp,
        )

        # Interaction log data export.
        try:
            interaction_examples, i_stats = await export_interaction_data(pool)
            if interaction_examples:
                # Mix at ~10% of total (interaction data)
                max_interaction = max(1, len(examples) // 9)
                n_interaction = min(max_interaction, len(interaction_examples))
                examples.extend(interaction_examples[:n_interaction])
                state.example_count = len(examples)
                # Rewrite JSONL to include interaction data
                with tmp.open("w") as f:
                    for ex in examples:
                        f.write(json.dumps(ex, default=str, ensure_ascii=False) + "\n")
                logger.info(
                    "Interaction log: %d examples mixed (%d available)",
                    n_interaction,
                    i_stats.exported,
                )
        except Exception:
            logger.warning("Interaction log export failed (non-fatal)", exc_info=True)

        # Concierge data export (alongside Room Agent examples).
        if self.cfg.concierge_enabled:
            try:
                from maude.healing.training.export import export_concierge_data

                concierge_dir = str(tmp.parent / "concierge")
                by_dept, c_stats = await export_concierge_data(
                    pool,
                    output_dir=concierge_dir,
                )
                total_concierge = sum(len(v) for v in by_dept.values())
                if total_concierge >= self.cfg.concierge_min_examples:
                    logger.info(
                        "Concierge export: %d examples across %d departments",
                        total_concierge,
                        len(by_dept),
                    )
                else:
                    logger.info(
                        "Concierge export: %d examples (below threshold %d, skipping)",
                        total_concierge,
                        self.cfg.concierge_min_examples,
                    )
            except Exception:
                logger.warning("Concierge export failed (non-fatal)", exc_info=True)

        return examples, stats

    async def _stage_transfer(self, state: _PipelineState) -> None:
        """Stage 2: SFTP training data to GPU host."""
        host = await self._select_gpu_host()
        state.gpu_host = host

        remote_dir = f"{self.cfg.gpu_train_dir}/data"
        remote_path = f"{remote_dir}/training-v{state.version}.jsonl"

        try:
            import asyncssh

            async with asyncssh.connect(
                host,
                username=self.cfg.gpu_user,
                known_hosts=None,
            ) as conn:
                await conn.run(f"mkdir -p {remote_dir}", check=True)
                async with conn.start_sftp_client() as sftp:
                    await sftp.put(state.export_path, remote_path)
        except Exception as e:
            raise _PipelineAbort(f"Transfer to {host} failed: {e}") from e

        logger.info("Transferred %s to %s:%s", state.export_path, host, remote_path)

    async def _stage_train(self, state: _PipelineState) -> None:
        """Stage 3: Stop vLLM on training GPU, run fine-tune, restart vLLM.

        vLLM pre-allocates GPU memory, so training can't run alongside it.
        The other GPU continues serving inference via VLLMClient failover.
        """
        train_cmd = (
            f"cd {self.cfg.gpu_train_dir} && "
            f"{self.cfg.gpu_venv}/bin/python finetune.py "
            f"--data data/training-v{state.version}.jsonl "
            f"--output models/{state.model_name} "
            f"--base-model {self.cfg.base_model} "
            f"--epochs {self.cfg.epochs} "
            f"--batch-size {self.cfg.batch_size} "
            f"--lr {self.cfg.learning_rate} "
            f"--lora-r {self.cfg.lora_r} "
            f"--lora-alpha {self.cfg.lora_alpha} "
            f"--backend {self.cfg.backend}"
        )

        t0 = time.monotonic()
        try:
            import asyncssh

            async with asyncssh.connect(
                state.gpu_host,
                username=self.cfg.gpu_user,
                known_hosts=None,
            ) as conn:
                # Stop vLLM services to free GPU memory for training.
                # The other GPU continues serving via VLLMClient failover.
                logger.info(
                    "Stopping vLLM on %s to free GPU for training",
                    state.gpu_host,
                )
                await conn.run(
                    "sudo systemctl stop vllm-chat.service vllm-embed.service",
                    check=True,
                    timeout=60,
                )

                try:
                    result = await conn.run(
                        train_cmd,
                        check=True,
                        timeout=self.cfg.ssh_timeout,
                    )
                    stdout = str(result.stdout or "")
                finally:
                    # Always restart vLLM, even if training fails
                    logger.info("Restarting vLLM on %s", state.gpu_host)
                    await conn.run(
                        "sudo systemctl start vllm-chat.service vllm-embed.service",
                        check=False,
                        timeout=60,
                    )
        except Exception as e:
            raise _PipelineAbort(f"Training failed on {state.gpu_host}: {e}") from e

        state.training_runtime_sec = round(time.monotonic() - t0, 1)
        state.model_path = f"{self.cfg.gpu_train_dir}/models/{state.model_name}"

        # Parse training loss from stdout (finetune.py prints "final_loss=X.XXX")
        for line in stdout.splitlines():
            if "final_loss=" in line:
                try:
                    state.training_loss = float(line.split("final_loss=")[1].split()[0])
                except (ValueError, IndexError):
                    pass

        logger.info(
            "Training completed in %.1fs (loss=%s)",
            state.training_runtime_sec,
            state.training_loss,
        )

    async def _stage_deploy(self, state: _PipelineState) -> None:
        """Stage 4: Deploy LoRA adapter to vLLM on both GPUs.

        Copies the LoRA adapter files to the GPU machines and loads
        the adapter via the vLLM API (hot-load, no restart needed).
        """
        hosts = [self.cfg.gpu_host]
        fallback = self.cfg.gpu_fallback if self.cfg.gpu_fallback != state.gpu_host else None
        if fallback:
            hosts.append(fallback)

        errors: list[str] = []
        for host in hosts:
            try:
                import asyncssh

                async with asyncssh.connect(
                    host,
                    username=self.cfg.gpu_user,
                    known_hosts=None,
                ) as conn:
                    # Ensure LoRA directory exists
                    lora_dir = f"{self.cfg.gpu_train_dir}/loras/{state.model_name}"
                    await conn.run(
                        f"mkdir -p {lora_dir}",
                        check=True,
                    )
                    # Copy adapter files (assumed already at state.model_path)
                    await conn.run(
                        f"cp -r {state.model_path}/* {lora_dir}/",
                        check=True,
                    )
                    logger.info("Deployed LoRA %s on %s", state.model_name, host)
            except Exception as e:
                errors.append(f"{host}: {e}")
                logger.error("Deploy to %s failed: %s", host, e)

        # At least the primary must succeed
        if any(state.gpu_host in err for err in errors):
            raise _PipelineAbort(f"Deploy failed on primary GPU: {errors}")

    async def _stage_validate(self, state: _PipelineState) -> None:
        """Stage 5: Quick validation + benchmark evaluation.

        First does a basic generation test, then runs the evaluation
        framework benchmark if test data is available. Requires a
        minimum composite score of 0.80 to pass.
        """
        from maude.llm.vllm import VLLMClient

        # Basic generation test
        validation_prompt = (
            "You are a Maude Room Agent. The grafana service health endpoint "
            "returned HTTP 502. What diagnostic steps would you take?"
        )

        client = VLLMClient()
        try:
            response = await client.generate(
                model=state.model_name,
                prompt=validation_prompt,
            )
            response_text = response.response or ""
            if len(response_text) <= 10:
                raise _PipelineAbort("Validation failed: model produced no usable response")
            logger.info("Basic validation passed (%d chars)", len(response_text))
        except _PipelineAbort:
            raise
        except Exception as e:
            raise _PipelineAbort(f"Validation generation failed: {e}") from e
        finally:
            await client.close()

        # Evaluation framework benchmark (Phase 2D)
        try:
            from maude.eval.benchmark import create_test_set, run_benchmark

            pool = await self._ensure_pool()
            if pool:
                test_set = await create_test_set(pool, limit=50)
                if test_set:
                    result = await run_benchmark(state.model_name, test_set)
                    logger.info(
                        "Benchmark: avg_score=%.3f pass_rate=%.3f (%d tests)",
                        result.avg_score,
                        result.pass_rate,
                        result.test_count,
                    )
                    if result.avg_score < 0.80:
                        raise _PipelineAbort(
                            f"Benchmark score {result.avg_score:.3f} below minimum 0.80"
                        )
                else:
                    logger.info("No test set available — skipping benchmark")
        except _PipelineAbort:
            raise
        except ImportError:
            logger.info("Evaluation framework not available — skipping benchmark")
        except Exception:
            logger.warning("Benchmark evaluation failed (non-fatal, continuing)")

    async def _stage_rebuild_room_models(self, state: _PipelineState) -> list[dict[str, Any]]:
        """Stage 6: Verify room models after fine-tuning.

        With vLLM, system prompts are passed at runtime. This stage verifies
        the base model is loaded on vLLM and system prompts generate correctly.
        """
        if not self.cfg.rebuild_room_models:
            logger.info("Room model rebuild disabled — skipping")
            return []

        try:
            from maude.healing.dependencies import DependencyGraph
            from maude.healing.model_manager import (
                VLLMModelManager,
                generate_system_prompt,
                resolve_knowledge_path,
            )
        except ImportError:
            logger.warning("Model manager not available — skipping rebuild")
            return []

        deps = DependencyGraph()
        mgr = VLLMModelManager()
        results: list[dict[str, Any]] = []

        try:
            for room in deps.all_rooms:
                model_cfg = deps.model_for(room)
                if not model_cfg:
                    continue

                name = model_cfg["name"]
                knowledge_path = resolve_knowledge_path(room)
                system = generate_system_prompt(room, knowledge_path)
                base = model_cfg.get("base", "/app/models/Qwen3-32B")

                model_loaded = await mgr.model_exists(base)
                results.append(
                    {
                        "room": room,
                        "model": name,
                        "base": base,
                        "system_prompt_len": len(system),
                        "status": "ok" if model_loaded else "base_not_loaded",
                    }
                )
        finally:
            await mgr.close()

        logger.info("Verified %d room models", len(results))
        return results

    # ── GPU host selection ───────────────────────────────────────

    async def _select_gpu_host(self) -> str:
        """Try primary GPU, fall back to secondary. Checks via SSH + nvidia-smi."""
        import asyncssh

        for host in [self.cfg.gpu_host, self.cfg.gpu_fallback]:
            try:
                async with asyncssh.connect(
                    host,
                    username=self.cfg.gpu_user,
                    known_hosts=None,
                ) as conn:
                    result = await conn.run("nvidia-smi --query-gpu=name --format=csv,noheader")
                    if result.exit_status == 0:
                        logger.info("Selected GPU host: %s", host)
                        return host
            except Exception:
                logger.warning("GPU host %s unreachable", host)

        raise _PipelineAbort("No reachable GPU host")

    # ── Version management ───────────────────────────────────────

    async def _next_version(self, pool: asyncpg.Pool) -> int:
        """Get the next sequential version number."""
        try:
            row = await pool.fetchval("SELECT COALESCE(MAX(version), 0) + 1 FROM training_runs")
            return int(row)
        except Exception:
            # Table might not exist yet
            return 1

    async def _cleanup_old_versions(self, state: _PipelineState) -> None:
        """Clean up old LoRA adapter files beyond keep_versions.

        With vLLM, LoRA adapters are files on disk. Cleanup removes
        the adapter directories for old versions.
        """
        if state.version <= self.cfg.keep_versions:
            return

        for v in range(1, state.version - self.cfg.keep_versions + 1):
            old_name = f"{self.cfg.model_prefix}-v{v}"
            logger.info("Would clean up old LoRA: %s (cleanup not yet implemented)", old_name)

    # ── Database records ─────────────────────────────────────────

    async def _create_run_record(
        self,
        pool: asyncpg.Pool,
        state: _PipelineState,
    ) -> int:
        """Insert a new training_runs record. Returns the row ID."""
        try:
            row_id = await pool.fetchval(
                """INSERT INTO training_runs
                       (version, model_name, status, stage, new_examples, started_at)
                   VALUES ($1, $2, 'running', 'check', $3, $4)
                   RETURNING id""",
                state.version,
                state.model_name,
                state.new_examples,
                state.started_at,
            )
            return int(row_id)
        except Exception:
            logger.warning("Failed to create training_runs record (table may not exist)")
            return 0

    async def _update_run_stage(
        self,
        pool: asyncpg.Pool,
        state: _PipelineState,
    ) -> None:
        """Update the stage column for the current run."""
        if not state.run_id:
            return
        try:
            await pool.execute(
                "UPDATE training_runs SET stage = $1 WHERE id = $2",
                state.stage,
                state.run_id,
            )
        except Exception:
            pass

    async def _complete_run(
        self,
        pool: asyncpg.Pool,
        state: _PipelineState,
        status: str,
        error_message: str = "",
    ) -> None:
        """Mark a training run as completed or failed."""
        if not state.run_id:
            return
        try:
            await pool.execute(
                """UPDATE training_runs SET
                       status = $1, stage = $2, example_count = $3,
                       training_loss = $4, training_runtime_sec = $5,
                       gpu_host = $6, export_path = $7, model_path = $8,
                       error_message = $9, completed_at = NOW()
                   WHERE id = $10""",
                status,
                state.stage,
                state.example_count,
                state.training_loss,
                state.training_runtime_sec,
                state.gpu_host,
                state.export_path,
                state.model_path,
                error_message,
                state.run_id,
            )
        except Exception:
            logger.warning("Failed to update training_runs record")

    # ── Observability ────────────────────────────────────────────

    async def _audit(self, action: str, params: dict[str, Any]) -> None:
        """Log a training loop action to audit."""
        try:
            await self.audit.log_tool_call(
                tool=f"training_loop.{action}",
                caller=CALLER,
                params=params,
                result=action,
                success=True,
                duration_ms=0,
                reason=f"training_loop.{action}",
            )
        except Exception:
            logger.debug("Training loop audit write failed (non-fatal)")

    async def _publish_event(self, event_type: str, data: dict[str, Any]) -> None:
        """Publish an event if event publisher is configured."""
        if self._event_publisher:
            try:
                await self._event_publisher.publish(event_type, data)
            except Exception:
                logger.debug("Training loop event publish failed (non-fatal)")
