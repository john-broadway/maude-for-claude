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
#        scripts/release-notes.sh --title 0.20.0 [CHANGELOG.md]
#
# --title prints the Release page TITLE, `v<version>: <reason>`, from the entry's
# heading (`## v<version> - <reason>` or `## v<version> — <reason>`). The title is
# the stranger's line: what a visitor reads without clicking. The tag workflow
# used to mint `--title "$TAG"`, so nine of the last ten pages read as a bare
# version number. A heading with no reason, or a date where the reason should be,
# is refused (exit 1) — better no page than a bare one, and the workflow fails loud.

set -uo pipefail

MODE=notes
if [ "${1:-}" = "--title" ]; then MODE=title; shift; fi
V="${1:-}"
[ -n "$V" ] || { printf 'usage: release-notes.sh [--title] <version> [changelog]\n' >&2; exit 2; }
CL="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"
[ -f "$CL" ] || { printf 'release-notes: no changelog at %s\n' "$CL" >&2; exit 1; }

if [ "$MODE" = "title" ]; then
  HEADING="$(awk -v ver="$V" '$1=="##" && $2=="v"ver {print; exit}' "$CL")"
  [ -n "$HEADING" ] || { printf 'release-notes: no CHANGELOG entry for v%s\n' "$V" >&2; exit 1; }
  REST="${HEADING#"## v$V"}"
  case "$REST" in
    " - "*) REASON="${REST#" - "}" ;;
    " — "*) REASON="${REST#" — "}" ;;
    *) printf 'release-notes: the v%s heading carries no reason — a bare title is the defect, not a fallback\n' "$V" >&2; exit 1 ;;
  esac
  REASON="${REASON%"${REASON##*[![:space:]]}"}"
  [ -n "$REASON" ] || { printf 'release-notes: the v%s heading has a separator and nothing after it — a bare title is the defect, not a fallback\n' "$V" >&2; exit 1; }
  case "$REASON" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf 'release-notes: the v%s heading carries a date where the reason should be\n' "$V" >&2; exit 1 ;;
  esac
  printf 'v%s: %s\n' "$V" "$REASON"
  exit 0
fi

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
