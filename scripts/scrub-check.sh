#!/bin/bash
# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
#
# Origin Scrub Check — hard gate for CI and local development.
# Reads patterns from scripts/scrub-patterns.txt (single source of truth).
# Exits 0 (clean) or 1 (leaks found).
#
# Usage:
#   bash scripts/scrub-check.sh              # scan and report
#   bash scripts/scrub-check.sh --fix-hint   # include replacement hints

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS_FILE="$SCRIPT_DIR/scrub-patterns.txt"

SCAN_DIRS="$REPO_ROOT/src/ $REPO_ROOT/tests/ $REPO_ROOT/template/ $REPO_ROOT/.github/ $REPO_ROOT/docs/ $REPO_ROOT/examples/ $REPO_ROOT/skills/"
EXCLUDE='--exclude-dir=__pycache__ --exclude=*.pyc --exclude=scrub-patterns.txt'

FIX_HINT=false
[[ "${1:-}" == "--fix-hint" ]] && FIX_HINT=true

if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "ERROR: Pattern file not found: $PATTERNS_FILE"
    exit 2
fi

FOUND=0

# Validate pattern file format — every non-comment line must be LABEL ||| PATTERN
LINENUM=0
while IFS= read -r vline; do
    LINENUM=$((LINENUM + 1))
    [[ "$vline" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${vline// /}" ]] && continue
    if [[ "$vline" != *"|||"* ]]; then
        echo "ERROR: scrub-patterns.txt line $LINENUM: invalid format (missing |||)"
        echo "  $vline"
        exit 2
    fi
done < "$PATTERNS_FILE"

echo "=== Maude Origin Scrub Check ==="
echo ""

while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    label="${line%%|||*}"
    pattern="${line##*|||}"
    # Trim whitespace (sed preserves backslashes; xargs does not)
    label="$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    pattern="$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    [[ -z "$pattern" ]] && continue

    matches=$(grep -rEn "$pattern" $SCAN_DIRS $EXCLUDE 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        echo "--- FAIL: $label ---"
        echo "$matches"
        echo ""
        FOUND=1
    fi
done < "$PATTERNS_FILE"

if [[ "$FOUND" -eq 0 ]]; then
    echo "PASS: No internal references detected."
    exit 0
else
    echo "=== SCRUB CHECK FAILED ==="
    echo "Internal references found. Fix all matches above before merging."
    exit 1
fi
