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

# Parse args: KEY and optional DURATION are positional.
# --john and --marker authorize a RED key, and since the 2026-07-30 yellow/red
# split this script refuses every red key outright (see the maude_is_red_key branch
# below). They were still being parsed into JOHN/MARKER variables that nothing ever
# read, under a comment claiming they authorized a red clear. Dead flags plus a
# comment asserting they work is the same defect as a refusal naming the wrong
# rule: the file lying about itself. The variables are gone.
# --marker still SKIPS its value, which is not cosmetic: without the skip, the link
# in `--marker <link>` stops being a flag value and lands in KEY or DURATION.
KEY=""
DURATION=""
_skip_next=0
for _a in "$@"; do
  if [ "$_skip_next" -eq 1 ]; then _skip_next=0; continue; fi
  case "$_a" in
    --marker) _skip_next=1 ;;   # RED-only; swallow its value so it can't become KEY
    -*)       ;;                # ignore other flags, --john included
    *)        if [ -z "$KEY" ]; then KEY="$_a"; elif [ -z "$DURATION" ]; then DURATION="$_a"; fi ;;
  esac
done
DURATION="${DURATION:-300}"

# ── Marker chain (PROVE) ─────────────────────────────────────────────────────
# A RED key is John's hand alone, and until 2026-07-30 the only discriminator was
# --john plus a provenance grep in maude-gate.sh for this script's own filename.
# An audit defeated that by copying the scripts dir and renaming the script, and
# the trace entry was indistinguishable from a real authorization. The structural
# problem: anything Claude can READ to verify, he can read to forge.
#
# maude_marker closes it with a one-time hash chain. Maude stores only the current
# HEAD; authorizing presents a preimage of it. Claude, holding the head, can
# compute every already-spent link and no future one.
#
# The rule: PROVISIONING IS ENABLING.
#   chain configured for this key -> a valid --marker link is REQUIRED
#   no chain configured           -> the --john path still works, and says loudly
#                                    that it is the weak one
#   MAUDE_MARKER_REQUIRED=1       -> no chain means no clear
# The fallback exists so John is never locked out of authorizing before he has
# generated a chain. It is loud on purpose: a silent weak path is one nobody closes.
# NO ENVIRONMENT OVERRIDES ON THIS PATH. A 2026-07-30 redteam forged a RED
# clearance four ways without editing a single file, purely by pointing this gate at
# things it never authenticated:
#   MAUDE_MARKER_STATE  -> a chain Claude minted himself           (accepted)
#   MAUDE_MARKER_STATE  -> nowhere, so "no chain" downgraded       (accepted)
#   CLAUDE_PLUGIN_ROOT  -> a fake maude_marker that exits 0        (accepted)
#   a shadowed jq on PATH reporting the chain as absent            (accepted)
# MAUDE_MARKER_STATE existed only so tests would not touch the real home. The
# testability seam was the bypass. Tests now drive HOME instead, and this path
# derives everything from HOME and from its own location on disk.
MARKER_DIR="$(maude_user_dir)"
MARKER_STATE="$MARKER_DIR/markers.json"
MARKER_LEDGER="$MARKER_DIR/marker-ledger.jsonl"
PLUGIN_ROOT="$(cd "$DIR/../.." && pwd)"

# 0 (true) if a chain is provisioned for $1.
maude_marker_chain_configured() {
  [ -f "$MARKER_STATE" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ "$(jq -r --arg k "$1" '.chains[$k].head // "null"' "$MARKER_STATE" 2>/dev/null)" != "null" ]
}

# 0 (true) if this house is marker-managed AT ALL. Attack B was "make the chain
# unreadable and the gate falls back to --john", so absence of a readable chain can
# no longer be treated as absence of enforcement. If the marker directory exists,
# somebody provisioned markers here, and a RED key needs one — an unreadable or
# missing state file is then a REFUSAL, not a downgrade.
maude_marker_house() {
  [ -d "$MARKER_DIR" ] && { [ -f "$MARKER_STATE" ] || [ -f "$MARKER_DIR/.marker-enforced" ]; }
}

# 0 (true) if $2 is a valid unspent link for key $1. CONSUMES it on success.
maude_marker_verify() {
  command -v python3 >/dev/null 2>&1 || return 1
  PYTHONPATH="$PLUGIN_ROOT" python3 -m maude_marker verify "$1" "$2" \
    --state "$MARKER_STATE" --ledger "$MARKER_LEDGER" >/dev/null 2>&1
}

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

# RED keys are NOT handled here (2026-07-30 split). They live in
# maude-clear-red.sh so a harness deny-rule can name that PATH instead of trying to
# match arguments — an argument-shaped rule was already walked past once by putting
# the key after a flag value. Keeping the yellow keys in this file means Claude can
# still self-clear git-push and friends without John's hand on every push.
if maude_is_red_key "$KEY"; then
  cat <<EOF >&2
Maude: "$KEY" is a RED key — John's hand only, and this script no longer clears
them at all. Claude must NOT self-clear a red key.

RED clears live in their own script so the permission layer can deny that one path:

  ! bash "$DIR/maude-clear-red.sh" "$KEY" --marker <link>

(or --john if no marker chain is provisioned for it yet)
EOF
  maude_log_trace "gate-clear-refused" "key=$KEY reason=red-wrong-script"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Maude: jq required for gate clearance — please install jq." >&2
  exit 1
fi

maude_ensure_self_dir
# Yellow tokens only — this script refused every red key above.
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
