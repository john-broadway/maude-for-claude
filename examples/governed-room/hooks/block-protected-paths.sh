#!/bin/bash
# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the MIT License
# Version: 1.0
# Created: 2026-03-28 MST
# Authors: John Broadway, Claude (Anthropic)
#
# Governance hook — block writes to protected paths.
#
# This hook demonstrates the Claude Code PreToolUse hook pattern.  It reads
# the tool input JSON from stdin and denies any Write/Edit/Bash tool call that
# targets a protected path.
#
# Protected paths in this example:
#   - /etc/*          — system configuration (never modify directly)
#   - /var/lib/maude/*  — Maude sovereign state (use MCP tools)
#   - *.env / *.pem / *.key   — credentials (managed out-of-band)
#
# Hook contract (Claude Code PreToolUse):
#   stdin  — JSON tool-use payload
#   stdout — JSON response (permissionDecision: "allow" | "deny")
#   exit 0 — allow (when no stdout JSON is emitted)
#   exit 0 + JSON with deny — block the tool call
#
# Installation (in .claude/settings.json hooks array):
#   {
#     "hooks": [
#       {
#         "event": "PreToolUse",
#         "command": "bash examples/governed-room/hooks/block-protected-paths.sh"
#       }
#     ]
#   }
#
# See: src/maude/governance/hooks/ for the full hook library shipped with
# the Maude framework.

set -euo pipefail

INPUT=$(cat)

# Extract the file path from Write, Edit, or Bash tool input.
# Different tools use different field names.
FILE_PATH=$(echo "$INPUT" | jq -r '
  .tool_input.file_path //
  .tool_input.path //
  empty
' 2>/dev/null || true)

# For Bash tool calls, extract the command and check for writes to protected paths.
BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

deny() {
  local reason="$1"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# --- File path checks (Write / Edit tools) ---
if [[ -n "$FILE_PATH" ]]; then
  # Block writes to system config
  if [[ "$FILE_PATH" == /etc/* ]]; then
    deny "Write to /etc/ is blocked. Use a configuration management tool."
  fi

  # Block writes to Maude sovereign state — use MCP tools instead
  if [[ "$FILE_PATH" == /var/lib/maude/* ]]; then
    deny "Write to Maude state dir blocked. Use memory_store MCP tool."
  fi

  # Block credential files
  if [[ "$FILE_PATH" == *.env ]] || \
     [[ "$FILE_PATH" == *.env.* ]] || \
     [[ "$FILE_PATH" == *.pem ]] || \
     [[ "$FILE_PATH" == *.key ]] || \
     [[ "$FILE_PATH" == *id_rsa* ]] || \
     [[ "$FILE_PATH" == *id_ed25519* ]]; then
    deny "Write to credential file blocked: $FILE_PATH — use manual editor."
  fi
fi

# --- Bash command checks ---
if [[ -n "$BASH_CMD" ]]; then
  # Block direct writes to Maude state via shell redirection
  if echo "$BASH_CMD" | grep -qE '>\s*/var/lib/maude/'; then
    deny "Shell write to Maude state dir blocked. Use memory_store MCP tool."
  fi

  # Block rm -rf on Maude state
  if echo "$BASH_CMD" | grep -qE 'rm\s+-[rf]+\s+/var/lib/maude'; then
    deny "Deletion of Maude state blocked — archive, do not delete."
  fi
fi

# Allow by default (exit 0 with no output)
exit 0
