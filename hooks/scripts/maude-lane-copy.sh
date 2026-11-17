#!/usr/bin/env bash
# Maude lane copy: one rolling copy of each lane at rest, and a wake line when a lane
# shrank since then.
#
#   keep   (SessionEnd)   copy each lane file (now.md, now_<name>.md in the project's
#                         memory dir) to ~/.claude/maude/pile/lanes/<slug>/<name>, only
#                         when its bytes changed. One copy per lane, never a dated file.
#                         A lane more than SHRINK bytes shorter than its copy is NOT
#                         copied: one rest must not launder a loss into the copy.
#   check  (SessionStart) print one signed line per lane more than SHRINK bytes shorter
#                         than its copy, naming the copy. Silent otherwise.
#
# Restore is phase 3. Design: docs/specs/2026-11-11-the-circle-design.md (heal checks).

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

SHRINK=512
MODE="${1:-}"
MEM="$(maude_mem_dir)"
[ -d "$MEM" ] || exit 0
PILE="$(maude_user_dir)/pile/lanes/$(maude_slug)"

bytes() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# now.md is NOT watched in phase 1: scripts/maude-now-write.sh replaces it whole by
# design (it archives the old buffer first), so a shrink there is routine, not a loss.
# Phase 3 makes it prepend-and-keep and brings it in. (Review, 2026-11-12.)
# check walks the copies too, so a lane deleted outright is named.
for f in "$MEM"/now_*.md "$PILE"/now_*.md; do
  name="${f##*/}"
  case "$name" in now_\*.md) continue ;; esac
  [ "$f" = "$PILE/$name" ] && [ -e "$MEM/$name" ] && continue   # seen via the live file
  copy="$PILE/$name"
  if [ ! -f "$MEM/$name" ]; then
    if [ "$MODE" = "check" ] && [ -f "$copy" ]; then
      printf 'Maude: %s is gone from the memory dir. The copy from the last rest is %s.\n' "$name" "$copy"
    fi
    continue
  fi
  f="$MEM/$name"
  case "$MODE" in
    keep)
      if [ -f "$copy" ]; then
        cmp -s "$f" "$copy" && continue
        [ "$(bytes "$f")" -lt "$(( $(bytes "$copy") - SHRINK ))" ] && continue
      fi
      (umask 077; mkdir -p "$PILE") || continue
      chmod 700 "$PILE" 2>/dev/null
      tmp="$copy.tmp.$$"
      cp -p "$f" "$tmp" 2>/dev/null && mv -f "$tmp" "$copy" 2>/dev/null || rm -f "$tmp"
      ;;
    check)
      [ -f "$copy" ] || continue
      have="$(bytes "$f")"; was="$(bytes "$copy")"
      if [ "${have:-0}" -lt "$(( ${was:-0} - SHRINK ))" ]; then
        printf 'Maude: %s is %s bytes shorter than at the last rest. The copy from then is %s.\n' \
          "$name" "$(( was - have ))" "$copy"
      fi
      ;;
  esac
done
exit 0
