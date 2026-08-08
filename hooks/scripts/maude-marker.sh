#!/usr/bin/env bash
# maude-marker.sh — the marker CLI, with PYTHONPATH handled for you.
#
# WHY THIS WRAPPER EXISTS
# On 2026-07-30 Claude handed John this line to close the RED self-clear hole:
#
#     ! python3 -m maude_marker gen sole-copy-target 20
#
# and it failed with "No module named maude_marker", because -m only resolves when
# PYTHONPATH already points at the plugin root. Claude had run it exclusively from
# a shell where he had set that himself, so he verified his own convenience and not
# the user's invocation. Every user-facing marker line now goes through here.
#
# Usage (the leading ! matters for gen — it must run in YOUR shell so the links
# never enter Claude's context):
#
#     ! bash <this-script> gen <key> <count>
#     ! bash <this-script> verify <key> <link>
#     bash <this-script> status
#
# Everything is passed straight through to `python3 -m maude_marker`.

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# CLAUDE_PLUGIN_ROOT when a hook calls us; the repo root when John calls us by path.
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'maude-marker: python3 is required and was not found on PATH.\n' >&2
  exit 2
fi

if [ ! -d "$ROOT/maude_marker" ]; then
  printf 'maude-marker: cannot find the maude_marker package under %s\n' "$ROOT" >&2
  printf '              (set CLAUDE_PLUGIN_ROOT to the plugin root and retry)\n' >&2
  exit 2
fi

# PYTHONPATH prepended, not replaced: an ambient PYTHONPATH stays usable.
exec env PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m maude_marker "$@"
