#!/usr/bin/env bash
# Maude bash-watch hook — fires before Bash. Spots dangerous patterns and surfaces
# a one-line "are you sure?" reminder. Never blocks.
# Reads tool input JSON from stdin.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
fi
[ -z "$CMD" ] && exit 0

# Define the watch patterns. Order matters — most specific first.
# Each line: PATTERN ||| MESSAGE
PATTERNS=(
  'rm -rf / ||| "rm -rf /" — that wipes the system. STOP.'
  'rm -rf \* ||| "rm -rf *" — wide blast. Be specific.'
  'git push.*--force ||| force-push. Sure? Have you checked branch protection?'
  'git push.*-f( |$) ||| force-push (-f). Sure?'
  'git reset --hard ||| hard reset. Have you stashed first?'
  'git checkout -- \. ||| checkout-discard. You will lose uncommitted work.'
  'git restore \. ||| restore-discard. You will lose uncommitted work.'
  'git clean -f ||| force-clean. You will lose untracked files.'
  '--no-verify ||| --no-verify skips hooks. Why?'
  '--no-gpg-sign ||| skipping signing. Was this asked for?'
  '> *~?/.claude/.*\.json ||| writing to a registry JSON. Have you backed up?'
  '> *~?/.claude/settings ||| editing settings.json. Use the update-config skill?'
  'pip uninstall ||| pip uninstall — make sure you mean it.'
  'DROP TABLE ||| SQL DROP TABLE. Have you backed up?'
  'sudo rm ||| sudo rm. Path right?'
  'curl .*\| *(bash|sh) ||| curl-pipe-shell. Inspect the script first.'
)

for entry in "${PATTERNS[@]}"; do
  PAT="${entry%% ||| *}"
  MSG="${entry##* ||| }"
  if printf '%s' "$CMD" | grep -qE -- "$PAT"; then
    printf 'Maude: %s\n' "$MSG" >&2
    # Also log to today's daily so the trace shows the moment
    maude_log_to_today "- $(date +%H:%M) | watch | bash flagged: ${MSG}"
    break
  fi
done

exit 0
