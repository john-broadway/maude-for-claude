#!/usr/bin/env bash
# Maude self-check (SessionStart) — is the INSTALLED Maude what her source built?
#
# Born 2026-08-08: main carried 20 commits of finished work for TEN DAYS while
# the installed cache stayed at the prior release. The directory-marketplace
# updater keys on the VERSION, honest semver had held the number still, so
# `plugin update` said "already at latest" with 13 files differing — and every
# session ran the stale scripts believing itself current. She watches the whole
# house for drift; the blind spot was her own closet. This check runs where the
# blind spot was, at the moment it matters: wake.
#
# Two findings, two messages:
#   versions DIFFER          → the update was never applied: run plugin update.
#   versions EQUAL, files differ → the 10-day trap itself: the updater will
#                              NEVER deliver this — bump the version on main.
#
# Degrades SILENT (exit 0, no output) when there is nothing to compare: no jq,
# no marketplace record, no source dir on this machine, or running FROM the
# source (a dev checkout is its own source of truth). A whisper that cannot be
# computed must say nothing, not guess. Env seams (tests): MAUDE_SOURCE_DIR
# overrides discovery; MAUDE_SELF_CHECK=off kills it.
set +e

# Eye recursion guard: inert inside a blink subprocess. Standalone hook
# (doesn't source _maude-common.sh), so the guard is this inline copy —
# same pattern as maude-secret-scan.sh. Caught by the completeness test
# from the ARCHIVE: the working-tree run had masked it behind the
# dev-checkout short-circuit (ROOT == SRC → silent for the wrong reason).
[ -n "${MAUDE_EYE_BLINK:-}" ] && exit 0

[ "${MAUDE_SELF_CHECK:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"

SRC="${MAUDE_SOURCE_DIR:-}"
if [ -z "$SRC" ]; then
  KM="$HOME/.claude/plugins/known_marketplaces.json"
  [ -f "$KM" ] && SRC="$(jq -r '.maude.source.path // empty' "$KM" 2>/dev/null)"
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || exit 0
# Same dir (or same resolved dir) = dev checkout; nothing to compare.
[ "$(cd "$SRC" 2>/dev/null && pwd -P)" = "$(cd "$ROOT" 2>/dev/null && pwd -P)" ] && exit 0

IV="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
SV="$(jq -r '.version // empty' "$SRC/.claude-plugin/plugin.json" 2>/dev/null)"
[ -n "$IV" ] && [ -n "$SV" ] || exit 0

if [ "$IV" != "$SV" ]; then
  # The qualified name, not the bare one: `claude plugin update maude` fails
  # with "not found" on the canonical install (marketplace and plugin are both
  # named maude, and update wants name@marketplace). A whisper must hand the
  # user a command that RUNS — verified 2026-08-08 by the bare form failing
  # live, the same lesson the maude-marker wrapper carries.
  printf 'Maude: my installed self is v%s but my source carries v%s — an update is waiting. Run `claude plugin update maude@maude` and restart, so the house runs what was built.\n' "$IV" "$SV"
  exit 0
fi

# Versions equal — the trap is version-KEYED drift: same number, different files.
# Excludes are state/junk, not shipped surface. Bounded by the hook timeout.
N="$(diff -rq "$ROOT" "$SRC" \
      -x .git -x .maude -x '.claude' -x '__pycache__' -x '*.db' -x '.pytest_cache' \
      2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${N:-0}" -gt 0 ] 2>/dev/null; then
  printf 'Maude: installed v%s MATCHES the source version, but %s file(s) differ — the updater keys on the version, so this will NEVER auto-deliver. Bump the version on main (classify, then bump) or sync deliberately. Merged is not installed.\n' "$IV" "$N"
fi
exit 0
