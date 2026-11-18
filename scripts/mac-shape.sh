#!/usr/bin/env bash
# mac-shape.sh — run the full suite in a macOS-shaped userland, HERE, before any public PR.
#
# The public CI matrix is the only macOS that ever runs these tests, and it only runs on a
# public PR. v0.33.0 went red there twice (PRs #80, #81) for things this box could have
# shown: a sed back-reference BSD sed lacks, a lock bound that counted tries instead of the
# clock, tests that assumed flock and `date +%N`. A local stand-in then caught two more
# before #82. This makes that stand-in a gate instead of a memory.
#
# The shape: a PATH farm of this box's tools with
#   - no flock               (macOS ships none: every lock takes the mkdir fallback)
#   - awk = original-awk     (the one-true-awk macOS ships: it drops bytes after a NUL)
#   - a slowed mkdir         (macOS forks cost far more; a loop that counts tries overshoots)
#   - TMPDIR with a trailing slash, as macOS exports it
#   - no timeout / gtimeout   (coreutils is not on a stock Mac)
#   - wc pads its counts      (BSD wc prints "       1", and an unquoted compare fails)
# The bash is this box's own. Maude needs bash 5.0 or newer everywhere (the floor at the top
# of hooks/scripts/_maude-common.sh), so a Mac that runs her has a current bash too; the
# 3.2 a stock Mac ships is refused, and tests/test-bash-floor.sh covers that refusal. Until
# 2026-11-17 this shape could put a bash 3.2 first on the PATH (MACSHAPE_BASH).
# What it still cannot give: BSD sed. The public macOS leg stays the final word on it.
#
# Usage: scripts/mac-shape.sh            full suite (make test) under the shape
#        scripts/mac-shape.sh --check    build the shape, prove each property, run nothing
#        scripts/mac-shape.sh -- <cmd>   run one command under the proven shape (a test file)
# Exit: the suite's status; 2 when the shape cannot be built (never a silent pass).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'mac-shape: %s\n' "$*" >&2; exit 2; }

MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  --) MODE=cmd; shift; [ $# -gt 0 ] || die "-- needs a command" ;;
  "") ;;
  *) die "unknown argument: $1 (usage: mac-shape.sh [--check | -- <cmd>])" ;;
esac

BSD_AWK="$(command -v original-awk)" || die "original-awk is not installed (apt install original-awk): it is the awk macOS ships, and without it this run is not macOS-shaped"
REAL_MKDIR="$(command -v mkdir)"; REAL_SLEEP="$(command -v sleep)"; REAL_WC="$(command -v wc)"; REAL_SED="$(command -v sed)"
BASE="${TMPDIR:-/tmp}"; BASE="${BASE%/}"
FARM="$(mktemp -d "$BASE/maude-macshape-bin.XXXXXX")" || die "cannot make the farm dir"
TMPD="$(mktemp -d "$BASE/maude-macshape-tmp.XXXXXX")" || { rmdir "$FARM"; die "cannot make the tmp dir"; }

# The farm is links to real binaries: removing a LINK never touches its target, writing
# through one would (a shim dir of symlinks once overwrote /usr/bin/sleep on this box).
# So the shims are written FIRST, as new files, and no name is ever written twice.
cleanup() {
  find "$FARM" -mindepth 1 -maxdepth 1 -type l -delete 2>/dev/null
  rm -f "$FARM/mkdir" "$FARM/wc"
  rmdir "$FARM" 2>/dev/null
  rm -rf "$TMPD"
}
trap cleanup EXIT

printf '#!/bin/sh\n%s 0.05\nexec %s "$@"\n' "$REAL_SLEEP" "$REAL_MKDIR" > "$FARM/mkdir"
chmod +x "$FARM/mkdir"
ln -s "$BSD_AWK" "$FARM/awk"
printf '#!/bin/sh\n%s "$@" | %s -E '"'"'s/^ *([0-9]+)/       \\1/'"'"'\n' "$REAL_WC" "$REAL_SED" > "$FARM/wc"
chmod +x "$FARM/wc"
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  [ -d "$d" ] || continue
  for b in "$d"/*; do
    n="${b##*/}"
    case "$n" in flock|mkdir|awk|wc|timeout|gtimeout) continue ;; esac   # portability-shim (names flock to keep it OUT)
    [ -e "$FARM/$n" ] || [ -L "$FARM/$n" ] || ln -s "$b" "$FARM/$n" 2>/dev/null
  done
done

# Prove the shape before trusting a green from it.
bad=0
if PATH="$FARM" command -v flock >/dev/null 2>&1; then echo "mac-shape: FAIL flock is on the farm PATH"; bad=1; else echo "mac-shape: ok   no flock"; fi   # portability-shim (names flock to keep it OUT)
printf '1\n' > "$TMPD/p"; printf 'a\000b\n' > "$TMPD/q"
nb="$(PATH="$FARM" LC_ALL=C awk 'NR == FNR { t[$1]; next } (FNR in t)' "$TMPD/p" "$TMPD/q" 2>/dev/null | wc -c | tr -d ' ')"
if [ "$nb" = 4 ]; then echo "mac-shape: FAIL awk carried a NUL (not the BSD awk)"; bad=1; else echo "mac-shape: ok   awk drops bytes after a NUL ($nb of 4)"; fi
now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }
t0="$(now_ms)"; PATH="$FARM" mkdir "$TMPD/m" 2>/dev/null; t1="$(now_ms)"
ms=$((t1 - t0))
if [ "$ms" -lt 40 ]; then echo "mac-shape: FAIL mkdir is not slowed (${ms} ms)"; bad=1; else echo "mac-shape: ok   mkdir slowed (${ms} ms)"; fi
echo "mac-shape: ok   TMPDIR=$TMPD/ (trailing slash)"
if PATH="$FARM" command -v timeout >/dev/null 2>&1; then echo "mac-shape: FAIL timeout is on the farm PATH"; bad=1; else echo "mac-shape: ok   no timeout"; fi   # portability-shim (proves timeout is OUT of the farm)
case "$(printf 'x\n' | PATH="$FARM" wc -l)" in ' '*) echo "mac-shape: ok   wc pads its count" ;; *) echo "mac-shape: FAIL wc does not pad"; bad=1 ;; esac
v="$(PATH="$FARM" bash -c 'echo "${BASH_VERSINFO[0]}"')"
case "$v" in ''|*[!0-9]*|[0-4]) echo "mac-shape: FAIL bash on PATH is major ${v:-unreadable}, below Maude's floor of 5"; bad=1 ;; *) echo "mac-shape: ok   bash on PATH is $(PATH="$FARM" bash -c 'echo "$BASH_VERSION"') (the floor is 5.0)" ;; esac
[ "$bad" -eq 0 ] || die "the shape is not macOS-shaped; refusing to report a run from it"

[ "$MODE" = check ] && { echo "mac-shape: --check: shape built and proven; nothing run"; exit 0; }
if [ "$MODE" = cmd ]; then
  ( cd "$ROOT" && TMPDIR="$TMPD/" PATH="$FARM" "$@" ); rc=$?
  echo "mac-shape: command exit $rc"; exit "$rc"
fi

echo "mac-shape: running make test under the shape (this takes a while)"
( cd "$ROOT" && TMPDIR="$TMPD/" PATH="$FARM" make test ); rc=$?
if [ "$rc" -eq 0 ]; then
  echo "mac-shape: GREEN"
else echo "mac-shape: RED (exit $rc)"; fi
exit "$rc"
