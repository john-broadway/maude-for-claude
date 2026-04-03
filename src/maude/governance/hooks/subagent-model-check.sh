#!/usr/bin/env bash
# Hook: PreToolUse:Agent — Enforce explicit model selection on background agents
# Prevents accidentally burning opus tokens on verification/light tasks
#
# Rules:
#   - Background agents (run_in_background=true) MUST specify a model
#   - Foreground agents get a warning but aren't blocked
#
# Model guidance (from MEMORY.md):
#   haiku  — verify/audit, lint fixes, read-only checks
#   sonnet — moderate code, new files following patterns
#   opus   — complex implementation, novel architecture

set -euo pipefail

# Read tool input from stdin
INPUT=$(cat)

# Extract relevant fields
RUN_BG=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tool_input = data.get('tool_input', {})
print(tool_input.get('run_in_background', False))
" 2>/dev/null || echo "False")

MODEL=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tool_input = data.get('tool_input', {})
print(tool_input.get('model', ''))
" 2>/dev/null || echo "")

DESC=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tool_input = data.get('tool_input', {})
print(tool_input.get('description', '')[:60])
" 2>/dev/null || echo "")

# Background agents without explicit model → BLOCK
if [[ "$RUN_BG" == "True" && -z "$MODEL" ]]; then
    echo "BLOCKED: Background agent '${DESC}' has no explicit model. Defaults to opus (expensive)."
    echo "Add model='haiku' (verify/audit), 'sonnet' (moderate code), or 'opus' (complex) to the Task call."
    exit 1
fi

# Foreground agents without explicit model → WARN (don't block)
if [[ -z "$MODEL" ]]; then
    echo "WARNING: Agent '${DESC}' defaulting to opus. Consider haiku (verify) or sonnet (moderate code)." >&2
fi

exit 0
