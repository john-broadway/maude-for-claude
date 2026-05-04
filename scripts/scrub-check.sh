#!/bin/bash
# Maude — Origin Scrub Check
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
#
# Hard gate for CI and local development.
# Patterns are NOT in source. They live at:
#   - CI: GitHub Actions secret SCRUB_PATTERNS, materialized to a temp file
#   - Local: $HOME/.config/maude-scrub-patterns.txt by default
#   - Override: set $SCRUB_PATTERNS_FILE to a custom path
#
# Format: one rule per line, "LABEL ||| GREP_EXTENDED_REGEX". See
# scripts/scrub-patterns.example.txt for the format.
#
# Exit codes:
#   0 = clean (or patterns file absent and we're running locally — silent skip)
#   1 = leaks detected
#   2 = invalid pattern file format

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve patterns file — env var wins, fall back to user config
PATTERNS_FILE="${SCRUB_PATTERNS_FILE:-$HOME/.config/maude-scrub-patterns.txt}"

if [ ! -f "$PATTERNS_FILE" ]; then
    # Local-dev fallback: silent skip so contributors without the patterns file
    # can still run `make` without errors. CI sets SCRUB_PATTERNS_FILE explicitly,
    # so CI never reaches this branch.
    echo "=== Maude Origin Scrub Check ==="
    echo ""
    echo "SKIP: patterns file not found at $PATTERNS_FILE"
    echo ""
    echo "Maintainer: place your private patterns file there, or export"
    echo "  SCRUB_PATTERNS_FILE=/path/to/patterns.txt"
    echo ""
    echo "Contributors: this gate runs in CI on every PR. No local action needed."
    exit 0
fi

SCAN_DIRS=".claude .claude-plugin .github agents commands docs hooks skills"
SCAN_FILES="README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md"

# Validate pattern file format — every non-comment line must be LABEL ||| PATTERN
LINENUM=0
while IFS= read -r vline; do
    LINENUM=$((LINENUM + 1))
    [[ "$vline" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${vline// /}" ]] && continue
    if [[ "$vline" != *"|||"* ]]; then
        echo "ERROR: $PATTERNS_FILE line $LINENUM: invalid format (missing |||)"
        echo "  $vline"
        exit 2
    fi
done < "$PATTERNS_FILE"

echo "=== Maude Origin Scrub Check ==="
echo ""

FOUND=0

while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    label="${line%%|||*}"
    pattern="${line##*|||}"
    label="$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    pattern="$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    [[ -z "$pattern" ]] && continue

    cd "$REPO_ROOT"
    matches=$(grep -rEn "$pattern" $SCAN_DIRS $SCAN_FILES 2>/dev/null || true)
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
