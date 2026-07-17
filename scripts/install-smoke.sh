#!/usr/bin/env bash
# install-smoke.sh [repo] — the prove-it-real gate: run her like an end-user.
#
# A stranger doesn't get the working tree; they get the COMMIT. This stages a
# git-archive of HEAD (uncommitted files are invisible here, on purpose — a
# clean working tree is not a clean commit) and proves the shipped shape:
#
#   1. the archive validates as a plugin (claude plugin validate, when the
#      CLI is present — the same check the marketplace review pipeline runs)
#   2. the archive passes its OWN test fleet (the shipped tree is complete
#      and self-contained — a missing committed file fails here, loudly)
#   3. she greets from a pristine HOME (first-run experience of a stranger)
#
# Exit 0 only if every stage holds. Wired into release.sh's gate; runnable
# any time: make smoke
set -uo pipefail

REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO" || { echo "install-smoke: cannot cd to $REPO" >&2; exit 1; }
git rev-parse HEAD >/dev/null 2>&1 || { echo "install-smoke: not a git repo with a HEAD" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "== install-smoke: staging git-archive of HEAD ($(git rev-parse --short HEAD)) =="
git archive HEAD | tar -x -C "$STAGE" || { echo "install-smoke: archive failed" >&2; exit 1; }

RC=0

# ── Stage 1: plugin validation (the review pipeline's own check) ──────────
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$STAGE" >/dev/null 2>&1; then
    echo "  validate : PASS"
  else
    echo "  validate : FAIL — claude plugin validate rejected the archive"; RC=1
  fi
else
  echo "  validate : SKIP (claude CLI not on this box — release boxes must not skip)"
fi

# ── Stage 2: the archive's own fleet (self-containment) ──────────────────
# MAUDE_INSTALL_SMOKE=1 makes the smoke's own test self-skip inside this run —
# same recursion-guard pattern as the eye's blink.
if [ -f "$STAGE/tests/run.sh" ]; then
  if (cd "$STAGE" && MAUDE_INSTALL_SMOKE=1 bash tests/run.sh >/dev/null 2>&1); then
    echo "  fleet    : PASS (from the archive)"
  else
    echo "  fleet    : FAIL — the shipped tree does not pass its own tests"; RC=1
  fi
else
  echo "  fleet    : FAIL — no tests/run.sh in the archive"; RC=1
fi

# ── Stage 3: pristine first-run greet (the stranger's first session) ─────
PH="$STAGE/.pristine-home"; PP="$STAGE/.pristine-proj"
mkdir -p "$PH" "$PP"
GREET="$(printf '{}' | HOME="$PH" CLAUDE_PROJECT_DIR="$PP" \
  bash "$STAGE/hooks/scripts/maude-session-start.sh" 2>/dev/null)"
case "$GREET" in
  *"Maude here."*) echo "  greet    : PASS (she lands on a pristine home)" ;;
  *) echo "  greet    : FAIL — no greeting from the shipped shape"; RC=1 ;;
esac

echo "----------------------------------------"
if [ "$RC" -eq 0 ]; then
  echo "install-smoke: SMOKE GREEN — the commit ships as a working plugin."
else
  echo "install-smoke: SMOKE RED — fix before any release; the working tree may be lying."
fi
exit "$RC"
