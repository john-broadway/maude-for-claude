#!/usr/bin/env bash
# Tests for hooks/scripts/maude-dispatch-watch.sh — the sub-agent model whisper.
#
# The documented drift: sub-work (scouts, greps, reads) dispatched on the
# flagship model — real tokens wasted on work a small model does fine. The
# whisper fires when an Agent/Task dispatch carries a flagship model OR no
# model at all (which inherits the flagship main loop). Never blocks.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

WATCH="$HOOKS_DIR/maude-dispatch-watch.sh"

# Run the watch against a synthetic Agent dispatch. Sets $RC and $ERR.
# Usage: run_watch '<tool_input json>' [tool_name]
run_watch() {
  local args="$1" tool="${2:-Agent}"
  ERR="$(make_mcp_tool_input "$tool" "$args" | bash "$WATCH" 2>&1 >/dev/null)"
  RC=$?
}

# Reset the daily cooldown between scenarios (single key, like drift-watch).
clear_cooldown() {
  local care; care="$(care_path)"
  [ -f "$care" ] && jq 'del(.dispatch_warned, .dispatch_warned_workflow)' "$care" > "$care.tmp" && mv "$care.tmp" "$care"
}

# ── Whisper fires: flagship / unset ────────────────────────────────────

test_start "whispers on explicit flagship model (opus)"
run_watch '{"description":"search the repo","prompt":"grep stuff","model":"opus"}'
assert_contains "$ERR" "Maude:" "stderr"

test_start "flagship whisper never blocks (exit 0)"
assert_exit "$RC" "0" "exit"

test_start "flagship whisper names the drift (model-to-task match)"
assert_contains "$ERR" "model" "stderr"

test_start "whispers on fable too"
clear_cooldown
run_watch '{"description":"scout","prompt":"find files","model":"fable"}'
assert_contains "$ERR" "Maude:" "stderr"

test_start "whispers when model is unset (inherits the flagship)"
clear_cooldown
run_watch '{"description":"scout","prompt":"find files"}'
assert_contains "$ERR" "Maude:" "stderr"

test_start "unset-model whisper says the model was not chosen"
assert_contains "$ERR" "no model" "stderr"

test_start "whisper is logged to the trace as a drift catch"
TRACE_LINE="$(grep '"kind":"drift"' "$(trace_path)" | grep dispatch | head -1)"
assert_contains "$TRACE_LINE" "dispatch" "trace"

# ── Silent: right-sized dispatches ─────────────────────────────────────

test_start "silent on haiku"
clear_cooldown
run_watch '{"description":"scout","prompt":"find files","model":"haiku"}'
assert_eq "$ERR" "" "stderr empty"

test_start "silent on sonnet"
run_watch '{"description":"build a thing","prompt":"implement","model":"sonnet"}'
assert_eq "$ERR" "" "stderr empty"

test_start "silent dispatches still exit 0"
assert_exit "$RC" "0" "exit"

# ── Cooldown: once per day ─────────────────────────────────────────────

test_start "second flagship dispatch same day is silent (daily cooldown)"
clear_cooldown
run_watch '{"description":"a","prompt":"b","model":"opus"}'
run_watch '{"description":"c","prompt":"d","model":"opus"}'
assert_eq "$ERR" "" "stderr empty on repeat"

test_start "cooldown is shared across flagship and unset (one drift class)"
run_watch '{"description":"c","prompt":"d"}'
assert_eq "$ERR" "" "stderr empty"

# ── Workflow dispatches (the drift's second home) ──────────────────────
# A workflow script's agent() calls never pass through the Agent tool, so
# the Agent|Task whisper can't see them. Stock/named harnesses set no
# model: at all — every agent() inherits the flagship main loop.

test_start "whispers on inline workflow script with agent() calls and no model:"
clear_cooldown
run_watch '{"script":"export const meta={name:\"x\"}\nconst r = await agent(\"find bugs\")\nreturn r"}' "Workflow"
assert_contains "$ERR" "Maude:" "stderr"

test_start "workflow whisper says the agents inherit the flagship"
assert_contains "$ERR" "model:" "stderr"

test_start "silent when the workflow script sets model: somewhere"
clear_cooldown
run_watch '{"script":"const r = await agent(\"verify\", {model: \"haiku\"})"}' "Workflow"
assert_eq "$ERR" "" "stderr empty"

test_start "silent when the script has no agent() calls at all"
clear_cooldown
run_watch '{"script":"log(\"hello\"); return 1"}' "Workflow"
assert_eq "$ERR" "" "stderr empty"

test_start "the named-workflow block speaks (Maude: on stderr)"
clear_cooldown
run_watch '{"name":"deep-research","args":{"q":"x"}}' "Workflow"
assert_contains "$ERR" "Maude:" "stderr"

test_start "named-workflow block carries the tier-the-scriptPath rule"
assert_contains "$ERR" "scriptPath" "stderr"

test_start "whispers on scriptPath whose file has agent() and no model:"
clear_cooldown
printf 'const a = await agent("scan")\n' > "$TEST_TMP/wf.js"
run_watch "{\"scriptPath\":\"$TEST_TMP/wf.js\"}" "Workflow"
assert_contains "$ERR" "Maude:" "stderr"

test_start "silent on scriptPath whose file tiers its agents"
clear_cooldown
printf 'const a = await agent("scan", {model: "haiku"})\n' > "$TEST_TMP/wf2.js"
run_watch "{\"scriptPath\":\"$TEST_TMP/wf2.js\"}" "Workflow"
assert_eq "$ERR" "" "stderr empty"

test_start "workflow cooldown is separate from the Agent cooldown"
clear_cooldown
run_watch '{"description":"a","prompt":"b","model":"opus"}'      # burns the Agent key
run_watch '{"script":"await agent(\"x\")"}' "Workflow"           # workflow key still fresh
assert_contains "$ERR" "Maude:" "stderr"

test_start "second workflow whisper same day is silent"
run_watch '{"script":"await agent(\"y\")"}' "Workflow"
assert_eq "$ERR" "" "stderr empty"

test_start "workflow whisper is logged to the trace as a drift catch"
TRACE_LINE="$(grep '"kind":"drift"' "$(trace_path)" | grep workflow | head -1)"
assert_contains "$TRACE_LINE" "workflow" "trace"

# ── Teeth: the expensive fan-out BLOCKS (exit 2), not a whisper ────────
# A whisper is skippable — tonight proved it. An untiered fan-out (parallel/
# pipeline) or a named stock-harness workflow now hard-blocks: tier it, or
# consciously override. A single untiered agent stays a (proportionate) whisper.

test_start "blocks (exit 2) an inline workflow that fans out untiered (parallel)"
clear_cooldown
run_watch '{"script":"const r = await parallel(items.map(x => () => agent(\"scan \"+x)))"}' "Workflow"
assert_exit "$RC" "2" "exit"

test_start "fan-out block names the fix (tier the stages)"
assert_contains "$ERR" "haiku" "stderr"

test_start "fan-out block names the conscious override"
assert_contains "$ERR" "MAUDE_ALLOW_UNTIERED_WORKFLOW" "stderr"

test_start "a pipeline() fan-out blocks too"
clear_cooldown
run_watch '{"script":"await pipeline(xs, a => agent(a))"}' "Workflow"
assert_exit "$RC" "2" "exit"

test_start "blocks (exit 2) a named workflow (stock harness defaults to flagship)"
clear_cooldown
run_watch '{"name":"deep-research","args":{"q":"x"}}' "Workflow"
assert_exit "$RC" "2" "exit"

test_start "named block carries the tier-the-scriptPath rule"
assert_contains "$ERR" "scriptPath" "stderr"

test_start "the conscious env override lets an untiered fan-out through (exit 0)"
clear_cooldown
ERR="$(make_mcp_tool_input "Workflow" '{"script":"await parallel(xs.map(x=>()=>agent(x)))"}' | MAUDE_ALLOW_UNTIERED_WORKFLOW=1 bash "$WATCH" 2>&1 >/dev/null)"
RC=$?
assert_exit "$RC" "0" "exit"

test_start "the override is silent (no whisper, no block)"
assert_eq "$ERR" "" "stderr empty"

test_start "a single untiered agent (no fan-out) still only whispers, never blocks"
clear_cooldown
run_watch '{"script":"const r = await agent(\"one thing\")"}' "Workflow"
assert_exit "$RC" "0" "exit"

test_start "the single-agent whisper still speaks"
assert_contains "$ERR" "Maude:" "stderr"

test_start "a block fires every time — the daily cooldown never silences it"
clear_cooldown
run_watch '{"name":"a"}' "Workflow"    # block 1
run_watch '{"name":"b"}' "Workflow"    # block 2, same day — must STILL block
assert_exit "$RC" "2" "exit"

test_start "the block is logged to the trace"
TRACE_LINE="$(grep '"kind":"drift"' "$(trace_path)" | grep 'workflow-block' | head -1)"
assert_contains "$TRACE_LINE" "block" "trace"

# ── Defensive guards ───────────────────────────────────────────────────

test_start "non-dispatch tool input is ignored"
clear_cooldown
run_watch '{"command":"ls"}' "Bash"
assert_eq "$ERR" "" "stderr empty"

test_start "empty stdin is inert"
ERR="$(printf '' | bash "$WATCH" 2>&1 >/dev/null)"
RC=$?
assert_exit "$RC" "0" "exit"

test_start "no jq → inert exit 0"
NOJQ_BIN="$(make_nojq_bin)"
ERR="$(make_mcp_tool_input "Agent" '{"model":"opus"}' | PATH="$NOJQ_BIN" bash "$WATCH" 2>&1 >/dev/null)"
RC=$?
assert_exit "$RC" "0" "exit"

teardown_test_env
print_summary
