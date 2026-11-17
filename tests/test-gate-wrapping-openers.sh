#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: the lens rounds on where the opener line is, the blanker, prefixes and sudo.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

# ── lens on merged main b2faa51 (2026-10-02): the opener line is not always where the shell ──
# word is, the stripper opened phantom bodies on lines bash does not, and a shell can be spelled
# one indirection away. Every shape here was RED on main before the heredoc branch and passed
# after it. The payload is a wrapped force-push; for the stripper cases the BARE form is pinned
# too, because that is the form the PLAIN patterns read — if only the wrapped form blocks, the
# fix went into the shell-fed scan and the stripper is still blind.
rm -f "$(care_path)"
FP="eval 'git push --force'"
# F1: the shell is on the line before the opener.
for shape in \
  $'bash \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'sudo -i \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'ssh host \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'(\nbash\n) <<EOF\n'"$FP"$'\nEOF' \
  $'{\n  sh\n} <<EOF\n'"$FP"$'\nEOF' \
  $'echo start \\\n  && bash \\\n<<EOF\n'"$FP"$'\nEOF' \
  $'sudo \\\n-i <<EOF\n'"$FP"$'\nEOF' \
  $'ssh \\\nhost <<EOF\n'"$FP"$'\nEOF' \
  $'bash \\\n-s <<EOF\n'"$FP"$'\nEOF' \
  ; do
  # The last three put a non-shell word before the `<<` on the opener line, so only the
  # continuation join (not the group lookback) can see the shell: one rule, one fixture.
  test_start "a shell on the line before the opener feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# The allowlist (2026-10-04) strips only after lines it can prove bash reads the same way; a
# `\` continuation, a group, an escape, an unclosed quote or an odd delimiter is not one, so
# the text heredocs below are read in full and their gated text blocks: named cost, each
# confirmed by the bash oracle as a body bash never runs.
test_start "a continuation before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'cat \\\n<<EOF > notes.md\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
test_start "a group before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'(\necho hi\n) <<EOF\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
# F2: lines the stripper read as openers that bash does not. Wrapped AND bare.
for pre in \
  $'cat <<END-OF-FILE\nx\nEND-OF-FILE' \
  $'cat <<E.F\nx\nE.F' \
  $'cat <<EOF.txt\nx\nEOF.txt' \
  $'echo "\\"<<EOF"' \
  $'echo $\'\\\'<<EOF\'' \
  $'echo $(( (n+1) << k ))' \
  $'echo ${x:-<<EOF}' \
  ; do
  test_start "no phantom body after $(printf '%q' "${pre%%$'\n'*}"): a wrapped force-push on the next line blocks"
  run_gate "$pre"$'\n'"$FP"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "no phantom body after $(printf '%q' "${pre%%$'\n'*}"): a bare force-push on the next line blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a real heredoc with a hyphenated delimiter still hides its body"
run_gate $'cat <<END-OF-FILE > n.md\ngit push --force\nEND-OF-FILE'
assert_exit "$RC" "0" "passes"
test_start "the closing line of a hyphenated delimiter is honoured (text after it is read)"
run_gate $'cat <<E-F > n.md\nx\nE-F\ngit push --force'
assert_exit "$RC" "2" "blocked"
# F3: a shell spelled one indirection away.
for shape in \
  $'SH=bash; $SH <<EOF\n'"$FP"$'\nEOF' \
  $'"$SH" <<EOF\n'"$FP"$'\nEOF' \
  $'${0} <<EOF\n'"$FP"$'\nEOF' \
  $'${SHELL} <<EOF\n'"$FP"$'\nEOF' \
  $'sudo . /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'sudo -u root source /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'b\\ash <<EOF\n'"$FP"$'\nEOF' \
  $'cat <<EOF | $SH\n'"$FP"$'\nEOF' \
  $'cat <<EOF | sudo $SH\n'"$FP"$'\nEOF' \
  ; do
  test_start "a shell one indirection away feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# The named cost of fail-closed on a variable in command position: an interpreter held in a
# variable keeps its body in the wrapped scan.
test_start "named cost: \$PYTHON - <<PY quoting a wrapped amend is read (blocked)"
run_gate $'$PYTHON - <<PY\nx = "'"$WRAP"$'"\nPY'
assert_exit "$RC" "2" "blocked"
test_start "a variable NOT in command position is not a shell (echo \$X after a text heredoc)"
run_gate $'cat <<EOF > f.txt\n'"$FP"$'\nEOF\necho $X'
assert_exit "$RC" "0" "passes"
test_start "a variable assignment before a text heredoc is not a shell"
run_gate $'OUT=$DIR/f.txt; cat <<EOF > $OUT\n'"$FP"$'\nEOF'
assert_exit "$RC" "0" "passes"

# ── lens round 2 on the fold (2026-10-02): the blanker must not MAKE an opener, the shell ──
# word may hide behind a prefix, and sudo's `-u` takes its argument.
rm -f "$(care_path)"
# A `<<` bash reads as a shift or a literal is not an opener; a bare force-push after it blocks.
for pre in \
  '(( x = 1 << 2 ))' \
  '(( x <<= 2 ))' \
  'echo $[1<<2]' \
  'a[1<<2]=3' \
  'echo $(( $(( 1 )) << 2 ))' \
  'echo \<\<EOF' \
  'echo <\<EOF' \
  'cat <\< EOF' \
  "echo <''<EOF" \
  'echo |#}x<<22' \
  ; do
  test_start "not an opener: $(printf '%q' "$pre") — a bare force-push on the next line blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a trailing backslash on the opener line continues the COMMAND; the body starts after it"
run_gate $'cat <<E |\\\ngit push --force\nbody\nE'
assert_exit "$RC" "2" "blocked"
# Round 6: a backslash at the end of a COMMENT continues nothing; the body starts on the next
# line and closes at the first EOF, so the push after that close is read.
test_start "a trailing backslash inside a comment on the opener line is not a continuation"
run_gate $'cat <<EOF # x \\\nEOF\ngit push --force\nEOF'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "an odd run of backslashes at the end of the opener line IS a continuation (the next line is command)"
run_gate $'cat <<EOF x\\\\\\\n; git push --force\na\nEOF'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "backslashes on the opener line: the body is read in full (allowlist cost: read in full)"
run_gate $'cat <<EOF x\\\\\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
# Round 6 finish: the closing line is recognised exactly as bash recognises it. Closing EARLY
# is not safe either: body text after a too-early close can open a phantom body whose close
# sits after bash's real one and hides the lines between (oracle RAN on each, merged passed).
for c in $'cat <<\'EOF\'\nEOF \ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\nEOF \ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\n  EOF\ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\nx\\\nEOF\ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<EOF\nEOF\r\ncat <<Z\nEOF\ngit push --force\nZ'; do
  test_start "a closer bash does not close on does not close the body here: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# An unquoted body joins `\`⏎ before the closer is compared (`<<-` strips tabs from the
# joined line's start only); a quoted or escaped delimiter does not join.
for c in $'cat <<EOF\nEO\\\nF\ngit push --force\nEOF' \
         $'cat <<EOF\nE\\\nO\\\nF\ngit push --force\nEOF' \
         $'cat <<EOF\nEOF\\\n\ngit push --force\nEOF' \
         $'cat <<-EOF\n\tEO\\\nF\ngit push --force\nEOF' \
         $'cat <<\'EOF\'\nx\\\nEOF\ngit push --force' \
         $'cat <<\\EOF\nx\\\nEOF\ngit push --force' \
         $'cat <<\'EOF\'\nx\\\nEOF\ngit push --force\nEOF' \
         $'cat <<"EOF"\nx\\\nEOF\ngit push --force\nEOF' \
         $'cat <<\\EOF\nx\\\nEOF\ngit push --force\nEOF'; do
  test_start "the body closes where bash closes it, joined or not: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'cat <<EOF\nEO\\\nF\necho done' \
         $'cat <<-EOF\n\t'"$FP"$'\n\tEOF\necho done' \
         $'cat <<EOF\nx\\\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\'EOF\'\nx\\\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF\nx\\\\\nEOF\necho done'; do
  test_start "a text heredoc closed where bash closes it stays hidden: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
# Round 7: a delimiter word runs to a metacharacter. `cat <<EOF{` is delimited by `EOF{` in
# bash; read as `EOF` it closed past bash's close and hid the push between (merged too,
# oracle RAN). A word with a character outside the class before its end opens no body.
for s in '{' '}' '^' ']' '[' '$' '$X' '{a,b}' '[a]' '^^' '}}'; do
  c="cat <<EOF$s"$'\nx\n'"EOF$s"$'\ngit push --force\nEOF'
  test_start "a delimiter word does not stop short of its end: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'cat <<-EOF}\n\tEOF}\ngit push --force\nEOF' \
         $'cat <<\'EOF\'^\nEOF^\ngit push --force\nEOF' \
         $'cat <<\\EOF}\nEOF}\ngit push --force\nEOF' \
         $'cat <<"EOF"[\nEOF[\ngit push --force\nEOF'; do
  test_start "a quoted, escaped or dashed delimiter does not stop short of its end: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'cat <<A<<B\n'"$FP"$'\nA\n'"$FP"$'\nB\necho done' \
         $'cat <<EOF>/dev/null\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF;echo x\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF|cat\n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF&&true\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\'EOF\'>/dev/null\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\\EOF;echo x\n'"$FP"$'\nEOF\necho done' \
         $'cat <<-EOF\t\n\t'"$FP"$'\n\tEOF\necho done'; do
  test_start "a delimiter ended by a metacharacter still hides its body: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
test_start "a subshell around the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'(cat <<EOF)\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
# Round 8: a word ends where BASH ends it — a space, a tab, a newline, or `; | & < > )`. A
# `\r` `\v` `\f` is part of bash's word (`[[:space:]]` ended it here, and merged blocked these
# only because its closer was trimmed); `(` after the word is extglob's `@(x)` once
# `shopt -s extglob` ran; a Unicode space is a word character to bash while a UTF-8 sed reads
# it as space. Each made the gate key a shorter delimiter than bash's (oracle RAN).
for ws in $'\r' $'\v' $'\f'; do
  for open in "<<EOF$ws" "<<'EOF'$ws" "<<\\EOF$ws" "<<\"EOF\"$ws"; do
    c="cat $open"$'\n'"EOF$ws"$'\ngit push --force\nEOF'
    test_start "a word does not end at a byte bash reads as part of it: $(printf '%q' "$c")"
    run_gate "$c"
    assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  done
done
for c in $'cat <<-EOF\r\n\tEOF\r\ngit push --force\nEOF' \
         $'cat <<EOF\r <<B\nEOF\r\nB\ngit push --force\nEOF' \
         $'shopt -s extglob\ncat <<@(x)\n@(x)\ngit push --force\n@' \
         $'shopt -s extglob\ncat <<!(x)\n!(x)\ngit push --force\n!' \
         $'shopt -s extglob\ncat <<+(x)\n+(x)\ngit push --force\n+' \
         $'shopt -s extglob\ncat <<*(x)\n*(x)\ngit push --force\n*' \
         $'shopt -s extglob\ncat <<?(x)\n?(x)\ngit push --force\n?' \
         $'shopt -s extglob\ncat <<@(x|y)\n@(x|y)\ngit push --force\n@' \
         $'shopt -s extglob\ncat <<-@(x)\n\t@(x)\ngit push --force\n@'; do
  test_start "a word bash reads whole is not keyed short: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# … and before the word too: `<<\v'EOF'` is delimited by `\vEOF` in bash; read as a quoted
# `EOF` the body closed EARLY and body text opened a phantom over the push.
for ws in $'\v' $'\r' $'\f'; do
  for q in "'EOF'" '"EOF"' '\EOF'; do
    c="cat <<$ws$q"$'\nEOF\ncat <<Z\n'"${ws}EOF"$'\ngit push --force\nZ'
    test_start "a byte bash reads into the word does not separate << from it: $(printf '%q' "$c")"
    run_gate "$c"
    assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  done
done
# A word the gate cannot read opens no body, so bash's body text is read here as commands; a
# `cat <<Z` in it opened a phantom whose `Z` hid a push bash runs after its real close (merged
# too, oracle RAN). From the first uncertain `<<` on, no opener is trusted.
for c in $'cat <<EOF{\ncat <<Z\nEOF{\ngit push --force\nZ' \
         $'cat <<E\'O\'F\ncat <<Z\nEOF\ngit push --force\nZ' \
         $'cat <<\\#\\#\ncat <<Z\n##\ngit push --force\nZ'; do
  test_start "after a word the gate cannot read, a later opener is not trusted: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for c in $'echo "use <<\'E F\' here"\ncat <<EOF\n'"$FP"$'\nEOF\necho done' \
         $'echo hi # see <<E\'O\'F\ncat <<EOF\n'"$FP"$'\nEOF\necho done'; do
  test_start "an uncertain << inside a string or a comment distrusts nothing: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
for loc in C C.UTF-8 en_US.UTF-8; do
  for u in $' ' $'　' $' '; do
    c="cat <<EOF${u}x"$'\n'"EOF${u}x"$'\ngit push --force\nEOF'
    test_start "a Unicode space is part of bash's word under $loc: $(printf '%q' "$c")"
    LC_ALL=$loc run_gate "$c"
    assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  done
done
for c in $'cat <<EOF\t\n'"$FP"$'\nEOF\necho done' \
         $'cat <<\'EOF\' \n'"$FP"$'\nEOF\necho done' \
         $'cat <<EOF >/dev/null\n'"$FP"$'\nEOF\necho done'; do
  test_start "a word ended by a space or a tab still hides its body: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "0" "passes"
done
# Round 9: `#` after `{` or `}` is a word character to bash; read as a comment it hid an opener
# or an open quote, and a later `cat <<Z` hid a push bash runs (oracle RAN). The allowlist
# accepts `#` only at a token start.
for c in $'echo {#} <<\\E\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo }#x <<\\E\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo {#} <<E\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo {#} <<\'E\'\ncat <<Z\nE\ngit push --force\nZ' \
         $'echo {#\'\ncat <<Z\n\'\ngit push --force\nZ' \
         $'echo }#\'\ncat <<Z\n\'\ngit push --force\nZ' \
         $'echo {#"\ncat <<Z\n"\ngit push --force\nZ' \
         $'echo a{#\'\ncat <<Z\n\'\ngit push --force\nZ'; do
  test_start "a # inside a word is not a comment: $(printf '%q' "$c")"
  run_gate "$c"
  assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a variable in a word or a double quote does not end the stripping: the body stays hidden"
run_gate $'D=/tmp; cat > "$D/n.md" <<\'EOF\'\n'"$FP"$'\nEOF\necho ${D} $1 done'
assert_exit "$RC" "0" "passes"
test_start "a command substitution before the opener ends the stripping (allowlist cost: read in full)"
run_gate $'cat > $(echo n.md) <<\'EOF\'\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
test_start "a closing quote is not an opening quote: echo it's <<EOF 'x' opens no phantom (push read)"
run_gate $'echo it\'s <<EOF \'x\'\ngit push --force'
assert_exit "$RC" "2" "blocked"
# A delimiter bash accepts opens a real body: a digit, a path, an escaped backslash before it.
for shape in \
  $'cat <<1 > n.md\n'"$FP"$'\n1\necho done' \
  $'cat <</dev/null > n.md\n'"$FP"$'\n/dev/null\necho done' \
  $'echo \\\\<<EOF > n.md\n'"$FP"$'\nEOF\necho done' \
  ; do
  test_start "a delimiter outside [A-Za-z_][A-Za-z0-9_.-]*: the body is read in full (allowlist cost: read in full): $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"
done
# An escaped character is inert, not deleted: a real heredoc after `\#` or `\$` is still a heredoc.
test_start "an escape before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'cat \\#<<EOF > n.md\nrun '"$FP"$' now\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
# The shell word behind a prefix the shell steps over.
for shape in \
  $'SH=bash; env $SH <<EOF\n'"$FP"$'\nEOF' \
  $'exec $SH <<EOF\n'"$FP"$'\nEOF' \
  $'time $SH <<EOF\n'"$FP"$'\nEOF' \
  $'nohup $SH <<EOF\n'"$FP"$'\nEOF' \
  $'nice -n5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'nice -n 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'timeout 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'command $SH <<EOF\n'"$FP"$'\nEOF' \
  $'($SH) <<EOF\n'"$FP"$'\nEOF' \
  $'FOO=1 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'FOO=$X $SH <<EOF\n'"$FP"$'\nEOF' \
  $'</dev/null $SH <<EOF\n'"$FP"$'\nEOF' \
  $'<<EOF $SH -s\n'"$FP"$'\nEOF' \
  $'${SH:-bash} <<EOF\n'"$FP"$'\nEOF' \
  $'${ARR[0]} <<EOF\n'"$FP"$'\nEOF' \
  $'builtin source /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'command . /dev/stdin <<EOF\n'"$FP"$'\nEOF' \
  $'sudo -u root $SH <<EOF\n'"$FP"$'\nEOF' \
  ; do
  test_start "a shell behind a prefix feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# ── lens round 3 (2026-10-03): an array literal is words, not redirections; env/timeout/exec
# options that take an argument take it; `{` opens a group.
for pre in 'x=(1<<2)' 'declare -a x=(1<<2)' 'a=(b<<2 c)' 'x=(<<2)' 'x+=(1<<2)'; do
  test_start "not an opener: $(printf '%q' "$pre") — a bare force-push on the next line blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
for shape in \
  $'SH=bash; env -u X $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; env -C /tmp $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; timeout -s KILL 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; timeout -k 2 5 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; exec -a name $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; { $SH <<EOF\n'"$FP"$'\nEOF\n}' \
  ; do
  test_start "a shell behind a prefix feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# Round 3 final: a quote that runs across lines is text to its close; an escaped delimiter
# character is that character; a nested group walks back to ITS opener; more prefixes.
for pre in $'echo "a <<2\nb"' $'echo \'x <<1 y\nz\'' $'git commit -m "shift 1<<2\nbody"'; do
  test_start "a quote spanning lines opens no heredoc: $(printf '%q' "${pre%%$'\n'*}") — a bare force-push after it blocks"
  run_gate "$pre"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a quote spanning lines before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'echo "a\nb" <<EOF > n.md\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
test_start "text between a substitution's close and the outer quote is quoted: \"\$(echo a)<<EOF\" opens nothing"
run_gate $'echo "$(echo "a")<<EOF"\ngit push --force'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "the commit-message shape closing with text after )\" on the last line reads that text"
run_gate $'git commit -m "$(cat <<\'EOF\'\nnote\nEOF\n)" && git push --force'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
# Round 4: an escaped quote inside a multi-line quote is not its close; a delimiter may carry
# more than one escape; stdbuf's -o/-i/-e take an argument.
for pre in $'echo "a\n\\" x <<2\n"' $'git commit -m "fix\nhe said \\"x\\" and 1<<2\nend"' $'echo $\'a\n\\\' <<2\n\''; do
  test_start "an escaped quote on a continuation line is not the close: $(printf '%q' "${pre%%$'\n'*}") — the push after blocks"
  run_gate "$pre"$' ; git push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "escaped quotes in a quote before the opener: the body is read in full (allowlist cost: read in full)"
run_gate $'echo "a\n\\"x\\" b" <<EOF > n.md\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "2" "blocked"
for d in '\#\#' '\*\*' '\#\!' '\?\?' '\#a\#' '\#\#\#'; do
  plain="${d//\\/}"
  test_start "a delimiter with several escapes <<$d closes at $plain; the push after it blocks"
  run_gate "cat <<$d"$'\nfoo\n'"$plain"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "a delimiter with several escapes <<$d opens no body: its text is read (fail-closed, round 5)"
  run_gate "cat <<$d > n.md"$'\n'"$FP"$'\n'"$plain"$'\necho done'; assert_exit "$RC" "2" "blocked"
done
# An escaped backslash in the delimiter is a literal backslash: `<<\\E` closes at `\E`.
for pair in '\\E:\E' '\\#:\#' '\\\\#:\\#'; do
  d="${pair%%:*}"; cl="${pair#*:}"
  test_start "an escaped backslash in the delimiter is literal: <<$d closes at $cl; the push after blocks"
  run_gate "cat <<$d"$'\nfoo\n'"$cl"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "an escaped backslash in the delimiter: <<$d opens no body (fail-closed, round 5)"
  run_gate "cat <<$d > n.md"$'\n'"$FP"$'\n'"$cl"$'\necho done'; assert_exit "$RC" "2" "blocked"
done
test_start "a shell behind a prefix feeds the body: stdbuf -o 0 \$SH"
run_gate $'SH=bash; stdbuf -o 0 $SH <<EOF\n'"$FP"$'\nEOF'; assert_exit "$RC" "2" "blocked"
test_start "stdbuf's argument is not the command word: stdbuf -o \$N cat <<EOF is text"
run_gate $'stdbuf -o $N cat <<EOF\nrun '"$FP"$' now\nEOF'; assert_exit "$RC" "0" "passes"
for d in '#' '.' '!' '~' '*' '#x'; do
  test_start "an escaped delimiter <<\\$d: the push after its closing line blocks"
  run_gate "cat <<\\$d"$'\nbody\n'"$d"$'\ngit push --force'; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
  test_start "an escaped punctuation delimiter <<\\$d: the body is read in full (allowlist cost: read in full)"
  run_gate "cat <<\\$d > n.md"$'\n'"$FP"$'\n'"$d"$'\necho done'; assert_exit "$RC" "2" "blocked"
done
test_start "a whole-escaped plain delimiter <<\\EOF is read with certainty and hides its body"
run_gate $'cat <<\\EOF > n.md\n'"$FP"$'\nEOF\necho done'
assert_exit "$RC" "0" "passes"
# One rule away from the unclosed-body rule: a misread delimiter whose misreading happens to
# appear as a LATER line would close late and swallow the lines between. Without the
# "uncertain word opens no body" rule, `<<\#\#` would be read as `__` and the `__` line below
# would close it after the push.
test_start "an uncertain delimiter opens no body even when its misreading appears as a later line"
run_gate $'cat <<\\#\\#\nfoo\n##\ngit push --force\n__'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "an uncertain quoted-piece delimiter opens no body even when its misreading appears later"
run_gate $'cat <<E\'O\'F\nfoo\nEOF\ngit push --force\nEO'
assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
test_start "a body that never closes is not stripped: the wrapped payload in it is read (fail-closed)"
run_gate $'cat <<NEVER > n.md\n'"$FP"$'\nstill body'
assert_exit "$RC" "2" "blocked"
test_start "a body that never closes: a bare force-push inside it is read (fail-closed)"
run_gate $'cat <<NEVER > n.md\ngit push --force'
assert_exit "$RC" "2" "blocked"
# Round 5's four shapes: each misread delimiter had opened a body that never closed.
for shape in \
  $'cat <<\\-\\-\nfoo\n--\ngit push --force' \
  $'cat <<\\-x\nfoo\n-x\ngit push --force' \
  $'cat <<\\#\\ \\#\nfoo\n# #\ngit push --force' \
  $'cat <<\\#\'#\'\nfoo\n##\ngit push --force' \
  $'cat <<"E\\OF"\nfoo\nE\\OF\ngit push --force' \
  $'cat <<"\\#\\#"\nfoo\n\\#\\#\ngit push --force' \
  $'cat <<\\#"\\#"\nfoo\n#\\#\ngit push --force' \
  ; do
  test_start "a delimiter the gate cannot read with certainty opens no body: $(printf '%q' "${shape%%$'\n'*}") — the push blocks"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
test_start "a nested group walks back to its own opener: ( bash / ( cat ) / ) <<EOF feeds the body"
run_gate $'( bash\n( cat )\n) <<EOF\n'"$FP"$'\nEOF'
assert_exit "$RC" "2" "blocked"
for shape in \
  $'SH=bash; ionice -c 2 $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; ! $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; if $SH <<EOF\n'"$FP"$'\nEOF\nthen :; fi' \
  $'SH=bash; 2>/dev/null $SH <<EOF\n'"$FP"$'\nEOF' \
  $'SH=bash; { $SH; } <<EOF\n'"$FP"$'\nEOF' \
  ; do
  test_start "a shell behind a prefix feeds the body: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "2" "blocked"; assert_contains "$ERR" "force-push" "names force-push"
done
# The option that takes an argument takes it: the word after `-u` is not the command.
for shape in \
  $'ionice -c $C cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'env -u $V cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'timeout -s $SIG 5 cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -u $U tee /etc/x <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -u "$USER" tee /etc/x <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -n -u $U cat <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo -E cat $F <<EOF\nrun '"$FP"$' now\nEOF' \
  $'sudo tee $OUT <<EOF\nrun '"$FP"$' now\nEOF' \
  $'nice -n $N cat <<EOF\nrun '"$FP"$' now\nEOF' \
  ; do
  test_start "a variable that is an option's argument is not a shell: $(printf '%q' "${shape%%$'\n'*}")"
  run_gate "$shape"; assert_exit "$RC" "0" "passes"
done

# ── a flag belongs to ITS command (2026-09-28): `git push … && git worktree remove --force x`
# was blocked RED as a force-push, because `push[[:space:]].*--force` ran past the `&&`.
# The flag must sit in the same simple command as the verb; every real shape still blocks.
rm -f "$(care_path)"
test_start "a --force on a LATER command is not a force-push"
run_gate "git push -q origin main && git worktree remove --force /tmp/wt"
assert_not_contains "$ERR" "force-push" "stderr names no force-push"
test_start "a -f on a later command is not a force-push"
run_gate "git push origin main; rm -f /tmp/x.log"
assert_not_contains "$ERR" "force-push" "stderr names no force-push"
test_start "a --hard on a later command is not reset-hard"
run_gate "git reset HEAD~0 && git checkout --hard-to-guess-branch-name || true"
assert_not_contains "$ERR" "reset-hard" "stderr names no reset-hard"
test_start "an --amend on a later command is not commit-amend"
run_gate "git commit -m x | tee log; echo --amend"
assert_not_contains "$ERR" "commit-amend" "stderr names no commit-amend"
test_start "control: a force-push AFTER an unrelated command still blocks"
run_gate "git worktree remove --force /tmp/wt && git push --force origin main"
assert_exit "$RC" "2" "blocked"
test_start "control: --force at the end of the same push still blocks"
run_gate "git push origin main --force && echo done"
assert_exit "$RC" "2" "blocked"
test_start "control: -f in the middle of the same push still blocks"
run_gate "git push -f origin main | tee log"
assert_exit "$RC" "2" "blocked"
test_start "control: --force-with-lease=ref:sha still blocks"
run_gate "git push --force-with-lease=main:abc123 origin main"
assert_exit "$RC" "2" "blocked"
test_start "control: reset --hard in the same command still blocks"
run_gate "git reset -q --hard HEAD~1; echo ok"
assert_exit "$RC" "2" "blocked"

print_summary
teardown_test_env
exit $FAILED
