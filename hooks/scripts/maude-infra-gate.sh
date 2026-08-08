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
#   /maude:conscience infra-destructive token in care-redclear.json (John's hand).
#   Exits 2 to block.
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

# ── Prefixes: a LIST, and no longer the thing that decides coverage ──────────
# Until 2026-07-30 this was a single STRING and an empty value made the gate inert.
# Two holes, both proven live against the shipped gate:
#   1. a SECOND mcp server managing a SECOND live hypervisor was invisible — the
#      identical destructive tool returned exit 0 there while blocking on the
#      configured one. A whole production estate with no brake.
#   2. destructive-ness was a 9-name allowlist, so any destructive tool nobody had
#      enumerated (a disk wipe, a pool destroy, an invented name) passed even on the
#      CONFIGURED server. The config had sat untouched for 44 days while the tool
#      surface grew by hundreds of names.
# Same defect as a verb-keyed denylist: it only knows what somebody thought of.
# Now the prefix list only decides whether the CONFIGURED name list applies. The
# destructive-VERB check below applies to every mcp__ tool from any server, so an
# unconfigured or brand-new server fails CLOSED instead of open.
PREFIXES=""
if command -v jq >/dev/null 2>&1; then
  _cfg="$(maude_gate_config)"
  if [ -f "$_cfg" ]; then
    # Accept a string OR an array, so existing configs keep working untouched.
    PREFIXES="$(jq -r '(.infra_tool_prefix // empty) | if type=="array" then .[] else . end' "$_cfg" 2>/dev/null)"
  fi
fi
[ -z "$PREFIXES" ] && PREFIXES="$(maude_infra_tool_prefix)"

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

# Anything that is not an mcp tool is none of this gate's business.
case "$TOOL" in
  mcp__*) ;;
  *) exit 0 ;;
esac

# Is this one of the servers named in the config? Only used to decide whether the
# configured NAME list applies; it no longer decides whether we look at all.
CONFIGURED=0
for _p in $PREFIXES; do
  [ -z "$_p" ] && continue
  case "$TOOL" in "$_p"*) CONFIGURED=1; break ;; esac
done

BARE="${TOOL##*__}"

# Fail-CLOSED: if we could not identify the tool at all, we cannot prove this is safe.
if [ -z "$BARE" ]; then
  maude_log_trace "infra-gate" "blocked=unidentified-tool"
  printf 'Maude: infra-gate could not identify the tool (missing tool_name). Blocked fail-closed.\n' >&2
  exit 2
fi

# ── Is this destructive? ─────────────────────────────────────────────────────
# Two independent reasons, either sufficient:
#   (a) the configured name list, for a configured server (unchanged behaviour)
#   (b) a destructive VERB in the bare name, for ANY mcp server
# (b) is what closes the second-estate hole and the unenumerated-tool hole.
#
# READ verbs are checked FIRST and win, because on a real mcp surface reads vastly
# outnumber destructive calls. A gate that stops `list_guests` gets switched off
# within a day, and a gate that is off protects nothing — the ALLOW rows in
# tests/test-infra-gate.sh are as load-bearing as the BLOCK rows. Note that
# `list_snapshots` must stay allowed even though it contains no destructive verb;
# the read check is a prefix/word match, not a substring hunt.
DESTRUCTIVE=0
case "$BARE" in
  list_*|get_*|read_*|show_*|describe_*|status*|diagnose*|doctor*|verify*|audit*|\
  log|logs|*_log|*_logs|*_list|*_status|*_get|freshness*|*_freshness|search*|find_*|\
  content|*_content|tree*|*_tree|whoami|version*|help*)
    DESTRUCTIVE=0
    ;;
  *)
    if [ "$CONFIGURED" -eq 1 ]; then
      case " $(maude_infra_destructive_tools) " in
        *" $BARE "*) DESTRUCTIVE=1 ;;
      esac
    fi
    # (b) the verb sweep — deliberately only genuinely irreversible verbs. Power
    # actions (stop/shutdown/reboot) are YELLOW in the house rules, not RED, and are
    # left out on purpose so this stays a RED gate rather than a nuisance.
    case "$BARE" in
      *delete*|*destroy*|*wipe*|*erase*|*purge*|*prune*|*rollback*|*revoke*|\
      *remove*|*obliterate*|*format*|*initgpt*|*truncate*|*drop*|*reset*)
        DESTRUCTIVE=1 ;;
    esac
    ;;
esac
[ "$DESTRUCTIVE" -eq 0 ] && exit 0

# One-shot override token? infra-destructive is a RED key (v0.10.1) — its token
# lives in the dedicated, harness-locked care-redclear.json (written only by
# John's ! line), not in care.json.
NOW=$(date +%s)
CARE="$(maude_redclear_file)"
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
