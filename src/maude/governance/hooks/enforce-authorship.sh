#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# enforce-authorship.sh — Constitutional Authorship Enforcement
# ═══════════════════════════════════════════════════════════════
#
# Version:  1.0
# Created:  2026-02-26 12:14 MST
# Authors: John Broadway
#           Claude (Anthropic)
#
# Blocks Write tool from creating new files under ~/projects/
# that lack required header fields: Version, Created/Updated,
# and Authors/Author.
#
# Only triggers on NEW file creation (Write tool). Edits to
# existing files are not checked — the header should already
# be there from creation.
#
# Applies to: .sh, .py, .yaml, .yml, .toml, .md (config/docs)
# Skips: __pycache__, .pyc, node_modules, .git, test fixtures,
#        __init__.py, conftest.py, .env files
# ═══════════════════════════════════════════════════════════════

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')

# Only enforce on Write (new file creation), not Edit
[[ "$TOOL" != "Write" ]] && exit 0
[[ -z "$FILE_PATH" ]] && exit 0
[[ -z "$CONTENT" ]] && exit 0

# Only enforce under ~/projects/
[[ "$FILE_PATH" != /home/hp/projects/* ]] && exit 0

# Skip files that don't need headers
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
    __init__.py|conftest.py|*.pyc|.env|.env.*|*.lock|*.json)
        exit 0 ;;
esac

# Skip directories that don't need enforcement
case "$FILE_PATH" in
    */__pycache__/*|*/node_modules/*|*/.git/*|*/test/fixtures/*|*/.pytest_cache/*)
        exit 0 ;;
esac

# Only check file types that should have headers
EXT="${BASENAME##*.}"
case "$EXT" in
    sh|py|yaml|yml|toml|md|conf|cfg|ini)
        ;; # check these
    *)
        exit 0 ;; # skip binaries, images, etc.
esac

# If the file already exists, this is a rewrite — skip
# (the header should be there from original creation)
[[ -f "$FILE_PATH" ]] && exit 0

# ── Check for required fields in the first 20 lines ──────────

HEADER=$(echo "$CONTENT" | head -20)

MISSING=()

if ! echo "$HEADER" | grep -qi 'version'; then
    MISSING+=("Version")
fi

if ! echo "$HEADER" | grep -qiE 'created|updated|date'; then
    MISSING+=("Created/Date")
fi

if ! echo "$HEADER" | grep -qiE 'author'; then
    MISSING+=("Author(s)")
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
    exit 0
fi

# Format the missing fields list
MISSING_STR=$(IFS=', '; echo "${MISSING[*]}")

jq -n --arg missing "$MISSING_STR" --arg path "$FILE_PATH" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Constitutional authorship violation: new file " + $path + " is missing required header fields: " + $missing + ". Every artifact must have Version, Created date (with MST timestamp), and Author(s). Add a header block before writing.")
  }
}'
