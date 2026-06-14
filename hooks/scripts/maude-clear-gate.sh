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

# Ensure a valid JSON base so the merge can succeed even if care.json was missing,
# empty, or corrupt (shared helper — heals + records). Without this an empty/corrupt
# file made the merge silently fail while we still claimed the gate was cleared.
maude_care_ensure "$CARE"

MINS=$((DURATION / 60))
# Claim success ONLY if the token was actually written — never tell the user the gate
# is open when it isn't (a false clearance is exactly the assert-without-verify bug
# Maude's tripwire exists to catch). The failure direction stays fail-safe: no token
# written → the gate still blocks.
if maude_care_set "$CARE" --arg k "$KEY" --argjson until "$UNTIL" '.gate_cleared[$k] = {until: $until}'; then
  printf 'Maude: gate cleared for "%s" — %d minute(s). One matching command will pass, then the token clears.\n' "$KEY" "$MINS"
  maude_log_trace "gate-cleared" "key=$KEY duration=$DURATION"
else
  printf 'Maude: could NOT clear the gate for "%s" — care.json could not be written. The gate still stands.\n' "$KEY" >&2
  exit 1
fi

exit 0
