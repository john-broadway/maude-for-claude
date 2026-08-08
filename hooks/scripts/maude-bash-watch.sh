#!/usr/bin/env bash
# Maude bash-watch hook — fires before Bash. Spots dangerous patterns and surfaces
# a one-line "are you sure?" reminder. Never blocks.
# Reads tool input JSON from stdin.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Read stdin ONCE — the undo rail consumes it too, and jq would have drained it.
INPUT="$(cat 2>/dev/null)"

# UNDO (the sixth pillar) — best-effort snapshot of whatever this command is about to
# destroy. Called from here, not registered in hooks.json: registry entries are COLD
# until /reload-plugins; script edits are live on save.
printf '%s' "$INPUT" | bash "$DIR/maude-undo.sh" capture-bash 2>/dev/null

# REDTEAM rail — on a `git commit`, whisper if code changed with no adversarial pass since.
# NOTE: stderr is NOT suppressed here. The whisper IS stderr — a `2>/dev/null` on this line
# makes the rail run perfectly and deliver nothing, which is precisely how verify-watch
# fired 2084 times into a void before the 2026-07-30 audit found it. Not ignored:
# UNDELIVERED. The tests/test-redteam-watch.sh wiring rows pin this.
printf '%s' "$INPUT" | bash "$DIR/maude-redteam-watch.sh" check

CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
fi
[ -z "$CMD" ] && exit 0

# Whitespace-/option-tolerant building blocks (mirror maude-gate.sh) so ordinary
# forms — extra spaces, `git -C <dir> push`, reversed `rm -fr` — aren't missed.
GITW='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+'
RMRFW='rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*f[[:alnum:]]*|-[[:alnum:]]*f[[:alnum:]]*r[[:alnum:]]*)'

# Define the watch patterns. Order matters — most specific first.
# Each line: PATTERN ||| MESSAGE
PATTERNS=(
  "${RMRFW}[[:space:]]+/([[:space:]]|$) ||| \"rm -rf /\" — that wipes the system. STOP."
  "${RMRFW}[[:space:]]+\\*([[:space:]]|$) ||| \"rm -rf *\" — wide blast. Be specific."
  "${GITW}push.*--force ||| force-push. Sure? Have you checked branch protection?"
  "${GITW}push.*-f( |$) ||| force-push (-f). Sure?"
  'git[[:space:]]+reset[[:space:]]+--hard ||| hard reset. Have you stashed first?'
  'git checkout -- \. ||| checkout-discard. You will lose uncommitted work.'
  'git restore \. ||| restore-discard. You will lose uncommitted work.'
  'git clean -f ||| force-clean. You will lose untracked files.'
  '--no-verify ||| --no-verify skips hooks. Why?'
  '--no-gpg-sign ||| skipping signing. Was this asked for?'
  '> *~?/.claude/.*\.json ||| writing to a registry JSON. Have you backed up?'
  '> *~?/.claude/settings ||| editing settings.json. Use the update-config skill?'
  'pip uninstall ||| pip uninstall — make sure you mean it.'
  'DROP TABLE ||| SQL DROP TABLE. Have you backed up?'
  'sudo[[:space:]]+rm ||| sudo rm. Path right?'
  'curl .*\| *(bash|sh) ||| curl-pipe-shell. Inspect the script first.'
)

for entry in "${PATTERNS[@]}"; do
  PAT="${entry%% ||| *}"
  MSG="${entry##* ||| }"
  if printf '%s' "$CMD" | grep -qE -- "$PAT"; then
    printf 'Maude: %s\n' "$MSG" >&2
    # Also log to project-local trace so the audit shows the moment
    maude_log_trace "bash-watch" "flagged=${MSG}"
    break
  fi
done

exit 0
