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
# What it cannot give: BSD sed and bash 3.2. The portability lint covers what it can of
# those; the public macOS leg stays the final word on them.
#
# Usage: scripts/mac-shape.sh            full suite (make test) under the shape
#        scripts/mac-shape.sh --check    build the shape, prove each property, run nothing
# Exit: the suite's status; 2 when the shape cannot be built (never a silent pass).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'mac-shape: %s\n' "$*" >&2; exit 2; }

MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) die "unknown argument: $1 (usage: mac-shape.sh [--check])" ;;
esac

BSD_AWK="$(command -v original-awk)" || die "original-awk is not installed (apt install original-awk): it is the awk macOS ships, and without it this run is not macOS-shaped"
REAL_MKDIR="$(command -v mkdir)"; REAL_SLEEP="$(command -v sleep)"
BASE="${TMPDIR:-/tmp}"; BASE="${BASE%/}"
FARM="$(mktemp -d "$BASE/maude-macshape-bin.XXXXXX")" || die "cannot make the farm dir"
TMPD="$(mktemp -d "$BASE/maude-macshape-tmp.XXXXXX")" || { rmdir "$FARM"; die "cannot make the tmp dir"; }

# The farm is links to real binaries: removing a LINK never touches its target, writing
# through one would (a shim dir of symlinks once overwrote /usr/bin/sleep on this box).
# So the shims are written FIRST, as new files, and no name is ever written twice.
cleanup() {
  find "$FARM" -mindepth 1 -maxdepth 1 -type l -delete 2>/dev/null
  rm -f "$FARM/mkdir"
  rmdir "$FARM" 2>/dev/null
  rm -rf "$TMPD"
}
trap cleanup EXIT

printf '#!/bin/sh\n%s 0.05\nexec %s "$@"\n' "$REAL_SLEEP" "$REAL_MKDIR" > "$FARM/mkdir"
chmod +x "$FARM/mkdir"
ln -s "$BSD_AWK" "$FARM/awk"
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  [ -d "$d" ] || continue
  for b in "$d"/*; do
    n="${b##*/}"
    case "$n" in flock|mkdir|awk) continue ;; esac   # portability-shim (names flock to keep it OUT)
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
[ "$bad" -eq 0 ] || die "the shape is not macOS-shaped; refusing to report a run from it"

[ "$MODE" = check ] && { echo "mac-shape: --check: shape built and proven; nothing run"; exit 0; }

echo "mac-shape: running make test under the shape (this takes a while)"
( cd "$ROOT" && TMPDIR="$TMPD/" PATH="$FARM" make test ); rc=$?
[ "$rc" -eq 0 ] && echo "mac-shape: GREEN" || echo "mac-shape: RED (exit $rc)"
exit "$rc"
