#!/usr/bin/env bash
# Maude verify — programmatic audit of project state. The audit Maude runs
# before saying "ready." Catches version drift, JSON breakage, broken links,
# stale header dates, missing CHANGELOG entries, and watch-list-path drift.
#
# Output: structured report. Counts by category. Last line: "N findings".
# Exit code: 0 if no findings, 1 if any findings. Caller (e.g., /maude:conscience)
# decides what to do with the findings.
#
# Usage: maude-verify.sh [project_dir]
#   project_dir defaults to $CLAUDE_PROJECT_DIR or pwd.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
# Source common helpers if present (hooks/scripts/_maude-common.sh)
COMMON="$DIR/../hooks/scripts/_maude-common.sh"
# shellcheck disable=SC1090  # $COMMON is computed from $DIR; load is guarded by [ -f ]
[ -f "$COMMON" ] && . "$COMMON"
# MAUDE_HEADER_LINES — how far down a file a header can be. Sourced, never restated: a
# fallback default here would be a SECOND copy of the number the stamper owns, and two
# copies drift, which is the whole reason it was centralised. If the library is missing the
# checker cannot know where a header lives, so it says so as a finding and skips the header
# checks rather than auditing against a guess.
STAMPLIB="$DIR/lib-stamp.sh"
STAMPLIB_MISSING=""
# shellcheck disable=SC1090  # $STAMPLIB is computed from $DIR; load is guarded by [ -f ]
if [ -f "$STAMPLIB" ]; then . "$STAMPLIB"; else STAMPLIB_MISSING=1; fi

PROJ="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
cd "$PROJ" || { echo "verify: cannot cd to $PROJ" >&2; exit 1; }

FINDINGS=0
emit() { printf '  %s\n' "$1"; FINDINGS=$((FINDINGS + 1)); }

printf 'Maude verify: %s\n' "$PROJ"
printf '%s\n' "----------------------------------------"

# ─── Check 1: JSON validity ──────────────────────────────────────────
printf '\n## JSON validity\n'
if command -v jq >/dev/null 2>&1; then
  # `*/worktrees/*` like every selector here. This one is a `find`, not a grep, which is
  # why an enumeration of grep selectors missed it twice: the class is "walks the tree",
  # not "matches the pattern I searched for". It was live — 57 of the 68 files it scanned
  # in this repo were sibling-worktree files, so the count it printed described someone
  # else's checkout as much as this one.
  JSON_FILES=$(find . -name "*.json" -not -path "./.git/*" -not -path "./.maude/*" -not -path "./.pytest_cache/*" -not -path "./node_modules/*" -not -path "*/worktrees/*" 2>/dev/null)
  COUNT=0
  for f in $JSON_FILES; do
    COUNT=$((COUNT + 1))
    jq . "$f" > /dev/null 2>&1 || emit "BROKEN: $f"
  done
  printf '  %d JSON files scanned\n' "$COUNT"
else
  printf '  jq not available — skipped\n'
fi

# ─── Check 2: Version consistency ────────────────────────────────────
printf '\n## Version consistency\n'
CANONICAL=""
if [ -f .claude-plugin/plugin.json ] && command -v jq >/dev/null 2>&1; then
  CANONICAL=$(jq -r '.version // ""' .claude-plugin/plugin.json 2>/dev/null)
  printf '  Canonical (plugin.json): %s\n' "$CANONICAL"

  # Check marketplace.json matches
  if [ -f .claude-plugin/marketplace.json ]; then
    M_VER=$(jq -r '.plugins[0].version // ""' .claude-plugin/marketplace.json 2>/dev/null)
    if [ "$M_VER" != "$CANONICAL" ]; then
      emit "MISMATCH: marketplace.json plugins[0].version = '$M_VER' (expected '$CANONICAL')"
    fi
  fi

  if [ -n "$STAMPLIB_MISSING" ]; then
    emit "MISSING: $STAMPLIB — header checks skipped (the header window is defined there)"
  fi

  # Header sync: the release convention bumps EVERY `<!-- Version: -->` header
  # to the canonical version each release. A stale one means the release sweep
  # missed that file (the v0.4.0 release missed seven, including the README's own).
  if [ -n "$CANONICAL" ] && [ -z "$STAMPLIB_MISSING" ]; then
    HDR_FILES=$(grep -rl "<!-- Version:" . --include="*.md" \
      --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache \
      --exclude-dir=worktrees 2>/dev/null)
    for f in $HDR_FILES; do
      # HEADER BLOCK ONLY. This used to read the first match anywhere in the file, which
      # made a version quoted in a document's prose look like that document's header —
      # and release.sh, rewriting every match anywhere, kept that prose line current so
      # the mismatch never surfaced. Writer and checker now agree on where a header is.
      HV=$(head -n "$MAUDE_HEADER_LINES" "$f" 2>/dev/null \
           | grep -m1 -o "<!-- Version: [0-9][0-9a-zA-Z.-]*" 2>/dev/null | awk '{print $3}')
      if [ -n "$HV" ] && [ "$HV" != "$CANONICAL" ]; then
        emit "STALE HEADER: $f says Version: $HV (expected $CANONICAL)"
      fi
    done
  fi

  # The BLOCKQUOTE form. release.sh stamps two header shapes and this audited only one, so
  # a stale `> **Version:**` line was checked by nothing in the house. It covers exactly one
  # file today (.claude/CLAUDE.md), which is why it went unnoticed.
  if [ -n "$CANONICAL" ] && [ -z "$STAMPLIB_MISSING" ]; then
    BQ_FILES=$(grep -rlF '**Version:**' . --include="*.md" \
      --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache \
      --exclude-dir=worktrees 2>/dev/null)
    for f in $BQ_FILES; do
      BV=$(head -n "$MAUDE_HEADER_LINES" "$f" 2>/dev/null \
           | grep -m1 -oE '> \*\*Version:\*\* [0-9][0-9A-Za-z.-]*' | awk '{print $3}')
      if [ -n "$BV" ] && [ "$BV" != "$CANONICAL" ]; then
        emit "STALE HEADER: $f says Version: $BV (expected $CANONICAL)"
      fi
    done
  fi

  # Find any version-string mentions in markdown/json/sh and group
  if [ -n "$CANONICAL" ]; then
    # Pull all v0.X.Y references
    ALL_REFS=$(grep -rEho "v[0-9]+\.[0-9]+\.[0-9]+" . \
      --include="*.md" --include="*.json" --include="*.sh" \
      --exclude-dir=.git --exclude-dir=.pytest_cache --exclude-dir=.maude \
      --exclude-dir=worktrees 2>/dev/null | sort -u)
    if [ -n "$ALL_REFS" ]; then
      printf '  Distinct version refs found in repo: %s\n' "$(printf '%s' "$ALL_REFS" | tr '\n' ' ')"
    fi

    # CHANGELOG should have an entry for the canonical version
    if [ -f CHANGELOG.md ]; then
      if ! grep -qE "^## v$CANONICAL([^0-9.]|\$)" CHANGELOG.md; then
        emit "CHANGELOG.md is missing a v$CANONICAL section header"
      fi
    fi
  fi
fi

# ─── Check 3: README "What's new" mentions canonical version ─────────
printf "\n## README 'What's new' freshness\n"
if [ -f README.md ] && [ -n "$CANONICAL" ]; then
  if grep -q '^## What.s new' README.md; then
    # Look for canonical version in the What's new section
    if ! awk '/^## What.s new/{flag=1; next} /^## /{flag=0} flag' README.md | grep -q "v$CANONICAL"; then
      emit "README 'What's new' section does not mention v$CANONICAL"
    else
      printf "  v%s present in 'What's new'\n" "$CANONICAL"
    fi
  else
    printf "  No 'What's new' section in README — skipped\n"
  fi
fi

# ─── Check 3b: "What's new" stays condensed (the wall belongs in CHANGELOG) ──
printf "\n## README 'What's new' condensed\n"
WHATSNEW_MAX="${MAUDE_WHATSNEW_MAX:-6}"
if [ -f README.md ] && grep -q '^## What.s new' README.md; then
  WN_COUNT=$(awk '/^## What.s new/{flag=1; next} /^## /{flag=0} flag' README.md 2>/dev/null | grep -cE '^\*\*v[0-9]')
  if [ "$WN_COUNT" -gt "$WHATSNEW_MAX" ]; then
    emit "README 'What's new' has $WN_COUNT release entries (>$WHATSNEW_MAX) — condense older ones to the CHANGELOG so the public face stays fluid"
  else
    printf '  %d entries (<=%d) — condensed\n' "$WN_COUNT" "$WHATSNEW_MAX"
  fi
fi

# ─── Check 4: Header Revised dates tell the truth ────────────────────
printf '\n## Header revised dates\n'
# `Revised: D` is a claim: this file last changed on D. The check reads the claim against
# the file's history, never against the calendar. Until 2026-09-29 it was "older than 14
# days is stale", which reddened main on 09-28 with no commit between the green run and the
# red one, named eight stamps (seven honest), and its only cure was to restamp files nobody had
# touched: a gate whose fix is a lie. The same run passed the one stamp that WAS behind its
# file (CHANGELOG stamped 09-28, committed 09-29). A doc nobody edits does not go stale;
# a doc edited after its stamp is lying about when.
#
# Anchor = the file's last change: the working tree's today if the file is modified or
# untracked, else the date of the last commit that touched it. Stamp before anchor = finding.
# Stamp after today = finding (a typo'd year passes the first test and is still a lie).
#
# Env seam (tests): MAUDE_VERIFY_TODAY. Colon-guarded on purpose. The first version was not,
# so an ambient empty value became an unresolvable anchor, which made `make verify` exit 2
# and took ship.sh's gate down with it. Empty means "use today".
TODAY=${MAUDE_VERIFY_TODAY:-$(date +%Y-%m-%d)}
# Because it is ambient, the value can be anything. An anchor this script cannot resolve
# silences the dirty-file and future-date reads for EVERY file, and the run prints a clean
# bill for a check that examined nothing. Measured: MAUDE_VERIFY_TODAY=banana turned a
# stale file into 0 findings and exit 0.
if [ -z "$STAMPLIB_MISSING" ] && [ -z "$(maude_date_epoch "$TODAY" 2>/dev/null)" ]; then
  emit "cannot resolve today's date \"$TODAY\" (MAUDE_VERIFY_TODAY?) — revised dates NOT checked"
fi
# A parseable but WRONG date cannot be told from a test's, and a past pin can hide a dirty
# file's lie. This was a printf first, which was no mitigation at all — release.sh pipes
# verify through `tail -3` and both CI workflows gate on the exit code, so the one line
# saying the check had been switched off was truncated away in the only place it mattered.
# A FINDING travels: non-zero exit, pipefail carries it, the release gate stops.
[ -z "${MAUDE_VERIFY_TODAY:-}" ] || emit "today is pinned to $TODAY by MAUDE_VERIFY_TODAY — dirty files and future dates measured from a supplied date, not the clock"
HDRS=$([ -n "$STAMPLIB_MISSING" ] || grep -rln "Revised:" . --include="*.md" --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache --exclude-dir=worktrees 2>/dev/null)
# The history is asked once, and only when a header will be read against it. A tree with
# no Revised headers has nothing to anchor and says nothing (a mktemp fixture with a bare
# version header must still read 0 findings). A tree WITH one and no usable history is a
# finding, not a skip: in a shallow clone the boundary commit is a root that "adds" every
# file, so every stamp older than the boundary reads as behind it, and outside git there
# is no last change to read at all. Either way the check examined nothing and must say so.
GIT_ANCHOR=""   # "" until proven usable; then "ok"
GIT_ANCHOR_WHY=""
_anchor_ready() {
  [ -z "$GIT_ANCHOR$GIT_ANCHOR_WHY" ] || return 0
  if ! command -v git >/dev/null 2>&1; then GIT_ANCHOR_WHY="git is not installed"
  elif [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then GIT_ANCHOR_WHY="not a git work tree"
  # Two spellings of shallow: the flag (git >= 2.15; an older git echoes the flag back, which
  # is not "true" and would read as deep) and the marker file every shallow clone carries.
  elif [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] \
    || [ -f "$(git rev-parse --git-path shallow 2>/dev/null)" ]; then GIT_ANCHOR_WHY="shallow clone, a file's last change may lie past the boundary"
  else GIT_ANCHOR="ok"; fi
  [ -z "$GIT_ANCHOR_WHY" ] || emit "cannot anchor Revised dates on the file history ($GIT_ANCHOR_WHY) — revised dates NOT checked"
}
if [ -n "$HDRS" ]; then
  while IFS= read -r f; do
    # Header block only, for the same reason as the version check above: a date quoted in
    # prose is not this document's Revised date, and reading one as if it were would age a
    # historical plan into a finding on every run.
    REVDATE=$(head -n "$MAUDE_HEADER_LINES" "$f" 2>/dev/null \
              | grep -m1 -oE 'Revised:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [ -n "$REVDATE" ] || continue
    # Days the stamp sits AHEAD of today. Empty = the shape passed the regex and is still not
    # a date (2026-13-45). One day ahead is allowed: a writer east of the checker's clock
    # stamps a date the checker has not reached yet, and CI runs on UTC. Two is a typo.
    AHEAD=$(maude_days_between "$TODAY" "$REVDATE" 2>/dev/null)
    if [ -z "$AHEAD" ]; then
      emit "$f Revised: $REVDATE is not a date this clock can place"; continue
    elif [ "$AHEAD" -gt 1 ]; then
      emit "$f Revised: $REVDATE is after today ($TODAY) — a date the file cannot have"
    fi
    _anchor_ready
    [ "$GIT_ANCHOR" = "ok" ] || continue
    # An ignored file is not this tree's document (a vendored README, a build output).
    # check-ignore takes a pathname, not a pathspec, and refuses the literal flag; the calls
    # below take pathspecs, where a `[`, `*` or `?` in a name is otherwise a glob and
    # `a[1].md` reads its neighbour a1.md's history and diff, so they run literal.
    git check-ignore -q -- "$f" 2>/dev/null && continue
    # --untracked-files=normal: a user config of status.showUntrackedFiles=no would make a
    # new file read as clean, and clean-with-no-history is a refusal, not the finding it is.
    if [ -n "$(git --literal-pathspecs status --porcelain --untracked-files=normal -- "$f" 2>/dev/null)" ]; then
      ANCHOR="$TODAY"; ANCHOR_WHY="modified in the working tree"
    else
      # The file's history, newest first, following renames: each record is a commit that
      # added (A), modified (M) or renamed (R<similarity>) it, with the path(s) it had THEN.
      # The AUTHOR date, not the committer's: rebase, cherry-pick and amend re-date the
      # committer and would put every honest stamp on a rebased branch behind its file.
      # quotePath=false so a non-ASCII name comes back as itself, not as "caf\303\251.md";
      # a name carrying a tab, a quote or a backslash is still quoted and cannot be asked
      # about below, which fails toward a finding, never a pass.
      HIST="$(git --literal-pathspecs -c core.quotePath=false log --follow --diff-filter=AMR --format='%x01%H %as' --name-status -- "$f" 2>/dev/null)"
      SHA=""; ANCHOR=""; STATUS=""; PATHS=""; REC=""
      while IFS= read -r line; do
        case "$line" in
          $'\x01'*) REC="${line#?}" ;;
          '') ;;
          # An exact move is not a revision: walk past it to the change before it. A move
          # that also edits (R<100) IS one, and is read below with both of its paths.
          R100$'\t'*) ;;
          *) SHA="${REC%% *}"; ANCHOR="${REC#* }"; STATUS="${line%%$'\t'*}"; PATHS="${line#*$'\t'}"; break ;;
        esac
      done <<< "$HIST"
      ANCHOR_WHY="last changed"
      # A tracked, clean file always has such a commit; if git gives no date, or an old git
      # echoes the format back, the anchor is unknown and unknown is a finding, never a pass.
      case "$ANCHOR" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then WHY="git gave no date for its last commit"
           else WHY="not tracked by this repository: a nested repository or a submodule"; fi
           emit "$f Revised: $REVDATE could not be anchored ($WHY) — NOT checked"; continue ;;
      esac
      case "$STATUS" in
        # A new file's stamp is taken at its word once committed: the add commit carries
        # whatever the writer wrote, and a squash merge re-dates it to the merge day, so a
        # date test here would red every new doc that came in on a branch. The copied-header
        # lie is caught while the file is untracked (the dirty rule above).
        A) continue ;;
        # A commit that moved the stamp FORWARD along with the file is honest whatever its
        # date: the writer restamped when they changed it. This is what survives a squash
        # merge (one re-dated commit carrying weeks of a branch). Header-shaped lines only,
        # both halves, forward: a body line that mentions the word, a stamp moved backwards
        # or a whitespace-only change to the stamp line is not a restamp. The paths are the
        # repo-root paths git printed, so they are asked for from the top, literally
        # (`:(top,literal)`), which is what makes this right when the project is a
        # subdirectory of its repo and when the name carries a glob character. No colour:
        # a color.ui=always in the user's config would paint the `+` and hide the line.
        # --text: a `-diff` attribute on the file would print "Binary files differ" instead.
        # Header window only: the awk walks the hunks and keeps a `-`/`+` line only while
        # its line number in its own side of the file is within MAUDE_HEADER_LINES. A doc
        # that quotes the header format at column 0 in a fenced example, and a commit that
        # edits only that example, otherwise reads as a restamp (lens round 5).
        M|R*) P1="${PATHS%%$'\t'*}"; P2="${PATHS#*$'\t'}"
           STAMPS="$(git show --format= --no-color --text "$SHA" -- ":(top,literal)$P1" ":(top,literal)$P2" 2>/dev/null \
             | awk -v N="$MAUDE_HEADER_LINES" '
                 /^diff --git / { inh=0; next }
                 /^@@ / { o=$2; n=$3; sub(/^-/,"",o); sub(/^\+/,"",n); sub(/,.*/,"",o); sub(/,.*/,"",n); ol=o+0; nl=n+0; inh=1; next }
                 !inh || /^\\/ { next }
                 /^-/ { if (ol<=N) print; ol++; next }
                 /^\+/ { if (nl<=N) print; nl++; next }
                 { ol++; nl++ }' \
             | grep -oE '^[-+]<!-- Revised:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}')"
           OLD="$(printf '%s\n' "$STAMPS" | grep -m1 '^-' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
           NEW="$(printf '%s\n' "$STAMPS" | grep -m1 '^+' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
           if [ -n "$OLD" ] && [ -n "$NEW" ] && [ "$NEW" \> "$OLD" ]; then continue; fi ;;
        *) emit "$f Revised: $REVDATE could not be anchored (git reported '$STATUS' for its last change) — NOT checked"; continue ;;
      esac
    fi
    if [ "$REVDATE" \< "$ANCHOR" ]; then
      emit "$f Revised: $REVDATE but $ANCHOR_WHY $ANCHOR — the stamp is behind the file"
    fi
  done <<< "$HDRS"
fi
[ "$FINDINGS" -eq 0 ] || true  # keep going

# ─── Check 5: Relative markdown links resolve ────────────────────────
printf '\n## Markdown link integrity\n'
if [ -f README.md ]; then
  BROKEN=0
  while IFS= read -r link; do
    case "$link" in
      http*) ;;
      \#*) ;;
      "") ;;
      *)
        # Strip fragment
        LINK_NO_FRAG="${link%%#*}"
        [ -z "$LINK_NO_FRAG" ] && continue
        if [ ! -e "$LINK_NO_FRAG" ]; then
          emit "README broken link: $link"
          BROKEN=$((BROKEN+1))
        fi
        ;;
    esac
  done < <(grep -oE '\]\([^)]+\)' README.md | sed 's/^](//;s/)$//')
  [ "$BROKEN" -eq 0 ] && printf '  README relative links all resolve\n'
fi

# ─── Check 6: House-map watch-list paths exist ───────────────────────
printf '\n## Watch-list path reconciliation\n'
MAP=".maude/plugin/house-map.md"
if [ -f "$MAP" ]; then
  WATCH=$(awk '/^## Watch list/{flag=1; next} /^## /{flag=0} flag' "$MAP" 2>/dev/null)
  if [ -n "$WATCH" ]; then
    MISSING=0
    while IFS= read -r line; do
      # Take the FIRST whitespace-delimited field: a watch-list entry is one path,
      # and any trailing "(description)" or inline note must not be glued onto the
      # path (else the whole line reads as a missing path — a false finding).
      TERM=$(printf '%s' "$line" | sed -E 's/^[-* `]+//; s/`+$//' | awk '{print $1}')
      [ -z "$TERM" ] && continue
      # Try as relative path; if not found, skip silently (terms can be tags too)
      case "$TERM" in
        /*|./*|[a-zA-Z0-9._-]*/*)
          if [ ! -e "$TERM" ]; then
            emit "Watch-list path missing: $TERM"
            MISSING=$((MISSING+1))
          fi
          ;;
      esac
    done <<< "$WATCH"
    [ "$MISSING" -eq 0 ] && printf '  Watch-list paths all resolve\n'
  else
    printf '  No watch-list section in house-map\n'
  fi
else
  printf '  No house-map yet (run /maude:found) — skipped\n'
fi

# ─── Check 7: Worn-framings (project-configurable) ───────────────────
printf '\n## Worn-framing scan\n'
WORN_FILE=".maude/plugin/worn-framings.txt"
if [ -f "$WORN_FILE" ]; then
  WORN_HITS=0
  while IFS= read -r phrase; do
    [ -z "$phrase" ] && continue
    case "$phrase" in '#'*) continue;; esac
    # `worktrees` excluded like every other selector here: a phrase in another branch's
    # checkout is not this tree's finding. This scan kept its tree-wide walk when the others
    # were narrowed because it is inert until a project writes worn-framings.txt, so nothing
    # ever ran it. A check that cannot fire looks exactly like a check that passed.
    HITS=$(grep -rln "$phrase" . --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache \
             --exclude-dir=worktrees 2>/dev/null | grep -v "^./$WORN_FILE\$" | grep -v "^./CHANGELOG.md\$")
    if [ -n "$HITS" ]; then
      while IFS= read -r f; do
        emit "Worn framing in $f: '$phrase'"
        WORN_HITS=$((WORN_HITS+1))
      done <<< "$HITS"
    fi
  done < "$WORN_FILE"
  [ "$WORN_HITS" -eq 0 ] && printf '  No worn-framing hits (against %s)\n' "$WORN_FILE"
else
  printf '  No %s — skipped (create one to scan project-specific phrases)\n' "$WORN_FILE"
fi

# ─── Check 8: Command-reference integrity ────────────────────────────
# The recurring miss: a command is cut, but a /maude:<name> reference lingers in
# the doc surface (README / SKILL / agent). Every referenced command must have a
# commands/<name>.md. CHANGELOG is excluded (history legitimately names old cmds).
printf '\n## Command-reference integrity\n'
if [ -d commands ]; then
  REF_FILES=""
  for rf in README.md skills/maude/SKILL.md agents/maude.md; do
    [ -f "$rf" ] && REF_FILES="$REF_FILES $rf"
  done
  DANGLING=0
  if [ -n "$REF_FILES" ]; then
    # shellcheck disable=SC2086  # intentional word-split of REF_FILES into grep args
    REFS=$(grep -rhoE '/maude:[a-z][a-z-]*' $REF_FILES 2>/dev/null | sed 's|/maude:||' | sort -u)
    for name in $REFS; do
      if [ ! -f "commands/$name.md" ]; then
        emit "Doc references /maude:$name but commands/$name.md does not exist (cut-command straggler?)"
        DANGLING=$((DANGLING + 1))
      fi
    done
  fi
  [ "$DANGLING" -eq 0 ] && printf '  All /maude:<cmd> references resolve to a command file\n'
else
  printf '  No commands/ dir — skipped\n'
fi

# ─── Check 9: Design rules ────────────────────────────────────────────
printf '\n## Design rules\n'
# An EXECUTE probe, not a presence test: the Windows Store alias stub and a macOS
# without Command Line Tools both answer `command -v` and then die at the call site.
if maude_python3_ok && [ -d "$DIR/../maude_rules" ]; then
  SQL_COUNT=0
  TABLE_COUNT=0
  # The name exclusions in the find below mirror rules_is_fixture in the rail: tests/ and
  # fixtures/ AND the names test_*, *_test.*, *.spec.*. A fixture schema beside real code
  # was a finding on this side of the house and not on the other.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SQL_COUNT=$((SQL_COUNT + 1))
    # `python3 -m` prepends the CWD to sys.path ahead of PYTHONPATH, and this runs
    # from the audited project, so a project carrying its own maude_rules/ would be
    # the linter verify runs, and a stdout ending in ": clean" would read as a pass.
    # Two belts: PYTHONSAFEPATH=1 drops the implicit CWD entry (python 3.11+), and
    # the interpreter is launched from the plugin root, which needs an ABSOLUTE path
    # because `find .` here yields ./x.sql relative to the project.
    ABS="$PWD/${f#./}"
    RAW="$(cd "$DIR/.." 2>/dev/null && PYTHONSAFEPATH=1 PYTHONPATH="$DIR/.." python3 -m maude_rules schema --brief "$ABS" 2>/dev/null)"
    RC=$?
    # Non-zero AND silent means the linter never spoke: a dead interpreter, an import
    # that blew up, a cd that failed. Reading that as a clean file is the silent-pass
    # this check exists to prevent, so it is a finding of its own. Non-zero WITH output
    # is the normal shape: the CLI exits 1 whenever it found something.
    if [ "$RC" -ne 0 ] && [ -z "$RAW" ]; then
      emit "SCHEMA-LINT FAILED: $f (the linter returned $RC and said nothing)"
      continue
    fi
    LINE="${RAW%%$'\n'*}"
    [ -n "$LINE" ] && LINE="$f: ${LINE#"$ABS": }"
    case "$LINE" in *": clean"|*": no CREATE TABLE found"|"") ;; *) emit "SCHEMA: $LINE" ;; esac
    # How many tables the linter actually READ. "3 schema files linted" says nothing
    # about what was looked at: a file of ALTERs and a file of tables both count as one
    # file, and only this number tells them apart.
    N="$(cd "$DIR/.." 2>/dev/null && PYTHONSAFEPATH=1 PYTHONPATH="$DIR/.." python3 -m maude_rules schema --count "$ABS" 2>/dev/null)"
    N="${N##*: }"; N="${N%% table*}"
    case "$N" in ''|*[!0-9]*) N=0 ;; esac
    TABLE_COUNT=$((TABLE_COUNT + N))
  done <<EOF_SQL
$(find . -name '*.sql' -not -path './.git/*' -not -path '*/tests/*' -not -path '*/fixtures/*' -not -path './.maude/*' -not -path './node_modules/*' -not -path '*/worktrees/*' -not -name 'test_*' -not -name '*_test.*' -not -name '*.spec.*' 2>/dev/null)
EOF_SQL
  printf '  %d tables in %d schema files linted\n' "$TABLE_COUNT" "$SQL_COUNT"
else
  printf '  python3 or maude_rules not available: schema lint skipped\n'
fi
if command -v jq >/dev/null 2>&1 && [ -f .maude/plugin/care.json ]; then
  # An unnamed class is THIS session's business. care.json holds every sid that has
  # worked in this tree, so counting all of them let a sibling lane's UI edit jam a
  # run that had touched nothing, and a release run, which carries no session
  # context at all, could be jammed by every lane at once. So: with a session id,
  # only that sid is a finding; every other sid, and every sid when there is no
  # session id, is an informational `note:` line that is printed and not counted.
  MY_SID="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | cut -c1-8)"
  UNNAMED="$(jq -r --arg mine "$MY_SID" '(.rules // {}) | to_entries[] | .key as $s | .value as $v
    | (["ui","schema","memory"][] | . as $c | ($v.touched[$c] // [] | length) as $n
       | select($n > 0 and (($v.named[$c].ts // "") == ""))
       | if $mine != "" and $s == $mine
         then "UNNAMED: \($c) touched (\($n) file(s)) and no design names a law (session \($s))"
         else "note: \($c) touched (\($n) file(s)) and unnamed in another session (\($s))"
         end)' .maude/plugin/care.json 2>/dev/null)"
  if [ -n "$UNNAMED" ]; then
    while IFS= read -r u; do
      case "$u" in
        "") ;;
        note:*) printf '  %s\n' "$u" ;;
        *) emit "$u" ;;
      esac
    done <<EOF_U
$UNNAMED
EOF_U
  else
    printf '  No touched class is unnamed\n'
  fi
else
  printf '  No care.json: session classes skipped\n'
fi

# ─── Summary ─────────────────────────────────────────────────────────
printf '\n%s\n' "----------------------------------------"
printf '%d findings\n' "$FINDINGS"
[ "$FINDINGS" -eq 0 ] && exit 0 || exit 1
