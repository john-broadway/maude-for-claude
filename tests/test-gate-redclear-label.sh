#!/usr/bin/env bash
# The red-clear refusal names what it read. "a command that names the red-clear token file
# may only read it" was printed for every refusal, and most refusals in a day's work named
# no token file at all: a closet path beside `${MAP:-…}`, `$(ls …)`, `$1` in an awk program,
# `$(date …)` in a trace name, each refused because the static fold could not read the
# expansion and failed closed, as it should; the label said the command did what it did
# not do. A refusal that states the wrong reason is a lying refusal (the push-label rule:
# a wrong label trains clearing without reading; 2026-11-05, Maude's own wake refused
# twice). The rule is unchanged, fail-closed; only the label is true now, one of three:
#   unread   — the fold could not read something beside `.maude`, and nothing beside it
#              was caught writing (a write caught beside an unread expansion is still a
#              write, and says so: the lens on 1e4618d, finding 1)
#   redirect — a redirect into the token, or into a quoted or shell-built target
#   word     — a command word beside the token that is not a plain reader, named
# and the way the token was named is said too: by its stem, or by a word the shell
# builds inside .maude/plugin at run time, which the gate must read as the token (finding
# 2: "names the token file" was said of `trace/today-$(date +%F).jsonl`). The word printed
# is bounded to [a-z0-9_./+-] and 40 characters, and a word holding a quote marker prints
# as "a quoted word" (findings 4 and 5: a credential in a URL-shaped word and terminal
# escapes reached stderr; `"r"m` printed as `m`).

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

HOOKS_DIR="$(dirname "$0")/../hooks/scripts"
GATE="$HOOKS_DIR/maude-gate.sh"

run_gate() {
  ERR="$(make_bash_tool_input "$1" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

P="$TEST_TMP/.maude/plugin"
mkdir -p "$P/trace"; : > "$P/house-map.md"; : > "$P/trace/today.jsonl"
T="$P/care-redclear.json"

# ── unread: the fold could not read an expansion beside `.maude`, nothing caught writing ─
for c in \
  "cat \${MAP:-$P/house-map.md}" \
  "f=\$(ls -t $P/trace/*.jsonl | head -1); wc -l \"\$f\"" \
  "TZ=\"\$(grep -m1 '^timezone:' $P/house-map.md | awk '{print \$2}')\"; echo \$TZ" \
  "cat $P/house-map.md | awk '{print \$1}'" \
  "cat \$DIR/$P/house-map.md" \
  "echo .maude \$1" \
  "cat /srv/.maude-notes/a.txt \$X" \
  "cat $T \${x-sed}" \
  "cat $T \${x/rm/sed}" \
  "cat $T \${x+rm}" \
  "cat $T \$((1+2))" \
  "cat $T \$(( 1 + 2 ))" \
  "x=\${y-rm} cat $T" \
  "cat \${x-$P/house-map.md}" \
  ; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "unread: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "could not read" "says the fold could not read it"
  assert_contains "$ERR" "refused unread" "says it was refused unread"
  assert_not_contains "$ERR" "not caught writing" "does not claim nothing was caught"
  assert_contains "$ERR" "spells \`.maude\`" "names what the fold keyed on: the spelling .maude, not the closet"
  assert_not_contains "$ERR" "names the red-clear token file and" "does not claim the command named the token"
  assert_not_contains "$ERR" "spells the closet" "does not claim the closet was spelled"
done

# ── a write BEFORE the first expansion on an unread command is still a write, and says so ─
while IFS=$'\t' read -r cmd want; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "caught writing before an unread expansion: $cmd"
  run_gate "$cmd"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "$want" "names the write"
  assert_not_contains "$ERR" "refused unread" "not labelled unread"
done <<EOF
rm $T \$1	has \`rm\` beside it
echo x > $T; echo \$FOO	redirects into
sed -i s/a/b/ $T; cat \${MAP:-$P/house-map.md}	has \`sed\` beside it
mv $T $T.bak; echo \${x:-q}	has \`mv\` beside it
"rm" $T; cat $T \$1	has \`a quoted word\` beside it
EOF

# ── a write AFTER the first expansion on an unread command is not read: unread, and the
#    label says a write elsewhere in it was not read (lens 3 on 601ff37: naming it took a
#    boundary test that read `;` inside \${x:-a;rm b}, comments and case patterns as
#    boundaries, and a per-word loop that outran the hook) ───────────────────────────────
for c in \
  "cat \${MAP:-x} $T; rm $T" \
  "cat \${x:-q} $T; sed -i s/a/b/ $T" \
  "echo \${x:-q}; mv $T $T.bak" \
  "cat $T \$1; \"rm\" $T" \
  "cat $T \${x:-a;rm b}" \
  "cat $T \${x:-a&&mv b}" \
  "cat \${x:-q} $T # ; rm" \
  "cat \${x:-q} $T; case a in a|rm ) :;; esac" \
  "cat \${MAP:-x} $T; { rm $T; }" \
  "cat \${MAP:-x} $T; time -p rm $T" \
  ; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "unread, a write past the first expansion not read: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "refused unread; a write elsewhere in it was not read" "the honest label"
  assert_not_contains "$ERR" "has \`" "names no word"
done

# ── the touch is one pass: 620 fragments and a write, under the hook's budget ────────────
test_start "620 fragments do not outrun the hook (lens 3 on 601ff37, BLOCKING)"
rm -f "$(care_path)" "$(redclear_path)"
big="cat $T$(printf ' \${x-y}%.0s' $(seq 1 620)); rm $T"
t0=$EPOCHREALTIME
run_gate "$big"
t1=$EPOCHREALTIME
assert_exit "$RC" "2" "refused"
el="$(python3 -c "print(int(($t1-$t0)*1000))")"
assert_eq "$(( el < 2500 ))" "1" "under 2.5 s (took ${el} ms at loadavg $(cut -d' ' -f1 /proc/loadavg))"

# ── word: a command word beside the token that is not a plain reader, named ───────────
while IFS=$'\t' read -r cmd word; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "word: $cmd"
  run_gate "$cmd"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "names the red-clear token file and has \`$word\` beside it" "names the token by its stem and the word: $word"
  assert_contains "$ERR" "not a plain reader" "says why the word is refused"
done <<EOF
sed -i s/a/b/ $T	sed
rm $T	rm
mv $T $T.bak	mv
cat $T | python3 -c 'pass'	python3
cp $T /tmp/x	cp
time rm $T	rm
EOF

# ── built: a word inside the closet the shell builds reads as the token; the label says so ─
while IFS=$'\t' read -r cmd want; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "built word in the closet: $cmd"
  run_gate "$cmd"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "names a word inside .maude/plugin" "says the token was named by a built word"
  assert_contains "$ERR" "$want" "and what was caught"
  assert_not_contains "$ERR" "names the red-clear token file and" "does not claim the token's name was spelled"
done <<EOF
wc -l $P/trace/today-\$(date +%F).jsonl	has \`date\` beside it
tail -n 3 $P/trace/today-\`date +%F\`.jsonl	has \`date\` beside it
echo x > $P/trace/\$(date +%F).log	redirects into
rm $P/trace/*.jsonl	has \`rm\` beside it
PROJ="\${CLAUDE_PROJECT_DIR:-\$(pwd)}"; cat \$PROJ/.maude/plugin/house-map.md	has \`pwd\` beside it
EOF

# ── redirect: into the token, a quoted target, or one the shell builds ────────────────
for c in \
  "echo x > $T" \
  "echo x >> $T" \
  "cat $T > \"$T\"" \
  "cat $T > \$T2" \
  ; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "redirect: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "names the red-clear token file and redirects into" "names the redirect"
done

# ── the word printed is bounded, and a quoted word is not spelled ──────────────────────
while IFS=$'\t' read -r cmd want; do
  [ -n "$cmd" ] || continue
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "the printed word: $cmd"
  run_gate "$cmd"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "$want" "prints what it may"
done <<EOF
"r"m $T	has \`a quoted word\` beside it
a"b"c $T	has \`a quoted word\` beside it
rm"" $T	has \`a quoted word\` beside it
""cat x; "rm" $T	has \`a quoted word\` beside it
"rm" $T	has \`a quoted word\` beside it
https://u:p@h.example $T	has \`a word the label does not print
$(printf 'w%.0s' $(seq 1 60)) $T	has \`a word the label does not print
x$(printf '\033')[31mred $T	has \`a word the label does not print
caf$(printf '\303\251') $T	has \`a word the label does not print
$(printf '\357\275\222\357\275\215') $T	has \`a word the label does not print
EOF
test_start "a non-ASCII word does not reach stderr whatever the locale (lens 2 on f03f02e, finding 3)"
rm -f "$(care_path)" "$(redclear_path)"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 run_gate "caf$(printf '\303\251') $T"
assert_not_contains "$ERR" "caf" "the accented word is not printed"
test_start "a credential-shaped word does not reach stderr"
rm -f "$(care_path)" "$(redclear_path)"
run_gate "https://u:p@h.example $T"
assert_not_contains "$ERR" "u:p@" "the URL's credential part is not printed"
test_start "an escape byte does not reach stderr"
run_gate "x$(printf '\033')[31mred $T"
assert_not_contains "$ERR" "$(printf '\033')" "no ESC byte on stderr"

# ── every label keeps the rule and the way out ───────────────────────────────────────
for c in "cat \${MAP:-$P/house-map.md}" "rm $T" "echo x > $T" "rm $P/trace/*.jsonl"; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "the rule and the hand stay on the label: $c"
  run_gate "$c"
  assert_contains "$ERR" "may only read it" "the rule"
  assert_contains "$ERR" "account owner's hand" "whose hand clears a write"
  assert_contains "$ERR" "(looked in: " "names the file it read"
done

# ── controls: plain reads pass, as before ─────────────────────────────────────────────
for c in "grep -c x $P/house-map.md" "cat $T" "jq . $T" "MAP=$P/house-map.md; sed -n '1,5p' \$MAP" "ls $P/trace/*.jsonl" "cat $P/house-map.md | head -3; ls -t $P/trace/ | head -3" "cksum $T" "test -f $T"; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "control passes: $c"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done

# ── lens 5 on 238e1c9: four labels that lied ─────────────────────────────────────────
# 1. the word walk takes the first word after every seam as a command word: a case
#    pattern, an arithmetic operand, an array element, a function name or a comment is
#    read the same; the label says so and never says the word RUNS
for c in "cat $T; case x in a|rm) :;; esac" "cat $T && (( a > b ))" "cat $T; a=(1 2); echo" "cat $T; f() { :; }"; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "word read, not run: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "read as a command word" "says the gate read it as a command word"
  assert_contains "$ERR" "a case pattern" "says a pattern or an operand reads the same"
  assert_not_contains "$ERR" "runs \`" "never says the word runs"
done
# 2. a ( or { before the write empties the clean prefix; the write is not "past that
#    point" (the expansion), it is elsewhere, and the label says elsewhere
for c in "(rm $T); cat $T \$1" "{ rm $T; }; cat $T \$1"; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "unread, a write before the expansion behind a group: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "refused unread" "refused unread"
  assert_contains "$ERR" "a write elsewhere in it was not read" "says elsewhere"
  assert_not_contains "$ERR" "past that point" "never says past the expansion"
done
# 3. a quoted glob character is a literal byte: the word is one the gate cannot read whole,
#    not one the shell builds at run time
for c in "cat \"$P/house-map.md?\" | python3" "cat '$P/house-map[1].md' | python3"; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "quoted glob character: $c"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "cannot read whole" "says the gate cannot read the word whole"
  assert_contains "$ERR" "quoted or not" "names the quoted case"
  assert_not_contains "$ERR" "builds a word" "never says the shell builds it"
done
# 4. the fold's own caps (65 literal names, a value past 4 KB) are OVER with no expansion
#    in the command: the label says the cap, not "move the expansion out"
_caps="$(for i in $(seq 1 65); do printf 'a%s=1; ' "$i"; done)cat $T"
_big="v=$(printf 'x%.0s' $(seq 1 4097)); cat $T"
for c in "$_caps" "$_big"; do
  rm -f "$(care_path)" "$(redclear_path)"
  test_start "the fold's cap: ${c:0:40}…"
  run_gate "$c"
  assert_exit "$RC" "2" "refused"
  assert_contains "$ERR" "more than the gate's fold reads" "names the cap"
  assert_contains "$ERR" "refused unread" "still refused unread"
  assert_not_contains "$ERR" "move the expansion out" "no expansion to move"
done
rm -f "$(care_path)" "$(redclear_path)"
test_start "control: under the cap passes"
run_gate "v=$(printf 'x%.0s' $(seq 1 4000)); cat $T"
assert_exit "$RC" "0" "passes"
unset _caps _big

# ── the ritual text does not set a variable from \$(…) and spell the closet in one block ──
test_start "wake.md and check-on-claude.md leave no dangling closet variable"
for f in "$(dirname "$0")/../commands/wake.md" "$(dirname "$0")/../commands/check-on-claude.md"; do
  n="$(grep -cE '\$MAP\b|\$SELF\b|\$TRACE\b' "$f")"
  assert_eq "$n" "0" "no \$MAP/\$SELF/\$TRACE left in $(basename "$f")"
done

print_summary
teardown_test_env
exit $FAILED
