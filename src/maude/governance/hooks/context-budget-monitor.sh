#!/bin/bash
# Context Budget Monitor — inspired by GSD, adapted for Maude
# Authors: John Broadway
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 2.0.0
# Updated: 2026-03-17
#
# PostToolUse hook: reads bridge file from statusline, injects warnings.
# v2: Raised thresholds (35%/20%), checkpoint writes at critical + periodic.
# Exit 2 = pass tool call but inject stderr as model-visible system message

input=$(cat)
SESSION=$(echo "$input" | jq -r '.session_id // ""')
[ -z "$SESSION" ] || [ "$SESSION" = "null" ] && exit 0

BRIDGE="/tmp/claude-ctx-${SESSION}.json"
[ -f "$BRIDGE" ] || exit 0

# Check staleness (>120s = stale, skip)
TS=$(jq -r '.ts // 0' "$BRIDGE")
NOW=$(date +%s)
(( NOW - TS > 120 )) && exit 0

REMAINING=$(jq -r '.remaining_pct // 100' "$BRIDGE")

# Debounce state: warn every 5 calls, escalate immediately on severity change
STATE="/tmp/claude-ctx-${SESSION}-state.json"
CALL_COUNT=0
LAST_SEVERITY="none"
if [ -f "$STATE" ]; then
    CALL_COUNT=$(jq -r '.calls // 0' "$STATE")
    LAST_SEVERITY=$(jq -r '.severity // "none"' "$STATE")
fi
CALL_COUNT=$((CALL_COUNT + 1))

# Determine current severity
# Thresholds raised from 15/25 to 20/35 for earlier intervention
SEVERITY="none"
if (( REMAINING <= 20 )); then
    SEVERITY="critical"
elif (( REMAINING <= 35 )); then
    SEVERITY="warning"
fi

# Write state
echo "{\"calls\":$CALL_COUNT,\"severity\":\"$SEVERITY\"}" > "$STATE" 2>/dev/null

# --- Checkpoint helper ---
write_checkpoint() {
    local source="$1"
    local CHECKPOINT="/tmp/claude-checkpoint-${SESSION}.json"

    # Find most recent plan file
    local PLAN_FILE=""
    local PLANS_DIR="$HOME/.claude/plans"
    if [ -d "$PLANS_DIR" ]; then
        PLAN_FILE=$(find "$PLANS_DIR" -name '*.md' -type f -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)
    fi

    # Get last 5 files from reads log
    local READS_LOG="/tmp/claude-reads-${SESSION}.log"
    local RECENT_READS="[]"
    if [ -f "$READS_LOG" ]; then
        RECENT_READS=$(tail -5 "$READS_LOG" | jq -R . | jq -s .)
    fi

    jq -n \
        --arg session "$SESSION" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg plan "$PLAN_FILE" \
        --arg cwd "$(pwd)" \
        --argjson ctx "$REMAINING" \
        --argjson reads "$RECENT_READS" \
        --arg src "$source" \
        '{
            session_id: $session,
            timestamp: $ts,
            plan_file: $plan,
            cwd: $cwd,
            context_remaining_pct: $ctx,
            recent_reads: $reads,
            source: $src
        }' > "$CHECKPOINT" 2>/dev/null
}

# --- Periodic silent checkpoint ---
# Every 25 tool calls when context is >50% used (i.e., remaining < 50%)
if (( REMAINING < 50 )) && (( CALL_COUNT % 25 == 0 )); then
    write_checkpoint "periodic"
fi

# Exit if no warning needed
[ "$SEVERITY" = "none" ] && exit 0

# Debounce: every 5 calls unless severity escalated
ESCALATED=false
[ "$SEVERITY" = "critical" ] && [ "$LAST_SEVERITY" != "critical" ] && ESCALATED=true
if [ "$ESCALATED" = "false" ] && (( CALL_COUNT % 5 != 0 )); then
    exit 0
fi

# Emit warning (stderr -> Claude sees it via exit 2)
if [ "$SEVERITY" = "critical" ]; then
    # Write checkpoint at critical before emitting warning
    write_checkpoint "critical"
    echo "CRITICAL: Context at ${REMAINING}% remaining. STOP new work. Commit current changes, save important state to memory, and inform user context is nearly exhausted. Recovery checkpoint saved at /tmp/claude-checkpoint-${SESSION}.json." >&2
    exit 2
elif [ "$SEVERITY" = "warning" ]; then
    echo "WARNING: Context at ${REMAINING}% remaining. Begin wrapping up current task. Do not start new complex work." >&2
    exit 2
fi
