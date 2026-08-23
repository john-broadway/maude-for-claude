#!/usr/bin/env bash
# maude-receipts.sh — the measured table (issue #43): what she caught, counted
# honestly, from her own records. Ponytail's practice, adopted as law:
#   - stated window, stated method, one workspace, self-reported
#   - friction (push-clears, verify flags) NEVER counts as value
#   - no percentages: there is no honest denominator for disasters that
#     did not happen
#   - counts, never content: payloads are read only to classify, never shown
#   - READ-ONLY: unlike the catch-digest, receipts advance no watermark and
#     write nothing anywhere
#
# Usage: maude-receipts.sh [--days N]   (default: the whole trace)
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/../hooks/scripts/_maude-common.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'receipts: jq is required to count the trace — install jq and re-run.\n'
  exit 0
}

DAYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || { printf 'receipts: missing value for --days\n' >&2; exit 1; }
            DAYS="$2"; shift 2 ;;
    *) printf 'usage: maude-receipts.sh [--days N]\n' >&2; exit 1 ;;
  esac
done

SELF="$(maude_self_dir)"
TDIR="$SELF/trace"
LEDGER="$SELF/chores.json"
[ -d "$TDIR" ] || { printf 'receipts: no trace yet — nothing to count.\n'; exit 0; }

CUTOFF=""
if [ -n "$DAYS" ]; then
  case "$DAYS" in (''|*[!0-9]*) printf 'receipts: --days wants a number\n' >&2; exit 1 ;; esac
  DAYS="$((10#$DAYS))"   # force decimal: bash reads 010 as octal in arithmetic
  CUTOFF_ISO="$(maude_epoch_iso "$(( $(date +%s) - DAYS * 86400 ))")" || CUTOFF_ISO=""
  CUTOFF="${CUTOFF_ISO%%T*}"
fi

FILES=()
MIN_D="" MAX_D=""
for f in "$TDIR"/today-*.jsonl; do
  [ -e "$f" ] || continue
  d="${f##*/today-}"; d="${d%.jsonl}"
  if [ -n "$CUTOFF" ] && [ "$d" \< "$CUTOFF" ]; then continue; fi
  FILES+=("$f")
  [ -z "$MIN_D" ] || [ "$d" \< "$MIN_D" ] && MIN_D="$d"
  [ -z "$MAX_D" ] || [ "$d" \> "$MAX_D" ] && MAX_D="$d"
done

printf '# Maude — measured receipts\n\n'
if [ "${#FILES[@]}" -eq 0 ]; then
  printf 'Window: empty — no trace day-files%s.\n' "${CUTOFF:+ in the last $DAYS days}"
else
  printf 'Window: %s -> %s (%s trace day-file(s); one workspace; self-reported by the machinery being measured)\n\n' \
    "$MIN_D" "$MAX_D" "${#FILES[@]}"

  # -R + fromjson?: a half-flushed corrupt line must never blind the table —
  # it is skipped, COUNTED, and stated (the codebase's own JSONL guard rule).
  TOTAL_LINES="$(cat "${FILES[@]}" 2>/dev/null | wc -l | tr -d ' ')"
  cat "${FILES[@]}" 2>/dev/null | jq -rRn --argjson total "${TOTAL_LINES:-0}" '
    [inputs | fromjson? | objects] as $ev
    | ($total - ($ev|length)) as $malformed
    | ( [ $ev[] | select(.kind=="gate"
                         and ((.payload // "")|startswith("blocked="))
                         and (((.payload // "")|test("git-push"))|not)) ] ) as $blocks
    | ( [ $blocks[] | select((.payload // "")|test("rm-rf-sole-copy")) ]|length ) as $saves
    | ( ($blocks|length) - $saves ) as $otherblocks
    | ( [ $ev[] | select(.kind=="infra-gate" and ((.payload // "")|test("blocked"))) ]|length ) as $infra
    | ( [ $ev[] | select(.kind=="gate-clear-refused") ]|length ) as $redrefused
    | ( [ $ev[] | select(.kind=="drift") ]|length ) as $drift
    | ( [ $ev[] | select(.kind=="eye") ]|length ) as $staleeye
    | ( [ $ev[] | select(.kind=="gate-cleared" and ((.payload // "")|test("git-push"))) ]|length ) as $pushclears
    # Only WHISPERS are flags. kind=="verify" also carries routine success
    # stamps and stamp-failure bookkeeping — counting those as "flags"
    # inflated the number ~10x on real data (~5,100 vs ~525; review finding
    # #1 — the original comment overstated this as ~1000x). And the
    # two whisper classes are NOT the same shape: a commit-whisper is one
    # distinct act (a commit that landed unverified); a stop-whisper fires
    # per TURN while a session merely sits in an unverified state — the same
    # condition re-observed, so it lives behind the fence.
    | ( [ $ev[] | select(.kind=="verify" and ((.payload // "")|test("commit-without-verify"))) ]|length ) as $vcommit
    | ( [ $ev[] | select(.kind=="verify" and ((.payload // "")|test("stop-without-verify"))) ]|length ) as $vstop
    # Freshen events carry counts in the payload (stale=N checkfailed=N) —
    # sum the caught-drift counts across runs; counts, never claim content.
    | ( [ $ev[] | select(.kind=="freshen")
        | (.payload // "") | capture("stale=(?<s>[0-9]+)").s | tonumber ] | add // 0 ) as $freshstale
    | ( [ $ev[] | select(.kind=="freshen")
        | (.payload // "") | capture("checkfailed=(?<c>[0-9]+)").c | tonumber ] | add // 0 ) as $freshbroken
    | "| what she caught | count | reading it honestly |",
      "|---|---|---|",
      "| sole-copy saves | \($saves) | rm -rf aimed at a sole-copy path, blocked before it fired |",
      "| infra blocks | \($infra) | destructive op on co-managed infrastructure, blocked |",
      "| other gate blocks | \($otherblocks) | red/yellow-key commands stopped pending a conscience check |",
      "| red-key clear refusals | \($redrefused) | attempts to self-clear a red key, refused (that clear is a human hand by design) |",
      "| drift catches | \($drift) | repeated-action drift, nudged at the moment it fired |",
      "| commit-without-verify whispers | \($vcommit) | one per commit that landed with unverified code — distinct acts |",
      "| stale vault claims caught (freshen) | \($freshstale) | a memory claim about live state that no longer matched the world when re-checked |",
      "| broken freshen probes | \($freshbroken) | verify commands that errored or timed out — the probe needs fixing, loud by design |",
      "| friction and bookkeeping (not value) | | |",
      "| push-clears | \($pushclears) | routine git-push toll booth; counted separately BY RULE — never a save |",
      "| stop-without-verify whispers | \($vstop) | re-observed per TURN while a session sat unverified — repetition, NOT distinct catches |",
      "| stale whispers dropped | \($staleeye) | eye output past its TTL, discarded UNSHOWN — hygiene, not a catch |",
      (if $malformed > 0
       then "| malformed trace lines skipped | \($malformed) | unparseable records excluded from every count above — the gap is stated, not hidden |"
       else empty end)
  '

  # #49: the cost column — she publishes her own bill next to her catches.
  # Spend entries are metadata (hook class + bytes); tokens are DERIVED here
  # (bytes/4, marked approximate) and never stored. Savings stay event counts
  # above — the no-denominator law extends: we never print "N tokens saved."
  COST="$(cat "${FILES[@]}" 2>/dev/null | jq -rRn '
    [inputs | fromjson? | objects
     | select(.kind=="spend")
     | (.payload // "") | capture("hook=(?<h>[a-z-]+) bytes=(?<b>[0-9]+)")] as $sp
    | if ($sp|length) == 0 then "" else
      ( $sp | group_by(.h)
        | map({h: .[0].h, n: length, bytes: (map(.b|tonumber)|add)})
        | sort_by(-.bytes)
        | ["", "| what she cost (injected context) | events | bytes | ~tokens (bytes/4, approximate) |",
           "|---|---|---|---|"]
          + map("| \(.h) | \(.n) | \(.bytes) | ~\((.bytes/4)|floor) |")
        | join("\n") )
      end
  ')"
  [ -n "$COST" ] && printf '%s\n' "$COST"
fi

if [ -f "$LEDGER" ]; then
  printf '\nChores (from the ledger): %s\n' "$(jq -r '
    [ to_entries[] | .value.status ] as $s
    | ([ $s[] | select(.=="done") ]|length | tostring) + " done, "
      + ([ $s[] | select(.=="undone") ]|length | tostring) + " undone, "
      + ([ $s[] | select(.=="failed") ]|length | tostring) + " failed; cost stamps: "
      + ([ to_entries[] | .value.cost.model // "none" ] | group_by(.)
         | map("\(.[0]):\(length)") | join(", "))
  ' "$LEDGER" 2>/dev/null)"
fi

cat <<'METHOD'

Method: counts derive from .maude/plugin/trace/*.jsonl event metadata (kind +
short flags — the trace stores no content by design) and chores.json, on this
one workspace, self-reported by the same machinery being measured. Counts are
EVENTS, not unique incidents — one stubborn command retried three times logs
three blocks; the records don't dedup and neither does this table. There are
no percentages here: a rate needs a denominator, and there is no honest
denominator for disasters that did not happen. A push-clear is friction a
session paid at the toll booth, not a disaster avoided — it never counts as
value. The measure of a protector is the disaster that didn't happen; these
are the ones the records can actually testify to.
The cost table (when present) counts what her instrumented hook classes
injected — page, session-start, mission-hold, watch-list, eye-whisper,
drift-whisper — in bytes, with tokens derived as bytes/4 and marked
approximate. Savings are never converted to tokens: drift-stops and
dispatch-downgrades stay event counts above, because a saved-token number
has no honest denominator. Judging a garment's cost-per-catch stays a human read
over these two columns — report-first, the human decides.
METHOD
