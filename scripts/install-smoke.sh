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

_ismk_base="${TMPDIR:-/tmp}"; _ismk_base="${_ismk_base%/}"; [ -n "$_ismk_base" ] || _ismk_base=/
STAGE="$(mktemp -d "$_ismk_base/maude-smoke.XXXXXX")"   # a template: macOS mktemp ignores TMPDIR without one
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
# The inner fleet's output is kept and, on a red, its FAIL lines and summary are printed:
# a red that says nothing is a launch stamp (the GitHub macOS runner went red here with
# every other suite green and nothing to read, 2026-09-13, PR #70).
if [ -f "$STAGE/tests/run.sh" ]; then
  if (cd "$STAGE" && MAUDE_INSTALL_SMOKE=1 bash tests/run.sh > "$STAGE/.fleet.log" 2>&1); then
    echo "  fleet    : PASS (from the archive)"
  else
    echo "  fleet    : FAIL — the shipped tree does not pass its own tests"; RC=1
    # FAIL lines when the fleet ran and reported; the tail when it died before reporting
    # (a missing file, a shell that would not start): either way the red is readable.
    if grep -qE '^FAIL  |^    FAIL  ' "$STAGE/.fleet.log" 2>/dev/null; then
      grep -E '^FAIL  |^    FAIL  |test files passed' "$STAGE/.fleet.log" 2>/dev/null | head -40 | sed 's/^/             /'
    else
      echo "             (no FAIL line: the archive's fleet did not report; last lines follow)"
      tail -30 "$STAGE/.fleet.log" 2>/dev/null | sed 's/^/             /'
    fi
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
