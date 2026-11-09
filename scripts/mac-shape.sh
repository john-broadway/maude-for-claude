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
#   - bash 3.2 first on PATH, when MACSHAPE_BASH names one (macOS ships 3.2: no
#     EPOCHREALTIME, no `local -`, no ${x@Q}); without it the run says so on every line
#     that matters and the shape is reported as PARTIAL, never as macOS-shaped
#   - no timeout / gtimeout   (coreutils is not on a stock Mac)
#   - wc pads its counts      (BSD wc prints "       1", and an unquoted compare fails)
# v0.36.0 went red on the public macOS leg (PR #90, 2026-11-08) on all three while this
# shape was green: it had no bash 3.2 to give. Build one once (GNU bash-3.2.57, CC=gcc,
# YACC="bison -y", -fcommon -std=gnu89) and point MACSHAPE_BASH at it.
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
BASH32="${MACSHAPE_BASH:-}"
if [ -n "$BASH32" ]; then
  [ -x "$BASH32" ] || die "MACSHAPE_BASH=$BASH32 is not an executable"
  case "$("$BASH32" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" in 3.2) ;; *) die "MACSHAPE_BASH=$BASH32 is not bash 3.2" ;; esac
fi
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
[ -z "$BASH32" ] || ln -s "$BASH32" "$FARM/bash"
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
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
t0="$(now_ms)"; PATH="$FARM" mkdir "$TMPD/m" 2>/dev/null; t1="$(now_ms)"
ms=$((t1 - t0))
if [ "$ms" -lt 40 ]; then echo "mac-shape: FAIL mkdir is not slowed (${ms} ms)"; bad=1; else echo "mac-shape: ok   mkdir slowed (${ms} ms)"; fi
echo "mac-shape: ok   TMPDIR=$TMPD/ (trailing slash)"
if PATH="$FARM" command -v timeout >/dev/null 2>&1; then echo "mac-shape: FAIL timeout is on the farm PATH"; bad=1; else echo "mac-shape: ok   no timeout"; fi   # portability-shim (proves timeout is OUT of the farm)
case "$(printf 'x\n' | PATH="$FARM" wc -l)" in ' '*) echo "mac-shape: ok   wc pads its count" ;; *) echo "mac-shape: FAIL wc does not pad"; bad=1 ;; esac
PARTIAL=""
if [ -n "$BASH32" ]; then
  v="$(PATH="$FARM" bash -c 'echo "$BASH_VERSION ${EPOCHREALTIME:-no-epoch}"')"
  case "$v" in 3.2*no-epoch) echo "mac-shape: ok   bash on PATH is $v" ;; *) echo "mac-shape: FAIL bash on PATH is $v"; bad=1 ;; esac
else
  PARTIAL=1; echo "mac-shape: PARTIAL bash on PATH is $BASH_VERSION, not 3.2 (set MACSHAPE_BASH): this run is NOT macOS-shaped for bash"
fi
[ "$bad" -eq 0 ] || die "the shape is not macOS-shaped; refusing to report a run from it"

[ "$MODE" = check ] && { echo "mac-shape: --check: shape built and proven; nothing run"; exit 0; }
if [ "$MODE" = cmd ]; then
  ( cd "$ROOT" && TMPDIR="$TMPD/" PATH="$FARM" "$@" ); rc=$?
  echo "mac-shape: command exit $rc${PARTIAL:+ (PARTIAL: no bash 3.2)}"; exit "$rc"
fi

echo "mac-shape: running make test under the shape (this takes a while)"
( cd "$ROOT" && TMPDIR="$TMPD/" PATH="$FARM" make test ); rc=$?
if [ "$rc" -eq 0 ]; then
  if [ -n "$PARTIAL" ]; then echo "mac-shape: GREEN, PARTIAL (no bash 3.2: the public macOS leg can still go red)"; else echo "mac-shape: GREEN"; fi
else echo "mac-shape: RED (exit $rc)"; fi
exit "$rc"
