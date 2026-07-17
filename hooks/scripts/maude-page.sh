#!/usr/bin/env bash
# UserPromptSubmit: page the prompt against the vault; emit hits as context.
#
# Reads stdin (Claude Code passes hook input as JSON on stdin) the same way
# every sibling UserPromptSubmit hook does — see maude-secret-scan.sh /
# maude-user-prompt-submit.sh: `jq -r '.prompt // .message // ""'`, empty when
# jq is absent (no dedicated maude_json_field helper exists; this is the
# house convention, reused as-is rather than adding a new parser).
#
# stdout on a UserPromptSubmit hook becomes additionalContext, so a hit here
# is what surfaces the relevant memory note to Claude for this turn.
#
# The prompt is piped to the CLI on stdin, NOT passed as an argv element —
# argv has a real ceiling (128KiB, E2BIG) and this hook fires on every
# prompt, so a large paste would silently kill paging. printf is a bash
# builtin, so this never touches argv/exec limits either.
#
# Degrades silently: missing python3, missing DB, empty prompt, or no hits ->
# exit 0, no output. Never blocks the prompt.
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v python3 >/dev/null 2>&1 || exit 0

DB="$(maude_project_dir)/.maude/plugin/vault.db"
[ -f "$DB" ] || exit 0

PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT="$(jq -r '.prompt // .message // ""' 2>/dev/null)"
fi
[ -z "$PROMPT" ] && exit 0

printf '%s' "$PROMPT" | PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -m maude_vault page \
  --db "$DB" --k 5 --log "$(maude_project_dir)/.maude/plugin/recall-log.jsonl" 2>/dev/null
exit 0
