#!/usr/bin/env bash
# tests/test-mac-shape.sh — the macOS stand-in builds the shape it claims, proves it before
# trusting a run from it, refuses when it cannot, and leaves nothing behind.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"
MS="$ROOT/scripts/mac-shape.sh"

if ! command -v original-awk >/dev/null 2>&1; then
  # macOS itself and any box without the BSD awk: the stand-in is a Linux tool.
  printf '  skip  original-awk not installed: the macOS stand-in cannot be built here\n'
  test_start "skip recorded"; _pass
  print_summary; exit "$FAILED"
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/maude-ms-test.XXXXXX")"
count_farms() { ls -d "$T"/maude-macshape-* 2>/dev/null | wc -l | tr -d ' '; }

test_start "--check builds the shape and proves every property"
OUT="$(TMPDIR="$T/" bash "$MS" --check 2>&1)"; RC=$?
assert_exit "$RC" "0" "check passes"
assert_contains "$OUT" "ok   no flock" "no flock"
assert_contains "$OUT" "ok   awk drops bytes after a NUL" "BSD awk"
assert_contains "$OUT" "ok   mkdir slowed" "slow mkdir"
assert_contains "$OUT" "nothing run" "check runs no suite"

test_start "nothing is left behind (farm and tmp removed)"
assert_eq "$(count_farms)" "0" "no maude-macshape dirs left"

test_start "an unknown argument is refused, not run"
TMPDIR="$T/" bash "$MS" --bogus >/dev/null 2>&1; assert_exit "$?" "2" "refused"

test_start "control: an awk that carries a NUL is refused as not macOS-shaped"
FAKE="$(mktemp -d "$T/fake.XXXXXX")"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v mawk || command -v gawk || echo /usr/bin/awk)" > "$FAKE/original-awk"; chmod +x "$FAKE/original-awk"
OUT="$(PATH="$FAKE:$PATH" TMPDIR="$T/" bash "$MS" --check 2>&1)"; RC=$?
assert_exit "$RC" "2" "refused"
assert_contains "$OUT" "FAIL awk carried a NUL" "names the property that failed"
assert_eq "$(count_farms)" "0" "and still cleans up"

test_start "without original-awk it refuses and names the package"
NOAWK="$(mktemp -d "$T/noawk.XXXXXX")"
for b in bash sh mktemp mkdir sleep dirname rmdir rm find printf; do ln -s "$(command -v "$b")" "$NOAWK/$b" 2>/dev/null; done
OUT="$(PATH="$NOAWK" TMPDIR="$T/" "$(command -v bash)" "$MS" --check 2>&1)"; RC=$?
assert_exit "$RC" "2" "refused"
assert_contains "$OUT" "apt install original-awk" "names the fix"

find "$NOAWK" -mindepth 1 -maxdepth 1 -type l -delete; rmdir "$NOAWK"
rm -rf "$FAKE" "$T"
print_summary
exit "$FAILED"
