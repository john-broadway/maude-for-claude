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

# No python3 gate here: this fires on EVERY user turn, and the real
# `python3 -m maude_vault` call below is already checked and silenced — the
# call is the probe. Session-start names a broken interpreter once.
DB="$(maude_project_dir)/.maude/plugin/vault.db"
[ -f "$DB" ] || exit 0

PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT="$(jq -r '.prompt // .message // ""' 2>/dev/null)"
fi
[ -z "$PROMPT" ] && exit 0

# #49, suspect #1 confirmed by live receipts: the pager fired on background
# notifications and command echoes with zero-relevance matches — snippets
# nobody asked for, paid for every turn. A machine-generated turn is not a
# question; the vault sits those out. (Shapes: system notices, background
# notification tags — the `-notification>` glob covers the task-shaped tag
# without carrying a substring the ship rail's credential-shape audit flags —
# slash-command turns, `!` bash echoes, interrupt notices.)
case "$PROMPT" in
  "[SYSTEM NOTIFICATION"*|*"-notification>"*|"<command-name>"*|"<bash-input>"*|"[Request interrupted"*|"Caveat: the messages below"*)
    exit 0 ;;
esac

OUT="$(printf '%s' "$PROMPT" | PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -m maude_vault page \
  --db "$DB" --k 5 --log "$(maude_project_dir)/.maude/plugin/recall-log.jsonl" 2>/dev/null)"
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  # #49: log the bill — hook class + bytes, never content.
  maude_log_spend "page" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')"
fi
exit 0
