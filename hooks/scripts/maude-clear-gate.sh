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
#   filter-branch, commit-amend, rm-rf-root, rm-rf-glob, sudo-rm-rf,
#   rm-rf-sole-copy, public-publish, infra-destructive, drop-table,
#   run-governor

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Parse args: KEY and optional DURATION are positional; --john may appear
# anywhere and marks a human-hand authorization for a RED key.
KEY=""
DURATION=""
JOHN=0
for _a in "$@"; do
  case "$_a" in
    --john) JOHN=1 ;;
    -*)     ;;   # ignore other flags
    *)      if [ -z "$KEY" ]; then KEY="$_a"; elif [ -z "$DURATION" ]; then DURATION="$_a"; fi ;;
  esac
done
DURATION="${DURATION:-300}"

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
  rm-rf-sole-copy  (rm -rf of workspace / repo root / .git / .credentials / ~/.claude)
  public-publish   (gh release / twine upload / uv publish / hf upload)
  infra-destructive (destructive MCP op on a production target, per gate-config)
  drop-table       (DROP TABLE)
  run-governor     (run-length governor hard-pause — fresh budget)

Default duration: 300 seconds (5 minutes). Token clears on first matching command.
EOF
  exit 1
fi

# Unknown keys are refused — guards against typos AND keeps the synthetic
# 'red-self-clear' backstop key (used by maude-gate.sh) from being cleared here.
if ! maude_is_known_key "$KEY"; then
  printf 'Maude: "%s" is not a known gate key — refusing. Run with no args for the list.\n' "$KEY" >&2
  exit 1
fi

# RED keys are John's hand. Claude must NOT self-clear them; John authorizes by
# pasting the ! line below, which runs in his shell and skips the Bash tool-gate.
# SOFT rail (v0.10.0): this removes the reflexive self-clear, NOT a determined
# bypass — a direct care.json Write defeats it, because the gate is Bash-only and
# the token carries no provenance. The real, unbypassable layer is the harness
# deny-rules (see .scratch/maude-spine-deny.json). Saying this plainly is the
# point: a brake that claims to stop what it can't is the hype we are removing.
if maude_is_red_key "$KEY" && [ "$JOHN" -ne 1 ]; then
  cat <<EOF >&2
Maude: "$KEY" is a RED key — John's hand only. Claude must NOT self-clear it.

John, to authorize ONE matching command, paste this line (the leading ! runs it
as your hand, outside Claude's tool-gate):

  ! bash "$DIR/maude-clear-gate.sh" "$KEY" --john

(SOFT rail: removes the reflex, not a determined bypass. Real enforcement is the
harness deny-rules — see .scratch/maude-spine-deny.json.)
EOF
  maude_log_trace "gate-clear-refused" "key=$KEY reason=red-needs-john"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Maude: jq required for gate clearance — please install jq." >&2
  exit 1
fi

maude_ensure_self_dir
# RED tokens go in the dedicated, harness-lockable care-redclear.json; yellow
# tokens stay in care.json (Claude may self-clear those). Reaching here for a red
# key means --john was supplied (the refusal above already returned otherwise).
if maude_is_red_key "$KEY"; then
  CARE="$(maude_redclear_file)"
else
  CARE="$(maude_self_dir)/care.json"
fi
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
