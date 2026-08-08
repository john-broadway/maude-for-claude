#!/usr/bin/env bash
# maude-lint.sh — the lint ritual (issue #42): a deliberate entropy-reduction
# pass over the memory vault. Karpathy's missing organ: compaction here was
# size-driven; nothing was quality-driven until this.
#
# Laws (each one a test):
#   - SCOPE FIRST: archives are verbatim by design; letters, dailies and the two
#     rolling logs (now.md, recent.md) are historical — the lint NEVER scans any
#     of them. Targets: the index (MEMORY.md) + live topic files only.
#   - REPORT-FIRST, like the cushion-flip: this script proposes; the human
#     (or the session, with judgment) applies. It writes NOTHING into the
#     memory it lints — value before the dustpan.
#   - RECEIPTS: every pass logs its counts to the trace. Counts, never
#     content.
#
# The mechanical checks live here (links resolve, [[refs]] tally, index size
# vs cap, stale-OPEN candidates, superseded-but-indexed). The judgment checks
# — contradiction, staleness of CLAIMS — belong to the session reading this
# report (/maude:lint carries those instructions).
#
# Usage: maude-lint.sh [--mem-dir DIR]
# Env: MAUDE_LINT_INDEX_CAP (default 100 lines), MAUDE_LINT_STALE_DAYS (30).
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/../hooks/scripts/_maude-common.sh"

MEM="$(maude_mem_dir)"
while [ $# -gt 0 ]; do
  case "$1" in
    --mem-dir) [ $# -ge 2 ] || { printf 'lint: missing value for --mem-dir\n' >&2; exit 1; }
               MEM="$2"; shift 2 ;;
    *) printf 'usage: maude-lint.sh [--mem-dir DIR]\n' >&2; exit 1 ;;
  esac
done

INDEX="$MEM/MEMORY.md"
CAP="${MAUDE_LINT_INDEX_CAP:-100}"
STALE_DAYS="${MAUDE_LINT_STALE_DAYS:-30}"

printf '# Maude — lint report (report-first: proposes, never applies)\n\n'
if [ ! -f "$INDEX" ]; then
  printf 'No MEMORY.md at %s — nothing to lint.\n' "$MEM"
  exit 0
fi

# ── Scope law: live TOPIC files only. Archives verbatim; letters, dailies and the two
# rolling logs historical — excluded before any check runs.
#
# now.md and recent.md are pipeline OUTPUT, not durable notes: now.md is the live buffer
# (appended, periodically compacted to archive_now-precompaction-*) and recent.md is one
# entry per past session. A dead pointer inside either is frozen history that can never
# legitimately be repaired, so reporting them is permanent noise a reader can only ignore
# — which is how a report teaches people to stop reading it. Added 2026-08-06: they were
# the only two of the vault's file classes the original blocklist never named, and 4 of the
# 9 findings that day were unfixable history sitting in recent.md. ──
LIVE=()
for f in "$MEM"/*.md; do
  [ -e "$f" ] || continue
  base="${f##*/}"
  case "$base" in
    MEMORY.md|archive_*|letter*|today-*|now.md|recent.md) continue ;;
  esac
  LIVE+=("$f")
done

# ── Check 1: index links resolve ──
IDX_BROKEN=0
BROKEN_LIST=""
while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in http*|/*) continue ;; esac
  if [ ! -e "$MEM/$target" ]; then
    IDX_BROKEN=$((IDX_BROKEN + 1))
    BROKEN_LIST="${BROKEN_LIST}  - ${target}\n"
  fi
done < <(grep -oE '\]\((\./)?[A-Za-z0-9_.-]+\.md\)' "$INDEX" 2>/dev/null \
         | sed -E 's/^\]\(\.?\/?//; s/\)$//' | sort -u)
printf '## Index links\n'
if [ "$IDX_BROKEN" -gt 0 ]; then
  printf '%d broken (target missing):\n' "$IDX_BROKEN"
  # shellcheck disable=SC2059  # BROKEN_LIST carries its own \n formatting
  printf "$BROKEN_LIST"
else
  printf 'all resolve.\n'
fi

# ── Check 2: [[refs]] tally. An unwritten pointer is NOT an error — it marks
# something worth writing later (house doctrine); the lint counts it so the
# backlog is visible, nothing more. ──
UNWRITTEN=0
UNWRITTEN_LIST=""
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # Exact name first, then the prefix-less house convention: [[foo-bar]] may
  # live on disk as <type>_foo-bar.md (feedback_/project_/reference_/user_/…).
  if [ ! -e "$MEM/$ref.md" ] && ! ls "$MEM"/*_"$ref".md >/dev/null 2>&1; then
    UNWRITTEN=$((UNWRITTEN + 1))
    UNWRITTEN_LIST="${UNWRITTEN_LIST}  - [[${ref}]]\n"
  fi
done < <({ cat "$INDEX"; [ "${#LIVE[@]}" -gt 0 ] && cat "${LIVE[@]}"; } 2>/dev/null \
         | grep -o '\[\[[A-Za-z0-9_.-]*\]\]' | sed 's/^\[\[//; s/\]\]$//' | sort -u)
printf '\n## Unwritten [[pointers]] (worth writing later — not errors)\n'
if [ "$UNWRITTEN" -gt 0 ]; then
  printf '%d pointing at notes that do not exist yet:\n' "$UNWRITTEN"
  # shellcheck disable=SC2059
  printf "$UNWRITTEN_LIST"
else
  printf 'none.\n'
fi

# ── Check 3: index size vs cap ──
IDX_LINES="$(wc -l < "$INDEX" | tr -d ' ')"
printf '\n## Index size\n%s lines (cap %s) — %s\n' "$IDX_LINES" "$CAP" \
  "$([ "$IDX_LINES" -gt "$CAP" ] && printf 'OVER — compaction candidate' || printf 'within cap')"

# ── Check 4: stale-state candidates — live topic files carrying 🔴/OPEN/TODO
# whose file hasn't been touched in STALE_DAYS. Candidates for judgment, not
# verdicts: only a reader can tell settled state from stale state. ──
NOW_EPOCH="$(date +%s)"
STALE_CUTOFF=$(( NOW_EPOCH - STALE_DAYS * 86400 ))
STALE=0
STALE_LIST=""
# "${LIVE[@]}" on an EMPTY array is an unbound reference under set -u on
# bash 3.2 (stock macOS) — every expansion site carries the count guard,
# same as the sibling accumulator arrays in _maude-common.sh and receipts.
if [ "${#LIVE[@]}" -gt 0 ]; then
  for f in "${LIVE[@]}"; do
    n="$(grep -cE '🔴|(^|[^A-Za-z])OPEN([^A-Za-z]|$)|TODO' "$f" 2>/dev/null)"
    [ "${n:-0}" -gt 0 ] || continue
    m="$(maude_mtime "$f")"
    if [ "$m" -gt 0 ] && [ "$m" -lt "$STALE_CUTOFF" ]; then
      STALE=$((STALE + 1))
      STALE_LIST="${STALE_LIST}  - ${f##*/} (${n} open-flag line(s), untouched >${STALE_DAYS}d)\n"
    fi
  done
fi
printf '\n## Stale-state candidates (open flags in files untouched >%sd — judgment is the reader%ss)\n' "$STALE_DAYS" "'"
if [ "$STALE" -gt 0 ]; then
  # shellcheck disable=SC2059
  printf "$STALE_LIST"
else
  printf 'none.\n'
fi

# ── Check 5: superseded-but-indexed — a note whose frontmatter says
# superseded_by: while the index still points at it. The pointer forward
# exists; the index line drifted. ──
SUP=0
SUP_LIST=""
if [ "${#LIVE[@]}" -gt 0 ]; then
  for f in "${LIVE[@]}"; do
    head -10 "$f" 2>/dev/null | grep -q '^superseded_by:' || continue
    base="${f##*/}"
    if grep -qF "$base" "$INDEX" 2>/dev/null; then
      SUP=$((SUP + 1))
      SUP_LIST="${SUP_LIST}  - ${base%.md} (superseded, still in the index)\n"
    fi
  done
fi
printf '\n## Supersession drift (retired notes the index still serves)\n'
if [ "$SUP" -gt 0 ]; then
  # shellcheck disable=SC2059
  printf "$SUP_LIST"
else
  printf 'none.\n'
fi

printf '\n## Scope\n%d live topic file(s) scanned. Archives, letters, dailies, and the rolling logs (now.md, recent.md) excluded by law (verbatim/historical).\n' "${#LIVE[@]}"
printf '\nThe judgment checks — contradictions between notes, stale claims wearing a present tense — are the reader%ss pass over this report (/maude:lint). This script changes nothing.\n' "'"

# ── Receipts: counts, never content ──
maude_log_trace "lint" "index_broken=$IDX_BROKEN unwritten=$UNWRITTEN index_lines=$IDX_LINES stale=$STALE superseded_indexed=$SUP scanned=${#LIVE[@]}"

exit 0
