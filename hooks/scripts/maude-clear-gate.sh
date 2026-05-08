#!/usr/bin/env bash
# Maude gate-clear helper — writes a 5-minute (or specified duration) token
# to care.json that allows ONE matching irreversible command to pass the gate.
#
# Called by /maude:conscience after the user confirms the action is intentional.
#
# Usage: maude-clear-gate.sh <key> [duration_seconds=300]
#
# Known keys (must match maude-gate.sh's PATTERNS):
#   force-push, git-push, no-verify, no-gpg-sign, reset-hard, filter-repo,
#   filter-branch, commit-amend, rm-rf-root, rm-rf-glob, sudo-rm-rf, drop-table

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

KEY="${1:-}"
DURATION="${2:-300}"

if [ -z "$KEY" ]; then
  cat <<EOF >&2
Usage: maude-clear-gate.sh <key> [duration_seconds]

Known keys:
  force-push       (git push --force / -f / --force-with-lease)
  git-push         (any git push)
  no-verify        (--no-verify)
  no-gpg-sign      (--no-gpg-sign)
  reset-hard       (git reset --hard)
  filter-repo      (git filter-repo)
  filter-branch    (git filter-branch)
  commit-amend     (git commit --amend)
  rm-rf-root       (rm -rf /)
  rm-rf-glob       (rm -rf *)
  sudo-rm-rf       (sudo rm -rf)
  drop-table       (DROP TABLE)

Default duration: 300 seconds (5 minutes). Token clears on first matching command.
EOF
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Maude: jq required for gate clearance — please install jq." >&2
  exit 1
fi

maude_ensure_self_dir
CARE="$(maude_self_dir)/care.json"
NOW=$(date +%s)
UNTIL=$((NOW + DURATION))

# Initialize care.json if missing
[ -f "$CARE" ] || printf '{}\n' > "$CARE"

TMP="$(mktemp 2>/dev/null)" || exit 1
jq --arg k "$KEY" --argjson until "$UNTIL" '.gate_cleared[$k] = {until: $until}' "$CARE" > "$TMP" 2>/dev/null && mv "$TMP" "$CARE"

MINS=$((DURATION / 60))
printf 'Maude: gate cleared for "%s" — %d minute(s). One matching command will pass, then the token clears.\n' "$KEY" "$MINS"
maude_log_trace "gate-cleared" "key=$KEY duration=$DURATION"

exit 0
