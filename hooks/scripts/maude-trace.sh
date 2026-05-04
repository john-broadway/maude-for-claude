#!/usr/bin/env bash
# Maude trace hook — appends a one-line JSON record per turn/event.
# Used by both UserPromptSubmit and PostToolUse.
# Reads stdin (Claude Code passes a JSON envelope). Always exits 0.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Trace lives in her closet. Auto-create — her own dir.
maude_ensure_self_dir
TRACE_DIR="$(maude_self_dir)/trace"
mkdir -p "$TRACE_DIR" 2>/dev/null
TRACE="$TRACE_DIR/today-$(date +%Y-%m-%d).jsonl"

# Read stdin once. If empty or non-JSON, write a minimal record.
INPUT="$(cat 2>/dev/null)"
KIND="${1:-event}"

if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  # Compact the input + add our own envelope fields
  printf '%s' "$INPUT" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg kind "$KIND" \
    '{ts: $ts, kind: $kind} + .' >> "$TRACE" 2>/dev/null
else
  printf '{"ts":"%s","kind":"%s","raw":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIND" \
    "$(printf '%s' "$INPUT" | head -c 200 | sed 's/"/\\"/g')" >> "$TRACE"
fi

exit 0
