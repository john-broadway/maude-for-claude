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

print_summary
exit $FAILED
