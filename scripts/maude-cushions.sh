#!/usr/bin/env bash
# Maude cushions — the cushion-flip: find CHANGE that fell where no sensor
# watches. Her hooks watch actions; her sweep empties her own dustpan; the
# house-walk maps rooms. None of them reach INTO the cushions — the places
# value hides: work committed but never pushed, files changed but never
# committed, repos that exist nowhere else, scratch that aged past memory.
#
# This script REPORTS value candidates. It never deletes, never commits,
# never pushes — the trash decision stays human.
#
# Parked change: a `.parked` file (in a repo root or a scratch dir) lists
# paths that are deliberately in the cushion — one per line, optionally
# `path — reason`. A single `.` parks the whole repo/dir. Parked items are
# shown separately and never counted as findings, so a deliberate park is
# named once instead of re-flagged forever.
#
# Output: structured report. Last line: "N value candidates". Exit 0 always
# (a report, not a gate).
#
# Usage: maude-cushions.sh [project_dir]
#   project_dir defaults to $CLAUDE_PROJECT_DIR or pwd.
#   MAUDE_CUSHION_DAYS  — scratch age threshold in days (default 14)

set +e

PROJ="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
cd "$PROJ" || { echo "cushions: cannot cd to $PROJ" >&2; exit 1; }
DAYS="${MAUDE_CUSHION_DAYS:-14}"

CANDIDATES=0
PARKED_LINES=""

emit()   { printf '  %s\n' "$1"; CANDIDATES=$((CANDIDATES + 1)); }
park()   { PARKED_LINES="${PARKED_LINES}  ${1}
"; }

# Read .parked entries for a dir. Prints one entry (path part only) per line.
parked_entries() {
  local pfile="$1/.parked"
  [ -f "$pfile" ] || return 0
  # Strip an optional " — reason" tail and surrounding whitespace; skip
  # comments and blanks. (em-dash or double-hyphen accepted.)
  sed -e 's/[[:space:]]*—.*$//' -e 's/[[:space:]]*--.*$//' \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$pfile" 2>/dev/null \
    | grep -v -E '^(#|$)'
}

# Is relative path $2 covered by an entry for dir $1? ("." parks everything.)
is_parked() {
  local dir="$1" rel="$2" e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$e" = "." ] && return 0
    case "$rel" in "$e"|"$e"/*) return 0 ;; esac
  done < <(parked_entries "$dir")
  return 1
}

printf 'Maude cushions: %s\n' "$PROJ"
printf '%s\n' "----------------------------------------"

# ─── Cushion 1: git repos — uncommitted, unpushed, local-only ────────
printf '\n## Repos\n'
REPO_COUNT=0
while IFS= read -r gitdir; do
  repo="$(dirname "$gitdir")"
  rel_repo="${repo#"$PROJ"/}"; [ "$repo" = "$PROJ" ] && rel_repo="."
  REPO_COUNT=$((REPO_COUNT + 1))

  if is_parked "$repo" "."; then
    park "$rel_repo — whole repo parked"
    continue
  fi

  # Uncommitted change, minus per-file parks.
  unc=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line:3}"; f="${f#\"}"; f="${f%\"}"
    [ "$(basename "$f")" = ".parked" ] && continue   # the marker is not the change
    is_parked "$repo" "$f" && { park "$rel_repo/$f"; continue; }
    unc=$((unc + 1))
  done < <(git -C "$repo" status --porcelain 2>/dev/null)

  # Commits on no remote anywhere: unpushed if a remote exists, local-only
  # (sole-copy risk) if none does.
  if [ -n "$(git -C "$repo" remote 2>/dev/null)" ]; then
    unp="$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
    [ "$unp" -gt 0 ] && emit "$rel_repo — $unp unpushed commit(s)"
  else
    n="$(git -C "$repo" rev-list --all --count 2>/dev/null | tr -d ' ')"
    [ "${n:-0}" -gt 0 ] && emit "$rel_repo — LOCAL-ONLY repo ($n commits exist nowhere else)"
  fi
  [ "$unc" -gt 0 ] && emit "$rel_repo — $unc uncommitted file(s)"
done < <(find "$PROJ" -maxdepth 4 -type d -name .git -not -path '*/.git/*' 2>/dev/null | sort)
printf '  %d repo(s) checked\n' "$REPO_COUNT"

# ─── Cushion 2: aging scratch — old enough to be forgotten, big enough to matter ──
printf '\n## Aging scratch (>%sd old, >512B)\n' "$DAYS"
SCRATCH_COUNT=0
while IFS= read -r sdir; do
  while IFS= read -r f; do
    rel="${f#"$sdir"/}"
    if is_parked "$sdir" "$rel"; then park "${f#"$PROJ"/}"; continue; fi
    SCRATCH_COUNT=$((SCRATCH_COUNT + 1))
    [ "$SCRATCH_COUNT" -le 20 ] && emit "${f#"$PROJ"/}"
  done < <(find "$sdir" -type f -mtime +"$DAYS" -size +512c -not -name '.parked' 2>/dev/null | sort)
done < <(find "$PROJ" -maxdepth 3 -type d \( -name '.scratch' -o -name 'scratch' \) -not -path '*/.git/*' 2>/dev/null | sort)
[ "$SCRATCH_COUNT" -gt 20 ] && printf '  … and %d more (listing capped, all counted)\n' "$((SCRATCH_COUNT - 20))" && CANDIDATES=$((CANDIDATES + SCRATCH_COUNT - 20))
printf '  %d aging scratch file(s)\n' "$SCRATCH_COUNT"

# ─── Parked (by design) — named once, never re-flagged ───────────────
printf '\n## Parked (by design)\n'
if [ -n "$PARKED_LINES" ]; then
  printf '%s' "$PARKED_LINES"
else
  printf '  none marked — a .parked file (repo root or scratch dir) names deliberate change\n'
fi

printf '\n%s\n' "----------------------------------------"
printf '%d value candidates\n' "$CANDIDATES"
exit 0
