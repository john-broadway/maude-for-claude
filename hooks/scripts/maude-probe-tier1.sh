#!/usr/bin/env bash
# Maude tier-1 probe — runs once per session at SessionStart.
# Checks if local services are up: localhost daemons (redis, qdrant, neo4j) and
# any tier-1 sources registered in the house-map. Caches result in care.json so
# commands can read it cheaply.
#
# Probes are fast (sub-second) but not free — that's why hooks don't run them
# per-turn. This script runs once and the result is consulted via maude_tier1_up().
#
# Never blocks. Fail-silent.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

maude_ensure_self_dir
SELF="$(maude_self_dir)"
CARE="$SELF/care.json"
NOW=$(date +%s)

# Tally: how many tier-1 sources are reachable
UP_COUNT=0
PROBED=""

# Probe localhost services if their ports are commonly used
for endpoint in 127.0.0.1:6379 127.0.0.1:6333 127.0.0.1:7474 127.0.0.1:8000; do
  if maude_tier2_reachable "$endpoint" 1; then
    UP_COUNT=$((UP_COUNT + 1))
    PROBED="${PROBED}${endpoint}=up "
  fi
done

# Decide tier1_up
TIER1_UP="false"
[ "$UP_COUNT" -gt 0 ] && TIER1_UP="true"

# Update care.json with probe results — preserve any existing fields via jq if available
if command -v jq >/dev/null 2>&1 && [ -f "$CARE" ]; then
  TMP="$(mktemp)"
  jq --arg now "$NOW" --arg up "$TIER1_UP" --arg probed "$PROBED" \
    '. + {tier1_last_probe: ($now|tonumber), tier1_up: ($up == "true"), tier1_probed: $probed}' \
    "$CARE" > "$TMP" 2>/dev/null && mv "$TMP" "$CARE" || rm -f "$TMP"
else
  # No jq or no existing care file — write a minimal one
  {
    printf '{\n'
    printf '  "tier1_last_probe": %s,\n' "$NOW"
    printf '  "tier1_up": %s,\n' "$TIER1_UP"
    printf '  "tier1_probed": "%s"\n' "$PROBED"
    printf '}\n'
  } > "$CARE"
fi

exit 0
