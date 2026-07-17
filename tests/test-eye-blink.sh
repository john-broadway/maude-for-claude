#!/usr/bin/env bash
# Eye blink worker: stub runner end-to-end — signal, silence, no-runner, recursion guard.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj/.maude/plugin"
export CLAUDE_PLUGIN_ROOT="$ROOT"
export MAUDE_PROJECT_DIR_OVERRIDE="$WORK/proj"

# a tiny fake transcript
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"fix the bug"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x.py"}}]}}' \
  > "$WORK/t.jsonl"

# stub runner that signals
cat > "$WORK/runner-signal" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"signal": true, "kind": "churn", "whisper": "stub caught it"}\n'
EOF
chmod +x "$WORK/runner-signal"

# stub runner that stays quiet
cat > "$WORK/runner-quiet" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '{"signal": false}\n'
EOF
chmod +x "$WORK/runner-quiet"

WHISPER="$WORK/proj/.maude/plugin/eye-whisper.txt"

# 1) signal → whisper file written
test_start "whisper written on signal"
MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-signal" \
  bash "$ROOT/hooks/scripts/maude-eye-blink.sh" "$WORK/t.jsonl" >/dev/null 2>&1
assert_file_exists "$WHISPER" "whisper written on signal"

test_start "whisper carries the verdict"
assert_contains "$(cat "$WHISPER")" "stub caught it" "whisper carries the verdict"

# 2) quiet → no whisper
rm -f "$WHISPER"
test_start "no whisper on signal:false"
MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-quiet" \
  bash "$ROOT/hooks/scripts/maude-eye-blink.sh" "$WORK/t.jsonl" >/dev/null 2>&1
[ ! -f "$WHISPER" ] || [ ! -s "$WHISPER" ]
assert_eq "$?" "0" "no whisper on signal:false"

# 3) no runner anywhere → silent exit 0
rm -f "$WHISPER"
test_start "dark eye exits 0"
PATH="/usr/bin:/bin" MAUDE_EYE_RUNNER_OVERRIDE="" \
  bash "$ROOT/hooks/scripts/maude-eye-blink.sh" "$WORK/t.jsonl" >/dev/null 2>&1
assert_eq "$?" "0" "dark eye exits 0"

# 4) recursion guard: any hook sourcing _maude-common.sh exits 0 immediately under MAUDE_EYE_BLINK
test_start "hooks are inert inside a blink"
OUT="$(printf '{"prompt":"hello"}' | MAUDE_EYE_BLINK=1 bash "$ROOT/hooks/scripts/maude-page.sh" 2>&1)"
assert_eq "$OUT" "" "hooks are inert inside a blink"

# 4b) maude-secret-scan.sh is the one registered hook that doesn't source
# _maude-common.sh, so it needed its own inline copy of the guard. Feed it a
# credential-shaped prompt (not an empty/benign one) so this test would
# actually fail without the guard — an empty prompt is silent either way,
# since the scan naturally has nothing to alert on. Slack-token shape chosen
# because it's a fake/synthetic string that maude-secret-scan.sh's own
# patterns match but isn't a shape this repo's write-time credential
# fingerprint guard also flags (AWS/GitHub/OpenAI/Anthropic/PEM), so the Edit
# adding this line doesn't trip that separate, unrelated guard.
test_start "secret-scan is inert inside a blink"
OUT="$(printf '{"prompt":"here is a token xoxb-0000000000-fakefaketoken"}' | \
  MAUDE_EYE_BLINK=1 bash "$ROOT/hooks/scripts/maude-secret-scan.sh" 2>&1)"
assert_eq "$OUT" "" "secret-scan is inert inside a blink"

# 5) wall-clock bound: a hung runner must not block the caller or outlive it.
# MAUDE_EYE_TIMEOUT=1 against a stub that sleeps 5s — the blink must return
# in a few seconds (timeout-killed), and write no whisper.
cat > "$WORK/runner-hang" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
sleep 5
printf '{"signal": true, "kind": "churn", "whisper": "should never arrive"}\n'
EOF
chmod +x "$WORK/runner-hang"

rm -f "$WHISPER"
test_start "wall-clock bound kills a hung runner"
START="$(date +%s)"
MAUDE_EYE_TIMEOUT=1 MAUDE_EYE_RUNNER_OVERRIDE="$WORK/runner-hang" \
  bash "$ROOT/hooks/scripts/maude-eye-blink.sh" "$WORK/t.jsonl" >/dev/null 2>&1
END="$(date +%s)"
ELAPSED=$((END - START))
[ "$ELAPSED" -lt 4 ]
assert_eq "$?" "0" "wall-clock bound kills a hung runner (elapsed=${ELAPSED}s)"

test_start "no whisper written after a timeout kill"
[ ! -f "$WHISPER" ] || [ ! -s "$WHISPER" ]
assert_eq "$?" "0" "no whisper written after a timeout kill"

# claude branch: MAUDE_EYE_MODEL overrides the model flag (default haiku)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" > "${FAKE_CLAUDE_ARGS:?}"
printf '{"signal": false}\n'
EOF
chmod +x "$WORK/bin/claude"

test_start "eye model defaults to haiku"
rm -f "$WORK/args"
FAKE_CLAUDE_ARGS="$WORK/args" PATH="$WORK/bin:/usr/bin:/bin" MAUDE_EYE_RUNNER_OVERRIDE="" \
  bash "$ROOT/hooks/scripts/maude-eye-blink.sh" "$WORK/t.jsonl" >/dev/null 2>&1
assert_contains "$(cat "$WORK/args" 2>/dev/null)" "--model haiku" "eye model defaults to haiku"

test_start "MAUDE_EYE_MODEL unpins the model"
rm -f "$WORK/args"
FAKE_CLAUDE_ARGS="$WORK/args" PATH="$WORK/bin:/usr/bin:/bin" MAUDE_EYE_RUNNER_OVERRIDE="" \
  MAUDE_EYE_MODEL="sonnet" \
  bash "$ROOT/hooks/scripts/maude-eye-blink.sh" "$WORK/t.jsonl" >/dev/null 2>&1
assert_contains "$(cat "$WORK/args" 2>/dev/null)" "--model sonnet" "MAUDE_EYE_MODEL unpins the model"

print_summary; exit $FAILED
