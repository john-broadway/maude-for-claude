#!/usr/bin/env bash
# Maude RED gate-clear — John's hand only. The yellow keys live in
# maude-clear-gate.sh, which refuses every red key outright.
#
# WHY THIS FILE IS SEPARATE (2026-07-30)
# The deny-rule that stops Claude self-authorizing a RED key has to be PATH-based. An
# argument-shaped rule inherits the exact weakness a redteam exploited: it put the key
# after a flag VALUE and walked straight past a grep that expected it after flags.
# There are always more spellings. But denying the whole clear-gate would also block
# Claude clearing git-push — a YELLOW key he is meant to self-clear — so every push
# would need John's hand, a chore he would rightly tear the protection out over.
# So the dangerous capability lives at its own path. Deny THIS file; leave the yellow
# one alone. See .scratch/maude-marker-deny-rules-PROPOSAL.md.
#
# Writes a duration-scoped token to care-redclear.json that allows ONE matching
# irreversible command to pass maude-gate.sh.
#
# Usage: maude-clear-red.sh <red-key> [duration_seconds=300] [--marker <link>] [--john]
#
# A provisioned marker chain makes --marker the ONLY thing that opens the key;
# --john alone is then refused. Without a chain, --john still works and says out loud
# that it is the weak path.
#
# RED keys (must match maude_red_keys in _maude-common.sh):
#   rm-rf-root, rm-rf-glob, sudo-rm-rf, rm-rf-sole-copy, sole-copy-target,
#   public-publish, force-push, filter-repo, filter-branch, infra-destructive,
#   drop-table

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# Parse args: KEY and optional DURATION are positional; --john may appear
# anywhere and marks a human-hand authorization for a RED key.
KEY=""
DURATION=""
JOHN=0
MARKER=""
_want_marker=0
for _a in "$@"; do
  if [ "$_want_marker" -eq 1 ]; then MARKER="$_a"; _want_marker=0; continue; fi
  case "$_a" in
    --john)   JOHN=1 ;;
    --marker) _want_marker=1 ;;
    -*)       ;;   # ignore other flags
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
  maude_python3_ok || return 1
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

# RED keys are John's hand. Claude must NOT self-clear them; John authorizes by
# pasting the ! line below, which runs in his shell and skips the Bash tool-gate.
# SOFT rail (v0.10.0): this removes the reflexive self-clear, NOT a determined
# bypass — a direct care.json Write defeats it, because the gate is Bash-only and
# the token carries no provenance. The real, unbypassable layer is the harness
# deny-rules (see .scratch/maude-spine-deny.json). Saying this plainly is the
# point: a brake that claims to stop what it can't is the hype we are removing.
if ! maude_is_red_key "$KEY"; then
  printf 'Maude: "%s" is not a RED key. This script handles RED keys only.\n' "$KEY" >&2
  printf '       Use: bash "%s/maude-clear-gate.sh" %s\n' "$DIR" "$KEY" >&2
  exit 1
fi

if true; then
  if maude_marker_chain_configured "$KEY"; then
    # HARD path. A chain exists, so nothing but a link opens this key: not --john,
    # not a copied-and-renamed script, not a hand-written token.
    if [ -z "$MARKER" ]; then
      cat <<EOF >&2
Maude: "$KEY" is a RED key with a marker chain provisioned — it needs a one-time
marker link. --john alone will not open it, and neither will anything Claude can
compute from what is on this disk.

John, paste your next unspent link (the leading ! runs it as your hand):

  ! bash "$DIR/maude-clear-gate.sh" "$KEY" --marker <link>

Chain status:  bash "$DIR/maude-marker.sh" status
EOF
      maude_log_trace "gate-clear-refused" "key=$KEY reason=red-needs-marker"
      exit 1
    fi
    if ! maude_marker_verify "$KEY" "$MARKER"; then
      printf 'Maude: marker REFUSED for "%s" — not a valid unspent link. Nothing was cleared.\n' "$KEY" >&2
      printf 'Reason detail: bash "%s/maude-marker.sh" verify %s <link>\n' "$DIR" "$KEY" >&2
      maude_log_trace "gate-clear-refused" "key=$KEY reason=marker-invalid"
      exit 1
    fi
    maude_log_trace "gate-marker-accepted" "key=$KEY"
  else
    # SOFT path, unchanged from v0.10.0 except that it now names itself as weak.
    if maude_marker_house; then
      cat <<EOF >&2
Maude: "$KEY" is a RED key and this house is marker-managed, but no readable chain
was found for it. Refusing rather than falling back — an unreadable chain used to
downgrade to --john, which a redteam turned into a one-command forgery.

If you genuinely have no chain for this key, provision one:
  ! bash "$DIR/maude-marker.sh" gen $KEY 20
Chain status:  bash "$DIR/maude-marker.sh" status
EOF
      maude_log_trace "gate-clear-refused" "key=$KEY reason=marker-house-no-chain"
      exit 1
    fi
    if [ "${MAUDE_MARKER_REQUIRED:-}" = "1" ]; then
      cat <<EOF >&2
Maude: "$KEY" is a RED key, MAUDE_MARKER_REQUIRED=1, and no marker chain is
provisioned for it. Refusing — there is no way to prove this is your hand.

Generate one in YOUR shell so the links never enter Claude's context:

  ! bash "$DIR/maude-marker.sh" gen $KEY 20
EOF
      maude_log_trace "gate-clear-refused" "key=$KEY reason=marker-required-no-chain"
      exit 1
    fi
    if [ "$JOHN" -ne 1 ]; then
      cat <<EOF >&2
Maude: "$KEY" is a RED key — John's hand only. Claude must NOT self-clear it.

John, to authorize ONE matching command, paste this line (the leading ! runs it
as your hand, outside Claude's tool-gate):

  ! bash "$DIR/maude-clear-gate.sh" "$KEY" --john

(SOFT rail: removes the reflex, not a determined bypass. Real enforcement is the
harness deny-rules — see .scratch/maude-spine-deny.json.)

Stronger: provision a marker chain for this key and --john stops being enough.

  ! bash "$DIR/maude-marker.sh" gen $KEY 20
EOF
      maude_log_trace "gate-clear-refused" "key=$KEY reason=red-needs-john"
      exit 1
    fi
    printf 'Maude: WEAK PATH — no marker chain for "%s", so this cleared on --john alone,\n' "$KEY" >&2
    printf '       which a copied script can forge. Close it:\n         ! bash "%s/maude-marker.sh" gen %s 20\n' "$DIR" "$KEY" >&2
    maude_log_trace "gate-clear-weak-path" "key=$KEY reason=no-chain-john-only"
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Maude: jq required for gate clearance — please install jq." >&2
  exit 1
fi

maude_ensure_self_dir
# RED tokens go in the dedicated, harness-lockable care-redclear.json; yellow
# tokens stay in care.json (Claude may self-clear those). Reaching here for a red
# key means --john was supplied (the refusal above already returned otherwise).
# RED tokens always go to the dedicated, harness-lockable care-redclear.json.
CARE="$(maude_redclear_file)"
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
  # SAY WHERE THE TOKEN LANDED — the red twin of the line in maude-clear-gate.sh.
  # v0.30.1 added it to the yellow script and a lens found this one still silent,
  # with the failure line below still naming a file this script never writes.
  # A writer that will not name its file cannot be checked against its reader.
  printf '       token: %s\n' "$CARE"
  maude_log_trace "gate-cleared" "key=$KEY duration=$DURATION"
else
  printf 'Maude: could NOT clear the gate for "%s" — %s could not be written. The gate still stands.\n' "$KEY" "$CARE" >&2
  exit 1
fi

exit 0
