#!/usr/bin/env bash
# Tests for hooks/scripts/maude-infra-gate.sh — the suspenders (MCP/infra gate).
# Uses INVENTED generic fixtures (mcp__testsrv__, delete_thing, test-node-a, 9001,
# prod-x) — no deployment-specific literals anywhere in this file.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
GATE="$HOOKS_DIR/maude-infra-gate.sh"

# Write the generic gate config before any tests that need it.
printf '{"infra_tool_prefix":"mcp__testsrv__","infra_destructive_tools":["delete_thing","wipe_store"],"infra_sandbox_nodes":["test-node-a"],"infra_sandbox_vmids":["9001"]}\n' > "$MAUDE_GATE_CONFIG"

run_infra() {  # tool, args-json
  ERR="$(make_mcp_tool_input "$1" "$2" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

# ── Block prod-destructive ───────────────────────────────────────────────
test_start "blocks delete_thing on a prod node"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x","vmid":777}'
assert_exit "$RC" "2" "prod delete blocked"

test_start "block names the infra-destructive key"
assert_contains "$ERR" "infra-destructive" "key hint"

test_start "blocks wipe_store on prod"
run_infra "mcp__testsrv__wipe_store" '{"node":"prod-x","storage":"data"}'
assert_exit "$RC" "2" "wipe_store blocked"

test_start "blocks another destructive op on prod"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "delete_thing prod blocked"

# ── Fail-closed: unprovable target → block ───────────────────────────────
test_start "fail-CLOSED: destructive with NO node/vmid → block"
run_infra "mcp__testsrv__delete_thing" '{}'
assert_exit "$RC" "2" "no target → block"

# ── Allow the named sandbox ──────────────────────────────────────────────
test_start "allows delete_thing on test-node-a (sandbox node)"
run_infra "mcp__testsrv__delete_thing" '{"node":"test-node-a","vmid":201}'
assert_exit "$RC" "0" "sandbox node allowed"

test_start "allows delete_thing on sandbox vmid 9001"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x","vmid":9001}'
assert_exit "$RC" "0" "sandbox vmid allowed"

# ── Non-destructive tool passes freely ──────────────────────────────────
test_start "passes a non-destructive configured-server read"
run_infra "mcp__testsrv__list_things" '{"node":"prod-x"}'
assert_exit "$RC" "0" "read allowed"

# ── Override token (one-shot) ────────────────────────────────────────────
# infra-destructive is a RED key (v0.10.1) — its one-shot token lives in the
# dedicated, harness-locked care-redclear.json, written only by John's ! line.
test_start "respects a live infra-destructive token in care-redclear.json"
printf '{"gate_cleared":{"infra-destructive":{"until":%d}}}\n' $(($(date +%s)+600)) > "$(redclear_path)"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x","vmid":777}'
assert_exit "$RC" "0" "token allowed pass"

test_start "token clears after one use"
remaining="$(jq -r '.gate_cleared["infra-destructive"].until // "absent"' "$(redclear_path)" 2>/dev/null)"
assert_eq "$remaining" "absent" "one-shot consumed"

test_start "second destructive call re-blocks after token use"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x","vmid":777}'
assert_exit "$RC" "2" "re-blocked"

# ── Without jq the gate is INERT (can't read config → exit 0) ───────────
# NOTE: jq is required to read infra_tool_prefix from gate-config.json.
# Without jq, maude_infra_tool_prefix() returns empty → gate exits 0 (inert).
# This is deliberate: the harness-level deny-rules are the jq-independent
# backstop for irreversible ops. The gate documents this in its header.
test_start "gate is INERT (exit 0) without jq — can't read config prefix"
NOJQ="$(make_nojq_bin)"
make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' \
  | PATH="$NOJQ" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "0" "no-jq → inert exit 0"

# ── Deepest degradation: no jq AND no grep → also inert (can't read config) ─
test_start "gate is INERT (exit 0) with neither jq nor grep"
NOTOOLS="$(make_nojq_nogrep_bin)"
make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' \
  | PATH="$NOTOOLS" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "0" "no-jq-no-grep → inert exit 0"

# ── Different-server tool is ignored (prefix doesn't match config) ───────
test_start "different-server tool passes (mcp__othersrv__ vs configured mcp__testsrv__)"
# Config is still set to mcp__testsrv__; a mcp__othersrv__ tool should exit 0.
run_infra "mcp__othersrv__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "0" "non-matching prefix → gate ignores"

# ── No config → gate is inert ────────────────────────────────────────────
# This test MUST come last because it removes the config file, leaving gate inert.
test_start "gate is inert when no config file is present"
rm -f "$MAUDE_GATE_CONFIG"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "0" "no config → gate inert"

print_summary
teardown_test_env
exit $FAILED
