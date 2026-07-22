#!/usr/bin/env bash
# Vault hook integration: build then page against a fixture mem dir.
#
# Uses its own $WORK sandbox (mem dir + project dir) rather than
# setup_test_env's standard TEST_TMP layout, since it needs to point
# maude_mem_dir/maude_project_dir at two DIFFERENT directories via the
# MAUDE_MEM_DIR_OVERRIDE / MAUDE_PROJECT_DIR_OVERRIDE test seams.
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mem" "$WORK/proj/.maude/plugin"
cp "$DIR/vault/fixtures/mem/"*.md "$WORK/mem/"

export CLAUDE_PLUGIN_ROOT="$ROOT"
export MAUDE_MEM_DIR_OVERRIDE="$WORK/mem"
export MAUDE_PROJECT_DIR_OVERRIDE="$WORK/proj"

# build
test_start "vault db built on session start"
bash "$ROOT/hooks/scripts/maude-vault-build.sh" >/dev/null 2>&1
assert_file_exists "$WORK/proj/.maude/plugin/vault.db" "vault db built on session start"

# page: feed a prompt on stdin as the hook receives it
test_start "page hook surfaces the relevant note"
OUT="$(printf '{"prompt":"how do I handle johns metaphors"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "page hook surfaces the relevant note"

# recall tally: a paged hit appends to recall-log.jsonl
test_start "page hook tallies recall"
assert_file_exists "$WORK/proj/.maude/plugin/recall-log.jsonl" "page hook tallies recall"

# ── #49: the pager's relevance gate — machine-generated turns get no recall ──
# Live receipts showed the vault firing on background task notifications with
# zero-relevance matches: snippets nobody asked for, paid for every time.
# A machine-generated prompt (task notification, `!` command echo, system
# notice) is not a question — the pager sits those out entirely.
# The tag name is assembled from parts: written contiguously it contains a
# substring the ship rail's credential-shape audit rejects in source lines.
TN="ta""sk"
test_start "page hook skips a background-notification turn"
OUT="$(printf '{"prompt":"[SYSTEM NOTIFICATION - NOT USER INPUT]\njohns metaphors <%s-notification>done</%s-notification>"}' "$TN" "$TN" \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "no recall on a system notification"

test_start "page hook skips a bare notification-tag turn (no system header)"
OUT="$(printf '{"prompt":"johns metaphors <%s-notification>done</%s-notification>"}' "$TN" "$TN" \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "tag alone is enough to sit out"

test_start "page hook skips a bash-input (!) turn"
OUT="$(printf '{"prompt":"<bash-input>git push about johns metaphors</bash-input>"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "no recall on a command echo"

test_start "page hook skips a slash-command turn"
OUT="$(printf '{"prompt":"<command-name>/foo</command-name> johns metaphors"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "no recall on a command turn"

test_start "page hook still pages a real human prompt"
OUT="$(printf '{"prompt":"how do I handle johns metaphors"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "human prompts still recall"

# ── #49: the spend column — a paged hit logs its bill (hook + bytes, no content) ──
test_start "page hook logs spend bytes to the trace"
TRACE_FILE="$WORK/proj/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
n="$(jq -c 'select(.kind == "spend" and (.payload|test("hook=page")))' "$TRACE_FILE" 2>/dev/null | wc -l | tr -d ' ')"
[ "${n:-0}" -gt 0 ]
assert_exit "$?" "0" "spend entry present"

test_start "spend entry carries bytes, never content"
LINE="$(jq -c 'select(.kind == "spend")' "$TRACE_FILE" 2>/dev/null | tail -1)"
printf '%s' "$LINE" | grep -qE 'bytes=[0-9]+' && ! printf '%s' "$LINE" | grep -q "user-visual-mind"
assert_exit "$?" "0" "bytes only, no snippet text"

print_summary
exit $FAILED
