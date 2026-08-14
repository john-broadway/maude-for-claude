#!/usr/bin/env bash
# Maude secret-scan hook (UserPromptSubmit).
#
# Scans the submitted prompt for credential-shaped strings (API tokens, keys).
# If one is found, it alerts Claude — and the user — that a secret is now in the
# transcript and must be revoked.
#
# IMPORTANT — what this is and isn't:
#   - It DETECTS a leaked secret fast and tells Claude to drive an immediate revoke.
#     It does NOT prevent the leak: by the time any hook runs, the text the user
#     typed is already submitted. Value = a much smaller exposure window.
#   - It catches secrets in normal prompts for sure. Whether it also fires for a
#     `!`-prefixed local bash line is environment-dependent (undocumented) — it is
#     strictly additive either way, and never blocks anything.
#   - It NEVER echoes the matched secret value (only the credential TYPE).
#
# Reads stdin (Claude Code passes hook input as JSON on stdin). Always exits 0.
# Born 2026-06-15 after a PyPI token leaked twice via `!` (the maude-gate hooks
# Claude's tool calls, not `!` lines — so this watches the input surface instead).

set +e

# Eye recursion guard: inert inside a blink subprocess. This is the one
# registered hook that doesn't source _maude-common.sh (deliberately
# standalone), so it can't inherit that file's guard — this inline copy is
# the surgical fix rather than pulling in the whole shared file.
[ -n "${MAUDE_EYE_BLINK:-}" ] && exit 0

# --- mode: which surface are we scanning? ---
# "prompt" (default, UserPromptSubmit) = what John typed.
# "tool-output" (PostToolUse)          = what a tool handed back.
#
# The second mode exists because the first could not see either real leak in this
# workspace: 2026-07-08 a Steam GSLT came back from `ps -ef`, and 2026-07-10/29
# another came back from a grep of a game-server config. Both went into the
# transcript through TOOL OUTPUT, which nothing watched, and one then sat unrotated
# for 22 days until an audit found it.
#
# HONEST CEILING: PostToolUse runs AFTER the tool. This cannot PREVENT a leak; the
# value is already in the transcript by the time we see it. It converts "nobody
# noticed for three weeks" into "you know this second." Do not describe it as
# prevention.
MODE="${1:-prompt}"

PROMPT=""
if command -v jq >/dev/null 2>&1; then
  INPUT="$(cat)"
  if [ "$MODE" = "tool-output" ]; then
    # Bash gives {stdout, stderr}; MCP tools give {content:[{text}]}; some tools
    # return a bare string. Take all of them, so a new tool shape fails LOUD
    # (scans something) rather than silently scanning nothing.
    PROMPT="$(printf '%s' "$INPUT" | jq -r '
      [ (.tool_response.stdout? // ""),
        (.tool_response.stderr? // ""),
        ((.tool_response.content? // []) | if type=="array" then map(.text? // "") | join("\n") else "" end),
        (if (.tool_response? | type) == "string" then .tool_response else "" end)
      ] | join("\n")' 2>/dev/null)"
  else
    PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // .message // ""' 2>/dev/null)"
  fi
fi
[ -z "$PROMPT" ] && exit 0

# --- credential shapes: label|ERE ---
# Mirrored in maude_tape/voice.py SECRET_PATTERNS (the voice corpus refuses these
# shapes at ingest). CHANGE ONE -> CHANGE THE OTHER.
# Each prefix carries enough trailing entropy to avoid matching prose mentions
# ("a pypi token", "ghp_-shaped"). Hyphens sit at the end of every char class.
PATTERNS=(
  "PyPI token|pypi-[A-Za-z0-9_-]{40,}"
  "GitHub token|gh[pousr]_[A-Za-z0-9]{36,}"
  "GitHub fine-grained PAT|github_pat_[A-Za-z0-9_]{60,}"
  "AWS access key|AKIA[0-9A-Z]{16}"
  "Slack token|xox[baprs]-[A-Za-z0-9-]{10,}"
  "Anthropic key|sk-ant-[A-Za-z0-9_-]{40,}"
  "OpenAI key|sk-(proj-)?[A-Za-z0-9_-]{40,}"
  "Google API key|AIza[A-Za-z0-9_-]{30,}"
  "private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  # Shapes taken from the two leaks that actually happened here, rather than from a
  # generic list. Each is anchored on its own key name so it cannot fire on prose.
  "Steam GSLT|(server_logon_token|sv_setsteamaccount)[^A-Za-z0-9]{1,4}[0-9A-Fa-f]{32}"
  "game-server RCON password|rcon_password[^A-Za-z0-9]{1,4}[^[:space:]]{8,}"
  "Proxmox API token|PVEAPIToken=[^[:space:]]{8,}"
  # Deliberately last and deliberately narrow: a 32-hex value sitting next to a word
  # that means secret. Catches the class without firing on every hash in a diff.
  "labelled secret value|(token|secret|passwo?rd|apikey|api_key)[\"'\`[:space:]]*[:=][\"'\`[:space:]]*[0-9A-Fa-f]{32}"
)

HITS=""
for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  if printf '%s' "$PROMPT" | grep -qE -- "$regex" 2>/dev/null; then
    HITS="${HITS}${label}, "
  fi
done

[ -z "$HITS" ] && exit 0
HITS="${HITS%, }"

# --- alert ---
# stdout on a UserPromptSubmit exit-0 hook is injected as context for Claude, so he
# reliably sees this and drives the revoke. Never print the secret value itself.
if [ "$MODE" = "tool-output" ]; then
  printf '%s\n' \
"[MAUDE SECRET GUARD] A tool just returned a credential-shaped string: ${HITS}." \
"This hook runs AFTER the tool, so the value is ALREADY IN THE TRANSCRIPT and cannot be recalled." \
"Treat it as COMPROMISED. Claude: do NOT echo, quote, or reuse it — refer to it by name only." \
"Tell John NOW, in this reply, which credential it is and that it needs ROTATING. Do not put the" \
"rotation on a list for later: the last one found this way sat unrotated for 22 days."
else
  printf '%s\n' \
"[MAUDE SECRET GUARD] A credential-shaped string was just submitted into this conversation: ${HITS}." \
"It is now in the transcript and must be treated as COMPROMISED. Claude: STOP — do not echo or reuse it." \
"Immediately tell the user to REVOKE it at the provider and re-issue if needed. If it came from a" \
"bang-prefixed (!) command, remind them: paste secrets only in a separate terminal, never into Claude's input."
fi

# Terse, visible stderr line in the maude house style.
if [ "$MODE" = "tool-output" ]; then
  printf 'Maude: a tool just printed a secret-shaped value (%s) — it is in the transcript. Rotate it tonight.\n' "$HITS" >&2
else
  printf 'Maude: secret-shaped string detected in your input (%s) — revoke it; never paste secrets here.\n' "$HITS" >&2
fi

exit 0
