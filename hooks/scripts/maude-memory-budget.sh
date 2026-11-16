#!/usr/bin/env bash
# Maude memory-budget rail: the auto-memory index (<slug>/memory/MEMORY.md) has a budget.
#
#   gate          stdin = PreToolUse JSON for Write/Edit/MultiEdit. Exit 42 (with the reason
#                 on stderr) when the edit would leave the index past its budget AND larger
#                 than it is now; maude-pre-tool-use.sh turns 42, and only 42, into the
#                 harness's refusal (2). bash itself exits 2 on a syntax error, so a broken
#                 copy of this file must not be able to speak the refusal code. A shrinking
#                 edit always passes: a trim is never refused.
#   prompt <file> print one line on stdout while <file> is over budget. A write made through
#                 Bash cannot be judged before it runs, so this is the net for it.
#
# Claude Code loads the index whole at every session start, so its size is rent every
# session pays. The budget is maude_memory_budget (gate-config "memory_index_budget",
# default just under the loader's 25,000-unit cut). Measured in UTF-16 units, the loader's
# unit, with \r\n as two. Fails OPEN without jq or python3: this rail keeps the index lean,
# it guards nothing irreversible, and an adopter without them should not lose their Write
# tool to it. python3 runs isolated (-I): the hook's working directory is the user's
# project, and a plain `python3 -c` imports a json.py sitting there.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

MODE="${1:-}"
BUDGET="$(maude_memory_budget)"

if [ "$MODE" = "prompt" ]; then
  F="${2:-}"
  [ -f "$F" ] || exit 0
  # A UTF-16 unit is never more than a UTF-8 byte, so a file within budget in bytes is
  # within it in units, and the common case costs one stat, not a python start.
  BYTES="$(wc -c < "$F" 2>/dev/null | tr -d ' ')"
  [ "${BYTES:-0}" -le "$BUDGET" ] 2>/dev/null && exit 0
  maude_python3_ok || exit 0
  UNITS="$(maude_utf16_units "$F")"
  if [ "${UNITS:-0}" -gt "$BUDGET" ] 2>/dev/null; then
    printf 'Maude: MEMORY.md is %s units, past its budget of %s, and every session loads all of it. Move detail into topic files and keep one line per pointer in the index.\n' "$UNITS" "$BUDGET"
  fi
  exit 0
fi

[ "$MODE" = "gate" ] || exit 0
INPUT="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
maude_is_memory_index "$FP" || exit 0
maude_python3_ok || exit 0

# The file the edit would leave, applied the way the tool applies it: Write replaces,
# Edit and MultiEdit replace old_string (once, or every one with replace_all), in order.
# An old_string that is not there is the tool's to refuse, not this rail's. The input
# goes in on stdin: an environment variable holds 128 KiB at most, and a write past that
# would never reach python at all.
VERDICT="$(printf '%s' "$INPUT" | python3 -I -c '
import json, os, sys
budget = int(sys.argv[1])
try:
    d = json.loads(sys.stdin.read())
    ti, tool = d.get("tool_input") or {}, d.get("tool_name") or ""
    fp = ti["file_path"]
except Exception:
    sys.exit(0)
if os.path.lexists(fp) and not os.path.isfile(fp):
    sys.exit(0)  # a FIFO or a directory: opening one could hang, and it is not an index
try:
    with open(fp, encoding="utf-8", errors="replace", newline="") as f:
        cur = f.read()
except FileNotFoundError:
    cur = ""
except Exception:
    sys.exit(0)
if tool == "Write":
    new = ti.get("content") or ""
elif tool in ("Edit", "MultiEdit"):
    new = cur
    for e in ([ti] if tool == "Edit" else (ti.get("edits") or [])):
        old, rep = e.get("old_string") or "", e.get("new_string") or ""
        if not old or old not in new:
            sys.exit(0)
        new = new.replace(old, rep) if e.get("replace_all") else new.replace(old, rep, 1)
else:
    sys.exit(0)
units = lambda s: len(s.encode("utf-16-le")) // 2
before, after = units(cur), units(new)
if after > budget and after > before:
    print(before, after)
' "$BUDGET" 2>/dev/null)"
[ -n "$VERDICT" ] || exit 0
read -r NOW AFTER <<< "$VERDICT"
maude_log_trace "memory-budget" "blocked=$AFTER budget=$BUDGET" 2>/dev/null
printf 'Maude: this would grow MEMORY.md to %s units, past its budget of %s (it is %s now). Every session loads the whole index: put the detail in a topic file and keep one line here pointing to it. An edit that shrinks the index always passes. The budget is memory_index_budget in %s.\n' "$AFTER" "$BUDGET" "$NOW" "$(maude_gate_config)" >&2
exit 42
