# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.healing.training.loop — config, lifecycle, pipeline stages."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from maude.healing.training.loop import TrainingLoop, TrainingLoopConfig, _PipelineAbort
from maude.testing import FakeAudit, FakeTrainingLoop

# ── TrainingLoopConfig ───────────────────────────────────────────


def test_config_from_dict_valid():
    cfg = TrainingLoopConfig.from_dict(
        {
            "enabled": True,
            "interval_seconds": 3600,
            "threshold": 50,
            "gpu_host": "gpu1",
            "epochs": 5,
        }
    )
    assert cfg.enabled is True
    assert cfg.interval_seconds == 3600
    assert cfg.threshold == 50
    assert cfg.gpu_host == "gpu1"
    assert cfg.epochs == 5
    # Defaults preserved
    assert cfg.batch_size == 2
    assert cfg.learning_rate == 2e-4


def test_config_from_dict_none():
    cfg = TrainingLoopConfig.from_dict(None)
    assert cfg.enabled is False
    assert cfg.interval_seconds == 21600
    assert cfg.threshold == 100


def test_config_from_dict_partial():
    cfg = TrainingLoopConfig.from_dict({"enabled": True})
    assert cfg.enabled is True
    assert cfg.threshold == 100  # default


# ── TrainingLoop lifecycle ───────────────────────────────────────


@pytest.mark.asyncio
async def test_start_disabled():
    """Disabled loop does not create a background task."""
    cfg = TrainingLoopConfig(enabled=False)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)
    await loop.start()
    assert loop._task is None
    await loop.stop()


@pytest.mark.asyncio
async def test_start_stop_enabled():
    """Enabled loop creates and cancels a background task."""
    cfg = TrainingLoopConfig(enabled=True, interval_seconds=9999)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    # Mock _ensure_pool to avoid real DB
    loop._ensure_pool = AsyncMock(return_value=None)

    await loop.start()
    assert loop._task is not None
    assert not loop._task.done()

    await loop.stop()
    assert loop._task is None


# ── current_status ───────────────────────────────────────────────


def test_current_status_idle():
    cfg = TrainingLoopConfig(enabled=True, threshold=100)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)
    status = loop.current_status()
    assert status["enabled"] is True
    assert status["stage"] == "idle"
    assert status["threshold"] == 100
    assert status["last_completed"] is None


# ── Pipeline abort ───────────────────────────────────────────────


def test_pipeline_abort_is_exception():
    exc = _PipelineAbort("Export failed")
    assert str(exc) == "Export failed"
    assert isinstance(exc, Exception)


# ── _stage_export ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_stage_export_success():
    """Export stage writes JSONL and returns examples."""
    cfg = TrainingLoopConfig(enabled=True)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    fake_examples = [
        {
            "messages": [
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": "hello"},
            ]
        },
    ]

    from maude.healing.training.export import ExportStats

    fake_stats = ExportStats(total_fetched=5, exported=1, skipped_quality=3, skipped_english=1)

    from maude.healing.training.loop import _PipelineState

    state = _PipelineState(version=1)

    patch_target = "maude.healing.training.loop.export_training_data"
    with patch(patch_target, new_callable=AsyncMock) as mock_export:
        mock_export.return_value = (fake_examples, fake_stats)
        pool = MagicMock()

        examples, stats = await loop._stage_export(pool, state)
        assert len(examples) == 1
        assert stats.exported == 1
        assert state.example_count == 1
        assert state.export_path.endswith(".jsonl")


@pytest.mark.asyncio
async def test_stage_export_empty_aborts():
    """Export with zero examples raises _PipelineAbort."""
    cfg = TrainingLoopConfig(enabled=True)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    from maude.healing.training.export import ExportStats
    from maude.healing.training.loop import _PipelineState

    state = _PipelineState(version=1)

    patch_target = "maude.healing.training.loop.export_training_data"
    with patch(patch_target, new_callable=AsyncMock) as mock_export:
        mock_export.return_value = ([], ExportStats())
        pool = MagicMock()

        with pytest.raises(_PipelineAbort, match="zero examples"):
            await loop._stage_export(pool, state)


# ── _select_gpu_host ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_select_gpu_host_primary():
    """Selects primary when it responds to nvidia-smi."""
    cfg = TrainingLoopConfig(gpu_host="gpu-node-1", gpu_fallback="gpu-node-2")
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    mock_result = MagicMock()
    mock_result.exit_status = 0

    mock_conn = AsyncMock()
    mock_conn.run = AsyncMock(return_value=mock_result)
    mock_conn.__aenter__ = AsyncMock(return_value=mock_conn)
    mock_conn.__aexit__ = AsyncMock(return_value=False)

    mock_asyncssh = MagicMock()
    mock_asyncssh.connect = MagicMock(return_value=mock_conn)

    with patch.dict("sys.modules", {"asyncssh": mock_asyncssh}):
        host = await loop._select_gpu_host()
        assert host == "gpu-node-1"


@pytest.mark.asyncio
async def test_select_gpu_host_none_reachable():
    """Raises _PipelineAbort when no GPU is reachable."""
    cfg = TrainingLoopConfig(gpu_host="dead1", gpu_fallback="dead2")
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    mock_asyncssh = MagicMock()
    mock_asyncssh.connect = MagicMock(side_effect=ConnectionRefusedError("nope"))

    with patch.dict("sys.modules", {"asyncssh": mock_asyncssh}):
        with pytest.raises(_PipelineAbort, match="No reachable GPU"):
            await loop._select_gpu_host()


# ── FakeTrainingLoop ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_fake_training_loop():
    """FakeTrainingLoop has the same API surface."""
    fake = FakeTrainingLoop()
    await fake.start()
    await fake.stop()
    assert fake.current_status()["enabled"] is False
    history = await fake.training_history()
    assert history == []
    result = await fake.trigger_manual()
    assert result["status"] == "disabled"


# ── Validation storage ──────────────────────────────────────────────


def test_pipeline_state_has_validation_fields():
    """_PipelineState includes validation_score and validation_passed."""
    from maude.healing.training.loop import _PipelineState

    state = _PipelineState()
    assert state.validation_score is None
    assert state.validation_passed is False


# ── Completion callback ─────────────────────────────────────────────


def test_set_completion_callback():
    """set_completion_callback stores the callback."""
    cfg = TrainingLoopConfig(enabled=True)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    callback = AsyncMock()
    loop.set_completion_callback(callback)
    assert loop._on_complete is callback


@pytest.mark.asyncio
async def test_completion_callback_not_called_on_failure():
    """Completion callback is NOT invoked when pipeline fails."""
    cfg = TrainingLoopConfig(enabled=True)
    loop = TrainingLoop(audit=FakeAudit(), config=cfg)

    callback = AsyncMock()
    loop.set_completion_callback(callback)

    # Simulate a failed pipeline (export produces zero examples)
    from maude.healing.training.export import ExportStats

    loop._ensure_pool = AsyncMock(return_value=MagicMock())
    loop._next_version = AsyncMock(return_value=1)
    loop._create_run_record = AsyncMock(return_value=1)
    loop._update_run_stage = AsyncMock()
    loop._complete_run = AsyncMock()
    loop._audit = AsyncMock()

    with patch(
        "maude.healing.training.loop.export_training_data",
        new_callable=AsyncMock,
    ) as mock_export:
        mock_export.return_value = ([], ExportStats())
        pool = MagicMock()
        result = await loop._run_pipeline(pool, 100)
        assert result["status"] == "failed"

    callback.assert_not_called()
