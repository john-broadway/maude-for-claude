#!/usr/bin/env bash
# tests/test-chores-model-pin.sh — THE FENCE (2026-07-16, 4th tier-models strike):
# no `claude -p` in this repo may omit an explicit --model. A doer that inherits
# the session model burns flagship on grunt work. This test is the rule.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

test_start "every claude -p pins --model"
VIOLATIONS="$(grep -rn 'claude -p' "$ROOT/scripts" "$ROOT/hooks" 2>/dev/null | grep -v -- '--model' || true)"
assert_eq "$VIOLATIONS" "" "every claude -p pins --model"

exit "$FAILED"
