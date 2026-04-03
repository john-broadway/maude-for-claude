# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Predictive trend analysis for health loop metrics.

Uses in-memory linear regression over sliding windows to predict
threshold breaches before they happen. No external dependencies.
"""

import logging
import math
import threading
import time
from collections import deque
from typing import Any

logger = logging.getLogger(__name__)

# Minimum samples required for regression
MIN_SAMPLES = 5


class TrendAnalyzer:
    """Sliding-window linear regression for metric trend prediction.

    Args:
        window_hours: How many hours of samples to retain per metric.
    """

    def __init__(self, window_hours: float = 6.0) -> None:
        self.window_seconds = window_hours * 3600.0
        self._data: dict[str, deque[tuple[float, float]]] = {}
        self._lock = threading.Lock()

    def record(self, metric: str, value: float, timestamp: float | None = None) -> None:
        """Record a sample for a metric."""
        ts = timestamp if timestamp is not None else time.monotonic()
        with self._lock:
            if metric not in self._data:
                self._data[metric] = deque()
            self._data[metric].append((ts, value))
            self._prune(metric, ts)

    def predict_breach(self, metric: str, threshold: float) -> float | None:
        """Predict seconds until metric breaches *threshold*.

        Returns estimated seconds until breach, or None if no breach
        is predicted (flat/declining toward safe side, or insufficient data).
        """
        reg = self._regression(metric)
        if reg is None:
            return None

        slope, intercept, latest_ts = reg["slope"], reg["intercept"], reg["latest_ts"]

        # No upward/downward movement toward threshold
        current = slope * latest_ts + intercept
        if slope == 0.0:
            return None

        # Time at which trend line hits threshold
        t_breach = (threshold - intercept) / slope
        seconds_until = t_breach - latest_ts

        # Breach must be in the future
        if seconds_until <= 0.0:
            return None

        # Only report if trend is moving *toward* the threshold
        if threshold > current and slope <= 0.0:
            return None
        if threshold < current and slope >= 0.0:
            return None

        return seconds_until

    def anomaly_score(self, metric: str) -> float:
        """Return 0.0-1.0 anomaly score for the latest value.

        Based on how many standard deviations the latest value is
        from the regression prediction.  0.0 = on the trend line,
        1.0 = extreme outlier (>= 3 sigma).
        """
        reg = self._regression(metric)
        if reg is None:
            return 0.0

        slope, intercept = reg["slope"], reg["intercept"]
        residuals = reg["residuals"]
        latest_ts, latest_val = reg["latest_ts"], reg["latest_val"]

        if not residuals:
            return 0.0

        # Standard deviation of residuals
        mean_r = sum(residuals) / len(residuals)
        variance = sum((r - mean_r) ** 2 for r in residuals) / len(residuals)
        std_dev = math.sqrt(variance)

        if std_dev == 0.0:
            return 0.0

        predicted = slope * latest_ts + intercept
        deviation = abs(latest_val - predicted) / std_dev

        # Map to 0-1 via sigmoid-like clamp at 3 sigma
        return min(deviation / 3.0, 1.0)

    def get_trend(self, metric: str) -> dict[str, Any]:
        """Return trend summary for a metric."""
        reg = self._regression(metric)
        if reg is None:
            with self._lock:
                count = len(self._data.get(metric, []))
            return {
                "slope": 0.0,
                "r_squared": 0.0,
                "current_value": None,
                "predicted_value": None,
                "window_hours": self.window_seconds / 3600.0,
                "sample_count": count,
            }

        slope, intercept = reg["slope"], reg["intercept"]
        latest_ts, latest_val = reg["latest_ts"], reg["latest_val"]
        predicted = slope * latest_ts + intercept

        return {
            "slope": slope,
            "r_squared": reg["r_squared"],
            "current_value": latest_val,
            "predicted_value": predicted,
            "window_hours": self.window_seconds / 3600.0,
            "sample_count": reg["n"],
        }

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _prune(self, metric: str, now: float) -> None:
        """Remove samples outside the sliding window (caller holds lock)."""
        dq = self._data[metric]
        cutoff = now - self.window_seconds
        while dq and dq[0][0] < cutoff:
            dq.popleft()

    def _regression(self, metric: str) -> dict[str, Any] | None:
        """Ordinary least-squares regression on the window.

        Returns None if fewer than MIN_SAMPLES points are available.
        """
        with self._lock:
            dq = self._data.get(metric)
            if dq is None or len(dq) < MIN_SAMPLES:
                return None
            points = list(dq)

        n = len(points)
        sum_x = sum_y = sum_xy = sum_x2 = sum_y2 = 0.0
        for x, y in points:
            sum_x += x
            sum_y += y
            sum_xy += x * y
            sum_x2 += x * x
            sum_y2 += y * y

        denom = n * sum_x2 - sum_x * sum_x
        if denom == 0.0:
            return None

        slope = (n * sum_xy - sum_x * sum_y) / denom
        intercept = (sum_y - slope * sum_x) / n

        # R-squared
        ss_tot = sum_y2 - (sum_y * sum_y) / n
        ss_res = 0.0
        residuals: list[float] = []
        for x, y in points:
            predicted = slope * x + intercept
            r = y - predicted
            residuals.append(r)
            ss_res += r * r

        r_squared = 1.0 - (ss_res / ss_tot) if ss_tot != 0.0 else 0.0

        latest_ts, latest_val = points[-1]

        return {
            "slope": slope,
            "intercept": intercept,
            "r_squared": r_squared,
            "residuals": residuals,
            "latest_ts": latest_ts,
            "latest_val": latest_val,
            "n": n,
        }
