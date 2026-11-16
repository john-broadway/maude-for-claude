#!/usr/bin/env bash
# tests/test-rolodex-cli.sh — the Rolodex CLI: show, approve, live, revoke, index.
# Everything lives under $TEST_TMP; HOME is the test home; --home/--project are explicit.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
export HOME="$TEST_TMP/home"
RD="$SCRIPTS_DIR/maude-rolodex.sh"
ROLO="$HOME/.claude/maude/rolodex"
PROJ="$TEST_TMP/proj"
mkdir -p "$PROJ" "$ROLO/pending" "$HOME/.claude/skills/diary"

rd() { bash "$RD" "$@" --home "$HOME" --project "$PROJ"; }
# the hash show printed for a pending page: the last line, "pending sha256: <hex>"
phash() { rd show "$1" 2>/dev/null | tail -1 | sed 's/^pending sha256: //'; }
DB="$ROLO/rolodex.db"
# count rows in the store with stdlib python, read-only; 0 when there is no db
q() { python3 -I -c 'import sqlite3, sys, os
p = sys.argv[1]
if not os.path.isfile(p): print(0); sys.exit()
c = sqlite3.connect("file:" + p + "?mode=ro", uri=True)
print(c.execute(sys.argv[2]).fetchone()[0])' "$DB" "$1"; }
live_rows() { q "SELECT count(*) FROM live"; }
# every file under the test dir with its checksum: a write to the db changes its line
tree() { (cd "$TEST_TMP" && find . -type f -exec cksum {} + | sort); }

# one personal skill in the inventory, one pending page that names it
printf -- '---\nname: diary\ndescription: keeps a diary\n---\nbody\n' > "$HOME/.claude/skills/diary/SKILL.md"
cat > "$ROLO/pending/mending.md" <<'PAGE'
trade: mending
what: putting right a thing that broke
when: mend this fence
provider: skill | diary | personal | read in full 2026-11-10 by Claude
pick: skill | diary | keeps a record
cue: Call the diary before you pick up the hammer.
---
free notes
PAGE

test_start "show on a pending page prints its cue line"
OUT="$(rd show mending 2>&1)"
assert_contains "$OUT" "cue: Call the diary before you pick up the hammer." "cue line shown"

test_start "show escapes a hostile byte"
printf 'trade: x\ncue: a\033[31mb\n' > "$ROLO/pending/hostile.md"
OUT="$(rd show hostile 2>&1)"
assert_contains "$OUT" '\x1b[31m' "ESC is shown as an escape"

test_start "an unapproved page never goes live"
rd live >/dev/null 2>&1
assert_eq "$(live_rows)" "0" "no live row before approval"

test_start "approve exits 0"
H="$(phash mending)"
assert_eq "${#H}" "64" "show ends with a 64-hex hash"
rd approve "mending@$H" >/dev/null 2>&1
assert_exit "$?" "0" "approve"

test_start "approve puts the trade on call in this project at once"
assert_eq "$(live_rows)" "1" "one live row, no rebuild needed"
assert_eq "$(q "SELECT slug FROM live")" "mending" "the row names the trade"
rd live >/dev/null 2>&1
assert_eq "$(live_rows)" "1" "still one live row after live"

test_start "a second approve of an unchanged page appends a ledger row and stays live"
rd approve "mending@$(phash mending)" >/dev/null 2>&1
assert_eq "$(q "SELECT count(*) FROM ledger WHERE verb = 'approve'")" "2" "two ledger rows"
assert_eq "$(q "SELECT count(*) FROM pages")" "1" "one page, stored once"
rd live >/dev/null 2>&1
assert_eq "$(live_rows)" "1" "still one live row"

test_start "approve ../x fails with 'not a trade name' and creates nothing"
BEFORE="$(tree)"
ERR="$(rd approve "../x@$H" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "refused"
assert_contains "$ERR" "not a trade name" "reason on stderr"
assert_eq "$(tree)" "$BEFORE" "no file created anywhere"
test -e "$TEST_TMP/x.md" -o -e "$TEST_TMP/../x.md" -o -e "$ROLO/x.md"; assert_exit "$?" "1" "no stray page"

test_start "an invalid page is refused with one line and nothing written"
printf 'trade: x\n' > "$ROLO/pending/short.md"
BEFORE="$(tree)"
ERR="$(rd approve "short@$(phash short)" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "refused"
assert_eq "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" "1" "one line"
assert_eq "$(tree)" "$BEFORE" "nothing written"

test_start "a batch with one bad slug writes nothing"
BEFORE="$(tree)"
rd approve "mending@$H" "absent@$H" >/dev/null 2>&1; RC=$?
assert_exit "$RC" "2" "refused"
assert_eq "$(tree)" "$BEFORE" "nothing written"

test_start "a bare slug with no hash is refused with exit 2 and nothing written"
BEFORE="$(tree)"
ERR="$(rd approve mending 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "refused"
assert_contains "$ERR" "needs the hash" "reason on stderr"
assert_eq "$(tree)" "$BEFORE" "nothing written"

test_start "a page edited after show is refused: changed since it was shown"
printf 'late edit\n' >> "$ROLO/pending/mending.md"
BEFORE="$(tree)"
ERR="$(rd approve "mending@$H" 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "2" "refused"
assert_contains "$ERR" "changed since it was shown" "reason on stderr"
assert_eq "$(tree)" "$BEFORE" "nothing written"

test_start "revoke takes the trade off call in the same command"
rd revoke mending >/dev/null 2>&1
assert_exit "$?" "0" "revoke"
assert_eq "$(live_rows)" "0" "no live row right after revoke, before any rebuild"
rd live >/dev/null 2>&1
assert_eq "$(live_rows)" "0" "and none after live"
assert_eq "$(q "SELECT verb FROM ledger ORDER BY id DESC LIMIT 1")" "revoke" "the last ledger row is the revoke"

test_start "the store is one file: no approved/ or live/ dir"
test -e "$ROLO/approved" -o -e "$ROLO/live"; assert_exit "$?" "1" "no flat-file store"
test -f "$DB"; assert_exit "$?" "0" "rolodex.db is there"

test_start "index writes the per-project inventory and signature"
rd index >/dev/null 2>&1
assert_exit "$?" "0" "index"
assert_contains "$(cat "$ROLO"/inventory/*.tsv)" "diary" "inventory holds the skill"
assert_eq "$(ls "$ROLO"/inventory/*.sig | wc -l | tr -d ' ')" "1" "one signature file"

test_start "options may come before the verb"
bash "$RD" --home "$HOME" --project "$PROJ" live >/dev/null 2>&1
assert_exit "$?" "0" "options first"

test_start "an unknown verb fails"
bash "$RD" frobnicate --home "$HOME" --project "$PROJ" >/dev/null 2>&1
assert_ne "$?" "0" "unknown verb"

test_start "the wrapper is not fooled by a maude_rolodex in the cwd"
EVIL="$TEST_TMP/evil"; mkdir -p "$EVIL/maude_rolodex"
printf '' > "$EVIL/maude_rolodex/__init__.py"
printf 'print("PWNED")\n' > "$EVIL/maude_rolodex/__main__.py"
OUT="$(cd "$EVIL" && bash "$RD" show mending --home "$HOME" --project "$PROJ" 2>&1)"
assert_not_contains "$OUT" "PWNED" "the plugin's own module ran"
assert_contains "$OUT" "pending: mending" "and it worked"

test_start "no python3: signed message on stderr, exit 3"
EMPTY="$TEST_TMP/empty-bin"; mkdir -p "$EMPTY"
ERR="$(PATH="$EMPTY" /bin/bash "$RD" live 2>&1 >/dev/null)"; RC=$?
assert_exit "$RC" "3" "no python"
assert_contains "$ERR" "**Maude:** the Rolodex needs python3, and this house has none that runs." "message"

test_start "the wrapper works through a symlink (relative and absolute)"
mkdir -p "$TEST_TMP/links/sub"
ln -s "$RD" "$TEST_TMP/links/abs-link"
ln -s "../abs-link" "$TEST_TMP/links/sub/rel-link"
OUT="$(cd "$TEST_TMP/links" && bash abs-link show mending --home "$HOME" --project "$PROJ" 2>&1)"
assert_contains "$OUT" "pending: mending" "absolute link"
OUT="$(cd "$TEST_TMP/links/sub" && bash ./rel-link show mending --home "$HOME" --project "$PROJ" 2>&1)"
assert_contains "$OUT" "pending: mending" "relative link of a link"

test_start "the wrapper is executable"
test -x "$RD"; assert_exit "$?" "0" "mode"

print_summary
teardown_test_env
exit "$FAILED"
