#!/usr/bin/env bash
# The Rolodex cue: one approved line at the prompt, once per session per trade, from the
# approved page itself, and silence on any doubt.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
export HOME="$TEST_TMP/home"
export CLAUDE_PROJECT_DIR="$TEST_TMP/proj"
HOOK="$HOOKS_DIR/maude-rolodex-cue.sh"
RD="$SCRIPTS_DIR/maude-rolodex.sh"
ROLO="$HOME/.claude/maude/rolodex"
DB="$ROLO/rolodex.db"
mkdir -p "$CLAUDE_PROJECT_DIR" "$ROLO/pending" "$HOME/.claude/skills/diary" "$HOME/.claude/skills/ledger"

rd() { bash "$RD" "$@" --home "$HOME" --project "$CLAUDE_PROJECT_DIR"; }
phash() { rd show "$1" 2>/dev/null | tail -1 | sed 's/^pending sha256: //'; }
approve() { rd approve "$1@$(phash "$1")" >/dev/null 2>&1; }
prompt() {  # prompt <text> [session id]: the hook's stdout
  local sid="${2-s1}"
  if [ -n "$sid" ]; then
    jq -nc --arg p "$1" --arg s "$sid" '{prompt:$p, session_id:$s}' | bash "$HOOK" 2>/dev/null
  else
    jq -nc --arg p "$1" '{prompt:$p}' | bash "$HOOK" 2>/dev/null
  fi
}
sql() { python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1], isolation_level=None)
for s in sys.argv[2:]:
    c.execute(s)' "$DB" "$@"; }

printf -- '---\nname: diary\ndescription: keeps a diary\n---\nbody\n' > "$HOME/.claude/skills/diary/SKILL.md"
printf -- '---\nname: ledger\ndescription: keeps the books\n---\nbody\n' > "$HOME/.claude/skills/ledger/SKILL.md"
cat > "$ROLO/pending/mending.md" <<'PAGE'
trade: mending
what: putting right a thing that broke
when: mend this fence
when: fix the gate
provider: skill | diary | personal | read in full 2026-11-10 by Claude
pick: skill | diary | keeps a record
cue: Call the diary before you pick up the hammer.
---
PAGE
cat > "$ROLO/pending/books.md" <<'PAGE'
trade: books
what: the accounts
when: fix the gate today
provider: skill | ledger | personal | read in full 2026-11-10 by Claude
pick: skill | ledger | keeps the books
cue: The ledger keeps the books.
---
PAGE
WANT='**Maude:** I know who handles that: mending -> diary (skill). Call the diary before you pick up the hammer.'

test_start "no Rolodex store: silent"
assert_eq "$(prompt 'please mend this fence')" "" "no db, no cue"

approve mending
test_start "an approved phrase cues the exact approved line"
assert_eq "$(prompt 'please mend this fence now' s1)" "$WANT" "the cue"

test_start "the same trade is not cued twice in one session"
assert_eq "$(prompt 'mend this fence again' s1)" "" "second time silent"

test_start "a new session cues it again"
assert_eq "$(prompt 'mend this fence' s2)" "$WANT" "new session"

test_start "the phrase's words out of order or apart: silent"
assert_eq "$(prompt 'this fence needs a mend' s3)" "" "out of order"
assert_eq "$(prompt 'mend the old fence' s3)" "" "apart"

test_start "no session id: silent"
assert_eq "$(prompt 'mend this fence' '')" "" "no sid"

test_start "a machine turn or another agent's words: silent"
assert_eq "$(prompt 'Another Claude session sent a message: mend this fence' s4)" "" "peer"
assert_eq "$(prompt 'x <agent-message from="a">mend this fence' s4)" "" "agent"
assert_eq "$(prompt '[SYSTEM NOTIFICATION] mend this fence' s4)" "" "system"
assert_eq "$(prompt 'mend this fence' s4)" "$WANT" "the person's own prompt still cues after"

test_start "no jq: silent, exit 0"
NOJQ="$(make_no_binary_bin jq)"
OUT="$(jq -nc '{prompt:"mend this fence", session_id:"s5"}' > "$TEST_TMP/in.json"; PATH="$NOJQ" bash "$HOOK" < "$TEST_TMP/in.json" 2>/dev/null)"; RC=$?
assert_eq "$OUT" "" "no cue"
assert_exit "$RC" "0" "exit 0"

test_start "after a cue the trace holds one rolodex row, no prompt text, and a spend row"
TRACE="$CLAUDE_PROJECT_DIR/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
: > "$TRACE"
prompt 'SECRETWORD mend this fence' s6 >/dev/null
assert_eq "$(jq -c 'select(.kind=="rolodex") | [.payload, .sid]' "$TRACE")" '["trade=mending pick=skill:diary","s6"]' "the row"
assert_not_contains "$(cat "$TRACE")" "SECRETWORD" "no prompt text"
assert_contains "$(jq -r 'select(.kind=="spend") | .payload' "$TRACE")" "hook=rolodex-cue" "spend logged"

approve books
test_start "the longest phrase wins; once cued, the next-best does not step in"
assert_eq "$(prompt 'fix the gate today please' s7)" '**Maude:** I know who handles that: books -> ledger (skill). The ledger keeps the books.' "books wins on length"
assert_eq "$(prompt 'fix the gate today please' s7)" "" "books seen; mending does not step in"

test_start "a revoked trade is silent with no rebuild in between"
rd revoke mending >/dev/null 2>&1
assert_eq "$(prompt 'mend this fence' s8)" "" "revoked"
approve mending

test_start "re-approved with new bytes and not yet rebuilt here: silent; rebuilt: the new line"
sed -i.bak 's/^cue: .*/cue: The diary first, always./' "$ROLO/pending/mending.md"
python3 -I -c 'import sqlite3, sys, hashlib
c = sqlite3.connect(sys.argv[1], isolation_level=None)
body = open(sys.argv[2], "rb").read(); d = hashlib.sha256(body).hexdigest()
c.execute("BEGIN"); c.execute("INSERT OR IGNORE INTO pages VALUES (?, ?)", (d, body))
c.execute("INSERT INTO ledger (slug, verb, digest, at) VALUES (?, ?, ?, ?)", ("mending", "approve", d, "2026-11-11T00:00:00Z"))
c.execute("COMMIT")' "$DB" "$ROLO/pending/mending.md"
assert_eq "$(prompt 'mend this fence' s9)" "" "new approval, live row still names the old page"
rd live >/dev/null 2>&1
assert_eq "$(prompt 'mend this fence' s10)" '**Maude:** I know who handles that: mending -> diary (skill). The diary first, always.' "rebuilt"

test_start "the seen file lives under the home; a link planted in the project closet is not followed"
VICTIM="$TEST_TMP/victim"; mkdir -p "$VICTIM" "$CLAUDE_PROJECT_DIR/.maude/plugin"
ln -s "$VICTIM" "$CLAUDE_PROJECT_DIR/.maude/plugin/rolodex-seen"
prompt 'fix the gate today' s20 >/dev/null
assert_eq "$(ls "$VICTIM" | wc -l | tr -d ' ')" "0" "nothing written through the planted link"
assert_file_exists "$HOME/.claude/maude/rolodex-seen/$(printf '%s' "$CLAUDE_PROJECT_DIR" | sed 's/[^a-zA-Z0-9]/-/g')/s20" "seen file under home"

test_start "a recipe whose file changes after approval and derive: silent"
mkdir -p "$HOME/r"; printf 'read me\n' > "$HOME/r/SKILL.md"
PIN="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$HOME/r/SKILL.md")"
cat > "$ROLO/pending/recipe.md" <<PAGE
trade: recipe
what: a hot-loaded file
when: cook the stew
pick: recipe | ~/r/SKILL.md | the house recipe
pin: $PIN
cue: Read the recipe first.
---
PAGE
approve recipe
assert_contains "$(prompt 'cook the stew' s21)" "Read the recipe first." "cues while the file matches its pin"
printf 'one more line\n' >> "$HOME/r/SKILL.md"
assert_eq "$(prompt 'cook the stew' s22)" "" "silent once the file changed"

test_start "a page whose stored bytes no longer hash to their key: silent"
sql "DROP TRIGGER pages_keep_u" "UPDATE pages SET body = CAST(body || x'0a' AS BLOB)"
assert_eq "$(prompt 'mend this fence' s11)" "" "tampered page"

print_summary
teardown_test_env
exit $FAILED
