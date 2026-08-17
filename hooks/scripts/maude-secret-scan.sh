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
  # Added 2026-08-16 after a lens beat the table above with 14 of 26 constructed shapes.
  # Anchored on structure (a prefix, a scheme, a header name) so prose about credentials
  # never fires. Mirrored in maude_tape/voice.py — the two are held together by
  # tests/tape/test_lens_2026_08_16.py::test_python_guard_and_shell_hook_agree.
  "JWT|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
  "bearer token|bearer[[:space:]]+[A-Za-z0-9_.=-]{20,}"
  "credentials in a URI|[a-z][a-z0-9+.-]{0,32}://[^[:space:]:@/]{1,256}:[^[:space:]:@/]{8,256}@"
  "Stripe key|[sr]k_(live|test)_[A-Za-z0-9]{16,}"
  "SendGrid key|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"
  "DigitalOcean token|dop_v1_[A-Fa-f0-9]{40,}"
  "npm token|npm_[A-Za-z0-9]{36,}"
  "AWS secret access key|aws_secret_access_key[^A-Za-z0-9]{1,4}[A-Za-z0-9/+=]{40}"
  # Deliberately last and deliberately narrow: a 32-hex value next to a word that means
  # secret. Measured 2026-08-16: widening the value class to any 16+ non-space run fired
  # on 20 rows of pasted CODE in the real corpus. A guard that cries wolf on his paste
  # habit is the one he learns to ignore. The demonstrated gap was case, closed by -i.
  "labelled secret value|(token|secret|passwo?rd|apikey|api[_-]?key)[\"'\`[:space:]]*[:=][\"'\`[:space:]]*[0-9A-Fa-f]{32}"
)

# Rich-text pastes (Word, Notion, Slack, a PDF) substitute Unicode spaces for plain ones.
# GNU grep's [:space:] does NOT treat U+00A0 as whitespace while python's \s does, so
# `password:<NBSP><value>` was refused by the tape's guard and waved through by THIS one —
# the only surface that can warn him while the paste is still fresh. Normalising the input
# closes the class instead of one character, and keeps both pattern tables identical.
# printf octal (not \x) so BSD/macOS reads it the same as GNU; parameter substitution
# rather than sed for the same reason. Mirrored in maude_tape/voice.py _UNICODE_SPACES.
for _oct in '\302\240' '\341\232\200' '\342\200\200' '\342\200\201' '\342\200\202' \
            '\342\200\203' '\342\200\204' '\342\200\205' '\342\200\206' '\342\200\207' \
            '\342\200\210' '\342\200\211' '\342\200\212' '\342\200\257' '\342\201\237' \
            '\343\200\200'; do
  _ch=$(printf "$_oct")
  PROMPT="${PROMPT//$_ch/ }"
done

# DELETE the invisibles, do not space them. Every pattern needs a contiguous run, so one
# zero-width character between each letter of a token defeats the whole table while the
# credential stays visually intact. The python side got this and this one did not — and
# THIS is the surface that can warn him in real time, and the only one that watches tool
# output, which is how both of the real leaks in this house actually arrived.
for _oct in '\342\200\213' '\342\200\214' '\342\200\215' '\342\201\240' \
            '\357\273\277' '\342\200\252' '\342\200\253' '\342\200\254' \
            '\342\200\255' '\342\200\256' '\342\201\246' '\342\201\247' \
            '\342\201\250' '\342\201\251' '\302\255'; do
  _ch=$(printf "$_oct")
  PROMPT="${PROMPT//$_ch/}"
done

HITS=""
for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  # -i: the labelled-secret catch-all was case-sensitive, so PASSWORD=<value> walked
  # through while password:<value> was caught. Its python twin now compiles with re.I.
  if printf '%s' "$PROMPT" | grep -qEi -- "$regex" 2>/dev/null; then
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
