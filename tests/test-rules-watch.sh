#!/usr/bin/env bash
# Tests for hooks/scripts/maude-rules-watch.sh — the design-law rail.
#
# WHY THIS FILE EXISTS
# John, 2026-09-03: "maude needs to make sure claude follows rules. especially the 30 ux ones.
# the codd rule for db desing including 1nf 2nf and 3nf. at a minium" · "there is also the laws
# of memory human and machine" · "its also for everything we develop" · "and for the users".
# The laws live on a website and in textbooks; nothing consulted them at the moment a schema
# or a button was written. A hook is a rail.
#
# THE ASYMMETRY
# A missed class costs one whisper. A false NAMING stamp is a false all-clear. So classification
# may be generous and the stamp may not: heading AND canonical alias, in a file, never a commit
# message. Every row below that says "silent" is a control that must be able to fail.
set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT

RW="$HOOKS_DIR/maude-rules-watch.sh"
CARE="$(care_path)"
reset_all() { printf '{}\n' > "$CARE"; : > "$(trace_path)"; rm -rf "$TEST_TMP/proj"; mkdir -p "$TEST_TMP/proj"; }

write_env() {  # $1 path, $2 content, $3 sid (default abcdef12)
  jq -nc --arg p "$1" --arg c "$2" --arg s "${3:-abcdef12}" \
    '{tool_name:"Write", hook_event_name:"PostToolUse", session_id:$s, tool_input:{file_path:$p, content:$c}}'
}
edit_env() {  # $1 path, $2 new_string, $3 sid
  jq -nc --arg p "$1" --arg c "$2" --arg s "${3:-abcdef12}" \
    '{tool_name:"Edit", hook_event_name:"PostToolUse", session_id:$s, tool_input:{file_path:$p, old_string:"x", new_string:$c}}'
}
commit_env() {  # $1 sid, $2 message
  jq -nc --arg s "${1:-abcdef12}" --arg m "${2:-wip}" \
    '{tool_name:"Bash", hook_event_name:"PreToolUse", session_id:$s, tool_input:{command:("git commit -m " + $m)}}'
}
# The redirect ORDER is deliberate: `2>&1 >/dev/null` sends stderr to the captured stdout and
# drops the original stdout, so a caller sees the whisper channel ONLY. Shellcheck reads the
# order as the common mistake (SC2069); here it is the point.
# shellcheck disable=SC2069
classify() { bash "$RW" classify 2>&1 >/dev/null; }
# shellcheck disable=SC2069
check()    { bash "$RW" check    2>&1 >/dev/null; }
care() { read_care "$1"; }

# ── classify by path ───────────────────────────────────────────────────────────
test_start "an html write whispers the UI law once and records the touch"
reset_all
ERR="$(write_env "$TEST_TMP/proj/race-card.html" "<div>hi</div>" | classify)"
assert_contains "$ERR" "UI surface" "first touch whispers"
assert_contains "$ERR" "/maude:rules ux" "names the command"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "1" "touch recorded"
assert_ne "$(care '.rules.abcdef12.whispered.ui')" "null" "whispered stamped"

test_start "a second UI write in the same session is silent"
ERR2="$(write_env "$TEST_TMP/proj/other.css" "a{}" | classify)"
assert_eq "$ERR2" "" "silent on the second touch"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "2" "but the touch is still recorded"

test_start "another session gets its own whisper and its own state"
ERR3="$(write_env "$TEST_TMP/proj/x.html" "<p>" "ffffffff" | classify)"
assert_contains "$ERR3" "UI surface" "sibling session whispers for itself"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "2" "mine untouched by theirs"

test_start "a .sql write whispers the schema law"
reset_all
ERR="$(write_env "$TEST_TMP/proj/orders.sql" "CREATE TABLE orders (id INT PRIMARY KEY);" | classify)"
assert_contains "$ERR" "declares a schema" "schema whisper"
assert_contains "$ERR" "third normal form" "names the floor"

test_start "a memory-stem file whispers the memory law; restore.py does not"
reset_all
ERR="$(write_env "$TEST_TMP/proj/store.py" "x = 1" | classify)"
assert_contains "$ERR" "memory surface" "store.py is a memory surface by stem"
reset_all
ERR="$(write_env "$TEST_TMP/proj/restore.py" "x = 1" | classify)"
assert_eq "$ERR" "" "restore.py is not (stem, not substring)"

# ── classify by content, with boundaries ───────────────────────────────────────
test_start "CREATE TABLE inside a python string classifies as schema"
reset_all
printf 'cur.execute("CREATE TABLE laps (driver TEXT)")\n' > "$TEST_TMP/proj/db.py"
ERR="$(write_env "$TEST_TMP/proj/db.py" "$(cat "$TEST_TMP/proj/db.py")" | classify)"
assert_contains "$ERR" "declares a schema" "content marker"

test_start "ttl inside throttle and lru inside lru_cache do not classify as memory"
reset_all
ERR="$(write_env "$TEST_TMP/proj/net.py" "throttle = 5; from functools import lru_cache" | classify)"
assert_eq "$ERR" "" "no substring hit"
ERR="$(write_env "$TEST_TMP/proj/evictor.py" "def evict(key): pass" | classify)"
assert_contains "$ERR" "memory surface" "the identifier evict does classify"

# The marker literals in the rail are written disarmed so the file does not classify
# itself; these rows prove the disarmed patterns still match the real thing.
test_start "the UI content markers still match a real tag, handler and toolkit"
reset_all
ERR="$(write_env "$TEST_TMP/proj/widget.lua" 'local s = [[<button>ok</button>]]' | classify)"
assert_contains "$ERR" "UI surface" "a button tag in a lua string"
reset_all
ERR="$(write_env "$TEST_TMP/proj/panel.py" "import tkinter" | classify)"
assert_contains "$ERR" "UI surface" "a toolkit import"
reset_all
ERR="$(write_env "$TEST_TMP/proj/w.lua" 'el.onClick = f' | classify)"
assert_contains "$ERR" "UI surface" "a click handler"

test_start "the memory content markers still match ttl, lru and supersede"
reset_all
ERR="$(write_env "$TEST_TMP/proj/c.lua" "local ttl = 60" | classify)"
assert_contains "$ERR" "memory surface" "ttl"
reset_all
ERR="$(write_env "$TEST_TMP/proj/c2.lua" "-- lru policy" | classify)"
assert_contains "$ERR" "memory surface" "lru"
reset_all
ERR="$(write_env "$TEST_TMP/proj/c3.lua" "-- superseded by the next row" | classify)"
assert_contains "$ERR" "memory surface" "supersed"

# ── an ORM marker only counts where an ORM can live ───────────────────────────
# Ruling: the ORM markers were matched in any file at all, so any text that merely
# QUOTED one classified. The markers now apply to py, php, js, ts and rb; a raw
# CREATE TABLE still counts anywhere, because a schema in a string is a schema.
test_start "an ORM marker classifies in a language an ORM lives in, and not elsewhere"
reset_all
ERR="$(write_env "$TEST_TMP/proj/models.py" "class Hero(SQLModel, table=True): pass" | classify)"
assert_contains "$ERR" "declares a schema" "py: the ORM marker counts"
reset_all
ERR="$(write_env "$TEST_TMP/proj/models.rb" "class X; Column(:a); end" | classify)"
assert_contains "$ERR" "declares a schema" "rb: the ORM marker counts"
reset_all
ERR="$(write_env "$TEST_TMP/proj/m.py" "class Lap(models.Model): pass" | classify)"
assert_contains "$ERR" "declares a schema" "py: models.Model counts"
reset_all
ERR="$(write_env "$TEST_TMP/proj/m.php" 'Schema::create("laps", $cb);' | classify)"
assert_contains "$ERR" "declares a schema" "php: Schema::create counts"
reset_all
ERR="$(write_env "$TEST_TMP/proj/deploy.sh" "echo SQLModel" | classify)"
assert_eq "$ERR" "" "sh: the same word is not a schema"
assert_eq "$(care '.rules.abcdef12.touched // {} | length')" "0" "and no touch"
reset_all
ERR="$(write_env "$TEST_TMP/proj/deploy.sh" 'psql -c "CREATE TABLE t (id INT)"' | classify)"
assert_contains "$ERR" "declares a schema" "sh: a real CREATE TABLE still counts"

# The rail scans text, and the rail IS text. Writing its own source must not classify it
# by the schema or memory markers its own comments carry: documenting a trap springs it.
# It IS a UI surface, though: it prints "Maude:" lines to the person (the UX lens,
# 2026-09-06, D6), and the one honest classification is the one it gets.
test_start "the rail's own source is the UI surface it is, and nothing else"
reset_all
ERR="$(write_env "$RW" "$(cat "$RW")" | classify)"
assert_contains "$ERR" "UI surface" "the rail speaks to the person, so it is a UI surface"
assert_eq "$(care '.rules.abcdef12.touched.schema // [] | length')" "0" "not a schema by its own markers"
assert_eq "$(care '.rules.abcdef12.touched.memory // [] | length')" "0" "not a memory surface by its own markers"

# ── fixtures are not surfaces ──────────────────────────────────────────────────
test_start "files under tests/ or fixtures/ and test_* names are never classified"
reset_all
mkdir -p "$TEST_TMP/proj/tests/fixtures"
for p in "$TEST_TMP/proj/tests/fixtures/bad.sql" "$TEST_TMP/proj/test_schema.py" "$TEST_TMP/proj/ui_test.html" "$TEST_TMP/proj/card.spec.js"; do
  ERR="$(write_env "$p" "CREATE TABLE t (x INT); <button>" | classify)"
  assert_eq "$ERR" "" "silent: $p"
done
assert_eq "$(care '.rules.abcdef12.touched // {} | length')" "0" "no touches recorded"

# ── a stamp can only come from a doc that is not a fixture ────────────────────
# Ruling: rules_stamp used to run on every written file, so a fixture under tests/
# or the rail's OWN script (its header prose names rulebooks and law aliases) could
# stamp a class that was never honestly named. Fixture wins first, before any stamp
# attempt; a non-doc file (code) never attempts a stamp at all.
test_start "a fixture doc never stamps, even with a valid UX-laws section"
reset_all
DOC=$'## UX laws this holds to\n\nFitts: every button pressable across its box.\n'
write_env "$TEST_TMP/proj/tests/design.md" "$DOC" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "fixture path: no stamp"

test_start "a non-doc file whose comments look like a heading and an alias does not stamp or touch"
reset_all
SH=$'#!/usr/bin/env bash\n# ## Normal forms\n# including 1nf 2nf and 3nf at a minimum\n'
write_env "$TEST_TMP/proj/hooks/scripts/x.sh" "$SH" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.schema // "" | tostring')" "" "no stamp: not a doc"
assert_eq "$(care '.rules.abcdef12.touched // {} | length')" "0" "no touch either"

# ── the stamp ─────────────────────────────────────────────────────────────────
test_start "a design with a UX-laws heading and a canonical name stamps named.ui"
reset_all
DOC=$'# Race card\n\n## UX laws this holds to\n\n- Fitts: every button pressable across its box.\n- Hick: four choices, not nine.\n'
ERR="$(write_env "$TEST_TMP/proj/docs/design.md" "$DOC" | classify)"
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "stamped"
assert_contains "$(care '.rules.abcdef12.named.ui.laws | join(",")')" "fitts" "law recorded"
assert_eq "$(care '.rules.abcdef12.touched.ui // [] | length')" "0" "a markdown file is never a touch"
assert_eq "$ERR" "" "the stamp is silent"

test_start "heading alone does not stamp; a law name alone does not stamp"
reset_all
write_env "$TEST_TMP/proj/docs/a.md" $'## UX laws\n\nnothing named here' | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "heading alone: no stamp"
write_env "$TEST_TMP/proj/docs/b.md" $'# Notes\n\nFitts and Hick are relevant.' | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "name alone: no stamp"

# ── the stamp is section-scoped ──────────────────────────────────────────────
# Ruling: the alias must fall between the matching heading line and the next line
# that opens at the same or shallower "#" depth (or EOF). A rulebook name and a
# law name can both be true of a document without either one governing the other.
test_start "an alias past the section boundary (a later same-depth heading) does not stamp"
reset_all
DOC=$'## UX laws\n\n## Notes\n\nFitts and Hick are relevant here.\n'
write_env "$TEST_TMP/proj/docs/c.md" "$DOC" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "alias outside the section: no stamp"

test_start "an alias inside the section (before the next same-depth heading) stamps"
reset_all
DOC=$'## UX laws\n\nFitts: every button pressable across its box.\n\n## Notes\n\nunrelated\n'
write_env "$TEST_TMP/proj/docs/d.md" "$DOC" | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "alias inside the section: stamped"

# ── only PROSE may stamp ──────────────────────────────────────────────────────
# Ruling: DOC_RE decides "never a touch" for a wide set (json, yml, lock, csv, svg,
# png, pdf). Deciding "may stamp" from the same set let a config file's own words
# stamp a class, and cost a `cat` of every lockfile and every binary written. The
# only stamp source is prose: md, markdown, txt, rst, adoc.
test_start "a .yml whose content reads like a naming section does not stamp"
reset_all
write_env "$TEST_TMP/proj/laws.yml" $'# Laws of UX\nflow: fast\n' | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "yml: no stamp"
assert_eq "$(care '.rules.abcdef12.touched // {} | length')" "0" "yml: no touch either"

test_start "a .lock with a real heading and a real alias does not stamp and is never read"
reset_all
mkdir -p "$TEST_TMP/proj"
printf '## UX laws this holds to\n\nFitts: pressable across its box\n' > "$TEST_TMP/proj/deps.lock"
write_env "$TEST_TMP/proj/deps.lock" "irrelevant" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named // "" | tostring')" "" "lock: nothing named"

test_start "a binary write prints nothing at all, not even a null-byte warning"
reset_all
mkdir -p "$TEST_TMP/proj"
printf 'PNG\000\000IHDR\000rest\n' > "$TEST_TMP/proj/logo.png"
OUT="$(write_env "$TEST_TMP/proj/logo.png" "binary" | bash "$RW" classify 2>&1)"
assert_eq "$OUT" "" "png: no stdout, no stderr"

test_start "a .txt design still stamps: prose is prose"
reset_all
write_env "$TEST_TMP/proj/design.txt" $'## UX laws this holds to\n\nFitts: pressable.\n' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "txt stamps"

# ── the heading phrase matches on word boundaries ─────────────────────────────
# Ruling: the heading match had no boundary, so `## Redux laws` matched `ux laws?`
# and any UX alias below it stamped a class no one had named.
test_start "Redux laws does not open the UX section; UX laws does"
reset_all
write_env "$TEST_TMP/proj/docs/redux.md" $'## Redux laws\n\nflow: fast\n' | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "Redux laws: no stamp"
reset_all
write_env "$TEST_TMP/proj/docs/ux.md" $'## UX laws\n\nflow: one task at a time\n' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "UX laws: stamped"
reset_all
write_env "$TEST_TMP/proj/docs/ux2.md" $'## The UX laws this holds to\n\nFitts: pressable.\n' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "the phrase inside a longer heading: stamped"

test_start "Linux laws of memory does not open the UX section; Laws of memory opens the memory one"
reset_all
write_env "$TEST_TMP/proj/docs/linux.md" $'## Linux laws of memory\n\nflow: fast\n' | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "ux laws inside linux laws: no ui stamp"
reset_all
write_env "$TEST_TMP/proj/docs/mem2.md" $'## Laws of memory\n\nJost: the newest memory is the most fragile.\n' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.memory.ts')" "null" "Laws of memory: stamped"

test_start "a normal-forms heading with 3NF stamps schema; a laws-of-memory heading with Jost stamps memory"
reset_all
write_env "$TEST_TMP/proj/docs/db.md" $'## Normal forms\n\nEvery table holds to 3NF.' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.schema.ts')" "null" "schema stamped"
write_env "$TEST_TMP/proj/docs/mem.md" $'## Laws of memory\n\nJost: the newest memory is the most fragile.' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.memory.ts')" "null" "memory stamped"

# ── an Edit envelope stamps from the file on disk, not new_string alone ────────
# Ruling: new_string is only the replacement fragment. PostToolUse fires AFTER the
# write has landed, so the file on disk is the one complete copy — read it when it
# exists; fall back to the envelope's own content only when the file is absent.
test_start "an Edit envelope stamps from the file already landed on disk"
reset_all
mkdir -p "$TEST_TMP/proj/docs"
# The heading was already there; the alias line is what this Edit just landed. The
# envelope's new_string alone carries no heading — only the disk copy has both.
printf '## UX laws this holds to\n\n- Fitts: pressable across its box\n' > "$TEST_TMP/proj/docs/design.md"
edit_env "$TEST_TMP/proj/docs/design.md" "- Fitts: pressable across its box" | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "stamped from disk, not the fragment"

test_start "the envelope content is the fallback when the file is absent from disk"
reset_all
edit_env "$TEST_TMP/proj/docs/ghost.md" $'## UX laws this holds to\n\nFitts.' | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "no file on disk: envelope content used"

# ── fenced code blocks are inert to the extractor ──────────────────────────────
test_start "a heading-shaped line inside a fence does not close the section"
reset_all
DOC=$'## UX laws this holds to\n\n```\n## Notes\n```\n\nFitts: every button pressable.\n'
write_env "$TEST_TMP/proj/docs/fence-heading.md" "$DOC" | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "section stayed open past the fenced heading-shaped line"

test_start "an alias inside a fence does not stamp"
reset_all
DOC=$'## UX laws this holds to\n\n```\nFitts: every button pressable.\n```\n'
write_env "$TEST_TMP/proj/docs/fence-alias.md" "$DOC" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "fenced alias does not stamp"

# CommonMark allows a fence to open indented up to three spaces; the fence test must walk
# the leading spaces rather than matching only column zero.
test_start "a fence indented by one space still hides its alias"
reset_all
DOC=$'## UX laws this holds to\n\n ```\nFitts: every button pressable.\n ```\n'
write_env "$TEST_TMP/proj/docs/fence-indent.md" "$DOC" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.named.ui // "" | tostring')" "" "indented fence still hides the alias"

test_start "the same doc with Fitts outside an indented fence stamps"
reset_all
DOC=$'## UX laws this holds to\n\nFitts: every button pressable.\n\n ```\nsomething unrelated\n ```\n'
write_env "$TEST_TMP/proj/docs/fence-indent-outside.md" "$DOC" | classify >/dev/null
assert_ne "$(care '.rules.abcdef12.named.ui.ts')" "null" "stamped: alias outside the indented fence"

# ── the alias alternation is built in one pass, and escapes the same ──────────
# Ruling: the alternation forked maude_ere_escape once per alias, which is one
# process per law per book on every doc write. One sed over the whole stream does
# the same job; these rows hold the escaping identical where it matters.
test_start "an alias carrying an apostrophe or a parenthesis still matches"
reset_all
mkdir -p "$TEST_TMP/books"
cat > "$TEST_TMP/books/laws-of-ux.json" <<'JSON'
{"name":"t","class":"ui","heading":"ux laws?","laws":[
 {"id":"a","name":"A","aliases":["Fitts's Law"],"ask":"?"},
 {"id":"b","name":"B","aliases":["Miller (chunking)"],"ask":"?"}]}
JSON
DOC=$'## UX laws\n\nFitts\'s Law: pressable across its box.\n'
write_env "$TEST_TMP/proj/docs/apos.md" "$DOC" | MAUDE_RULES_DIR="$TEST_TMP/books" bash "$RW" classify >/dev/null 2>&1
assert_contains "$(care '.rules.abcdef12.named.ui.laws | join(",")')" "fitts's law" "the apostrophe alias matched"
reset_all
DOC=$'## UX laws\n\nMiller (chunking): seven plus or minus two.\n'
write_env "$TEST_TMP/proj/docs/paren.md" "$DOC" | MAUDE_RULES_DIR="$TEST_TMP/books" bash "$RW" classify >/dev/null 2>&1
assert_contains "$(care '.rules.abcdef12.named.ui.laws | join(",")')" "miller (chunking)" "the parenthesis alias matched"

# ── the first write in a project with no .maude/plugin still records ───────────
# Ruling: maude_care_ensure could not seed care.json into a directory that did not
# exist, so the whispered flag never landed and the SAME class whispered on every
# single write. The writer creates its own closet.
test_start "a project with no .maude/plugin whispers once, not every time"
FRESH="$(mktemp -d)"
ERR="$(printf '%s' "$(write_env "$FRESH/a.html" "<p>")" | CLAUDE_PROJECT_DIR="$FRESH" bash "$RW" classify 2>&1 >/dev/null)"
assert_contains "$ERR" "UI surface" "the first write whispers"
ERR="$(printf '%s' "$(write_env "$FRESH/b.html" "<p>")" | CLAUDE_PROJECT_DIR="$FRESH" bash "$RW" classify 2>&1 >/dev/null)"
assert_eq "$ERR" "" "the second write is silent"
assert_eq "$(jq -r '.rules.abcdef12.touched.ui | length' "$FRESH/.maude/plugin/care.json" 2>/dev/null)" "2" "both touches recorded"
rm -rf "$FRESH"

# ── the last fifty are the last fifty TOUCHED ────────────────────────────────
# Ruling: `unique` sorts alphabetically, so the bounded window kept the last fifty
# paths in the ALPHABET, not the last fifty touched. Remove then append.
test_start "re-touching a file moves it to the end of the touched list"
reset_all
for n in c a b; do write_env "$TEST_TMP/proj/$n.html" "<p>" | classify >/dev/null; done
assert_eq "$(care '.rules.abcdef12.touched.ui | map(split("/") | last) | join(",")')" "c.html,a.html,b.html" "touch order, not alphabetical"
write_env "$TEST_TMP/proj/c.html" "<p>" | classify >/dev/null
assert_eq "$(care '.rules.abcdef12.touched.ui | map(split("/") | last) | join(",")')" "a.html,b.html,c.html" "the re-touched file moved to the end"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "3" "and is not duplicated"

# ── the check at commit ────────────────────────────────────────────────────────
test_start "commit with UI touched and unnamed whispers once, re-armed by a new touch"
reset_all
write_env "$TEST_TMP/proj/a.html" "<p>" | classify >/dev/null
# The re-arm predicate is second-resolution: a touch landing in the SAME second as the
# check that follows it is treated as a re-arm, not silence (that direction is the safe
# one). Separate the touch from the first check by a full second so "second commit is
# silent" below tests the intended shape (checked strictly after the touch), not a tie.
sleep 1
ERR="$(commit_env | check)"
assert_contains "$ERR" "no design names a Law of UX" "whispers at the commit"
assert_contains "$ERR" "1 UI file" "counts the files"
ERR="$(commit_env | check)"
assert_eq "$ERR" "" "second commit is silent"
sleep 1
write_env "$TEST_TMP/proj/b.html" "<p>" | classify >/dev/null
ERR="$(commit_env | check)"
assert_contains "$ERR" "2 UI file" "a new touch re-arms it"

test_start "a commit message naming the laws never stamps"
reset_all
write_env "$TEST_TMP/proj/a.html" "<p>" | classify >/dev/null
ERR="$(commit_env abcdef12 '"## UX laws: Fitts, Hick"' | check)"
assert_contains "$ERR" "no design names a Law of UX" "message text is not a stamp"

test_start "named BEFORE the edits keeps the commit silent (design-first order)"
reset_all
write_env "$TEST_TMP/proj/docs/design.md" $'## UX laws\n\nFitts.' | classify >/dev/null
sleep 1
write_env "$TEST_TMP/proj/a.html" "<p>" | classify >/dev/null
ERR="$(commit_env | check)"
assert_eq "$ERR" "" "silent when the law was named first"

test_start "docs-only edits never whisper at the commit"
reset_all
write_env "$TEST_TMP/proj/README.md" "hello" | classify >/dev/null
ERR="$(commit_env | check)"
assert_eq "$ERR" "" "no touched class, no whisper"

test_start "a non-commit command is ignored by check"
reset_all
write_env "$TEST_TMP/proj/a.html" "<p>" | classify >/dev/null
ERR="$(jq -nc '{tool_name:"Bash",hook_event_name:"PreToolUse",session_id:"abcdef12",tool_input:{command:"git status"}}' | check)"
assert_eq "$ERR" "" "git status is not a commit"

# ── the linter through the rail ────────────────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
  test_start "a schema write with no key whispers the finding, unchanged is silent, fixed says clean"
  reset_all
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/proj/s.sql"
  ERR="$(write_env "$TEST_TMP/proj/s.sql" "$(cat "$TEST_TMP/proj/s.sql")" | classify)"
  assert_contains "$ERR" "1 finding(s)" "finding whispered"
  assert_contains "$ERR" "codd-2" "rule named"
  ERR="$(write_env "$TEST_TMP/proj/s.sql" "$(cat "$TEST_TMP/proj/s.sql")" | classify)"
  assert_eq "$ERR" "" "same findings, silent"
  printf 'CREATE TABLE t (id INT PRIMARY KEY, name TEXT);\n' > "$TEST_TMP/proj/s.sql"
  ERR="$(write_env "$TEST_TMP/proj/s.sql" "$(cat "$TEST_TMP/proj/s.sql")" | classify)"
  assert_contains "$ERR" "clean now" "fixed says clean once"

  test_start "the commit check re-runs the linter over touched schema files"
  reset_all
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/proj/s.sql"
  write_env "$TEST_TMP/proj/s.sql" "x" | classify >/dev/null
  write_env "$TEST_TMP/proj/docs/db.md" $'## Normal forms\n\n3NF' | classify >/dev/null
  ERR="$(commit_env | check)"
  assert_contains "$ERR" "finding(s)" "open findings reported even when named"
  assert_not_contains "$ERR" "no design names" "naming satisfied"

  # ── a schema file with no table is neither a finding nor a fix ───────────────
  # "clean" is a claim the linter earned; "no CREATE TABLE found" is a file it had
  # nothing to say about. Storing the second would make the next real result read as
  # a change, and whispering "clean now" would claim a repair that never happened.
  test_start "an ALTER-only schema file is silent and records no finding"
  reset_all
  printf 'ALTER TABLE orders ADD COLUMN total INT;\n' > "$TEST_TMP/proj/alter.sql"
  ERR="$(write_env "$TEST_TMP/proj/alter.sql" "x" | classify)"
  assert_contains "$ERR" "declares a schema" "the class whisper still fires"
  assert_not_contains "$ERR" "finding" "no finding whispered"
  assert_not_contains "$ERR" "clean now" "no repair claimed"
  assert_eq "$(care '.rules.abcdef12.findings // {} | length')" "0" "nothing stored"

  # ── a project's own maude_rules/ is never the linter the rail runs ────────────
  # `python3 -m` puts the CWD ahead of PYTHONPATH on sys.path, so a project that
  # carries its own maude_rules/ package would be EXECUTED by the rail and its
  # stdout spoken as Maude. Both belts are tested at once here: whatever the
  # planted package prints must never reach the whisper, and the real finding must
  # still arrive.
  test_start "a project's own maude_rules package is never the linter the rail runs"
  reset_all
  mkdir -p "$TEST_TMP/proj/maude_rules"
  : > "$TEST_TMP/proj/maude_rules/__init__.py"
  printf 'import sys\nprint("EVIL: 0 finding(s): clean")\nsys.exit(0)\n' > "$TEST_TMP/proj/maude_rules/__main__.py"
  printf 'CREATE TABLE t (name TEXT);\n' > "$TEST_TMP/proj/s.sql"
  ERR="$(cd "$TEST_TMP/proj" && write_env "$TEST_TMP/proj/s.sql" "x" | classify)"
  assert_not_contains "$ERR" "EVIL" "the shadowing package is not executed"
  assert_contains "$ERR" "codd-2" "the real finding still whispers"

  test_start "the commit check is shadow-proof too"
  ERR="$(cd "$TEST_TMP/proj" && commit_env | check)"
  assert_not_contains "$ERR" "EVIL" "check does not run the shadowing package"
  assert_contains "$ERR" "1 finding(s) still open" "check counts the real finding"
fi

# ── stale sessions age out of the store ───────────────────────────────────────
# Ruling: care.json kept every sid that ever worked in this tree, so a lane that
# ran once in April was still an unnamed class in September. The writer prunes any
# session whose NEWEST timestamp across last_touch, whispered, named.*.ts and
# checked is older than seven days. The cutoff is computed with the portable epoch
# helpers; `date -u -d '7 days ago'` is GNU-only and would be silently empty on BSD.
iso_days_ago() {  # $1 whole days back, as the rail's own ISO shape
  bash -c ". \"$HOOKS_DIR/_maude-common.sh\"; maude_epoch_iso $(( $(date -u +%s) - $1 * 86400 ))"
}
plant_two_sessions() {
  jq -nc --arg s "$(iso_days_ago 8)" --arg f "$(iso_days_ago 6)" \
    '{rules:{
       "11111111":{touched:{ui:["old.html"]},last_touch:{ui:$s},whispered:{ui:$s}},
       "22222222":{touched:{ui:["recent.html"]},last_touch:{ui:$f},whispered:{ui:$f}}}}' > "$CARE"
}

test_start "classify prunes a session older than seven days and keeps a six-day-old one"
reset_all
plant_two_sessions
write_env "$TEST_TMP/proj/new.html" "<p>" | classify >/dev/null
assert_eq "$(care '.rules["11111111"] // "" | tostring')" "" "the eight-day-old session is gone"
assert_ne "$(care '.rules["22222222"].last_touch.ui')" "null" "the six-day-old session stays"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "1" "this session's own touch still lands"

test_start "check prunes too, and a naming stamp alone keeps a session alive"
reset_all
jq -nc --arg s "$(iso_days_ago 8)" --arg f "$(iso_days_ago 6)" \
  '{rules:{
     "11111111":{touched:{ui:["old.html"]},last_touch:{ui:$s}},
     "22222222":{named:{ui:{ts:$f,file:"d.md",laws:["fitts"]}}}}}' > "$CARE"
commit_env | check >/dev/null
assert_eq "$(care '.rules["11111111"] // "" | tostring')" "" "stale session pruned at the commit"
assert_ne "$(care '.rules["22222222"].named.ui.ts')" "null" "named.ts alone counts as a timestamp"

# ── switches and guards ────────────────────────────────────────────────────────
test_start "MAUDE_RULES=off silences classify and check and writes nothing"
reset_all
ERR="$(write_env "$TEST_TMP/proj/a.html" "<p>" | MAUDE_RULES=off bash "$RW" classify 2>&1 >/dev/null)"
assert_eq "$ERR" "" "classify silent"
assert_eq "$(care '.rules // {} | length')" "0" "nothing written"

test_start "inert under MAUDE_EYE_BLINK=1"
reset_all
OUT="$(write_env "$TEST_TMP/proj/a.html" "<p>" | MAUDE_EYE_BLINK=1 bash "$RW" classify 2>&1)"
assert_eq "$OUT" "" "blink: no output"
assert_eq "$(care '.rules // {} | length')" "0" "blink: nothing written"

test_start "silent without jq"
reset_all
NOJQ="$(make_nojq_bin)"
OUT="$(write_env "$TEST_TMP/proj/a.html" "<p>" | PATH="$NOJQ" bash "$RW" classify 2>&1)"
assert_eq "$OUT" "" "no jq: silent"

test_start "a missing python3 leaves the schema whisper and skips the linter"
reset_all
NOPY="$(make_no_binary_bin python3)"
ERR="$(write_env "$TEST_TMP/proj/s.sql" "CREATE TABLE t (name TEXT);" | PATH="$NOPY" bash "$RW" classify 2>&1 >/dev/null)"
assert_contains "$ERR" "declares a schema" "whisper survives"
assert_not_contains "$ERR" "finding" "no linter output"

# ── wiring: the calls that make the rail real ──────────────────────────────────
test_start "post-tool-use delivers classify with NO house-map (above the map guard)"
reset_all
ERR="$(write_env "$TEST_TMP/proj/a.html" "<p>" | bash "$HOOKS_DIR/maude-post-tool-use.sh" 2>&1 >/dev/null)"
assert_contains "$ERR" "UI surface" "wired above maude_have_map"

test_start "post-tool-use reads stdin once: the watched-path trace names the real tool"
reset_all
mkdir -p "$TEST_TMP/.maude/plugin"
printf '# map\n\n## Watch list\n- a.html\n\n## Other\n' > "$TEST_TMP/.maude/plugin/house-map.md"
edit_env "$TEST_TMP/proj/a.html" "<p>" | bash "$HOOKS_DIR/maude-post-tool-use.sh" >/dev/null 2>&1
assert_eq "$(count_trace_lines '.kind == "post-tool" and (.payload | test("tool=Edit"))')" "1" "tool=Edit, not the write default"
rm -f "$TEST_TMP/.maude/plugin/house-map.md"

test_start "bash-watch delivers check on stderr (not suppressed)"
reset_all
write_env "$TEST_TMP/proj/a.html" "<p>" | classify >/dev/null
ERR="$(commit_env | bash "$HOOKS_DIR/maude-bash-watch.sh" 2>&1 >/dev/null)"
assert_contains "$ERR" "no design names a Law of UX" "delivered through bash-watch"

# ── Her own voice is a UI surface (the UX lens, 2026-09-06, D6): the rail classified
# app.css and Button.tsx and was silent on maude-gate.sh, maude-session-start.sh and
# commands/wake.md, the surfaces the person actually reads. A terminal is a UI.
test_start "a shell script that prints to the person's stderr is a UI surface"
reset_all
mkdir -p "$TEST_TMP/proj/hooks/scripts"
ERR="$(write_env "$TEST_TMP/proj/hooks/scripts/maude-nudge.sh" "$(printf '#!/usr/bin/env bash\nprintf "Maude: heads up\\n" >&2\n')" | classify)"
assert_contains "$ERR" "UI surface" "a hook that speaks is a UI surface"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "1" "the touch is recorded"

test_start "a shell script that prints nothing to the person is not"
reset_all
mkdir -p "$TEST_TMP/proj/scripts"
ERR="$(write_env "$TEST_TMP/proj/scripts/build.sh" "$(printf '#!/usr/bin/env bash\nmake all\n')" | classify)"
assert_eq "$ERR" "" "a silent script gets no UI whisper"
assert_eq "$(care '.rules.abcdef12.touched // {} | length')" "0" "and no touch"

test_start "a command file with a Format section is a UI surface as well as a stamp site"
reset_all
mkdir -p "$TEST_TMP/proj/commands"
ERR="$(write_env "$TEST_TMP/proj/commands/wake.md" "$(printf '# /maude:wake\n\n## Format\n\nMaude here.\n')" | classify)"
assert_contains "$ERR" "UI surface" "the format a person reads is a UI surface"
assert_eq "$(care '.rules.abcdef12.touched.ui | length')" "1" "the touch is recorded"

test_start "a prose file with no Format section is still only a stamp site"
reset_all
mkdir -p "$TEST_TMP/proj/docs"
ERR="$(write_env "$TEST_TMP/proj/docs/notes.md" "$(printf '# Notes\n\nplain prose\n')" | classify)"
assert_eq "$(care '.rules.abcdef12.touched // {} | length')" "0" "no touch from plain prose"


# ── the Format exception is a HEADING at depth two, not quoted text, not a subsection ──
# (the 23rd lens, MINOR-7: `^##+[[:space:]]+Format` matched a "## Format" inside a fenced
# code block, so any doc that documents command files became a UI surface, and it matched
# "### Format" at depth three.)
test_start "a '## Format' inside a fenced code block does not make a doc a UI surface"
reset_all
ERR="$(write_env "$TEST_TMP/proj/notes.md" "$(printf '# Notes on command files\n\n```markdown\n## Format\nsomething\n```\n')" | classify)"
assert_eq "$(care '.rules.abcdef12.touched.ui // [] | length')" "0" "quoted text is not a section"

test_start "a '### Format' at depth three is not the command's Format section"
reset_all
ERR="$(write_env "$TEST_TMP/proj/deep.md" "$(printf '# Doc\n\n### Format\nx\n')" | classify)"
assert_eq "$(care '.rules.abcdef12.touched.ui // [] | length')" "0" "depth three does not count"

test_start "a real '## Format' section still classifies the command file as a UI surface"
reset_all
ERR="$(write_env "$TEST_TMP/proj/commands/wake.md" "$(printf '# /wake\n\n## Format\n\nMaude here.\n')" | classify)"
assert_eq "$(care '.rules.abcdef12.touched.ui // [] | length')" "1" "the section is a surface"

print_summary
teardown_test_env
exit "$FAILED"
