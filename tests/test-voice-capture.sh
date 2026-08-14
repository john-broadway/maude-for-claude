#!/usr/bin/env bash
# Tests for hooks/scripts/maude-voice-capture.sh — the
# silent UserPromptSubmit capture hook.
#
# Stubs python3 on PATH rather than invoking the real
# `python3 -m maude_tape voice-capture`: these tests prove the SHELL SCRIPT's
# own contract — parse stdin, resolve the db, build the right argv, pipe the
# prompt, stay silent no matter what the CLI does — in isolation from the CLI.
# The end-to-end proof (a real prompt landing in the voice table through the
# real CLI) lives in tests/tape/test_voice_capture.py.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

VC="$HOOKS_DIR/maude-voice-capture.sh"
export CLAUDE_PLUGIN_ROOT="$MAUDE_ROOT"

DB_DIR="$TEST_TMP/.maude/plugin/tape"
DB="$DB_DIR/tape.db"

STUB_DIR="$(mktemp -d)"
CAPTURE="$STUB_DIR/capture.out"
trap 'rm -rf "$STUB_DIR"' EXIT

# A stub python3 that records its argv + stdin to $CAPTURE, then behaves per
# $STUB_MODE: "ok" (default) mimics a silent successful CLI; "loud" mimics the
# real shape of hitting the NotImplementedError stub — noise on stdout/stderr,
# non-zero exit.
cat > "$STUB_DIR/python3" <<EOF
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %q' "\$@"; printf '\n'; printf 'STDIN:'; cat; printf '\n'; } > "$CAPTURE"
if [ "\${STUB_MODE:-ok}" = "loud" ]; then
  printf 'noise on stdout\n'
  printf 'noise on stderr\n' >&2
  exit 1
fi
exit 0
EOF
chmod +x "$STUB_DIR/python3"

run_vc() {
  local json="$1"
  OUT="$(printf '%s' "$json" | PATH="$STUB_DIR:$PATH" bash "$VC" 2>"$STUB_DIR/stderr.out")"
  RC=$?
  ERR="$(cat "$STUB_DIR/stderr.out" 2>/dev/null)"
}

# ── guard: no tape db yet -> silent, python never invoked ──
test_start "vc silent + exit 0 with no tape db (guard)"
rm -f "$CAPTURE"
run_vc '{"prompt":"hello there"}'
assert_exit "$RC" "0" "exit"
assert_eq "$OUT" "" "stdout"
assert_eq "$ERR" "" "stderr"
assert_file_absent "$CAPTURE" "python not invoked"

# From here on a real (schema-less, but existing) tape db is present so the
# file guard passes — the hook only checks existence, never opens it itself.
mkdir -p "$DB_DIR"
: > "$DB"

# ── MAUDE_VOICE=off -> the kill switch wins before anything else runs ──
test_start "vc kill switch: MAUDE_VOICE=off exits 0, silent, python never invoked"
rm -f "$CAPTURE"
MAUDE_VOICE=off run_vc '{"prompt":"this must never be captured"}'
assert_exit "$RC" "0" "exit"
assert_eq "$OUT" "" "stdout"
assert_file_absent "$CAPTURE" "python not invoked with the switch off"

# ── empty prompt -> silent, python never invoked ──
test_start "vc silent + exit 0 on empty prompt"
rm -f "$CAPTURE"
run_vc '{"prompt":""}'
assert_exit "$RC" "0" "exit"
assert_eq "$OUT" "" "stdout"
assert_file_absent "$CAPTURE" "python not invoked on empty prompt"

# ── missing prompt key entirely -> same as empty (jq // fallback) ──
test_start "vc silent + exit 0 when the envelope carries no prompt key"
rm -f "$CAPTURE"
run_vc '{}'
assert_exit "$RC" "0" "exit"
assert_file_absent "$CAPTURE" "python not invoked without a prompt key"

# ── real prompt, no session_id -> invokes python, no --session arg ──
test_start "vc invokes voice-capture with --db/--source/--register, no --session"
rm -f "$CAPTURE"
run_vc '{"prompt":"this is what john actually typed"}'
assert_exit "$RC" "0" "exit"
assert_eq "$OUT" "" "stdout"
assert_file_exists "$CAPTURE" "python invoked"
ARGLINE="$(head -1 "$CAPTURE")"
assert_contains "$ARGLINE" "voice-capture" "subcommand"
assert_contains "$ARGLINE" "--db $DB" "db path"
assert_contains "$ARGLINE" "--source hook" "source"
assert_contains "$ARGLINE" "--register chat" "register"
assert_not_contains "$ARGLINE" "--session" "no session arg when envelope carries none"
STDINLINE="$(sed -n '2p' "$CAPTURE")"
assert_eq "$STDINLINE" "STDIN:this is what john actually typed" "prompt piped on stdin, not argv"

# ── real prompt WITH session_id -> --session passed through ──
test_start "vc passes --session when the envelope carries session_id"
rm -f "$CAPTURE"
run_vc '{"prompt":"another real line","session_id":"abc12345-def"}'
assert_exit "$RC" "0" "exit"
ARGLINE="$(head -1 "$CAPTURE")"
assert_contains "$ARGLINE" "--session abc12345-def" "session id passed through"

# ── the CLI fails loud (the real shape of the NotImplementedError stub) ──
# The hook must still exit 0 and print nothing: an observer must never let a
# broken capture surface into Claude's context or block the turn. The wrapper
# swallows the CLI's own stderr too (the whisper-on-failure the brief allows
# is not something this build adds — silence stays total, matching tape-wake
# / tape-rest's own style).
test_start "vc stays silent + exit 0 even when the CLI fails loud"
rm -f "$CAPTURE"
STUB_MODE=loud
export STUB_MODE
run_vc '{"prompt":"a prompt that will hit a failing CLI"}'
assert_exit "$RC" "0" "exit despite CLI failure"
assert_eq "$OUT" "" "stdout still empty despite CLI printing noise on stdout"
assert_eq "$ERR" "" "stderr still empty despite CLI printing noise on stderr"
unset STUB_MODE

print_summary
teardown_test_env
exit $FAILED
