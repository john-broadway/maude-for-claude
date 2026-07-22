#!/usr/bin/env bash
# Tests for hooks/scripts/maude-probe-tier1.sh — local-services liveness probe.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

PROBE="$HOOKS_DIR/maude-probe-tier1.sh"

test_start "probe writes care.json"
bash "$PROBE" >/dev/null 2>&1
assert_file_exists "$(care_path)" "care.json"

test_start "probe records tier1_last_probe timestamp"
ts="$(read_care '.tier1_last_probe')"
NOW=$(date +%s)
[ -n "$ts" ] && [ "$ts" != "null" ] && [ "$NOW" -ge "$ts" ] && [ $((NOW - ts)) -lt 10 ]
assert_exit "$?" "0" "fresh probe ts"

test_start "probe records tier1_up boolean"
up="$(read_care '.tier1_up')"
[ "$up" = "true" ] || [ "$up" = "false" ]
assert_exit "$?" "0" "tier1_up bool"

test_start "probe records tier1_probed key (may be empty if no daemons)"
probed="$(read_care '.tier1_probed')"
# The KEY must exist; the VALUE can be empty string when no endpoints reachable.
# read_care returns "null" only when the field is absent.
[ "$probed" != "null" ]
assert_exit "$?" "0" "tier1_probed key present"

test_start "probe is deterministic — second run still produces valid state"
bash "$PROBE" >/dev/null 2>&1
up="$(read_care '.tier1_up')"
[ "$up" = "true" ] || [ "$up" = "false" ]
assert_exit "$?" "0" "second run valid"

test_start "probe preserves existing care.json fields"
# Set a custom field
TMP="$(mktemp)"
jq '. + {custom_field: "preserved"}' "$(care_path)" > "$TMP" && mv "$TMP" "$(care_path)"
bash "$PROBE" >/dev/null 2>&1
preserved="$(read_care '.custom_field')"
assert_eq "$preserved" "preserved" "custom field kept"

test_start "probe always exits 0"
RC="$(bash "$PROBE" >/dev/null 2>&1; echo $?)"
assert_exit "$RC" "0" "exit"

# ── #45: the kill switch — every autonomous mechanism can be turned off by
# the person whose house it is; the probe was the one that couldn't. ──
test_start "MAUDE_PROBE=off skips the probe entirely (no reachability cache written)"
rm -f "$(care_path)"
RC="$(MAUDE_PROBE=off bash "$PROBE" >/dev/null 2>&1; echo $?)"
assert_exit "$RC" "0" "still exits 0"

test_start "probe off: care.json untouched"
[ ! -f "$(care_path)" ]
assert_exit "$?" "0" "no cache file created when off"

test_start "probe off: other spellings honored (0/false/no)"
MAUDE_PROBE=false bash "$PROBE" >/dev/null 2>&1
[ ! -f "$(care_path)" ]
assert_exit "$?" "0" "false spelling honored"

print_summary
teardown_test_env
exit $FAILED
