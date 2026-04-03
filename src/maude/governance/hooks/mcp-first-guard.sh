#!/bin/bash
# MCP-First Guard — Art. II Sec. 3: Communication through sanctioned interfaces
# Hard-blocks curl/wget/ssh/psql that target MCP-served endpoints.
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$CMD" ]] && exit 0

# --- Exemptions ---
# Diagnostic tools (read-only, no state change)
if echo "$CMD" | grep -qE '^\s*(ping|traceroute|tracepath|dig|nslookup|host|mtr)\s'; then
    exit 0
fi
# Git commands (gitea push/pull via SSH is legitimate)
if echo "$CMD" | grep -qE '^\s*git\s'; then
    exit 0
fi
# Localhost is always OK
if echo "$CMD" | grep -qE '(localhost|127\.0\.0\.1)'; then
    exit 0
fi

# --- Subnet-based blocking ---
# Maude network ranges (configurable per deployment)
MAUDE_SUBNET='192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+'
# OT VLAN (example)
PLC_SUBNET='198\.18\.20\.[0-9]+'
# Proxmox ports
PVE_PORTS=':(8006|8007)'

# Check for curl/wget to Maude subnets
if echo "$CMD" | grep -qE '(curl|wget)\s' && echo "$CMD" | grep -qE "$MAUDE_SUBNET"; then
    # Determine which MCP to suggest
    if echo "$CMD" | grep -qE '192\.0\.2\.30'; then
        echo "BLOCKED (Art. II Sec. 3 — MCP First): Use mcp__postgres__query or mcp__postgres__list_tables instead of direct PostgreSQL access."
    elif echo "$CMD" | grep -qE '192\.0\.2\.40'; then
        echo "BLOCKED (Art. II Sec. 3 — MCP First): Use the coordinator MCP tools instead of direct access."
    elif echo "$CMD" | grep -qE "$PVE_PORTS"; then
        echo "BLOCKED (Art. II Sec. 3 — MCP First): Use Proxmox MCP tools (pve_*) instead of direct API access."
    else
        echo "BLOCKED (Art. II Sec. 3 — MCP First): Use the appropriate MCP server. Check ~/.claude/reference/mcp-servers.md for routing."
    fi
    exit 1
fi

# Check for curl/wget to PLC VLAN
if echo "$CMD" | grep -qE '(curl|wget)\s' && echo "$CMD" | grep -qE "$PLC_SUBNET"; then
    echo "BLOCKED (Art. VII Sec. 4 — Protected Resources): PLC VLAN is off-limits. Use plc_read_tag MCP tools."
    exit 1
fi

# Check for curl/wget to PVE/PBS ports on any host
if echo "$CMD" | grep -qE '(curl|wget)\s' && echo "$CMD" | grep -qE "$PVE_PORTS"; then
    echo "BLOCKED (Art. II Sec. 3 — MCP First): Use Proxmox/PBS MCP tools (pve_*, pbs_*) instead of direct API access."
    exit 1
fi

# Check for ssh to Maude subnets
if echo "$CMD" | grep -qE 'ssh\s' && echo "$CMD" | grep -qE "$MAUDE_SUBNET"; then
    echo "BLOCKED (Art. II Sec. 3 — MCP First): Use the appropriate MCP server for room interaction. SSH bypasses sanctioned interfaces."
    exit 1
fi

# Check for psql direct connections
if echo "$CMD" | grep -qE 'psql\s' && echo "$CMD" | grep -qE '192\.0\.2\.30'; then
    echo "BLOCKED (Art. II Sec. 3 — MCP First): Use mcp__postgres__query or mcp__postgres__list_tables instead of psql."
    exit 1
fi

exit 0
