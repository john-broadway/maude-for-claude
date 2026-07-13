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

# --- read the submitted prompt (match the house convention used by sibling hooks) ---
PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT="$(jq -r '.prompt // .message // ""' 2>/dev/null)"
fi
[ -z "$PROMPT" ] && exit 0

# --- credential shapes: label|ERE ---
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
printf '%s\n' \
"[MAUDE SECRET GUARD] A credential-shaped string was just submitted into this conversation: ${HITS}." \
"It is now in the transcript and must be treated as COMPROMISED. Claude: STOP — do not echo or reuse it." \
"Immediately tell the user to REVOKE it at the provider and re-issue if needed. If it came from a" \
"bang-prefixed (!) command, remind them: paste secrets only in a separate terminal, never into Claude's input."

# Terse, visible stderr line in the maude house style.
printf 'Maude: secret-shaped string detected in your input (%s) — revoke it; never paste secrets here.\n' "$HITS" >&2

exit 0
