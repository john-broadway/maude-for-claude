#!/usr/bin/env bash
# tests/test-redclear-join.sh — maude_redclear_join against its oracle.
#
# The join (a backslash-newline or backslash-semicolon continuation joined the way bash
# joins it, only an odd run of backslashes continuing) was a per-character awk loop: 0.45 s
# over a 130 KB view, three times a command, with the hook killed at 5 s (the padding
# bypass, fix/gate-time-budget). It is now linear in the bytes, walking only the backslash
# runs. The old loop is kept HERE as the oracle: every case must join byte for byte the
# same, fixed cases and a seeded random corpus over the characters that matter. The join
# is also idempotent up to a trailing newline (awk's record reader drops one), which is
# what lets maude_redclear_touch join once and hand the fold a joined view.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
source_common

oracle_join() {
  printf '%s' "$1" | LC_ALL=C awk '
    { s = s (NR > 1 ? "\n" : "") $0 }
    END { n = length(s); i = 1; out = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; i++; continue }
        j = i; while (j <= n && substr(s, j, 1) == "\\") j++
        run = j - i; nxt = substr(s, j, 1)
        if (run % 2 == 1 && (nxt == "\n" || nxt == ";")) { out = out substr(s, i, run - 1); i = j + 1 }
        else { out = out substr(s, i, run); i = j }
      }
      printf "%s", out }'
}
bytes() { od -An -c | tr -d ' \n'; }

test_start "the fixed cases join as the oracle joins them"
for c in '' '\\' '\\\\' 'a\\' 'a\\\\' ';' '\\;' '\\\\;' '\\\n' '\\\\\n' 'a\\;b' 'a\\\\;b' 'a\\\\\\;b' \
         '\\\\\\' 'echo \\\\; rm FILE' 'care-red\\\nclear.json' 'a\\;\\;b' 'x\\\\;;y' 'q\\\n\n'; do
  t="$(printf '%b' "$c")"
  assert_eq "$(maude_redclear_join "$t" | bytes)" "$(oracle_join "$t" | bytes)" "join of $(printf '%q' "$t")"
done

test_start "a seeded random corpus joins as the oracle joins it"
n=0; diffs=0; idem=0
while IFS= read -r line; do
  t="$(printf '%b' "$line")"
  a="$(oracle_join "$t" | bytes)"; b="$(maude_redclear_join "$t" | bytes)"
  n=$((n + 1))
  [ "$a" = "$b" ] || { diffs=$((diffs + 1)); [ "$diffs" -le 3 ] && _fail "differs on $(printf '%q' "$t"): oracle=$a join=$b"; }
  j="$(maude_redclear_join "$t")"
  case "$j" in *$'\n') j="${j%$'\n'}" ;; esac
  c="$(maude_redclear_join "$j" | bytes)"
  [ "$(printf '%s' "$j" | bytes)" = "$c" ] || { idem=$((idem + 1)); [ "$idem" -le 3 ] && _fail "not idempotent on $(printf '%q' "$t"): once=$b twice=$c"; }
done < <(python3 -c '
import random
random.seed(7)
al = ["a", "\\\\", "\\\\", "\\\\", ";", "\\n", " ", "\"", "x", ".maude"]
for _ in range(400):
    print("".join(random.choice(al) for _ in range(random.randint(1, 24))))
')
assert_eq "$n" "400" "the corpus was read"
assert_eq "$diffs" "0" "cases that differ from the oracle"
assert_eq "$idem" "0" "cases where a second join changes a joined view (past a trailing newline)"

test_start "a view with no backslash is its own join, and a 130 KB one joins in well under a second"
V="$(printf 'ls;%.0s' $(seq 43000))"
_t0=$EPOCHREALTIME; J="$(maude_redclear_join "$V")"; _ms=$(( (${EPOCHREALTIME/./} - ${_t0/./}) / 1000 ))
assert_eq "${#J}" "${#V}" "same length"
assert_exit "$([ "$_ms" -lt 1000 ] && echo 0 || echo 1)" "0" "joined in ${_ms} ms"

teardown_test_env
print_summary
exit "$FAILED"
