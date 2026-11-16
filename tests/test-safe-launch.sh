#!/usr/bin/env bash
# Every python Maude starts runs her own packages and the standard library, never a
# same-named file from the directory the user happens to be in.
#
# WHY
# ---
# Her hooks run with the user's project as the working directory, and a project can be a
# cloned repository. The working directory must never be where an import is found: not her
# packages (maude_marker, maude_tape, ...), and not the standard library's (json, re,
# runpy, ...). `python3 -m` and a bare `python3 -c` put it first on sys.path; `python3 -I`
# leaves it off (and ignores PYTHONPATH) on every python 3 since 3.4, so every launch is
# -I, and the plugin's own root goes on sys.path by name inside the code.
#
# HOW
# ---
# A hostile directory holds a look-alike of every package and of the stdlib modules the
# launch paths import. Each look-alike writes a sentinel and exits 0. Each case runs from
# that directory and checks BOTH that the real code ran (a positive mark) and that no
# sentinel was written. The cases run under the default python3 and, when the box has one,
# under python3.9 placed first on PATH. A static guard then reads every shipped launch.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HOME="$TEST_TMP/home"
mkdir -p "$HOME/.claude/maude"

EVIL="$TEST_TMP/evil"
SENT="$TEST_TMP/sentinel"
mkdir -p "$EVIL"
plant() {  # plant <module path relative to EVIL, e.g. maude_marker/__init__.py or json.py>
  mkdir -p "$EVIL/$(dirname "$1")"
  cat > "$EVIL/$1" <<PY
import os
with open("$SENT", "a") as f:
    f.write("$1\n")
os._exit(0)
PY
}
for p in maude_marker maude_tape maude_vault maude_eye maude_rules maude_shell maude_recall maude_rolodex; do
  plant "$p/__init__.py"; plant "$p/__main__.py"
done
for m in json re runpy hashlib filecmp tempfile posixpath shlex fcntl; do plant "$m.py"; done

no_sentinel() {  # <label>
  if [ -e "$SENT" ]; then _fail "$1: a planted module ran: $(tr '\n' ' ' < "$SENT")"; rm -f "$SENT"
  else _pass "$1"; fi
}

# The interpreters to test: the default, and python3.9 when present (named skip otherwise).
PYS="python3"
OLDBIN=""
if command -v python3.9 >/dev/null 2>&1; then
  OLDBIN="$TEST_TMP/oldpy"; mkdir -p "$OLDBIN"
  ln -s "$(command -v python3.9)" "$OLDBIN/python3"
  PYS="python3 python3.9"
else
  printf '    skip  python3.9 cases (named limit: no python3.9 on this box)\n'
fi
path_for() { if [ "$1" = python3.9 ]; then printf '%s:%s' "$OLDBIN" "$PATH"; else printf '%s' "$PATH"; fi; }

. "$ROOT/hooks/scripts/_maude-common.sh"

for PY in $PYS; do
  P="$(path_for "$PY")"

  test_start "[$PY] the shared bootstrap runs the plugin's package, not the cwd's"
  OUT="$(cd "$EVIL" && PATH="$P" python3 -I -c "$MAUDE_PY_BOOT" "$ROOT" maude_marker no-such-verb 2>&1)"
  assert_contains "$OUT" "marker: unknown command" "the real maude_marker answered"
  no_sentinel "[$PY] bootstrap"

  test_start "[$PY] scripts/maude-py.sh runs the plugin's package, not the cwd's"
  OUT="$(cd "$EVIL" && PATH="$P" bash "$ROOT/scripts/maude-py.sh" maude_marker no-such-verb 2>&1)"
  assert_contains "$OUT" "marker: unknown command" "the real maude_marker answered"
  no_sentinel "[$PY] maude-py.sh"

  test_start "[$PY] scripts/maude-py.sh reached through a symlink still finds the plugin"
  ln -sf "$ROOT/scripts/maude-py.sh" "$TEST_TMP/linked-py.sh"
  OUT="$(cd "$EVIL" && PATH="$P" bash "$TEST_TMP/linked-py.sh" maude_marker no-such-verb 2>&1)"
  assert_contains "$OUT" "marker: unknown command" "the real maude_marker answered"
  no_sentinel "[$PY] maude-py.sh via a symlink"

  test_start "[$PY] the file digest helper hashes with the real hashlib"
  printf 'abc' > "$TEST_TMP/abc"
  OUT="$(cd "$EVIL" && PATH="$P" bash -c '. "$1"; maude_file_digest "$2"' _ "$ROOT/hooks/scripts/_maude-common.sh" "$TEST_TMP/abc")"
  assert_eq "$OUT" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "sha256 of abc"
  no_sentinel "[$PY] digest"

  # The PROVE pillar: a red clear with a chain configured must not take a forged link
  # because a look-alike maude_marker in the cwd said "valid".
  test_start "[$PY] a red clear from a hostile cwd refuses a link the chain never made"
  rm -rf "$HOME/.claude/maude"; mkdir -p "$HOME/.claude/maude"
  (cd "$TEST_TMP" && MAUDE_MARKER_GEN_FORCE=1 PATH="$P" PYTHONPATH="$ROOT" python3 -m maude_marker gen sole-copy-target 3 \
    --state "$HOME/.claude/maude/markers.json" >/dev/null 2>&1)
  assert_file_exists "$HOME/.claude/maude/markers.json" "chain provisioned"
  FORGED="$(printf '0%.0s' $(seq 1 64))"
  OUT="$(cd "$EVIL" && PATH="$P" bash "$ROOT/hooks/scripts/maude-clear-red.sh" sole-copy-target --marker "$FORGED" 2>&1)"; RC=$?
  assert_exit "$RC" "1" "forged link refused"
  no_sentinel "[$PY] clear-red"

  test_start "[$PY] the gate holds a push from a hostile cwd and imports nothing from it"
  INPUT="$(make_bash_tool_input 'git push origin main' "$EVIL")"
  OUT="$(cd "$EVIL" && printf '%s' "$INPUT" | PATH="$P" CLAUDE_PROJECT_DIR="$EVIL" bash "$ROOT/hooks/scripts/maude-gate.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "2" "git push is held"
  no_sentinel "[$PY] gate judge"
done

# ── the static guard: every shipped launch is one of the safe shapes (tests/launch_guard.py) ──
guard() { python3 -I "$ROOT/tests/launch_guard.py" "$1"; }

test_start "scripts/maude-py.sh carries the same bootstrap as the hooks (no drift)"
WRAPBOOT="$(awk '/^exec python3 -I -c .import os, sys$/{on=1; print "import os, sys"; next} on{ if ($0 ~ /^runpy\.run_module/) { sub(/'"'"' "\$ROOT" "\$@"$/, ""); print; exit } print }' "$ROOT/scripts/maude-py.sh")"
assert_eq "$WRAPBOOT" "$MAUDE_PY_BOOT" "maude-py.sh bootstrap"

test_start "no shipped file starts python3 in a shape that can import from the cwd"
BAD="$(guard "$ROOT")"
assert_eq "$BAD" "" "unsafe launches"

test_start "the guard is not blind: it names every planted unsafe shape"
mkdir -p "$TEST_TMP/fake/hooks/scripts" "$TEST_TMP/fake/maude_x"
cat > "$TEST_TMP/fake/hooks/scripts/bad.sh" <<'BAD'
PYTHONPATH="$R" python3 -m maude_tape wake
x="$(PYTHONPATH="$R" python3 -c 'import json')"
python3 - "$a" <<'PY'
y="$(python -c 'print(1)')"
"$PY" -c 'pass'
python3 \
  -c 'import json'
python3 -m json.tool < f
python3.9 -S -c 'pass'
/usr/bin/python3 -c 'import json'
BAD
printf '%s\n' 'print("run: python3 -m maude_tape check")' > "$TEST_TMP/fake/maude_x/__main__.py"
BAD="$(guard "$TEST_TMP/fake")"
for n in 1 2 3 4 5 6 8 9 10; do assert_contains "$BAD" "hooks/scripts/bad.sh:$n" "line $n is named"; done
assert_contains "$BAD" "maude_x/__main__.py:1" "a printed -m hint is named"

test_start "the guard passes the safe shapes and plain prose"
rm -f "$TEST_TMP/fake/hooks/scripts/bad.sh" "$TEST_TMP/fake/maude_x/__main__.py"
cat > "$TEST_TMP/fake/hooks/scripts/ok.sh" <<'OK'
python3 -I -c "$MAUDE_PY_BOOT" "$ROOT" maude_tape wake
command -v python3 >/dev/null
printf 'maude-rules: python3 is missing\n'
# python3 -m maude_tape in a comment
bash "$ROOT/scripts/maude-py.sh" maude_tape rest
OK
printf '%s\n' '"""CLI: python3 -m maude_x run."""' > "$TEST_TMP/fake/maude_x/__main__.py"
BAD="$(guard "$TEST_TMP/fake")"
assert_eq "$BAD" "" "no safe line is named"

test_start "the boot refuses an empty or relative plugin root (it would be the cwd)"
for r in "" "." "rel"; do
  OUT="$(cd "$EVIL" && python3 -I -c "$MAUDE_PY_BOOT" "$r" maude_marker no-such-verb 2>&1)"; RC=$?
  assert_ne "$RC" "0" "root '$r' refused"
done
no_sentinel "relative roots"

print_summary
teardown_test_env
exit $FAILED
