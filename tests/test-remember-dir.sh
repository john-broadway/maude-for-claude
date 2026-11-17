#!/usr/bin/env bash
# Tests for maude_remember_dir / maude_remember_handoff: Maude follows the remember
# plugin's own store wherever it lives, and reads its per-session handoffs.
#
# The remember plugin (an official Claude Code plugin) keeps its store in
# <project>/.remember by default, or, in its external storage mode, at the
# `data_dir` named in ~/.remember/config.json (absolute or ~-relative, with {slug}
# expanded the way Claude Code slugs a project path). With handoff_mode
# "per_session" the handoff is remember.<session_id>.md, not remember.md.
# Maude hardcoded <project>/.remember, so moving the store blinded her wake.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

PROJ="$CLAUDE_PROJECT_DIR"
SLUG="$(maude_slug)"
CFG="$HOME/.remember/config.json"
mkcfg() { mkdir -p "$HOME/.remember"; printf '%s' "$1" > "$CFG"; }

test_start "no remember config: the store is <project>/.remember"
rm -f "$CFG"
assert_eq "$(maude_remember_dir)" "$PROJ/.remember" "default"

test_start "data_dir ~/.remember/{slug}: ~ expanded, {slug} is the project slug"
mkcfg '{"data_dir": "~/.remember/{slug}"}'
assert_eq "$(maude_remember_dir)" "$HOME/.remember/$SLUG" "external, home-relative"

test_start "data_dir /abs/{slug}: absolute path, slug expanded"
mkcfg '{"data_dir": "/abs/{slug}"}'
assert_eq "$(maude_remember_dir)" "/abs/$SLUG" "external, absolute"

test_start "a relative data_dir resolves against the project, as the remember plugin does"
mkcfg '{"data_dir": "mem"}'
assert_eq "$(maude_remember_dir)" "$PROJ/mem" "relative is project-relative"

test_start "{slug} comes from the remember plugin's own session_dir_slug when it is installed"
LIBD="$HOME/.claude/plugins/cache/claude-plugins-official/remember/9.9.9/scripts"
mkdir -p "$LIBD"
printf 'session_dir_slug() { printf "PLUGINSLUG"; }\n' > "$LIBD/lib-slug.sh"
mkcfg '{"data_dir": "/abs/{slug}"}'
assert_eq "$(maude_remember_dir)" "/abs/PLUGINSLUG" "the plugin's slug wins"
rm -rf "$HOME/.claude/plugins"

test_start "a linked git worktree reads the main checkout's store, as the remember plugin does"
if command -v git >/dev/null 2>&1; then
  MAIN="$TEST_TMP/mainrepo"; mkdir -p "$MAIN"
  git -C "$MAIN" init -q && git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
  git -C "$MAIN" worktree add -q "$TEST_TMP/wt" 2>/dev/null
  rm -f "$CFG"
  GOT="$(CLAUDE_PROJECT_DIR="$TEST_TMP/wt" maude_remember_dir)"
  assert_eq "$GOT" "$(cd -P "$MAIN" && pwd -P)/.remember" "worktree -> main checkout"
  git -C "$MAIN" worktree remove --force "$TEST_TMP/wt" 2>/dev/null
else
  _pass "git absent: worktree case skipped"
fi

test_start "malformed config: fall back, print nothing on stderr"
mkcfg '{"data_dir": '
ERR="$(maude_remember_dir 2>&1 >/dev/null)"
assert_eq "$(maude_remember_dir 2>/dev/null)" "$PROJ/.remember" "malformed ignored"
assert_eq "$ERR" "" "no stderr"

test_start "no jq and no python3: fall back"
mkcfg '{"data_dir": "/abs/{slug}"}'
GOT="$(PATH=/nonexistent maude_remember_dir 2>/dev/null)"
assert_eq "$GOT" "$PROJ/.remember" "tools absent"
rm -f "$CFG"

test_start "per_session: the newest non-empty handoff is the one read"
R="$PROJ/.remember"; mkdir -p "$R"
: > "$R/remember.md"
printf 'older\n' > "$R/remember.s1.md"; touch -t 202601010000 "$R/remember.s1.md"
printf 'newer\n' > "$R/remember.s2.md"; touch -t 202601020000 "$R/remember.s2.md"
assert_eq "$(maude_remember_handoff)" "$R/remember.s2.md" "newest non-empty"

test_start "no handoff at all: prints nothing, succeeds"
rm -f "$R"/remember*.md
OUT="$(maude_remember_handoff)"; RC=$?
assert_eq "$OUT" "" "empty"
assert_eq "$RC" "0" "rc 0"

test_start "the wake brief reads a per-session handoff (remember.<session>.md)"
R="$PROJ/.remember"; mkdir -p "$R"
printf '# Handoff\n\n## State\nPERSESSION-MARKER state line\n\n## Next\n1. PERSESSION-MARKER next\n' > "$R/remember.abc123.md"
OUT="$(bash "$HOOKS_DIR/maude-session-start.sh" < /dev/null 2>/dev/null)"
assert_contains "$OUT" "PERSESSION-MARKER" "brief shows the per-session handoff"
rm -f "$R"/remember*.md

print_summary
teardown_test_env
exit $FAILED
