# Maude LLM Quality Gate — detect degenerate vLLM output
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Created: 2026-04-03
"""LLM output quality gate — catches garbled/degenerate text before storage.

Lightweight heuristics that run on every LLM response. Designed to catch
obvious model failures (repetitive tokens, punctuation floods, whitespace
floods) without false-positiving on legitimate short responses.

Usage::

    from maude.llm.quality import check_output_quality

    result = check_output_quality(llm_response.content)
    if not result.passed:
        logger.warning("Degenerate output: %s", result.detail)
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

# Pre-compiled patterns for known garbage signatures
_RE_REPEATED_MUS = re.compile(r"\bmus\b.*\bmus\b.*\bmus\b", re.IGNORECASE)
_RE_PURE_PUNCTUATION_LINE = re.compile(r"^[,;:.\s!?()]+$")


@dataclass
class QualityResult:
    """Result of an LLM output quality check."""

    passed: bool
    score: float  # 0.0 = total garbage, 1.0 = clean
    flags: list[str] = field(default_factory=list)
    detail: str = ""


def check_output_quality(
    text: str,
    *,
    min_alpha_ratio: float = 0.40,
    max_repetition_ratio: float = 0.30,
    min_unique_ratio: float = 0.30,
    max_blank_line_ratio: float = 0.50,
) -> QualityResult:
    """Check LLM output for degenerate/garbled content.

    Args:
        text: The LLM output to validate.
        min_alpha_ratio: Minimum fraction of alphanumeric characters.
        max_repetition_ratio: Maximum fraction for the most repeated word.
        min_unique_ratio: Minimum fraction of unique words (for texts >= 20 words).
        max_blank_line_ratio: Maximum fraction of blank lines (for texts > 5 lines).

    Returns:
        QualityResult with pass/fail, score, and diagnostic flags.
    """
    if not text or not text.strip():
        return QualityResult(passed=True, score=1.0, detail="empty input")

    stripped = text.strip()
    words = stripped.lower().split()

    # Short text gets a pass — "OK", "no_action", etc.
    if len(words) < 3:
        return QualityResult(passed=True, score=1.0, detail="short text")

    flags: list[str] = []
    total_checks = 5

    # ── Heuristic 1: Repetition density ─────────────────────────
    # Most frequent word (len >= 3) > threshold of total words
    # Requires >= 10 long words — too few makes the ratio meaningless
    long_words = [w for w in words if len(w) >= 3]
    if len(long_words) >= 10:
        top_word, top_count = Counter(long_words).most_common(1)[0]
        if top_count / len(long_words) > max_repetition_ratio:
            flags.append(f"repetition_density ('{top_word}' x{top_count}/{len(long_words)})")

    # ── Heuristic 2: Alpha ratio ────────────────────────────────
    # Alphanumeric chars < threshold of total length
    alpha_count = sum(1 for c in stripped if c.isalnum())
    alpha_ratio = alpha_count / len(stripped)
    if alpha_ratio < min_alpha_ratio:
        flags.append(f"low_alpha_ratio ({alpha_ratio:.2f})")

    # ── Heuristic 3: Unique word ratio ──────────────────────────
    # Unique words < threshold (only for texts with >= 20 words)
    if len(words) >= 20:
        unique_ratio = len(set(words)) / len(words)
        if unique_ratio < min_unique_ratio:
            flags.append(f"low_unique_ratio ({unique_ratio:.2f})")

    # ── Heuristic 4: Blank line ratio ───────────────────────────
    # Empty lines > threshold (only for texts with > 5 lines)
    lines = stripped.split("\n")
    if len(lines) > 5:
        blank_count = sum(1 for line in lines if not line.strip())
        blank_ratio = blank_count / len(lines)
        if blank_ratio > max_blank_line_ratio:
            flags.append(f"blank_line_flood ({blank_count}/{len(lines)})")

    # ── Heuristic 5: Known garbage patterns ─────────────────────
    if _RE_REPEATED_MUS.search(stripped):
        flags.append("known_garbage_pattern (repeated 'mus')")
    # Check for lines that are nothing but punctuation/whitespace
    content_lines = [line for line in lines if line.strip()]
    if content_lines:
        punct_lines = sum(
            1 for line in content_lines if _RE_PURE_PUNCTUATION_LINE.match(line.strip())
        )
        if punct_lines > 0 and punct_lines / len(content_lines) > 0.50:
            flags.append(f"punctuation_lines ({punct_lines}/{len(content_lines)})")

    passed = len(flags) == 0
    score = (total_checks - len(flags)) / total_checks
    detail = "; ".join(flags) if flags else "clean"

    return QualityResult(passed=passed, score=max(score, 0.0), flags=flags, detail=detail)
