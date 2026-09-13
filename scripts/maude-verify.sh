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

# ─── Check 4: Header Revised dates within 14 days ────────────────────
printf '\n## Header revised dates\n'
# Env seam (tests): MAUDE_VERIFY_TODAY. Check 4 is otherwise untestable at THIS callsite.
# The old raw-seconds formula and the midnight-anchored one are byte-identical for every
# input in every zone EXCEPT inside a daylight-saving window, and the only integration test
# of this check runs under TZ=UTC, which has no such window. So reverting this callsite left
# all 61 test files green while the helper's own tests stayed happy. A fixed "today" lets a
# test put a real DST transition inside the span and read the day count back.
#
# Colon-guarded on purpose. The first version was not, so an ambient empty value became an
# unresolvable anchor, which made `make verify` exit 2 and took ship.sh's gate down with it:
# any environment exporting the name empty could not release. Empty now means "use today".
TODAY=${MAUDE_VERIFY_TODAY:-$(date +%Y-%m-%d)}
# Because it is ambient, the value can be anything. An anchor this script cannot resolve
# makes maude_days_between fail for EVERY file, so every file is skipped and the run prints
# a clean bill for a check that examined nothing. Measured: MAUDE_VERIFY_TODAY=banana turned
# a 247-day-stale file into 0 findings and exit 0.
if [ -z "$STAMPLIB_MISSING" ] && [ -z "$(maude_date_epoch "$TODAY" 2>/dev/null)" ]; then
  emit "cannot resolve today's date \"$TODAY\" (MAUDE_VERIFY_TODAY?) — revised dates NOT checked"
fi
# A parseable but WRONG date cannot be told from a test's, and a past pin silences this
# check completely: MAUDE_VERIFY_TODAY=2020-01-01 turns a 247-day-stale file into nothing.
# This was a printf first, which was no mitigation at all — release.sh pipes verify through
# `tail -3` and both CI workflows gate on the exit code, so the one line saying the check
# had been switched off was truncated away in the only place it mattered. A FINDING travels:
# non-zero exit, pipefail carries it, the release gate stops.
[ -z "${MAUDE_VERIFY_TODAY:-}" ] || emit "today is pinned to $TODAY by MAUDE_VERIFY_TODAY — staleness measured from a supplied date, not the clock"
STALE_LIMIT_DAYS=14
HDRS=$([ -n "$STAMPLIB_MISSING" ] || grep -rln "Revised:" . --include="*.md" --exclude-dir=.git --exclude-dir=.maude --exclude-dir=.pytest_cache --exclude-dir=worktrees 2>/dev/null)
if [ -n "$HDRS" ]; then
  while IFS= read -r f; do
    # Extract date in YYYY-MM-DD form from the first Revised: line
    # Header block only, for the same reason as the version check above: a date quoted in
    # prose is not this document's Revised date, and reading one as if it were would age a
    # historical plan into a finding on every run.
    REVDATE=$(head -n "$MAUDE_HEADER_LINES" "$f" 2>/dev/null \
              | grep -m1 -oE 'Revised:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    if [ -n "$REVDATE" ]; then
      # 2>/dev/null: if common wasn't sourced (guarded above) this fails open
      # exactly like the old raw-date parse did — empty DAYS, no noise.
      # Midnight to midnight, never "now" minus a stored midnight: the latter is short by
      # an hour across a spring-forward and under-reports the age by a day.
      DAYS=$(maude_days_between "$REVDATE" "$TODAY" 2>/dev/null)
      if [ -n "$DAYS" ]; then
        if [ "$DAYS" -gt "$STALE_LIMIT_DAYS" ]; then
          emit "$f Revised: $REVDATE (${DAYS} days ago — stale)"
        fi
      fi
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
