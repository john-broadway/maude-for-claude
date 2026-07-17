#!/usr/bin/env bash
# tests/test-portability.sh — issue #39: macOS/BSD portability.
#
# Two layers:
#   1. Behavioral: maude_mtime / maude_date_epoch shims work on the GNU path
#      AND on the BSD path — the BSD branch is exercised on Linux by shadowing
#      stat/date with wrappers that reject GNU flags and speak BSD ones (same
#      PATH-injection pattern as make_nojq_bin). touch_ago/touch_at prove the
#      test harness itself carries no GNU-isms.
#   2. Lint: no GNU-only construct may appear in product code outside a line
#      tagged `# portability-shim`, and no `touch -d` in tests/. This is the
#      audit issue #39 asked for, made permanent — a regression guard, not a
#      one-time grep. (Patterns below use [-] bracket tricks so this file
#      never matches its own lint.)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
source_common

# setup_test_env's hermetic guard unsets every MAUDE_* var — including
# lib.sh's MAUDE_ROOT — so re-derive the repo root locally for the lint scans.
ROOT="$(cd "$DIR/.." && pwd)"
NOW_EPOCH="$(date +%s)"

test_start "portability helpers are defined"
if type maude_mtime >/dev/null 2>&1 && type maude_date_epoch >/dev/null 2>&1 \
   && type touch_ago >/dev/null 2>&1 && type touch_at >/dev/null 2>&1; then
  _pass
else
  _fail "missing: $(for h in maude_mtime maude_date_epoch touch_ago touch_at; do type "$h" >/dev/null 2>&1 || printf '%s ' "$h"; done)"
fi

# ── Fake BSD userland: stat rejects -c and answers -f %m; date rejects -d
# and answers -j -f. Wrappers delegate to the real GNU tools underneath so
# answers stay correct — only the FLAG DIALECT is BSD.
REAL_STAT="$(command -v stat)"
REAL_DATE="$(command -v date)"
BSD_BIN="$(mktemp -d)"
cat > "$BSD_BIN/stat" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ]; then echo "stat: illegal option -- c" >&2; exit 1; fi
if [ "\$1" = "-f" ] && [ "\$2" = "%m" ]; then exec "$REAL_STAT" -c %Y "\$3"; fi
echo "stat: unsupported invocation: \$*" >&2; exit 1
EOF
cat > "$BSD_BIN/date" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-d" ]; then echo "date: illegal option -- d" >&2; exit 1; fi
done
if [ "\$1" = "-j" ] && [ "\$2" = "-f" ]; then
  # BSD: date -j -f FMT VALUE +OUT  →  GNU: date -d VALUE +OUT
  exec "$REAL_DATE" -d "\$4" "\$5"
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$BSD_BIN/stat" "$BSD_BIN/date"

# ── maude_mtime: GNU path ───────────────────────────────────────────────
test_start "maude_mtime returns epoch mtime (GNU path)"
F="$TEST_TMP/mtime-probe"
: > "$F"
M="$(maude_mtime "$F")"
if [ -n "$M" ] && [ "$M" -ge $((NOW_EPOCH - 5)) ] && [ "$M" -le $((NOW_EPOCH + 5)) ]; then
  _pass
else
  _fail "expected epoch near $NOW_EPOCH, got '$M'"
fi

test_start "maude_mtime missing file → 0"
assert_eq "$(maude_mtime "$TEST_TMP/does-not-exist")" "0" "missing file default"

test_start "maude_mtime missing file → caller default"
assert_eq "$(maude_mtime "$TEST_TMP/does-not-exist" 12345)" "12345" "caller default honored"

# ── maude_mtime: BSD path (fake BSD stat shadows the real one) ──────────
test_start "maude_mtime falls back to BSD stat -f %m"
M="$(PATH="$BSD_BIN:$PATH" bash -c '. "'"$HOOKS_DIR"'/_maude-common.sh"; maude_mtime "'"$F"'"')"
if [ -n "$M" ] && [ "$M" -ge $((NOW_EPOCH - 5)) ] && [ "$M" -le $((NOW_EPOCH + 5)) ]; then
  _pass
else
  _fail "BSD fallback: expected epoch near $NOW_EPOCH, got '$M'"
fi

test_start "maude_mtime BSD path, missing file → default"
M="$(PATH="$BSD_BIN:$PATH" bash -c '. "'"$HOOKS_DIR"'/_maude-common.sh"; maude_mtime "'"$TEST_TMP"'/nope" 777')"
assert_eq "$M" "777" "BSD missing-file default"

# ── maude_date_epoch ────────────────────────────────────────────────────
test_start "maude_date_epoch parses YYYY-MM-DD (GNU path)"
# Expected via python3 (portable + independent of the shell shim under test):
# local midnight, matching both GNU `date -d D` and BSD `-j -f` with T00:00:00.
WANT="$(python3 -c 'import datetime; print(int(datetime.datetime(2026,1,1).timestamp()))')"
assert_eq "$(maude_date_epoch 2026-01-01)" "$WANT" "GNU date parse"

test_start "maude_date_epoch rejects garbage"
E="$(maude_date_epoch not-a-date)"
RC=$?
if [ -z "$E" ] && [ "$RC" -ne 0 ]; then _pass; else _fail "expected empty+nonzero, got '$E' rc=$RC"; fi

test_start "maude_date_epoch rejects empty input"
E="$(maude_date_epoch "")"
RC=$?
if [ -z "$E" ] && [ "$RC" -ne 0 ]; then _pass; else _fail "expected empty+nonzero, got '$E' rc=$RC"; fi

test_start "maude_date_epoch falls back to BSD date -j -f"
E="$(PATH="$BSD_BIN:$PATH" bash -c '. "'"$HOOKS_DIR"'/_maude-common.sh"; maude_date_epoch 2026-01-01')"
assert_eq "$E" "$WANT" "BSD date parse"

# ── touch_ago / touch_at (test-harness portability helpers) ─────────────
test_start "touch_ago sets mtime N seconds back"
G="$TEST_TMP/aged"
touch_ago 600 "$G"
M="$(maude_mtime "$G")"
if [ "$M" -ge $((NOW_EPOCH - 610)) ] && [ "$M" -le $((NOW_EPOCH - 590)) ]; then
  _pass
else
  _fail "expected ~now-600, got '$M' (now=$NOW_EPOCH)"
fi

test_start "touch_ago creates the file if missing"
H="$TEST_TMP/born-aged"
touch_ago 60 "$H"
assert_file_exists "$H" "touch_ago creates"

test_start "touch_ago handles multiple files in one call"
touch_ago 300 "$TEST_TMP/multi1" "$TEST_TMP/multi2"
M1="$(maude_mtime "$TEST_TMP/multi1")"
M2="$(maude_mtime "$TEST_TMP/multi2")"
if [ "$M1" -ge $((NOW_EPOCH - 310)) ] && [ "$M1" -le $((NOW_EPOCH - 290)) ] && [ "$M1" = "$M2" ]; then
  _pass
else
  _fail "expected both ~now-300 and equal, got '$M1' / '$M2'"
fi

test_start "touch_at sets exact epoch mtime"
touch_at 1750000000 "$G"
assert_eq "$(maude_mtime "$G")" "1750000000" "exact epoch"

test_start "touch_at accepts ISO8601 with Z"
touch_at "2026-06-23T12:30:00Z" "$G"
assert_eq "$(maude_mtime "$G")" "1782217800" "ISO8601Z"

# ── Lint: GNU-isms banned from product code ─────────────────────────────
# Product = hooks/scripts/ + scripts/. A line may carry a banned construct
# ONLY if tagged `# portability-shim` (the shim's own GNU branch).
# Comment-only lines are ignored. Bracket tricks keep this file self-clean.
lint_product() {
  grep -rnE "$1" "$ROOT/hooks/scripts" "$ROOT/scripts" --include='*.sh' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -v 'portability-shim'
}

test_start "product: no GNU stat -c outside shim"
V="$(lint_product 'stat [-]c')"
assert_eq "$V" "" "stat -c leaked: $V"

test_start "product: no GNU date -d outside shim"
V="$(lint_product 'date [-]d ')"
assert_eq "$V" "" "date -d leaked: $V"

test_start "product: no GNU sed -i (use sed -i.bak)"
V="$(lint_product 'sed [-]i([^.]|$)')"
assert_eq "$V" "" "GNU sed -i leaked: $V"

test_start "product: no other GNU-only constructs"
V="$(lint_product 'touch [-]d |readlink [-]f|grep [-]P|[-]printf |[^a-z-]tac[^a-z-]|stat [-][-]format|date [-][-]date')"
assert_eq "$V" "" "GNU construct leaked: $V"

test_start "product+tests: no bash-4-only builtins (macOS ships bash 3.2)"
V="$(grep -rnE 'mapfil[e]|readarra[y]|declare [-]A' "$ROOT/hooks/scripts" "$ROOT/scripts" "$ROOT/tests" --include='*.sh' 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v 'portability-shim')"
assert_eq "$V" "" "bash-4 builtin leaked: $V"

test_start "tests: no GNU touch dash-d (use touch_ago/touch_at)"
V="$(grep -rnE 'touch [-]d ' "$ROOT/tests" --include='*.sh' 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
assert_eq "$V" "" "GNU touch in tests: $V"

rm -rf "$BSD_BIN"
teardown_test_env
print_summary
exit "$FAILED"
