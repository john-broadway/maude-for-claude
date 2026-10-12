#!/usr/bin/env bash
# Maude self-check (SessionStart) — is the INSTALLED Maude what her source built?
#
# Born 2026-08-08: main carried 20 commits of finished work for TEN DAYS while
# the installed cache stayed at the prior release. The directory-marketplace
# updater keys on the VERSION, honest semver had held the number still, so
# `plugin update` said "already at latest" with 13 files differing — and every
# session ran the stale scripts believing itself current. She watches the whole
# house for drift; the blind spot was her own closet. This check runs where the
# blind spot was, at the moment it matters: wake.
#
# Two findings, two messages:
#   versions DIFFER          → the update was never applied: run plugin update.
#   versions EQUAL, files differ → the 10-day trap itself: the updater will
#                              NEVER deliver this — bump the version on main.
#
# Degrades SILENT (exit 0, no output) when there is nothing to compare: no jq,
# no marketplace record, no source dir on this machine, or running FROM the
# source (a dev checkout is its own source of truth). A whisper that cannot be
# computed must say nothing, not guess. Env seams (tests): MAUDE_SOURCE_DIR
# overrides discovery; MAUDE_SELF_CHECK=off kills it.
set +e

# Eye recursion guard: inert inside a blink subprocess. Standalone hook
# (doesn't source _maude-common.sh), so the guard is this inline copy —
# same pattern as maude-secret-scan.sh. Caught by the completeness test
# from the ARCHIVE: the working-tree run had masked it behind the
# dev-checkout short-circuit (ROOT == SRC → silent for the wrong reason).
[ -n "${MAUDE_EYE_BLINK:-}" ] && exit 0

[ "${MAUDE_SELF_CHECK:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$DIR/../.." && pwd)}"

# Both records live under the config dir, which CLAUDE_CONFIG_DIR relocates (lens 1); the
# global config sits beside them there, else at $HOME/.claude.json (lens 4).
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
KM="$CFG/plugins/known_marketplaces.json"
GC="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"; GC="${GC:-$HOME/.claude.json}"

# ── Will the next Maude reach this house at all? ───────────────────────────
# Claude Code's only update notice for a plugin is its own
# "Plugin updated: maude" (suffixed: reloaded, or run /reload-plugins), printed after the
# startup pass refreshes a marketplace with auto-update ON. That is off by default
# for every marketplace that is not Anthropic's, so an adopter who followed the
# README never hears of a release (2026-10-10, read from 2.1.296 and the docs).
# She says so at session start, for a REMOTE marketplace (github, git, url;
# in-place directory/file sources load their current files and have nothing to
# auto-update), when NO record carries the key. The harness resolves it the way
# this does: the settings scopes merged, project-local over project over user,
# where a scope's `extraKnownMarketplaces.maude` entry replaces the lower one
# WHOLE (an entry without the key hides a lower true: lens 1), else the
# known_marketplaces.json record. Managed, --settings and --add-dir scopes are
# not read here. A boolean found there, true or false, is a choice somebody made.
# Silent under the harness's own kill switches, read with its grammar (2.1.296:
# DISABLE_AUTOUPDATER / DISABLE_UPDATES / FORCE_AUTOUPDATE_PLUGINS are on for
# 1, true, yes, on, trimmed and any case; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
# for any non-empty value; autoUpdates false in the global config unless the
# install is native and protected, lens 4), where the pass the toggle governs
# never runs, the menu hides the toggle, and the flip would change nothing. The
# host-pin switch (CLAUDE_CODE_AUTOUPDATER_DISABLED_BY_HOST) is not read. A file
# that fails to parse casts no vote.
# stdout is the brief Claude reads, as the two whispers below; whether a line
# reaches the human's screen is his to relay.
# An entry is what the harness keeps after its schema (2.1.296, the shapes `claude doctor`
# reports as "Invalid marketplace entry was ignored"): source an object with a string kind
# and the string field that kind requires (github: repo; git, url: url; file, directory:
# path; an unknown kind is left unvalidated), installLocation absent or a string,
# autoUpdate absent or a boolean (an explicit null is rejected). Anything else it drops
# before the merge, so a hand-edited {"autoUpdate":true} with no source is no entry
# (lens 2), and a broken higher entry does not hide a lower true (lens 3).
_au_entry() {  # <settings-file> → nothing (no entry) | none (entry, no key) | true | false
  [ -f "$1" ] && jq -r '.extraKnownMarketplaces.maude
    | if type != "object" or (.source | type) != "object" or (.source.source | type) != "string" then empty
      elif has("installLocation") and (.installLocation | type) != "string" then empty
      elif ({github: "repo", git: "url", url: "url", file: "path", directory: "path"}[.source.source]) as $need
           | $need != null and (.source[$need] | type) != "string" then empty
      elif has("autoUpdate") | not then "none"
      elif (.autoUpdate | type) == "boolean" then (.autoUpdate | tostring)
      else empty end' "$1" 2>/dev/null
}
_switch_on() {  # the harness's Ne(): trimmed, lowercased, one of 1 true yes on
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" in
    1|true|yes|on) return 0 ;; *) return 1 ;;
  esac
}
case "$(jq -r '.maude.source.source // empty' "$KM" 2>/dev/null)" in
  github|git|url)
    PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
    VOTE=""
    for f in "$PROJ/.claude/settings.local.json" "$PROJ/.claude/settings.json" "$CFG/settings.json"; do
      ENTRY="$(_au_entry "$f")"
      [ -n "$ENTRY" ] || continue            # this scope declares no entry: look lower
      [ "$ENTRY" != "none" ] && VOTE="$ENTRY"
      break                                  # the highest scope with an entry is the whole entry
    done
    [ -n "$VOTE" ] || VOTE="$(jq -r '.maude.autoUpdate | if type == "boolean" then tostring else empty end' "$KM" 2>/dev/null)"
    KILLED=""
    if ! _switch_on "${FORCE_AUTOUPDATE_PLUGINS:-}"; then
      if _switch_on "${DISABLE_AUTOUPDATER:-}" || _switch_on "${DISABLE_UPDATES:-}" \
         || [ -n "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ] \
         || { [ -f "$GC" ] && jq -e '.autoUpdates == false
                and (.installMethod != "native" or .autoUpdatesProtectedForNative != true)' "$GC" >/dev/null 2>&1; }
      then KILLED=y; fi
    fi
    if [ -z "$VOTE" ] && [ -z "$KILLED" ]; then
      printf 'Maude: auto-update is off for my marketplace, so Claude Code will never say a new Maude landed. Flip it once: /plugin, Marketplaces, maude, Enable auto-update. From then on each release prints "Plugin updated: maude" at the start of a session, with a note whether it reloaded or needs /reload-plugins.\n'
    fi
    ;;
esac

SRC="${MAUDE_SOURCE_DIR:-}"
if [ -z "$SRC" ]; then
  [ -f "$KM" ] && SRC="$(jq -r '.maude.source.path // empty' "$KM" 2>/dev/null)"
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || exit 0
# Same dir (or same resolved dir) = dev checkout; nothing to compare.
[ "$(cd "$SRC" 2>/dev/null && pwd -P)" = "$(cd "$ROOT" 2>/dev/null && pwd -P)" ] && exit 0

IV="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
SV="$(jq -r '.version // empty' "$SRC/.claude-plugin/plugin.json" 2>/dev/null)"
[ -n "$IV" ] && [ -n "$SV" ] || exit 0

if [ "$IV" != "$SV" ]; then
  # The qualified name, not the bare one: `claude plugin update maude` fails
  # with "not found" on the canonical install (marketplace and plugin are both
  # named maude, and update wants name@marketplace). A whisper must hand the
  # user a command that RUNS — verified 2026-08-08 by the bare form failing
  # live, the same lesson the maude-marker wrapper carries.
  printf 'Maude: my installed self is v%s but my source carries v%s — an update is waiting. Run `claude plugin update maude@maude` and restart, so the house runs what was built.\n' "$IV" "$SV"
  exit 0
fi

# Versions equal — the trap is version-KEYED drift: same number, different files.
# Excludes are state/junk, not shipped surface. Bounded by the hook timeout.
N="$(diff -rq "$ROOT" "$SRC" \
      -x .git -x .maude -x '.claude' -x '__pycache__' -x '*.db' -x '.pytest_cache' \
      2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${N:-0}" -gt 0 ] 2>/dev/null; then
  printf 'Maude: installed v%s MATCHES the source version, but %s file(s) differ — the updater keys on the version, so this will NEVER auto-deliver. Bump the version on main (classify, then bump) or sync deliberately. Merged is not installed.\n' "$IV" "$N"
fi
exit 0
