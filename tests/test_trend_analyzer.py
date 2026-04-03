# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.trend_analyzer — sliding-window linear regression."""

import pytest

from maude.analysis.trend_analyzer import MIN_SAMPLES, TrendAnalyzer


@pytest.fixture
def analyzer() -> TrendAnalyzer:
    """TrendAnalyzer with a 1-hour window for fast tests."""
    return TrendAnalyzer(window_hours=1.0)


# ------------------------------------------------------------------
# record()
# ------------------------------------------------------------------

class TestRecord:
    def test_stores_samples(self, analyzer: TrendAnalyzer):
        for i in range(5):
            analyzer.record("cpu", float(i), timestamp=float(i))
        assert len(analyzer._data["cpu"]) == 5

    def test_auto_timestamp(self, analyzer: TrendAnalyzer):
        analyzer.record("cpu", 42.0)
        ts, val = analyzer._data["cpu"][0]
        assert val == 42.0
        assert ts > 0.0

    def test_separate_metrics(self, analyzer: TrendAnalyzer):
        analyzer.record("cpu", 10.0, timestamp=1.0)
        analyzer.record("mem", 20.0, timestamp=1.0)
        assert len(analyzer._data["cpu"]) == 1
        assert len(analyzer._data["mem"]) == 1


# ------------------------------------------------------------------
# predict_breach()
# ------------------------------------------------------------------

class TestPredictBreach:
    def test_linearly_increasing_predicts_breach(self, analyzer: TrendAnalyzer):
        """Steadily rising values should predict when threshold is hit."""
        # y = x: at t=0 val=0, t=1 val=1, ... t=9 val=9
        for i in range(10):
            analyzer.record("cpu", float(i), timestamp=float(i))

        # Threshold at 20 — slope is ~1, so ~11 seconds from t=9
        result = analyzer.predict_breach("cpu", threshold=20.0)
        assert result is not None
        assert result == pytest.approx(11.0, abs=0.5)

    def test_stable_values_no_breach(self, analyzer: TrendAnalyzer):
        """Flat values should not predict a breach."""
        for i in range(10):
            analyzer.record("cpu", 5.0, timestamp=float(i))

        result = analyzer.predict_breach("cpu", threshold=20.0)
        assert result is None

    def test_insufficient_data(self, analyzer: TrendAnalyzer):
        """Fewer than MIN_SAMPLES should return None."""
        for i in range(MIN_SAMPLES - 1):
            analyzer.record("cpu", float(i), timestamp=float(i))

        result = analyzer.predict_breach("cpu", threshold=100.0)
        assert result is None

    def test_decreasing_toward_threshold_below(self, analyzer: TrendAnalyzer):
        """Decreasing values should predict breach of a lower threshold."""
        # y = 100 - x
        for i in range(10):
            analyzer.record("temp", 100.0 - i, timestamp=float(i))

        result = analyzer.predict_breach("temp", threshold=50.0)
        assert result is not None
        assert result > 0.0

    def test_decreasing_no_breach_above(self, analyzer: TrendAnalyzer):
        """Decreasing values should NOT predict breach of a higher threshold."""
        for i in range(10):
            analyzer.record("temp", 100.0 - i, timestamp=float(i))

        result = analyzer.predict_breach("temp", threshold=200.0)
        assert result is None

    def test_unknown_metric(self, analyzer: TrendAnalyzer):
        result = analyzer.predict_breach("nonexistent", threshold=10.0)
        assert result is None

    def test_threshold_already_passed(self, analyzer: TrendAnalyzer):
        """If values are already above threshold and rising, breach is 'past'."""
        for i in range(10):
            analyzer.record("cpu", 50.0 + i, timestamp=float(i))

        # Threshold below current — breach time would be in the past
        result = analyzer.predict_breach("cpu", threshold=40.0)
        assert result is None


# ------------------------------------------------------------------
# anomaly_score()
# ------------------------------------------------------------------

class TestAnomalyScore:
    def test_on_trend_line(self, analyzer: TrendAnalyzer):
        """Perfect linear data: latest point is on the line, score ~ 0."""
        for i in range(10):
            analyzer.record("cpu", float(i), timestamp=float(i))

        score = analyzer.anomaly_score("cpu")
        assert score == pytest.approx(0.0, abs=0.01)

    def test_spike_high_score(self, analyzer: TrendAnalyzer):
        """A sudden spike should produce a high anomaly score."""
        for i in range(9):
            analyzer.record("cpu", 10.0, timestamp=float(i))
        # Massive spike
        analyzer.record("cpu", 1000.0, timestamp=9.0)

        score = analyzer.anomaly_score("cpu")
        assert score > 0.5

    def test_insufficient_data_returns_zero(self, analyzer: TrendAnalyzer):
        analyzer.record("cpu", 1.0, timestamp=1.0)
        assert analyzer.anomaly_score("cpu") == 0.0

    def test_unknown_metric_returns_zero(self, analyzer: TrendAnalyzer):
        assert analyzer.anomaly_score("ghost") == 0.0

    def test_score_capped_at_one(self, analyzer: TrendAnalyzer):
        """Score must never exceed 1.0."""
        for i in range(9):
            analyzer.record("cpu", 1.0, timestamp=float(i))
        analyzer.record("cpu", 999999.0, timestamp=9.0)

        score = analyzer.anomaly_score("cpu")
        assert 0.0 <= score <= 1.0


# ------------------------------------------------------------------
# get_trend()
# ------------------------------------------------------------------

class TestGetTrend:
    def test_returns_expected_fields(self, analyzer: TrendAnalyzer):
        for i in range(10):
            analyzer.record("cpu", float(i), timestamp=float(i))

        trend = analyzer.get_trend("cpu")
        assert "slope" in trend
        assert "r_squared" in trend
        assert "current_value" in trend
        assert "predicted_value" in trend
        assert "window_hours" in trend
        assert "sample_count" in trend

    def test_linear_data_slope(self, analyzer: TrendAnalyzer):
        """Slope of y = 2x should be ~2."""
        for i in range(10):
            analyzer.record("cpu", 2.0 * i, timestamp=float(i))

        trend = analyzer.get_trend("cpu")
        assert trend["slope"] == pytest.approx(2.0, abs=0.01)
        assert trend["r_squared"] == pytest.approx(1.0, abs=0.01)
        assert trend["sample_count"] == 10

    def test_insufficient_data(self, analyzer: TrendAnalyzer):
        analyzer.record("cpu", 1.0, timestamp=1.0)
        trend = analyzer.get_trend("cpu")
        assert trend["slope"] == 0.0
        assert trend["current_value"] is None
        assert trend["sample_count"] == 1

    def test_window_hours_matches_config(self):
        a = TrendAnalyzer(window_hours=2.5)
        trend = a.get_trend("any")
        assert trend["window_hours"] == 2.5

    def test_unknown_metric(self, analyzer: TrendAnalyzer):
        trend = analyzer.get_trend("nope")
        assert trend["sample_count"] == 0
        assert trend["current_value"] is None


# ------------------------------------------------------------------
# Window expiry
# ------------------------------------------------------------------

class TestWindowExpiry:
    def test_old_samples_pruned(self):
        """Samples older than window_hours should be discarded."""
        # 1-second window for easy testing
        a = TrendAnalyzer(window_hours=1.0 / 3600.0)  # 1 second

        # Record at t=0
        a.record("cpu", 1.0, timestamp=0.0)
        # Record at t=2 — first sample is now >1s old
        a.record("cpu", 2.0, timestamp=2.0)

        assert len(a._data["cpu"]) == 1
        assert a._data["cpu"][0] == (2.0, 2.0)

    def test_fresh_samples_kept(self, analyzer: TrendAnalyzer):
        """Samples within window should not be pruned."""
        base = 1000.0
        for i in range(10):
            analyzer.record("cpu", float(i), timestamp=base + i)

        assert len(analyzer._data["cpu"]) == 10


# ------------------------------------------------------------------
# Multiple independent metrics
# ------------------------------------------------------------------

class TestMultipleMetrics:
    def test_metrics_independent(self, analyzer: TrendAnalyzer):
        """Recording one metric should not affect another."""
        for i in range(10):
            analyzer.record("cpu", float(i), timestamp=float(i))
            analyzer.record("mem", 100.0 - i, timestamp=float(i))

        cpu_trend = analyzer.get_trend("cpu")
        mem_trend = analyzer.get_trend("mem")

        assert cpu_trend["slope"] > 0
        assert mem_trend["slope"] < 0

    def test_breach_prediction_per_metric(self, analyzer: TrendAnalyzer):
        """Breach prediction is per-metric, not global."""
        for i in range(10):
            analyzer.record("rising", float(i), timestamp=float(i))
            analyzer.record("flat", 5.0, timestamp=float(i))

        assert analyzer.predict_breach("rising", threshold=20.0) is not None
        assert analyzer.predict_breach("flat", threshold=20.0) is None
