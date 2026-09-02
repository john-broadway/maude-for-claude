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

test_start "the block names the file it looked in (the red twin of the gate's line)"
assert_contains "$ERR" "(looked in: " "names the care file it read"
looked="$(printf '%s\n' "$ERR" | sed -n 's/^ *(looked in: \(.*\))$/\1/p' | head -1)"
assert_eq "$looked" "$(redclear_path)" "and it is care-redclear.json"

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
# CHANGED 2026-07-30 (intent reversed, deliberately): this asserted exit 0 —
# "inert without jq" — on the reasoning that the harness deny-rules are the
# jq-independent backstop. The audit showed inert-by-default was the whole bug: it
# is what left a second live hypervisor with no brake. The destructive-VERB sweep is
# pure shell `case` matching on the tool name recovered by the grep fallback, so it
# does not need jq, and a destructive verb now fails CLOSED here too. Reads are
# still allowed without jq (covered below), so this is not a wall.
test_start "without jq a destructive verb now fails CLOSED (was: inert)"
NOJQ="$(make_nojq_bin)"
make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' \
  | PATH="$NOJQ" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "2" "no-jq → fail closed"

test_start "without jq a READ verb is still allowed (not a wall)"
make_mcp_tool_input "mcp__testsrv__list_things" '{}' \
  | PATH="$NOJQ" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "0" "no-jq read allowed"

# ── Deepest degradation: no jq AND no grep → also inert (can't read config) ─
test_start "gate is INERT (exit 0) with neither jq nor grep"
NOTOOLS="$(make_nojq_nogrep_bin)"
make_mcp_tool_input "mcp__testsrv__delete_thing" '{"node":"prod-x"}' \
  | PATH="$NOTOOLS" bash "$GATE" >/dev/null 2>&1
assert_exit "$?" "0" "no-jq-no-grep → inert exit 0"

# ── Different-server tool: INTENT REVERSED 2026-07-30 ────────────────────
# This test asserted that a destructive tool from an unconfigured mcp server exits
# 0. That assertion WAS the hole: on the real box it meant every destructive tool
# on a second production hypervisor sailed through while the identical tool blocked
# on the configured one. A test can encode a bug as intended behaviour and stay
# green forever; this is what that looks like.
test_start "different-server destructive tool now BLOCKS (was: passes)"
run_infra "mcp__othersrv__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "unconfigured server still gated"

test_start "different-server READ tool still passes"
run_infra "mcp__othersrv__list_things" '{}'
assert_exit "$RC" "0" "unconfigured server read allowed"

# ── No config: INTENT REVERSED 2026-07-30 ────────────────────────────────
# Was "gate is inert when no config file is present" asserting exit 0. An
# unconfigured house getting NO protection from a RED gate is the same
# inert-by-default defect. Destructive verbs now block with no config at all; reads
# still pass, so a user who never configures anything is protected rather than
# nagged.
test_start "with no config, a destructive verb still blocks (was: inert)"
rm -f "$MAUDE_GATE_CONFIG"
run_infra "mcp__testsrv__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "no config → still gated"

# Restore the generic config: the test above removes it, and everything below
# needs the sandbox lists back. (Ambient state left by a neighbour is exactly how
# my sandbox-exemption case first failed here.)
printf '{"infra_tool_prefix":"mcp__testsrv__","infra_destructive_tools":["delete_thing","wipe_store"],"infra_sandbox_nodes":["test-node-a"],"infra_sandbox_vmids":["9001"]}\n' > "$MAUDE_GATE_CONFIG"

# ── Coverage holes found by the 2026-07-30 audit ────────────────────────────
# Two structural gaps, both proven live against the shipped 0.24.0 gate:
#
#  1. `infra_tool_prefix` was a single STRING, so a SECOND MCP server managing a
#     SECOND live hypervisor was invisible: the identical destructive tool returned
#     exit 0 there while blocking on the configured one.
#  2. destructive-ness was a 9-name allowlist, so any destructive tool nobody had
#     enumerated (disk wipe, pool destroy, an invented name) passed even on the
#     CONFIGURED server. The config had not been touched in 44 days while the tool
#     surface grew by hundreds of names.
#
# Both are the same defect as the verb-keyed Bash table: an allowlist of things
# somebody thought of. The fix is to fail CLOSED on a destructive-looking verb from
# ANY mcp server, while keeping read verbs free so the gate stays usable.

# Second server, same destructive tool. This is the one that mattered: a whole
# live hypervisor with no brake.
test_start "blocks a destructive tool on a SECOND, unconfigured mcp server"
run_infra "mcp__testsrv2__delete_thing" '{"node":"prod-x","vmid":777}'
assert_exit "$RC" "2" "second server blocked"

test_start "blocks a destructive VERB not in the configured name list"
run_infra "mcp__testsrv__destroy_pool" '{"node":"prod-x"}'
assert_exit "$RC" "2" "unenumerated destroy blocked"

test_start "blocks a disk-wipe verb not in the configured list"
run_infra "mcp__testsrv__node_disk_wipe" '{"node":"prod-x"}'
assert_exit "$RC" "2" "wipe verb blocked"

test_start "blocks an INVENTED destructive name on an unknown server"
run_infra "mcp__unknownsrv__obliterate_everything" '{"node":"prod-x"}'
assert_exit "$RC" "2" "invented name blocked"

test_start "blocks a purge verb"
run_infra "mcp__testsrv2__purge_archive" '{"node":"prod-x"}'
assert_exit "$RC" "2" "purge blocked"

# ── The gate must stay USABLE, or it gets switched off ──────────────────────
# Read verbs vastly outnumber destructive ones on a real MCP surface. If this
# section fails, the gate is a wall and the wall will come down.

test_start "ALLOWS a list verb on any server"
run_infra "mcp__testsrv2__list_things" '{}'
assert_exit "$RC" "0" "list allowed"

test_start "ALLOWS a get verb on an unknown server"
run_infra "mcp__unknownsrv__get_thing" '{"node":"prod-x"}'
assert_exit "$RC" "0" "get allowed"

test_start "ALLOWS a status verb"
run_infra "mcp__testsrv2__status_check" '{"node":"prod-x"}'
assert_exit "$RC" "0" "status allowed"

test_start "ALLOWS a diagnose verb"
run_infra "mcp__testsrv2__diagnose_node" '{"node":"prod-x"}'
assert_exit "$RC" "0" "diagnose allowed"

test_start "ALLOWS an unrelated non-infra mcp server's read tool"
run_infra "mcp__somemail__list_labels" '{}'
assert_exit "$RC" "0" "unrelated read allowed"

test_start "ALLOWS a create verb (additive, not destructive)"
run_infra "mcp__testsrv2__create_thing" '{"node":"prod-x"}'
assert_exit "$RC" "0" "create allowed"

test_start "a non-mcp tool is untouched"
run_infra "Bash" '{"command":"ls"}'
assert_exit "$RC" "0" "bash untouched"

# ── sandbox exemption must still work for verb-detected tools ───────────────
test_start "sandbox node still exempt for a verb-detected destructive tool"
run_infra "mcp__testsrv__destroy_pool" '{"node":"test-node-a"}'
assert_exit "$RC" "0" "sandbox exempt"

# ── prefix may now be a LIST ────────────────────────────────────────────────
test_start "infra_tool_prefix accepts an ARRAY of prefixes"
cp "$MAUDE_GATE_CONFIG" "$TEST_TMP/cfg.bak"
printf '{"infra_tool_prefix":["mcp__aaa__","mcp__bbb__"],"infra_destructive_tools":["delete_thing"],"infra_sandbox_nodes":["test-node-a"],"infra_sandbox_vmids":["9001"]}\n' > "$MAUDE_GATE_CONFIG"
run_infra "mcp__bbb__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "array prefix second element"

test_start "array prefix: sandbox still exempt"
run_infra "mcp__aaa__delete_thing" '{"node":"test-node-a"}'
assert_exit "$RC" "0" "array prefix sandbox"
cp "$TEST_TMP/cfg.bak" "$MAUDE_GATE_CONFIG"

test_start "with NO config at all, a destructive mcp verb still blocks"
mv "$MAUDE_GATE_CONFIG" "$TEST_TMP/cfg.away"
run_infra "mcp__anything__delete_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "no config still blocks destructive"

test_start "with NO config, a read verb is still allowed"
run_infra "mcp__anything__list_things" '{}'
assert_exit "$RC" "0" "no config read allowed"
mv "$TEST_TMP/cfg.away" "$MAUDE_GATE_CONFIG"

# ── Array-prefix support, tested so its ABSENCE is detectable ───────────────
# The first version of the array test above was VACUOUS: it used `delete_thing`,
# which the destructive-VERB sweep blocks whether or not the prefix matched, so
# removing array support broke nothing and the test still passed. A mutation run
# (PREFIXES="") killed 9 tests and left that one green, which is how it was caught.
# These use a name with NO destructive verb in it, so the ONLY thing that can gate
# it is the configured name list — which means it can only pass if the prefix
# actually matched.
test_start "array prefix: a non-verb name from the 2nd prefix blocks via the name list"
printf '{"infra_tool_prefix":["mcp__aaa__","mcp__bbb__"],"infra_destructive_tools":["shuffle_thing"],"infra_sandbox_nodes":["test-node-a"],"infra_sandbox_vmids":["9001"]}\n' > "$MAUDE_GATE_CONFIG"
run_infra "mcp__bbb__shuffle_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "2nd array prefix honoured"

test_start "array prefix: the same non-verb name from an UNlisted server passes"
run_infra "mcp__ccc__shuffle_thing" '{"node":"prod-x"}'
assert_exit "$RC" "0" "unlisted server, no destructive verb"

test_start "array prefix: first element also honoured"
run_infra "mcp__aaa__shuffle_thing" '{"node":"prod-x"}'
assert_exit "$RC" "2" "1st array prefix honoured"

printf '{"infra_tool_prefix":"mcp__testsrv__","infra_destructive_tools":["delete_thing","wipe_store"],"infra_sandbox_nodes":["test-node-a"],"infra_sandbox_vmids":["9001"]}\n' > "$MAUDE_GATE_CONFIG"

print_summary
teardown_test_env
exit $FAILED
