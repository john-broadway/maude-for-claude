#!/usr/bin/env bash
# Maude release updater — the "what, not who" for a release.
#
# Hand-walking ~12 files every release (bump each Version header, stamp dates,
# match marketplace.json, run the gate) is the remember-everything step that keeps
# MISSING things — version drift, stale dates, a skipped file. This makes the
# MECHANICAL parts deterministic from ONE source (the version you pass), then runs
# the full gate. It writes NO prose: the CHANGELOG entry and the README "What's new"
# entry stay yours, in your words. It stops at "ready for PR" — it never pushes.
#
# Usage: scripts/release.sh <version>     e.g.  scripts/release.sh 0.9.1
#
# What it does:
#   1. sets .version in plugin.json + marketplace.json
#   2. propagates every `<!-- Version: -->` markdown header to that version
#   3. stamps `<!-- Revised: -->` to today on every doc that carries one
#   4. runs the gate — verify + test + lint — and fails if any does
# The gate (maude-verify.sh) is what catches a miss: version drift, an
# un-condensed "What's new" wall, a doc reference to a cut command.

set -uo pipefail

V="${1:-}"
[ -n "$V" ] || { printf 'usage: release.sh <version>   e.g. release.sh 0.9.1\n' >&2; exit 2; }

# Honest semver: pre-1.0 software stays 0.x; a major>=1 must be intentional, never
# an accident of this script. Mirror the workspace version-audit discipline.
case "$V" in
  0.*) : ;;
  [1-9]*|*[!0-9.a-z-]*)
    if [ "${MAUDE_RELEASE_FORCE_MAJOR:-}" != "1" ]; then
      printf 'release: refusing version "%s" — pre-1.0 discipline keeps it 0.x; set MAUDE_RELEASE_FORCE_MAJOR=1 to override.\n' "$V" >&2
      exit 1
    fi
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { printf 'release: cannot cd to repo root\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'release: jq required\n' >&2; exit 1; }
TODAY="$(date +%Y-%m-%d)"

printf '== release.sh: setting version %s (Revised %s) ==\n' "$V" "$TODAY"

# 1. canonical JSON versions
t="$(mktemp)"; jq --arg v "$V" '.version=$v' .claude-plugin/plugin.json >"$t" && mv "$t" .claude-plugin/plugin.json
t="$(mktemp)"; jq --arg v "$V" '.plugins[0].version=$v' .claude-plugin/marketplace.json >"$t" && mv "$t" .claude-plugin/marketplace.json

# 2. propagate every markdown Version: header
while IFS= read -r f; do
  [ -n "$f" ] && sed -i.bak -E "s|<!-- Version: [0-9][0-9A-Za-z.-]* -->|<!-- Version: $V -->|" "$f" && rm -f "$f.bak"
done < <(grep -rlE '<!-- Version: [0-9]' --include='*.md' . \
  --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache 2>/dev/null)

# 2b. propagate the blockquote "> **Version:** X" form too — the project-local
#     .claude/CLAUDE.md carries no HTML-comment header, so step 2 never touched it
#     and it drifted (stranded at 0.8.0). This stamps it from the same source.
while IFS= read -r f; do
  [ -n "$f" ] && sed -i.bak -E "s|(> \*\*Version:\*\* )[0-9][0-9A-Za-z.-]*|\1$V|" "$f" && rm -f "$f.bak"
done < <(grep -rlE '> \*\*Version:\*\* [0-9]' --include='*.md' . \
  --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache 2>/dev/null)

# 3. stamp Revised dates to today (release-wide refresh; the convention is "current
#    as of this release", which also keeps verify's <=14-day check green)
while IFS= read -r f; do
  [ -n "$f" ] && sed -i.bak -E "s|<!-- Revised: [0-9]{4}-[0-9]{2}-[0-9]{2}[^>]*-->|<!-- Revised: $TODAY -->|" "$f" && rm -f "$f.bak"
done < <(grep -rlE '<!-- Revised: [0-9]' --include='*.md' . \
  --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache 2>/dev/null)

# 4. the gate — fail loudly if anything is incomplete/inconsistent
RC=0
printf '\n== verify ==\n'; bash scripts/maude-verify.sh "$ROOT" | tail -3 || RC=1
printf '\n== test ==\n';   env -u MAUDE_RUN_GOVERNOR bash tests/run.sh >/dev/null 2>&1 && printf '  suite green\n' || { printf '  SUITE FAILED — run: env -u MAUDE_RUN_GOVERNOR make test\n'; RC=1; }
printf '\n== lint ==\n';   shellcheck --severity=warning hooks/scripts/*.sh scripts/*.sh tests/*.sh >/dev/null 2>&1 && printf '  lint clean\n' || { printf '  LINT FAILED — run: make lint\n'; RC=1; }
# The prove-it-real gate: the release must work from the COMMIT a stranger
# gets, not the working tree. NOTE: version bumps above are still uncommitted
# at this point, so the smoke proves the last commit's shape — run release.sh,
# build the release commit, then `make smoke` once more before tagging.
printf '\n== install-smoke (HEAD, pre-bump shape) ==\n'
bash scripts/install-smoke.sh . 2>&1 | tail -1 | grep -q 'SMOKE GREEN' && printf '  smoke green\n' || { printf '  SMOKE FAILED — run: make smoke\n'; RC=1; }

printf '\n----------------------------------------\n'
if [ "$RC" -eq 0 ]; then
  printf 'release.sh: v%s propagated, dates stamped %s, gate GREEN.\n' "$V" "$TODAY"
  printf 'NEXT (yours, in our words): write the CHANGELOG v%s entry + the README "What'"'"'s new" v%s entry,\n' "$V" "$V"
  printf 'then build the curated commit -> branch -> PR for review. release.sh never pushes.\n'
  printf 'AFTER the tag lands (maintainer'"'"'s hand — the Releases tab must not fall behind the tags, #38):\n'
  printf '  scripts/release-notes.sh %s > /tmp/notes-v%s.md && gh release create v%s --title "v%s" --notes-file /tmp/notes-v%s.md\n' "$V" "$V" "$V" "$V" "$V"
else
  printf 'release.sh: GATE NOT GREEN — fix the findings above before building the release commit.\n'
fi
exit "$RC"
