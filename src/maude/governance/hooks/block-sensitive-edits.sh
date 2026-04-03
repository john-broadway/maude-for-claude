#!/bin/bash
# Block edits/writes to sensitive files
# Credentials, env files, SSH keys — use a manual editor

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Check for sensitive file patterns
if [[ "$FILE_PATH" == *.env ]] || \
   [[ "$FILE_PATH" == *.env.* ]] || \
   [[ "$FILE_PATH" == */.env ]] || \
   [[ "$FILE_PATH" == *"secrets.yaml" ]] || \
   [[ "$FILE_PATH" == *"credentials"* ]] || \
   [[ "$FILE_PATH" == *".pem" ]] || \
   [[ "$FILE_PATH" == *".key" ]] || \
   [[ "$FILE_PATH" == *"id_rsa"* ]] || \
   [[ "$FILE_PATH" == *"id_ed25519"* ]]; then

  jq -n --arg path "$FILE_PATH" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Editing sensitive file blocked: " + $path + " — use manual editor")
    }
  }'
else
  exit 0
fi
