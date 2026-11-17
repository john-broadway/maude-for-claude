#!/usr/bin/env bash
# CodeQL's scope is every Python package that ships (.github/codeql/codeql-config.yml).
# On 2026-11-16 the config listed three of the eight maude_* packages in the public tree:
# the gate's own judge (maude_shell), the Rolodex, the tape, the marker and the rules had
# never been scanned while the comment above the list said "the shipped Python". This
# pins the list to the tree: a shipped package missing from it is red, and so is a listed
# path that is not a package.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/.github/codeql/codeql-config.yml"

# The shipped packages: top-level maude_* dirs holding an __init__.py and not named in
# .publishignore (the internal set never reaches the public tree).
shipped() {
  local d n
  for d in "$ROOT"/maude_*/; do
    n="$(basename "$d")"
    [ -f "$d/__init__.py" ] || continue
    if [ -f "$ROOT/.publishignore" ] && grep -qxF -e "$n" -e "$n/" "$ROOT/.publishignore"; then continue; fi
    printf '%s\n' "$n"
  done | sort
}
# The listed paths: the "  - name" lines under paths:.
listed() {
  awk '/^paths:/ {p=1; next} p && /^[^ #]/ {p=0} p && /^  - / {sub(/^  - /, ""); print}' "$CFG" | sort
}

test_start "the CodeQL config exists"
assert_eq "$([ -f "$CFG" ] && echo yes)" "yes" "$CFG is there"

test_start "every shipped maude_* package is in CodeQL's paths"
MISSING="$(comm -23 <(shipped) <(listed) | tr '\n' ' ')"
assert_eq "$MISSING" "" "shipped packages CodeQL does not scan"

test_start "every CodeQL path is a shipped package"
EXTRA="$(comm -13 <(shipped) <(listed) | tr '\n' ' ')"
assert_eq "$EXTRA" "" "paths that name no shipped package"

test_start "the tree really has packages to compare (the walk is not empty)"
assert_ne "$(shipped | wc -l | tr -d ' ')" "0" "shipped package count"

print_summary
teardown_test_env
exit $FAILED
