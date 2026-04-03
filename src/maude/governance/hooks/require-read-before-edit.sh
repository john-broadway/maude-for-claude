#!/bin/bash
# Read-Before-Edit Guard — Art. IV Sec. 5: Inventory before you cut
# Hard-blocks Edit/Write if the target file hasn't been Read in this session.
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# --- Exemptions (narrow) ---
# Plan mode working files
[[ "$FILE_PATH" == "$HOME/.claude/plans/"* ]] && exit 0
# Auto-memory files
[[ "$FILE_PATH" == "$HOME/.claude/projects/"*"/memory/"* ]] && exit 0
# Temporary files
[[ "$FILE_PATH" == /tmp/* ]] && exit 0
# Lock files, bytecode, cache
case "$(basename "$FILE_PATH")" in
    *.lock|*.pyc|__pycache__) exit 0 ;;
esac

# New files (Write to non-existent path) are allowed
[[ ! -e "$FILE_PATH" ]] && exit 0

# --- Bridge check ---
SESSION_ID=""
[[ -f /tmp/claude-session-current.txt ]] && SESSION_ID=$(cat /tmp/claude-session-current.txt)
if [[ -z "$SESSION_ID" ]]; then
    # No session marker = no enforcement (graceful degradation)
    exit 0
fi

BRIDGE="/tmp/claude-reads-${SESSION_ID}.log"
if [[ ! -f "$BRIDGE" ]]; then
    # Bridge file missing = no enforcement
    exit 0
fi

# Check if file was read this session (exact line match)
if grep -qxF "$FILE_PATH" "$BRIDGE" 2>/dev/null; then
    exit 0
fi

# BLOCKED
echo "Art. IV Sec. 5: Read the file before editing. Use the Read tool on $FILE_PATH first."
exit 1
