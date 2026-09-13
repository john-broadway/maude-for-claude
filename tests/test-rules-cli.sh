#!/usr/bin/env bash
# Tests for scripts/maude-rules.sh — the checklist printer and linter runner.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RS="$ROOT/scripts/maude-rules.sh"

test_start "ux prints thirty laws with family and ask"
OUT="$(bash "$RS" ux 2>&1)"
assert_exit "$?" "0" "exit 0"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^- ')" "30" "thirty bullet lines"
assert_contains "$OUT" "Fitts's Law [reach]" "name and family"
assert_contains "$OUT" "pressable across its whole box" "the ask"

test_start "a law names its twins in the other seats by family"
OUT="$(bash "$RS" db 2>&1)"
assert_contains "$OUT" "Third normal form [provenance]" "3nf line"
assert_contains "$OUT" "same law elsewhere" "twin line present"
assert_contains "$OUT" "memory:" "a memory twin named"

test_start "memory prints the draft banner"
OUT="$(bash "$RS" memory 2>&1)"
assert_contains "$OUT" "DRAFT" "draft is said"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^- ')" "22" "twenty-two lines"

test_start "an unknown seat refuses with usage, exit 2"
OUT="$(bash "$RS" bogus 2>&1)"
assert_exit "$?" "2" "refuses"
assert_contains "$OUT" "usage" "usage printed"

if command -v python3 >/dev/null 2>&1; then
  test_start "db PATH runs the linter with asks and leads with the count"
  printf 'CREATE TABLE t (name TEXT, tags TEXT);\n' > "$TEST_TMP/s.sql"
  OUT="$(bash "$RS" db "$TEST_TMP/s.sql" 2>&1)"
  assert_exit "$?" "1" "findings exit 1"
  assert_contains "$OUT" "1 finding" "count first"
  assert_contains "$OUT" "ask:" "asks listed"
  printf 'CREATE TABLE t (id INT PRIMARY KEY);\n' > "$TEST_TMP/c.sql"
  OUT="$(bash "$RS" db "$TEST_TMP/c.sql" 2>&1)"
  assert_exit "$?" "0" "clean exit 0"
  assert_contains "$OUT" "0 finding(s)" "zero said"

  test_start "an unreadable path is not counted as a finding"
  OUT="$(bash "$RS" db "$TEST_TMP/nope-does-not-exist.sql" 2>&1)"
  assert_exit "$?" "0" "unreadable-only exits 0"
  assert_contains "$OUT" "0 finding(s)" "unreadable does not inflate the count"
  assert_contains "$OUT" "unreadable" "unreadable line still printed"
  OUT="$(bash "$RS" db "$TEST_TMP/s.sql" 2>&1)"
  assert_exit "$?" "1" "control: a real keyless schema still exits 1"
  assert_contains "$OUT" "1 finding" "control: count still 1"

  # The CLI takes paths the user typed, so it cannot move the interpreter to the
  # plugin root the way the rail and verify do; the safe-path env var is the whole
  # defence against a project's own maude_rules/ being executed instead.
  test_start "the CLI never runs the working directory's own maude_rules package"
  mkdir -p "$TEST_TMP/shadow/maude_rules"
  : > "$TEST_TMP/shadow/maude_rules/__init__.py"
  printf 'import sys\nprint("EVIL: 0 finding(s): clean")\nsys.exit(0)\n' > "$TEST_TMP/shadow/maude_rules/__main__.py"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/shadow/s.sql"
  OUT="$(cd "$TEST_TMP/shadow" && bash "$RS" db s.sql 2>&1)"
  assert_not_contains "$OUT" "EVIL" "the shadowing package is not executed"
  assert_contains "$OUT" "codd-2" "the real finding still arrives"
fi

test_start "no args reports this session's touched and unnamed classes"
mkdir -p "$TEST_TMP/.maude/plugin"
printf '{"rules":{"abcdef12":{"touched":{"ui":["a.html","b.html"]},"named":{}}}}\n' > "$(care_path)"
OUT="$(CLAUDE_CODE_SESSION_ID=abcdef12-rest bash "$RS" 2>&1)"
assert_contains "$OUT" "ui: 2 file(s) touched, no law named" "unnamed reported"
printf '{"rules":{"abcdef12":{"touched":{"ui":["a.html"]},"named":{"ui":{"ts":"t","file":"d.md","laws":["fitts"]}}}}}\n' > "$(care_path)"
OUT="$(CLAUDE_CODE_SESSION_ID=abcdef12-rest bash "$RS" 2>&1)"
assert_contains "$OUT" "ui: named in d.md (fitts)" "named reported"

# A report that prints nothing cannot be told apart from a report that failed to run.
test_start "no args with nothing touched says so out loud"
printf '{"rules":{"99999999":{"touched":{"ui":["a.html"]},"named":{}}}}\n' > "$(care_path)"
OUT="$(CLAUDE_CODE_SESSION_ID=abcdef12-rest bash "$RS" 2>&1)"
assert_eq "$OUT" "no class touched this session" "a sibling lane's touch is not mine"
printf '{}\n' > "$(care_path)"
OUT="$(CLAUDE_CODE_SESSION_ID=abcdef12-rest bash "$RS" 2>&1)"
assert_eq "$OUT" "no class touched this session" "an empty store says the same"

print_summary
teardown_test_env
exit "$FAILED"
