#!/usr/bin/env bash
# Session start rebuilds this project's live trades and says so in one brief line: how
# many are on call, which picks moved version since approval, which picks are gone. A
# house with no Rolodex store pays one test and prints nothing.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
export HOME="$TEST_TMP/home"
export CLAUDE_PROJECT_DIR="$TEST_TMP/proj"
START="$HOOKS_DIR/maude-session-start.sh"
RD="$SCRIPTS_DIR/maude-rolodex.sh"
ROLO="$HOME/.claude/maude/rolodex"
PLUG="$HOME/.claude/plugins"
mkdir -p "$CLAUDE_PROJECT_DIR" "$ROLO/pending"

rd() { bash "$RD" "$@" --home "$HOME" --project "$CLAUDE_PROJECT_DIR"; }
start() { OUT="$(printf '{}' | bash "$START" 2>/dev/null)"; }
install() {  # install <version>: plugin handyman@mk with skill mend, recorded at that version
  mkdir -p "$PLUG/cache/mk/handyman/$1/skills/mend"
  printf -- '---\nname: mend\ndescription: mends\n---\nbody\n' > "$PLUG/cache/mk/handyman/$1/skills/mend/SKILL.md"
  printf '{"version":2,"plugins":{"handyman@mk":[{"scope":"user","installPath":"%s","version":"%s","gitCommitSha":"abc1234","installedAt":"x","lastUpdated":"x"}]}}' \
    "$PLUG/cache/mk/handyman/$1" "$1" > "$PLUG/installed_plugins.json"
}
live_rows() { python3 -I -c 'import sqlite3, sys
print(sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True).execute("SELECT count(*) FROM live").fetchone()[0])' "$ROLO/rolodex.db"; }

test_start "no Rolodex store: no brief line, no inventory written"
start
assert_not_contains "$OUT" "Rolodex" "no line"
assert_file_absent "$ROLO/inventory" "no inventory"

install 1.0.0
cat > "$ROLO/pending/mending.md" <<'PAGE'
trade: mending
what: putting right a thing that broke
when: mend this fence
provider: skill | handyman:mend | handyman@mk@1.0.0 | read in full 2026-11-10 by Claude
pick: skill | handyman:mend | the one who mends
cue: Call the handyman.
---
PAGE
rd approve "mending@$(rd show mending 2>/dev/null | tail -1 | sed 's/^pending sha256: //')" >/dev/null 2>&1

test_start "one approved trade with its pick installed: on call, one live row"
start
assert_contains "$OUT" "Rolodex: 1 trade(s) on call" "brief line"
assert_eq "$(live_rows)" "1" "live row"

test_start "a second start with nothing changed does not rewrite the inventory"
INV="$(ls "$ROLO"/inventory/*.tsv)"
touch -t 202001010000 "$INV"
before="$(ls -l --time-style=+%s "$INV" 2>/dev/null | awk '{print $6}')"
[ -n "$before" ] || before="$(stat -f %m "$INV")"
start
after="$(ls -l --time-style=+%s "$INV" 2>/dev/null | awk '{print $6}')"
[ -n "$after" ] || after="$(stat -f %m "$INV")"
assert_eq "$after" "$before" "inventory untouched"

test_start "the plugin's version moved: the row stays and the brief flags it"
install 1.1.0
start
assert_contains "$OUT" "changed since approved: mending" "flag"
assert_eq "$(live_rows)" "1" "row kept"

test_start "the plugin removed: the row drops and the brief says the pick is gone"
printf '{"version":2,"plugins":{}}' > "$PLUG/installed_plugins.json"
start
assert_contains "$OUT" "pick gone: mending" "gone"
assert_eq "$(live_rows)" "0" "no live row"

test_start "every trade revoked: no brief line"
rd revoke mending >/dev/null 2>&1
start
assert_not_contains "$OUT" "Rolodex" "silent when nothing is approved"

print_summary
teardown_test_env
exit $FAILED
