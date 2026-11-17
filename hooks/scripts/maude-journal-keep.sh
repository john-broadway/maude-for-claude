#!/usr/bin/env bash
# Maude journal-keep rail: a Write never replaces a lane's history.
#
#   gate   stdin = PreToolUse JSON. Exit 42 (reason on stderr) when a Write would replace
#          an existing, non-empty lane file (<slug>/memory/now.md or now_<name>.md) with
#          content that does not keep the old text whole. maude-pre-tool-use.sh turns 42,
#          and only 42, into the harness refusal (2).
#
# A lane file is a line of work's dated history, newest entry on top. The Write tool
# replaces a file whole, so a Write that drops the old text throws the history away
# (2026-11-11 20:24Z: a ~3,900-line shared handoff replaced with 35 lines). Prepending a
# new dated entry above the old text, or appending below it, keeps the old text and
# passes. Edit and MultiEdit pass: they are targeted (named residual: an Edit that cuts
# a whole section passes). The remember plugin's own handoff is not a lane: its
# /remember replaces it by design. Design: docs/specs/2026-11-11-the-circle-design.md.
#
# Fails OPEN without jq or python3. python3 runs isolated (-I) and reads the tool input on
# stdin: an environment variable or an argument holds 128 KiB at most.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

[ "${1:-}" = "gate" ] || exit 0
INPUT="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
if printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
  FP="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
else
  # jq refuses some JSON python takes (a lone \ud800 surrogate escape); a parse jq
  # cannot do must not wave a Write through, so python reads the two fields.
  maude_python3_ok || exit 0
  TOOL="$(printf '%s' "$INPUT" | python3 -I -c 'import json,sys
d=json.loads(sys.stdin.read()); print(d.get("tool_name",""))' 2>/dev/null)"
  FP="$(printf '%s' "$INPUT" | python3 -I -c 'import json,sys
d=json.loads(sys.stdin.read()); print((d.get("tool_input") or {}).get("file_path",""))' 2>/dev/null)"
fi
[ "$TOOL" = "Write" ] || exit 0
[ -n "$FP" ] || exit 0
RAW="$FP"
FP="$(maude_lane_path "$RAW")"
# A lane by the path as given or as it resolves (a symlinked ~/.claude still counts).
maude_is_lane_file "$FP" || maude_is_lane_file "$RAW" || exit 0
[ -s "$FP" ] || exit 0
maude_python3_ok || exit 0

# The old text counts as kept when it appears in the new content after both are
# normalised the way an editor round-trip changes them: a UTF-8 BOM dropped, CRLF and
# lone CR read as LF, trailing newlines ignored (a model writing a file back through
# the Write tool sends LF and may drop the final newline). A content string the judge
# cannot encode (a lone surrogate) is refused, not waved through.
VERDICT="$(printf '%s' "$INPUT" | python3 -I -c '
import json, sys
try:
    new = json.loads(sys.stdin.read()).get("tool_input", {}).get("content", "")
    if not isinstance(new, str):
        print("open"); sys.exit(0)
    with open(sys.argv[1], encoding="utf-8", errors="surrogateescape", newline="") as f:
        old = f.read()
except SystemExit:
    raise
except Exception:
    print("open"); sys.exit(0)
def norm(s):
    if s.startswith("﻿"):
        s = s[1:]
    return s.replace("\r\n", "\n").replace("\r", "\n")
try:
    old_n = norm(old).rstrip("\n").encode("utf-8", "surrogateescape")
    new_n = norm(new).encode("utf-8", "surrogateescape")
except Exception:
    print("drop %d" % len(old.encode("utf-8", "surrogateescape"))); sys.exit(0)
print("keep" if old_n in new_n else "drop %d" % len(old.encode("utf-8", "surrogateescape")))
' "$FP" 2>/dev/null)"

case "$VERDICT" in
  drop\ *)
    printf "Maude: %s is a lane's history (%s bytes). A Write would replace it. Put the new dated entry on top with Edit, or Write it with the old text kept below.\n" \
      "${FP##*/}" "${VERDICT#drop }" >&2
    exit 42 ;;
esac
exit 0
