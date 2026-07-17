#!/usr/bin/env bash
# release-notes.sh <version> [changelog] — print one version's CHANGELOG entry.
#
# The Release page is a rendering of the CHANGELOG, never new prose (#38):
# this extracts the body of `## v<version> …` up to the next version heading,
# with the `---` separators stripped, so `gh release create` can consume it
# and the two surfaces can never drift. Fails loud (exit 1) if the version
# has no entry — a Release page with an empty body is drift wearing a bow.
#
# Usage: scripts/release-notes.sh 0.20.0 [CHANGELOG.md]

set -uo pipefail

V="${1:-}"
[ -n "$V" ] || { printf 'usage: release-notes.sh <version> [changelog]\n' >&2; exit 2; }
CL="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"
[ -f "$CL" ] || { printf 'release-notes: no changelog at %s\n' "$CL" >&2; exit 1; }

# Field-exact heading match ($2 == "v<version>") — no regex, so version dots
# can't wildcard and 0.2.0 can never swallow 0.20.0's entry.
NOTES="$(awk -v ver="$V" '
  $1=="##" && $2=="v"ver {grab=1; next}
  grab && $1=="##" && $2 ~ /^v[0-9]/ {exit}
  grab && $0=="---" {next}
  grab {print}
' "$CL" | sed '/./,$!d')"

[ -n "$NOTES" ] || { printf 'release-notes: no CHANGELOG entry for v%s\n' "$V" >&2; exit 1; }
printf '%s\n' "$NOTES"
