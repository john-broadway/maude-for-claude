#!/usr/bin/env bash
# Maude infra-gate hook — the "suspenders". Fires before MCP infrastructure tools.
# CONFIG-DRIVEN: no deployment specifics live here. The gate reads its operating
# parameters from gate-config.json (path via $MAUDE_GATE_CONFIG or the default).
#
# When gate-config.json is absent or contains no infra_tool_prefix, the gate is
# INERT (exits 0) — safe for users who have not configured an infra server.
#
# NOTE: jq is REQUIRED to read the config. Without jq the gate is also inert
# (exits 0). The harness-level deny-rules are the jq-independent backstop for
# irreversible ops in that case.
#
# Configured behavior:
#   HARD-BLOCKS destructive ops against non-sandbox targets; ALLOWS targets that
#   match the configured sandbox nodes/vmids (RoE lane). FAIL-CLOSED: a destructive
#   op whose target cannot be proven to be a sandbox is blocked. Override: one-shot
#   /maude:conscience infra-destructive token in care.json. Exits 2 to block.
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

# Config-driven prefix. Without a configured prefix the gate is unconfigured/inert.
PREFIX="$(maude_infra_tool_prefix)"
if [ -z "$PREFIX" ]; then
  exit 0
fi

# Tool name via jq (required). Without jq the prefix cannot be read either, so the
# gate already exited above. This path is defensive only.
TOOL=""
if command -v jq >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)"
fi

# Fallback grep without jq: extract any mcp__*__* pattern then verify against PREFIX.
if [ -z "$TOOL" ]; then
  TOOL="$(printf '%s' "$INPUT" | grep -oE 'mcp__[a-z0-9]+__[a-z_]+' | head -1)"
fi

# Verify the tool belongs to the configured server (prefix match). If not ours → pass.
case "$TOOL" in
  "$PREFIX"*) ;;   # our server — continue
  *) exit 0 ;;
esac

BARE="${TOOL##*__}"

# Fail-CLOSED: if we could not identify the tool at all, we cannot prove this is safe.
if [ -z "$BARE" ]; then
  maude_log_trace "infra-gate" "blocked=unidentified-tool prefix=$PREFIX"
  printf 'Maude: infra-gate could not identify the configured tool (missing tool_name). Blocked fail-closed.\n' >&2
  exit 2
fi

# Only destructive tools are gated; reads/lists/status pass freely.
case " $(maude_infra_destructive_tools) " in
  *" $BARE "*) ;;     # destructive — continue to target check
  *) exit 0 ;;
esac

# One-shot override token?
NOW=$(date +%s)
CARE="$(maude_self_dir)/care.json"
if [ -f "$CARE" ] && command -v jq >/dev/null 2>&1; then
  CU="$(jq -r '.gate_cleared["infra-destructive"].until // 0' "$CARE" 2>/dev/null)"
  if [ -n "$CU" ] && [ "$CU" -gt 0 ] && [ "$CU" -gt "$NOW" ] 2>/dev/null; then
    maude_care_set "$CARE" 'del(.gate_cleared["infra-destructive"])'
    maude_log_trace "infra-gate" "passed=infra-destructive tool=$BARE"
    exit 0
  fi
fi

# Target. Without jq we cannot parse the target → fail CLOSED (block below).
NODE=""; VMID=""
if command -v jq >/dev/null 2>&1; then
  NODE="$(printf '%s' "$INPUT" | jq -r '.tool_input.node // ""' 2>/dev/null)"
  VMID="$(printf '%s' "$INPUT" | jq -r '.tool_input.vmid // ""' 2>/dev/null)"
fi

if maude_is_comanage_target "$NODE" "$VMID"; then
  maude_log_trace "infra-gate" "allowed-sandbox tool=$BARE node=$NODE vmid=$VMID"
  exit 0
fi

maude_log_trace "infra-gate" "blocked=infra-destructive tool=$BARE node=$NODE vmid=$VMID"
printf 'Maude: destructive infrastructure tool "%s" against a non-sandbox target (node="%s" vmid="%s"). Irreversible. Configured sandbox targets are allowed automatically; for anything else run /maude:conscience infra-destructive only intentionally.\n' \
  "$BARE" "${NODE:-?}" "${VMID:-?}" >&2
exit 2
