#!/usr/bin/env bash
# Maude now-write — the one writer of the live buffer (now.md).
#
# now.md holds exactly ONE block: the latest digest. Its history is the daily
# (today-<date>.md) and recent.md, which are written FIRST, so a crash between the
# steps leaves the block in history and the old buffer in place, never neither.
#
# Earned 2026-10-06: the write lived as prose in three places (save.md "overwrite",
# rest.md "append a ## Tomorrow block", the hooks "append-only, newest is the LAST
# header"), each lane did what it had read, and one buffer grew to 496 KB with its
# timed blocks in both orders; the wake greeted a day-old one. One script, called by
# every command that writes the buffer, is the contract.
#
# Usage: <digest> | maude-now-write.sh
#   The digest's FIRST line must be "## HH:MM ..." — the shape the session-start
#   hook reads as "Anthropic now" — and it must be the ONLY such line, since the hook
#   reads the last one. Anything else is refused before a file moves.
#   A "## Tomorrow" section travels inside the digest, not as a second write.
#
# The old buffer: unless its whole text already sits, as one contiguous run of lines,
# in some today-*.md (the archive counts), it is appended WHOLE to
# today-<date>-now-archive.md and checked byte-for-byte before it is replaced.
#
# Env: MAUDE_MEM_DIR_OVERRIDE (via maude_mem_dir) points at a fixture dir in tests.
# Exit: 0 written and read back; 1 a write or readback failed; 2 empty or
#       unreadable digest; 3 memory dir absent (never created here).

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # computed path, load guarded
. "$DIR/../hooks/scripts/_maude-common.sh" || { echo "now-write: common lib missing" >&2; exit 1; }

HEADER_RE='^## [0-9]{2}:[0-9]{2}'   # the session-start reader's regex; keep them one

MEM="$(maude_mem_dir)"
[ -d "$MEM" ] || { echo "now-write: memory dir absent: $MEM (not created)" >&2; exit 3; }

DIGEST="$(cat)"
HEADER="$(printf '%s\n' "$DIGEST" | head -1)"
if [ -z "$DIGEST" ] || ! printf '%s\n' "$HEADER" | grep -qE "$HEADER_RE"; then
  echo "now-write: the first line must be '## HH:MM | <topic>' (got: ${HEADER:-<empty>}); nothing written" >&2
  exit 2
fi
# The wake reads the LAST timed header, so a second one in the body would be greeted in
# place of this one. Refuse it here, before any file moves (lens 1: it was caught only at
# readback, after the daily, recent.md and now.md were all written).
if [ "$(printf '%s\n' "$DIGEST" | grep -cE "$HEADER_RE")" != "1" ]; then
  echo "now-write: the digest holds more than one '## HH:MM' line; the wake would read the last. Nothing written" >&2
  exit 2
fi

NOW="$MEM/now.md"
TODAY="$(date +%Y-%m-%d)"
DAILY="$MEM/today-$TODAY.md"
ARCH="$MEM/today-$TODAY-now-archive.md"
NOTE=""

# in_daily <file>: 0 when the WHOLE text of <file> appears as one contiguous, line-aligned
# run in some daily. A header match vouched for bodies it never saw (lens 1: a "## Tomorrow"
# tail, a body edited after its daily copy, the same header on another day); a substring
# match let "b" be kept by the daily line "ab" (lens 2). ONE awk pass over every daily,
# lines held in arrays: one call per daily re-read a 496 KB buffer 160 times and took
# 50-70 s on this box's real store (lens 3), and string concatenation is quadratic in
# one-true-awk. Any awk failure exits non-zero, which reads as "not kept": archive.
in_daily() {
  set -- "$1" "$MEM"/today-*.md
  [ -f "$2" ] || return 1
  awk '
    function held(   i, j) {
      for (i = 1; i <= m - k + 1; i++) {
        if (h[i] != n[1]) continue
        for (j = 2; j <= k && h[i + j - 1] == n[j]; j++) ;
        if (j > k) return 1
      }
      return 0
    }
    NR == FNR { n[++k] = $0; next }
    FNR == 1  { if (m && held()) { found = 1; exit } m = 0 }
              { h[++m] = $0 }
    END       { if (!found && k && m && held()) found = 1; exit !found }
  ' "$@"
}

# 1. Keep whatever the buffer holds that lives nowhere else.
if [ -s "$NOW" ]; then
  KEPT=0
  in_daily "$NOW" && KEPT=1
  if [ "$KEPT" -eq 0 ]; then
    OLD_BYTES="$(wc -c < "$NOW" | tr -d ' ')"
    if ! { printf '\n<!-- now.md archived %s before its first one-block write -->\n' \
             "$(date -u +%Y-%m-%dT%H:%MZ)"; cat "$NOW"; } >> "$ARCH" \
       || ! tail -c "$OLD_BYTES" "$ARCH" | cmp -s - "$NOW"; then
      echo "now-write: archiving the old buffer to $ARCH failed; now.md untouched" >&2
      exit 1
    fi
    NOTE=" (old buffer archived to $(basename "$ARCH"))"
  fi
fi

# 2. History first: the daily and recent.md.
SEP=""; [ -s "$DAILY" ] && SEP=$'\n'
if ! printf '%s%s\n' "$SEP" "$DIGEST" >> "$DAILY" \
   || ! printf '%s\n' "$HEADER" >> "$MEM/recent.md"; then
  echo "now-write: appending history failed; now.md untouched" >&2
  exit 1
fi

# 3. Replace the buffer: a sibling temp (same filesystem, so mv is a rename; never
#    $TMPDIR) and a checked mv.
TMP="$(mktemp "$MEM/.now.md.XXXXXX")" || { echo "now-write: mktemp in $MEM failed" >&2; exit 1; }
if ! { printf '%s\n' "$DIGEST" > "$TMP" && mv -f "$TMP" "$NOW"; }; then
  rm -f "$TMP"
  echo "now-write: replacing now.md failed" >&2
  exit 1
fi

# 4. Read back through the reader's own lens.
LANDED="$(grep -E "$HEADER_RE" "$NOW" | tail -1)"
if [ "$LANDED" != "$HEADER" ]; then
  echo "now-write: readback mismatch (wanted: $HEADER, read: ${LANDED:-<none>})" >&2
  exit 1
fi
printf 'now.md: %s%s\n' "$LANDED" "$NOTE"
