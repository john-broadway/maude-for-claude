#!/usr/bin/env bash
# Maude trace hook — appends a one-line JSON event-metadata record per turn.
# Used by both UserPromptSubmit and PostToolUse.
#
# CAPTURES: ts, kind, hook event, tool name, target path (file_path arg only).
# DOES NOT CAPTURE: tool_response (file content, bash output), bash command
# content, prompt text. Those are leak vectors — anything Read/Edit/Bash does
# would otherwise dump user content into the local trace JSONL.
#
# Trade-off: less detailed audit trail than capturing full I/O. The cost of
# privacy.
#
# Reads stdin (Claude Code passes a JSON envelope). Always exits 0.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Trace lives in her closet. Auto-create — her own dir.
maude_ensure_self_dir
TRACE_DIR="$(maude_self_dir)/trace"
mkdir -p "$TRACE_DIR" 2>/dev/null
# Single source of truth for the filename (UTC date, matching each record's ts).
TRACE="$(maude_trace_file)"

INPUT="$(cat 2>/dev/null)"
KIND="${1:-event}"

if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  # Project metadata-only fields — drop tool_input.content, tool_response, etc.
  # `session` ties the entry to the session that produced it (the fleet fix:
  # concurrent sessions share this file). The envelope's session_id feeds the
  # ONE shared label computation — never a private substitution here, so
  # readers (drift-watch) resolve the identical label. `sid` keeps the raw
  # prefix for forensics.
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
  printf '%s' "$INPUT" | jq -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg kind "$KIND" \
    --arg s "$(maude_session_label "$SID")" \
    --arg sid "$SID" \
    '{
       ts: $ts,
       kind: $kind,
       hook: .hook_event_name,
       tool: .tool_name,
       target: (.tool_input.file_path // null),
       session: $s,
       sid: (if $sid == "" then null else $sid[0:8] end)
     }' >> "$TRACE" 2>/dev/null
else
  # No jq — write the bare-minimum event marker (still session-tied). The
  # label is sed-escaped like maude_log_trace's fallback: a tmux session name
  # can carry a quote, and one bad line would poison every later jq read of
  # the whole file.
  SESC="$(maude_session_label | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')"
  printf '{"ts":"%s","kind":"%s","session":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIND" "$SESC" >> "$TRACE"
fi

exit 0
