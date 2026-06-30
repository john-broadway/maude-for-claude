#!/usr/bin/env bash
# check-satellites.sh — verify the off-repo surfaces (the satellites in PUBLISHING.md §B)
# carry the expected Maude version. The durable answer to "did a leaf fall stale?"
#
# Usage:  scripts/check-satellites.sh <version>      e.g.  scripts/check-satellites.sh 0.13.2
# Needs:  gh (authenticated), base64, grep.
# Exit:   0 if every satellite references vX; 1 if any is stale / unfetchable.
#
# Scope note: this checks that the NEW version is PRESENT on each surface (the common
# miss). It does not by itself prove an OLD version was removed — for that, grep each
# surface for the prior version too (PUBLISHING.md §6). Keep the list below in sync with
# the manifest in PUBLISHING.md §B when a surface is added or removed.

set +e
VER="${1:?usage: check-satellites.sh <version>   e.g. 0.13.2}"
VER="${VER#v}"   # accept 0.13.2 or v0.13.2
fail=0

check() {
  local repo="$1" path="$2"
  local body n
  body="$(gh api "repos/$repo/contents/$path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)"
  if [ -z "$body" ]; then
    printf '  ??    %s/%s — could not fetch\n' "$repo" "$path"; fail=1; return
  fi
  n="$(printf '%s' "$body" | grep -cF "v$VER")"
  if [ "$n" -ge 1 ]; then
    printf '  ok    %s/%s — %d ref(s) to v%s\n' "$repo" "$path" "$n" "$VER"
  else
    printf '  STALE %s/%s — no v%s found\n' "$repo" "$path" "$VER"; fail=1
  fi
}

printf 'Checking Maude satellites for v%s ...\n' "$VER"
check john-broadway/john-broadway              README.md
check john-broadway/john-broadway.github.io    index.html
check john-broadway/john-broadway.github.io    maude/index.html

if [ "$fail" = 0 ]; then
  printf 'All satellites carry v%s.\n' "$VER"
else
  printf 'Some satellites STALE — sweep them (PUBLISHING.md §B), then re-run.\n'
fi
exit "$fail"
