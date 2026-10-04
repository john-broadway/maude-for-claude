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

PROMPT="" INPUT=""
if command -v jq >/dev/null 2>&1; then
  INPUT="$(cat)"
  PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // .message // ""' 2>/dev/null)"
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

# Quiet by default (2026-10-04, John: "quiet the maude recall lines"): at most two notes
# (MAUDE_PAGE_K, a whole number 1-99, else 2), and a note already shown this session is not
# shown again. The session's shown names live in one file per session id, the id reduced to
# [A-Za-z0-9_-] and 64 characters so it names no path and fits a file name; other sessions'
# files a week old are swept after paging. No session id: no once-per-session memory.
K="${MAUDE_PAGE_K:-2}"
K="${K#"${K%%[!0]*}"}"   # leading zeros off: `00` is 0, not a count
# 1-99, else 2 (a 20-digit K overflowed sqlite). The digits are spelled out: in a UTF-8 locale
# `[0-9]` also matches `٠` and `０`, which python reads as 0 (third lens).
case "$K" in ''|*[!0123456789]*|???*) K=2 ;; esac
SEEN_ARGS=() SEEN_DIR=""
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | cut -c1-64)"
if [ -n "$SID" ]; then
  SEEN_DIR="$(maude_project_dir)/.maude/plugin/recall-seen"
  mkdir -p "$SEEN_DIR" 2>/dev/null && SEEN_ARGS=(--seen "$SEEN_DIR/$SID")
fi
OUT="$(printf '%s' "$PROMPT" | PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -m maude_vault page \
  --db "$DB" --k "$K" --mem "$(maude_mem_dir)" "${SEEN_ARGS[@]}" \
  --log "$(maude_project_dir)/.maude/plugin/recall-log.jsonl" 2>/dev/null)"
[ -n "$SEEN_DIR" ] && find "$SEEN_DIR" -maxdepth 1 -type f -mtime +7 ! -name "$SID" -delete 2>/dev/null
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  # #49: log the bill — hook class + bytes, never content.
  maude_log_spend "page" "$(printf '%s' "$OUT" | wc -c | tr -d ' ')"
fi
exit 0
