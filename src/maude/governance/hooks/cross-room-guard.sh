#!/bin/bash
# Hook: cross-room-guard
# Version: 1.2
# Created: 2026-03-07
# Updated: 2026-03-19
# Purpose: Block SCP/rsync to Maude Room IPs without sanctioned deployment scripts (Article II)

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only check scp and rsync commands
if ! echo "$CMD" | grep -qE '(scp|rsync)\s'; then
  exit 0
fi

# Accept known deployment patterns
if echo "$CMD" | grep -qE '(deploy-fleet|deploy\.sh|deploy-room)'; then
  exit 0
fi

# Match any Maude subnet IP across all sites and VLANs:
#   site-a: 10.0.x.x    site-b: 10.0.x.x
#   site-c: 10.0.x.x    site-d: 10.0.x.x
# Exclude the control plane (localhost) since that's us.
DEST_IP=$(echo "$CMD" | grep -oE '(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]+' | head -1)

if [[ -z "$DEST_IP" ]]; then
  # Also check DNS names like *.example.com (customize for your domain)
  if echo "$CMD" | grep -qE '[a-z0-9-]+\.example\.com'; then
    DEST_HOST=$(echo "$CMD" | grep -oE '[a-z0-9.-]+\.example\.com' | head -1)
    echo "BLOCKED: SCP/rsync to $DEST_HOST violates Article II sovereignty. Use deploy-fleet.sh or deploy.sh for authorized deployments."
    exit 1
  fi
  exit 0
fi

# Allow transfers to ourselves (control plane)
if [[ "$DEST_IP" == "localhost" ]]; then
  exit 0
fi

echo "BLOCKED: SCP/rsync to Room at $DEST_IP violates Article II sovereignty. Use deploy-fleet.sh or deploy.sh for authorized deployments."
exit 1
