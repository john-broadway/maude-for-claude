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

# The version must LOOK like a version before anything else. The semver case below uses a
# negated class ([!0-9.a-z-]) that matches nothing in an all-lowercase word, so "broker"
# fell straight through to the writers: measured here 2026-09-02 (a cwd drift ran
# `release.sh broker 0.40.0` against this repo and stamped 20 files), and on proximo
# 2026-09-01 the same way. Class-swept from proximo/pacioli.
printf '%s' "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([a-z0-9.-]*)?$' \
  || { printf 'release: refusing "%s" — not an X.Y.Z version.\n' "$V" >&2; exit 1; }

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

STAMPLIB="$ROOT/scripts/lib-stamp.sh"
# Fail CLOSED, and do it BEFORE the first mutation. Sourced unguarded, a missing
# lib-stamp.sh left `.` failing, the script
# running on with no `set -e`, every stamp_header a command-not-found, and a release
# shipping an UNSTAMPED tree without a word. Silence read as success, which is the exact
# defect this file was edited to fix one commit earlier. Placed after step 1 it was no
# better: the refusal still left plugin.json and marketplace.json bumped, which is the
# half-stamped tree it claims to prevent. A refusal that has already written is not one.
if [ ! -r "$STAMPLIB" ]; then
  printf 'release: cannot stamp — %s is missing or unreadable.\n' "$STAMPLIB" >&2
  printf 'release: refusing to continue; a release that cannot stamp must not look like one that did.\n' >&2
  exit 1
fi
# shellcheck source=scripts/lib-stamp.sh
. "$STAMPLIB"

# 1. canonical JSON versions
t="$(mktemp)"; jq --arg v "$V" '.version=$v' .claude-plugin/plugin.json >"$t" && mv "$t" .claude-plugin/plugin.json
t="$(mktemp)"; jq --arg v "$V" '.plugins[0].version=$v' .claude-plugin/marketplace.json >"$t" && mv "$t" .claude-plugin/marketplace.json

# Every stamp below rewrites the FIRST match in a file and no other. That is not a
# tidiness preference: maude-verify.sh reads these headers with `grep -m1`, so the first
# match IS the header by the checker's own definition, and pointing the writer at the same
# occurrence is what keeps the two from disagreeing. The old unanchored `sed s|...|...|`
# rewrote every match, including version strings quoted inside a document's body, and
# because verify only ever looked at the first one nothing reported the damage for 13
# releases. See scripts/lib-stamp.sh and tests/test-release-stamp.sh.


# A file that could not be stamped is collected, not shrugged at. These loops used to
# discard stamp_header's return code entirely, so a file that failed to stamp simply was
# not stamped and the release said nothing: the same silence-reads-as-success shape as the
# unguarded source above it.
# `worktrees` is excluded, and NOT `.claude`: a release run in this repo would otherwise
# reach into every sibling agent checkout under .claude/worktrees/ and rewrite its headers
# (114 markdown files, measured 2026-09-04), while .claude/CLAUDE.md is exactly the file
# loop 2b exists to stamp. The hand-check that missed this used the interactive shell's
# `grep`, which is ugrep and skips those directories; a script gets /usr/bin/grep, which
# does not. Verify a selector with the grep the SCRIPT will run, not the one at the prompt.
STAMP_FAILED=""

# 2. propagate every markdown Version: header
while IFS= read -r f; do
  [ -n "$f" ] || continue
  stamp_header "$f" '<!-- Version: [0-9][0-9A-Za-z.-]* -->' "<!-- Version: $V -->" || STAMP_FAILED="$STAMP_FAILED $f"
done < <(grep -rlE '<!-- Version: [0-9]' --include='*.md' . \
  --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache \
  --exclude-dir=worktrees 2>/dev/null)

# 2b. propagate the blockquote "> **Version:** X" form too — the project-local
#     .claude/CLAUDE.md carries no HTML-comment header, so step 2 never touched it
#     and it drifted (stranded at 0.8.0). This stamps it from the same source.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  stamp_header "$f" '> [*][*]Version:[*][*] [0-9][0-9A-Za-z.-]*' "> **Version:** $V" || STAMP_FAILED="$STAMP_FAILED $f"
done < <(grep -rlE '> [*][*]Version:[*][*] [0-9]' --include='*.md' . \
  --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache \
  --exclude-dir=worktrees 2>/dev/null)

# 3. stamp Revised dates to today (release-wide refresh; the convention is "current
#    as of this release", which also keeps verify's <=14-day check green)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  stamp_header "$f" '<!-- Revised: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][^>]*-->' "<!-- Revised: $TODAY -->" || STAMP_FAILED="$STAMP_FAILED $f"
done < <(grep -rlE '<!-- Revised: [0-9]' --include='*.md' . \
  --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache \
  --exclude-dir=worktrees 2>/dev/null)

if [ -n "$STAMP_FAILED" ]; then
  printf 'release: could not stamp:%s\n' "$STAMP_FAILED" >&2
  printf 'release: refusing to continue with a partially stamped tree.\n' >&2
  exit 1
fi

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
  # The TITLE carries the reason, never a bare version. It is one of the few lines a
  # visitor reads WITHOUT clicking anything, and this NEXT block was handing out the
  # bare form. Same defect John flagged on proximo (bare release titles, 2026-08-24)
  # and again on the public commit subject (2026-09-01); class-swept here 2026-09-02.
  printf '  scripts/release-notes.sh %s > /tmp/notes-v%s.md && gh release create v%s --title "v%s: <the one-line reason, from the CHANGELOG heading>" --notes-file /tmp/notes-v%s.md\n' "$V" "$V" "$V" "$V" "$V"
else
  printf 'release.sh: GATE NOT GREEN — fix the findings above before building the release commit.\n'
fi
exit "$RC"
