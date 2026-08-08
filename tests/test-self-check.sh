#!/usr/bin/env bash
# tests/test-self-check.sh — maude-self-check.sh: the wake-time installed-vs-source
# drift whisper (born of the 10-day stale-install trap, 2026-08-08).
#
# Fixture: two fake plugin dirs (an "installed" ROOT and a "source" SRC), driven
# via CLAUDE_PLUGIN_ROOT + MAUDE_SOURCE_DIR so discovery never touches the real
# marketplace record. Every case asserts BOTH the exit code (always 0 — a
# whisper must never block a session start) and the message (or its absence —
# a probe that prints the same thing either way is not a check).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env

CHECK="$HOOKS_DIR/maude-self-check.sh"

mkplugin() {  # dir version
  mkdir -p "$1/.claude-plugin" "$1/hooks/scripts"
  printf '{"name":"maude","version":"%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\n' > "$1/hooks/scripts/stub.sh"
}

ROOTD="$TEST_TMP/installed"
SRCD="$TEST_TMP/source"

run_check() {  # rootdir srcdir [extra env assignments via caller export]
  OUT="$(CLAUDE_PLUGIN_ROOT="$1" MAUDE_SOURCE_DIR="$2" bash "$CHECK" 2>&1)"
  RC=$?
}

# ── versions differ → "update is waiting" ───────────────────────────────
mkplugin "$ROOTD" "0.26.0"
mkplugin "$SRCD"  "0.27.0"
test_start "self-check whispers when source version is ahead"
run_check "$ROOTD" "$SRCD"
assert_exit "$RC" "0" "whisper never blocks"
assert_contains "$OUT" "update is waiting" "version-diff message"

# ── versions EQUAL but files differ → the 10-day trap message ────────────
rm -rf "$ROOTD" "$SRCD"
mkplugin "$ROOTD" "0.27.0"
mkplugin "$SRCD"  "0.27.0"
printf 'new organ\n' > "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check names version-keyed drift (same version, files differ)"
run_check "$ROOTD" "$SRCD"
assert_exit "$RC" "0" "whisper never blocks"
assert_contains "$OUT" "NEVER auto-deliver" "unbumped-drift message"

# ── identical → silent ───────────────────────────────────────────────────
rm -f "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check is SILENT when installed matches source"
run_check "$ROOTD" "$SRCD"
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── dev checkout (ROOT == SRC) → silent ──────────────────────────────────
test_start "self-check is SILENT running from the source checkout itself"
run_check "$SRCD" "$SRCD"
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── no source discoverable → silent (a guess is worse than nothing) ──────
test_start "self-check is SILENT with no source dir on this machine"
OUT="$(CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$TEST_TMP/nope" HOME="$TEST_TMP/nohome" bash "$CHECK" 2>&1)"
RC=$?
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── eye recursion guard: inert inside a blink ────────────────────────────
# Drift is planted FIRST so the un-guarded script WOULD whisper — silence on
# a clean diff proves nothing (measured: the working tree masked exactly this
# behind the dev-checkout short-circuit while the archive failed).
printf 'drift\n' > "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check is SILENT under an eye blink (recursion guard)"
OUT="$(CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$SRCD" MAUDE_EYE_BLINK=1 bash "$CHECK" 2>&1)"
RC=$?
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence under blink, got: $OUT"; fi

# ── kill switch ──────────────────────────────────────────────────────────
printf 'drift\n' > "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check honors MAUDE_SELF_CHECK=off"
OUT="$(CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$SRCD" MAUDE_SELF_CHECK=off bash "$CHECK" 2>&1)"
RC=$?
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

teardown_test_env
print_summary
exit "$FAILED"
