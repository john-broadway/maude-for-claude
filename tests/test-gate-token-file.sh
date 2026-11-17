#!/usr/bin/env bash
# Tests for hooks/scripts/maude-gate.sh, the hard-block gate: the token file may only be read, newline-separated commands, path traversal, command-position prefixes.
# One of the tests/test-gate*.sh files that were one file until 2026-11-16; the shared
# helpers (run_gate, fp_of, seed_reserved, CR, WRAP) are in tests/gate-helpers.sh.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
. "$(dirname "$0")/gate-helpers.sh"

# ── The token file: a command that names it may only READ it (10-19) ──────────────
# The writer net was a list of verbs and redirects, and lens 8 on a19b8a0 walked past it with
# sed -i, >|, tee -a: the denylist shape that lost twice on 09-28. Now an allowlist: when a
# command names care-redclear.json, every command word in it must be a plain reader and no
# redirect may point into the file. Anything else is refused, the honest cost included.
test_start "redclear: sed -i rewrites it in place is refused"
run_gate 'sed -i s/a/b/ /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "sed -i rewrites it in place"
test_start "redclear: perl -pi rewrites it in place is refused"
run_gate 'perl -pi -e s/a/b/ /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "perl -pi rewrites it in place"
test_start "redclear: a clobber redirect is refused"
run_gate 'echo x >|/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a clobber redirect"
test_start "redclear: an &> redirect is refused"
run_gate 'echo x &>/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an &> redirect"
test_start "redclear: a >& redirect is refused"
run_gate 'echo x >&/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a >& redirect"
test_start "redclear: a read-write open is refused"
run_gate 'cat <>/x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a read-write open"
test_start "redclear: tee with a flag before the file is refused"
run_gate 'echo {} | tee -a /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "tee with a flag before the file"
test_start "redclear: a plain rm is refused"
run_gate 'rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a plain rm"
test_start "redclear: the name handed to xargs is refused"
run_gate 'echo /x/.maude/plugin/care-redclear.json | xargs rm'
assert_exit "$RC" "2" "the name handed to xargs"
test_start "redclear: the name handed out of a substitution is refused"
run_gate 'rm $(echo /x/.maude/plugin/care-redclear.json)'
assert_exit "$RC" "2" "the name handed out of a substitution"
test_start "redclear: the name parked in a variable is refused"
run_gate 'F=/x/.maude/plugin/care-redclear.json; sed -i s/a/b/ $F'
assert_exit "$RC" "2" "the name parked in a variable"
test_start "redclear: a reader redirected into it is refused"
run_gate 'cat /tmp/t.json > /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a reader redirected into it"
test_start "redclear: an interpreter is refused"
run_gate 'python3 -c "open('\''/x/.maude/plugin/care-redclear.json'\'','\''w'\'').write('\''x'\'')"'
assert_exit "$RC" "2" "an interpreter"
test_start "redclear: a reader wrapping a writer in a substitution is refused"
run_gate 'cat $(sed -i s/a/b/ /x/.maude/plugin/care-redclear.json)'
assert_exit "$RC" "2" "the writer inside the reader's substitution"
test_start "redclear: a reader wrapping a writer in backticks is refused"
run_gate 'cat `rm /x/.maude/plugin/care-redclear.json`'
assert_exit "$RC" "2" "the writer inside backticks"
test_start "redclear: a read beside other work is refused (split it into its own call)"
run_gate 'cat /x/.maude/plugin/care-redclear.json; rm -f /tmp/x'
assert_exit "$RC" "2" "a read and an rm in one command"
test_start "redclear: jq reads it still passes"
run_gate 'jq . /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "jq reads it"
test_start "redclear: a read piped to a reader still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json | jq .'
assert_exit "$RC" "0" "a read piped to a reader"
test_start "redclear: two reads still passes"
run_gate 'ls -la /x/.maude/plugin/care-redclear.json; wc -c /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "two reads"
test_start "redclear: a checksum still passes"
run_gate 'cksum /x/.maude/plugin/care-redclear.json; shasum -a 256 /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a checksum"
test_start "redclear: a test still passes"
run_gate 'test -s /x/.maude/plugin/care-redclear.json && echo yes'
assert_exit "$RC" "0" "a test"
test_start "redclear: a read redirected elsewhere still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json > /tmp/copy.json'
assert_exit "$RC" "0" "a read redirected elsewhere"
test_start "redclear: a read with stderr to null still passes"
run_gate 'grep -c until /x/.maude/plugin/care-redclear.json 2>/dev/null'
assert_exit "$RC" "0" "a read with stderr to null"
# A read is still a read when it wears the shell's grammar: an fd dup, a cd, a keyword,
# an assignment prefix (lens 9 on d247dba, M1). A keyword is skipped to the word after it.
test_start "redclear: an fd dup is not a command word still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json 2>&1 | head'
assert_exit "$RC" "0" "an fd dup is not a command word"
test_start "redclear: a read sent to stderr still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json >&2'
assert_exit "$RC" "0" "a read sent to stderr"
test_start "redclear: a cd before the read still passes"
run_gate 'cd /x/.maude/plugin && cat care-redclear.json'
assert_exit "$RC" "0" "a cd before the read"
test_start "redclear: a read inside if still passes"
run_gate 'if [ -f /x/.maude/plugin/care-redclear.json ]; then cat /x/.maude/plugin/care-redclear.json; fi'
assert_exit "$RC" "0" "a read inside if"
test_start "redclear: a read inside a for loop is refused since round 14 (the cost, owned: for binds a name)"
run_gate 'for f in /x/.maude/plugin/care-redclear.json; do cat $f; done'
assert_exit "$RC" "2" "a read inside a for loop (refused: for binds a name)"
test_start "redclear: an assignment prefix on a reader still passes"
run_gate 'LC_ALL=C cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "an assignment prefix on a reader"
test_start "redclear: the name parked in a variable, then read still passes"
run_gate 'f=/x/.maude/plugin/care-redclear.json; cat $f'
assert_exit "$RC" "0" "the name parked in a variable, then read"
test_start "redclear: a write inside a for loop (a keyword is skipped, not allowed) is refused"
run_gate 'for f in /x/.maude/plugin/care-redclear.json; do rm $f; done'
assert_exit "$RC" "2" "a write inside a for loop (a keyword is skipped, not allowed)"
test_start "redclear: a write after then is refused"
run_gate 'if true; then rm /x/.maude/plugin/care-redclear.json; fi'
assert_exit "$RC" "2" "a write after then"
test_start "redclear: an assignment prefix on a writer is refused"
run_gate 'LC_ALL=C rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an assignment prefix on a writer"
test_start "redclear: a read behind time still passes"
run_gate 'time cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a read behind time"
test_start "redclear: a write behind time is refused"
run_gate 'time rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a write behind time"
# Skipping an assignment let the name ride a variable into a redirect: a write redirect
# must point at a plain name (a security review of 4e4f09d).
test_start "redclear: the name parked in a variable, then written by a redirect is refused"
run_gate 'f=/x/.maude/plugin/care-redclear.json; echo x > $f'
assert_exit "$RC" "2" "the name parked in a variable, then written by a redirect"
test_start "redclear: a redirect into the loop variable is refused"
run_gate 'for f in /x/.maude/plugin/care-redclear.json; do echo x > $f; done'
assert_exit "$RC" "2" "a redirect into the loop variable"
test_start "redclear: an append into the variable is refused"
run_gate 'f=/x/.maude/plugin/care-redclear.json; printf x >> $f'
assert_exit "$RC" "2" "an append into the variable"
test_start "redclear: a read-write redirect into the variable is refused"
run_gate 'f=/x/.maude/plugin/care-redclear.json; cat $f 1<>$f'
assert_exit "$RC" "2" "a read-write redirect into the variable"
test_start "redclear: a redirect into a substitution is refused"
run_gate 'echo x > `echo /x/.maude/plugin/care-redclear.json`'
assert_exit "$RC" "2" "a redirect into a substitution"
test_start "redclear: a redirect into a dollar substitution is refused"
run_gate 'echo x > $(echo /x/.maude/plugin/care-redclear.json)'
assert_exit "$RC" "2" "a redirect into a dollar substitution"
test_start "redclear: a redirect into a glob is refused"
run_gate 'cat /x/.maude/plugin/care-redclear.json > /x/.maude/plugin/care-red*'
assert_exit "$RC" "2" "a redirect into a glob"
test_start "redclear: a read copied to a plain file still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json > /tmp/copy'
assert_exit "$RC" "0" "a read copied to a plain file"
test_start "redclear: a read sent to /dev/null still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json >/dev/null 2>&1'
assert_exit "$RC" "0" "a read sent to /dev/null"
test_start "redclear: a read with stdout closed still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json >&-'
assert_exit "$RC" "0" "a read with stdout closed"
test_start "redclear: the cost, named: a one-line commit message that spells the file is refused, and the refusal says why"
run_gate 'git commit -m "the gate reads care-redclear.json"'
assert_exit "$RC" "2" "a commit message naming the token file"
assert_contains "$ERR" "may only read it" "the refusal names the rule, not a write"

# lens 2 on the port (2026-11-03): spellings the full-name check let through, reads it refused
test_start "redclear: an uppercase spelling is refused"
run_gate 'echo x > /x/.maude/plugin/CARE-REDCLEAR.JSON'
assert_exit "$RC" "2" "an uppercase spelling is refused"
test_start "redclear: a backslash inside the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-red\\clear.json'
assert_exit "$RC" "2" "a backslash inside the name is refused"
test_start "redclear: an ANSI-C byte in the name is refused"
run_gate 'echo x > $'"'"'/x/.maude/plugin/care-redclear.js\\x6fn'"'"''
assert_exit "$RC" "2" "an ANSI-C byte in the name is refused"
test_start "redclear: an empty expansion inside the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-redclear.jso${e}n'
assert_exit "$RC" "2" "an empty expansion inside the name is refused"
test_start "redclear: the stem parked in a variable, then the name built, is refused"
run_gate 'a=care-redclear; echo x > /x/.maude/plugin/$a.json'
assert_exit "$RC" "2" "the stem parked in a variable, then the name built, is refused"
test_start "redclear: a one-character glob in the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-redclear.js?n'
assert_exit "$RC" "2" "a one-character glob in the name is refused"
test_start "redclear: fallocate is not a reader though it spells cat (the allowlist is anchored)"
run_gate 'fallocate -l 0 /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "fallocate is not a reader though it spells cat (the allowlist is anchored)"
test_start "redclear: a read copied into a quoted path is refused (the cost, named)"
run_gate 'cat /x/.maude/plugin/care-redclear.json > "/tmp/a b"'
assert_exit "$RC" "2" "a read copied into a quoted path is refused (the cost, named)"
test_start "redclear: a quoted redirect into the file is refused"
run_gate 'echo x > "/x/.maude/plugin/care-redclear.json"'
assert_exit "$RC" "2" "a quoted redirect into the file is refused"
test_start "redclear: a negated read still passes"
run_gate '! cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a negated read still passes"
test_start "redclear: a read inside case still passes"
run_gate 'case x in x) cat /x/.maude/plugin/care-redclear.json;; esac'
assert_exit "$RC" "0" "a read inside case still passes"
test_start "redclear: a [[ test still passes"
run_gate '[[ -f /x/.maude/plugin/care-redclear.json ]] && echo yes'
assert_exit "$RC" "0" "a [[ test still passes"
test_start "redclear: a read or true still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json || true'
assert_exit "$RC" "0" "a read or true still passes"
test_start "redclear: a jq filter with a pipe still passes"
run_gate 'jq -r '"'"'.gate_cleared | keys[]'"'"' /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a jq filter with a pipe still passes"
test_start "redclear: a grep for a > still passes"
run_gate 'grep '"'"'>'"'"' /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a grep for a > still passes"
test_start "redclear: sha256sum still passes"   # portability-name-only: the gate reads the name, nothing runs it
run_gate 'sha256sum /x/.maude/plugin/care-redclear.json'   # portability-name-only
assert_exit "$RC" "0" "sha256sum still passes"   # portability-name-only

# the commit security review on fd6851e (2026-11-03): three parser-differential seams, closed by the marked skeleton
test_start "redclear: a quoted name right after the directory is refused"
run_gate 'echo x > /x/.maude/plugin/"care-redclear.json"'
assert_exit "$RC" "2" "a quoted name right after the directory is refused"
test_start "redclear: a quoted command word before the file is refused"
run_gate '"rm" /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a quoted command word before the file is refused"
test_start "redclear: an erased span in command position cannot hide a writer"
run_gate '""cat /tmp/x; "rm" /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an erased span in command position cannot hide a writer"
test_start "redclear: an expansion inside the stem is refused"
run_gate 'echo x > /x/.maude/plugin/care-red${x}clear.json'
assert_exit "$RC" "2" "an expansion inside the stem is refused"
test_start "redclear: a brace inside the stem is refused"
run_gate 'echo x > /x/.maude/plugin/care-red{clear,x}.json'
assert_exit "$RC" "2" "a brace inside the stem is refused"
test_start "redclear: a quoted fragment of the stem is refused"
run_gate 'echo x > /x/.maude/plugin/"care-red"clear.json'
assert_exit "$RC" "2" "a quoted fragment of the stem is refused"
test_start "redclear: a quoted span in a read's own options still passes"
run_gate 'grep -c "until" /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a quoted span in a read's own options still passes"
test_start "redclear: a quoted plain path beside a read of another file still passes"
run_gate 'cat /x/.maude/plugin/"care.json"'
assert_exit "$RC" "0" "a quoted plain path beside a read of another file still passes"

# the review on b18802e (2026-11-03): a substitution inside a quoted span is walked, marked or not
test_start "redclear: a writer inside a quoted substitution is refused"
run_gate 'echo "$(rm /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "2" "a writer inside a quoted substitution is refused"
test_start "redclear: a writer inside quoted backticks is refused"
run_gate 'echo "`rm /x/.maude/plugin/care-redclear.json`"'
assert_exit "$RC" "2" "a writer inside quoted backticks is refused"
test_start "redclear: a writer inside a quoted substitution behind a reader is refused"
run_gate 'cat "$(sed -i s/a/b/ /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "2" "a writer inside a quoted substitution behind a reader is refused"
test_start "redclear: a read inside a quoted substitution still passes"
run_gate 'echo "$(cat /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "0" "a read inside a quoted substitution still passes"

# round 5 (2026-11-03): lens 3 on fd6851e and the review on a3ece74
test_start "redclear: a quoted command word followed by words is a writer (review on a3ece74)"
run_gate '"rm" cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a quoted command word followed by words is a writer (review on a3ece74)"
test_start "redclear: an empty quote before a reader and the file is refused"
run_gate '"" cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an empty quote before a reader and the file is refused"
test_start "redclear: a colon redirected into a partly quoted name is refused (lens 3 B1)"
run_gate ': > /x/.maude/plugin/"care-redclear.json"'
assert_exit "$RC" "2" "a colon redirected into a partly quoted name is refused (lens 3 B1)"
test_start "redclear: a name quoted from the middle is refused (lens 3 B1)"
run_gate 'echo x > /x/.maude/plugin/care-"redclear.json"'
assert_exit "$RC" "2" "a name quoted from the middle is refused (lens 3 B1)"
test_start "redclear: a brace inside the stem fed to tee is refused (lens 3 B2)"
run_gate 'echo x | tee /x/.maude/plugin/care-{redclear,x}.json'
assert_exit "$RC" "2" "a brace inside the stem fed to tee is refused (lens 3 B2)"
test_start "redclear: rm of a brace inside the stem is refused (lens 3 B2)"
run_gate 'rm /x/.maude/plugin/care-{redclear,x}.json'
assert_exit "$RC" "2" "rm of a brace inside the stem is refused (lens 3 B2)"
test_start "redclear: a stem split across two variables is refused (lens 3 B2)"
run_gate 'a=care-red; b=clear; echo x > /x/.maude/plugin/$a$b.json'
assert_exit "$RC" "2" "a stem split across two variables is refused (lens 3 B2)"
test_start "redclear: a glob inside the stem is refused (lens 3 B2)"
run_gate 'echo x > /x/.maude/plugin/care-redcl?ar.json'
assert_exit "$RC" "2" "a glob inside the stem is refused (lens 3 B2)"
test_start "redclear: a bracket inside the stem is refused (lens 3 B2)"
run_gate 'echo x > /x/.maude/plugin/care-red[c]lear.json'
assert_exit "$RC" "2" "a bracket inside the stem is refused (lens 3 B2)"
test_start "redclear: a write inside a bash-fed heredoc is refused (the content view stands in)"
run_gate 'bash <<'"'"'EOF'"'"'
echo x > /x/.maude/plugin/care-redclear.json
EOF'
assert_exit "$RC" "2" "a write inside a bash-fed heredoc is refused (the content view stands in)"
test_start "redclear: a checksum piped to cut still passes"   # portability-name-only
run_gate 'sha256sum /x/.maude/plugin/care-redclear.json | cut -c1-8'   # portability-name-only
assert_exit "$RC" "0" "a checksum piped to cut still passes"   # portability-name-only
test_start "redclear: a read piped to nl still passes"
run_gate 'cat /x/.maude/plugin/care-redclear.json | nl'
assert_exit "$RC" "0" "a read piped to nl still passes"
test_start "redclear: sort -o into the file is refused (sort is no reader)"
run_gate 'sort -o /x/.maude/plugin/care-redclear.json /tmp/forged'
assert_exit "$RC" "2" "sort -o into the file is refused (sort is no reader)"
test_start "redclear: uniq with the file as its second operand is refused"
run_gate 'uniq /tmp/forged /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "uniq with the file as its second operand is refused"
test_start "redclear: xxd -r into the file is refused"
run_gate 'xxd -r /tmp/forged.hex /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "xxd -r into the file is refused"
test_start "redclear: less with a log file is refused (less is no reader)"
run_gate 'less -o /x/.maude/plugin/care-redclear.json /tmp/forged'
assert_exit "$RC" "2" "less with a log file is refused (less is no reader)"
test_start "redclear: a read loop over the file is refused since round 12 (the cost, owned: read is a binding builtin)"
run_gate 'while read -r l; do echo "$l"; done < /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "a read loop over the file is refused since round 12 (the cost, owned: read is a binding builtin)"
test_start "redclear: a read inside a quoted substitution still passes (the lone marker)"
run_gate 'echo "$(cat /x/.maude/plugin/care-redclear.json)"'
assert_exit "$RC" "0" "a read inside a quoted substitution still passes (the lone marker)"

# round 7 (2026-11-03): lens 4 on ae87414, a name assembled across statement seams
test_start "redclear: the stem split across an assignment seam, written by cat, is refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; cat /tmp/f > ${p}clear.json'
assert_exit "$RC" "2" "the stem split across an assignment seam, written by cat, is refused (lens 4)"
test_start "redclear: the stem split across an assignment seam, replaced by mv, is refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; mv /tmp/forged.json ${p}clear.json'
assert_exit "$RC" "2" "the stem split across an assignment seam, replaced by mv, is refused (lens 4)"
test_start "redclear: the stem split across an assignment seam, fed to tee, is refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; tee ${p}clear.json < /tmp/forged.json'
assert_exit "$RC" "2" "the stem split across an assignment seam, fed to tee, is refused (lens 4)"
test_start "redclear: a cd into the directory, then a split name, is refused (lens 4)"
run_gate 'cd /x/.maude/plugin/; p=care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a cd into the directory, then a split name, is refused (lens 4)"
test_start "redclear: two variables making the name are refused (lens 4)"
run_gate 'p=/x/.maude/plugin/care-red; q=clear.json; echo x > $p$q'
assert_exit "$RC" "2" "two variables making the name are refused (lens 4)"
test_start "redclear: the directory itself split across variables is refused (lens 4)"
run_gate 'd=/x/.maude/plug; p=care-red; echo x > ${d}in/${p}clear.json'
assert_exit "$RC" "2" "the directory itself split across variables is refused (lens 4)"
test_start "redclear: a chained assignment making the directory is refused (lens 4)"
run_gate 'a=/x; b=$a/.maude; c=$b/plugin; echo x > $c/care-redclear.json'
assert_exit "$RC" "2" "a chained assignment making the directory is refused (lens 4)"
test_start "redclear: a split name read by cat still passes (lens 4's companion)"
run_gate 'p=/x/.maude/plugin/care-red; cat ${p}clear.json'
assert_exit "$RC" "0" "a split name read by cat still passes (lens 4's companion)"
test_start "redclear: the whole name in a variable read by cat still passes (lens 4's companion)"
run_gate 'p=/x/.maude/plugin/care-redclear.json; cat $p'
assert_exit "$RC" "0" "the whole name in a variable read by cat still passes (lens 4's companion)"
test_start "redclear: a cd into the directory then a plain read still passes"
run_gate 'cd /x/.maude/plugin/ && cat care-redclear.json'
assert_exit "$RC" "0" "a cd into the directory then a plain read still passes"

# round 8 (2026-11-03): the review on e69db43, the fold only ever adds a match
test_start "redclear: a backtick-built word in the directory is refused on the raw view (review on e69db43)"
run_gate 'echo x > /x/.maude/plugin/`cat /tmp/n`'
assert_exit "$RC" "2" "a backtick-built word in the directory is refused on the raw view (review on e69db43)"
test_start "redclear: a self-referential value in braces ends the fold and is refused"
run_gate 'p=${p}x; echo x > /x/.maude/plugin/${p}'
assert_exit "$RC" "2" "a self-referential value in braces ends the fold and is refused"
test_start "redclear: a value holding a substitution is not folded, and its use in the directory is refused"
run_gate 'p=$(echo care-red); echo x > /x/.maude/plugin/${p}clear.json'
assert_exit "$RC" "2" "a value holding a substitution is not folded, and its use in the directory is refused"
test_start "redclear: a self-referential value ends the fold and is refused"
run_gate 'p=${p}x; echo x > /x/.maude/plugin/$p'
assert_exit "$RC" "2" "a self-referential value ends the fold and is refused"
test_start "redclear: more than 64 assignments is refused outright"
run_gate 'v0=x; v1=x; v2=x; v3=x; v4=x; v5=x; v6=x; v7=x; v8=x; v9=x; v10=x; v11=x; v12=x; v13=x; v14=x; v15=x; v16=x; v17=x; v18=x; v19=x; v20=x; v21=x; v22=x; v23=x; v24=x; v25=x; v26=x; v27=x; v28=x; v29=x; v30=x; v31=x; v32=x; v33=x; v34=x; v35=x; v36=x; v37=x; v38=x; v39=x; v40=x; v41=x; v42=x; v43=x; v44=x; v45=x; v46=x; v47=x; v48=x; v49=x; v50=x; v51=x; v52=x; v53=x; v54=x; v55=x; v56=x; v57=x; v58=x; v59=x; v60=x; v61=x; v62=x; v63=x; v64=x; v65=x; v66=x; v67=x; v68=x; v69=x; echo x > /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "more than 64 assignments is refused outright"
test_start "redclear: a fold that grows past its length is refused outright"
run_gate 'a=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; b=$a$a$a$a$a$a$a$a; c=$b$b$b$b$b$b$b$b; d=$c$c$c$c$c$c$c$c; e=$d$d$d$d$d$d$d$d; echo x > /x/.maude/plugin/care-red$e'
assert_exit "$RC" "2" "a fold that grows past its length is refused outright"
test_start "redclear: a cd into the directory then an unset variable in the name is refused"
run_gate 'cd /x/.maude/plugin/; echo x > care-red${q}'
assert_exit "$RC" "2" "a cd into the directory then an unset variable in the name is refused"

# round 9 (2026-11-03): the review on adf94aa, the cd fold fails closed
test_start "redclear: cd with an option before the directory is refused (review on adf94aa)"
run_gate 'cd -P /x/.maude/plugin/; echo x > care-red${q}'
assert_exit "$RC" "2" "cd with an option before the directory is refused (review on adf94aa)"
test_start "redclear: pushd into the directory is cd"
run_gate 'pushd /x/.maude/plugin/; echo x > care-red${q}'
assert_exit "$RC" "2" "pushd into the directory is cd"
test_start "redclear: a chain of relative cds into the directory is refused"
run_gate 'cd /x; cd .maude; cd plugin; echo x > care-red${q}'
assert_exit "$RC" "2" "a chain of relative cds into the directory is refused"
test_start "redclear: a cd the fold cannot read, then a built relative name, is refused outright"
run_gate 'cd /x/.maude; cd $(cat /tmp/d); echo x > care-red${q}'
assert_exit "$RC" "2" "a cd the fold cannot read, then a built relative name, is refused outright"
test_start "redclear: a popd then a built relative name is refused outright"
run_gate 'cd /x/.maude/plugin/; popd; echo x > care-red${q}'
assert_exit "$RC" "2" "a popd then a built relative name is refused outright"
test_start "redclear: a cd the fold cannot read, then an absolute read, still passes"
run_gate 'cd $(cat /tmp/d) && cat /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "0" "a cd the fold cannot read, then an absolute read, still passes"
test_start "redclear: cd -- then the directory, then a plain read, still passes"
run_gate 'cd -- /x/.maude/plugin/ && cat care-redclear.json'
assert_exit "$RC" "0" "cd -- then the directory, then a plain read, still passes"

# round 10 (2026-11-03): the second review on adf94aa, a stale literal binding never folds
test_start "redclear: a name assigned twice is not folded and its use is refused (second review on adf94aa)"
run_gate 'p=/tmp/safe; p=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name assigned twice is not folded and its use is refused (second review on adf94aa)"
test_start "redclear: a name rebound by read is not folded and its use is refused"
run_gate 'p=/tmp/safe; read -r p < /x/.maude/d; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name rebound by read is not folded and its use is refused"
test_start "redclear: a name rebound by for is not folded and its use is refused"
run_gate 'p=/tmp/safe; for p in /x/.maude/plugin/care-red; do echo x > ${p}clear.json; done'
assert_exit "$RC" "2" "a name rebound by for is not folded and its use is refused"
test_start "redclear: a name rebound by printf -v is not folded and its use is refused"
run_gate 'p=/tmp/safe; printf -v p %s /x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name rebound by printf -v is not folded and its use is refused"
test_start "redclear: a name assigned once, used in a read, still passes"
run_gate 'p=/x/.maude/plugin/care-redclear.json; cat $p && cat $p'
assert_exit "$RC" "0" "a name assigned once, used in a read, still passes"
test_start "redclear: a reassigned name in a command that never spells .maude is not the gate's"
run_gate 'x=1; x=2; echo $x > /tmp/out'
assert_exit "$RC" "0" "a reassigned name in a command that never spells .maude is not the gate's"

# round 11 (2026-11-03): the review on b865c4d, the fold fails closed by construction
test_start "redclear: a name grown by += is not folded and its use is refused (review on b865c4d)"
run_gate 'p=/tmp/safe; p+=x; echo x > ${p}clear.json; cat /x/.maude/d'
assert_exit "$RC" "2" "a name grown by += is not folded and its use is refused (review on b865c4d)"
test_start "redclear: a name rebound by -v glued to it is not folded and its use is refused"
run_gate 'p=/tmp/safe; printf -vp %s /x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a name rebound by -v glued to it is not folded and its use is refused"
test_start "redclear: a name used inside another assignment's value is checked there too"
run_gate 'p=/tmp/safe; read -r p < /x/.maude/d; q=${p}clear.json; echo x > $q'
assert_exit "$RC" "2" "a name used inside another assignment's value is checked there too"
test_start "redclear: a declare -n in a command that spells .maude ends the fold outright"
run_gate 'declare -n p=q; q=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a declare -n in a command that spells .maude ends the fold outright"
test_start "redclear: a let in a command that spells .maude ends the fold outright"
run_gate 'let i=1; p=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a let in a command that spells .maude ends the fold outright"
test_start "redclear: a ${NAME:=} in a command that spells .maude ends the fold outright"
run_gate 'echo ${p:=/x/.maude/plugin/care-red}; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a ${NAME:=} in a command that spells .maude ends the fold outright"
test_start "redclear: a once-assigned name whose value reads another once-assigned name still passes"
run_gate 'd=/x/.maude/plugin/; p=${d}care-redclear.json; cat $p'
assert_exit "$RC" "0" "a once-assigned name whose value reads another once-assigned name still passes"

# round 12 (2026-11-03): the review on 4274bdc, a binding builtin ends the fold
test_start "redclear: a declare by any spelling ends the fold where .maude is spelled (review on 4274bdc)"
run_gate 'declare -x p=/x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a declare by any spelling ends the fold where .maude is spelled (review on 4274bdc)"
test_start "redclear: a binding builtin given a built name ends the fold"
run_gate 'n=p; p=/tmp/safe; printf -v $n %s /x/.maude/plugin/care-red; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a binding builtin given a built name ends the fold"
test_start "redclear: a shell-managed name in the token directory is refused"
run_gate 'echo x > /x/.maude/plugin/${REPLY}'
assert_exit "$RC" "2" "a shell-managed name in the token directory is refused"
test_start "redclear: a backslash cannot hide the binding builtin"
run_gate 'p=/tmp/safe; re\\ad -r p < /x/.maude/d; echo x > ${p}clear.json'
assert_exit "$RC" "2" "a backslash cannot hide the binding builtin"
test_start "redclear: a read of the file beside a read builtin is refused (the cost, owned)"
run_gate 'cat /x/.maude/plugin/care-redclear.json; read -r x < /tmp/y; echo $x'
assert_exit "$RC" "2" "a read of the file beside a read builtin is refused (the cost, owned)"
test_start "redclear: a plain read with no binding builtin and no shell-managed name still passes"
run_gate 'd=/x/.maude/plugin/; cat ${d}care-redclear.json | nl'
assert_exit "$RC" "0" "a plain read with no binding builtin and no shell-managed name still passes"

# round 13 (2026-11-03): the review on dd75ced, any directory change fails closed
test_start "redclear: the directory stack cannot reach the token (review on dd75ced)"
run_gate 'pushd /x/.maude/plugin/; pushd /tmp; pushd +1; echo x > care-red${q}'
assert_exit "$RC" "2" "the directory stack cannot reach the token (review on dd75ced)"
test_start "redclear: a bare cd then a built relative name is refused"
run_gate 'cd /x/.maude/plugin/; cd; echo x > care-red${q}'
assert_exit "$RC" "2" "a bare cd then a built relative name is refused"
test_start "redclear: CDPATH then a built relative name is refused"
run_gate 'CDPATH=/x/.maude; cd plugin; echo x > care-red${q}'
assert_exit "$RC" "2" "CDPATH then a built relative name is refused"
test_start "redclear: a cd then a built ABSOLUTE read still passes"
run_gate 'cd /tmp && cat /x/.maude/plugin/care-redclear.json | nl'
assert_exit "$RC" "0" "a cd then a built ABSOLUTE read still passes"

# round 14 (2026-11-03): the second review on dd75ced, any expansion not folded is OVER; continuations joined
test_start "redclear: a backslash-newline inside the stem is joined and refused (review on dd75ced)"
run_gate 'echo x > /x/.maude/plugin/care-red\
clear.json'
assert_exit "$RC" "2" "a backslash-newline inside the stem is joined and refused (review on dd75ced)"
test_start "redclear: a backslash-newline inside the stem, with a reader, is refused"
run_gate ': > /x/.maude/plugin/care-red\
clear.json'
assert_exit "$RC" "2" "a backslash-newline inside the stem, with a reader, is refused"
test_start "redclear: a positional parameter in the name is refused"
run_gate 'echo x > /x/.maude/plugin/care-red$1'
assert_exit "$RC" "2" "a positional parameter in the name is refused"
test_start "redclear: a name never assigned here, used in the directory, is refused"
run_gate 'echo x > /x/.maude/plugin/care-red$zz'
assert_exit "$RC" "2" "a name never assigned here, used in the directory, is refused"
test_start "redclear: a for over the name ends the fold"
run_gate 'p=/x/.maude/plugin/care-red; for q in x; do echo x > ${p}clear.json; done'
assert_exit "$RC" "2" "a for over the name ends the fold"
test_start "redclear: a read beside a special parameter is refused (the cost, owned)"
run_gate 'cat /x/.maude/plugin/care-redclear.json; echo $?'
assert_exit "$RC" "2" "a read beside a special parameter is refused (the cost, owned)"
test_start "redclear: a folded literal used in a read still passes"
run_gate 'p=/x/.maude/plugin/care-redclear.json; cat $p'
assert_exit "$RC" "0" "a folded literal used in a read still passes"

# round 15 (2026-11-03): the review on dbd9120, only an odd backslash run continues
test_start "redclear: an escaped backslash before a separator is not a continuation (review on dbd9120)"
run_gate 'echo \\; rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an escaped backslash before a separator is not a continuation (review on dbd9120)"
test_start "redclear: an escaped backslash before a newline is not a continuation"
run_gate 'echo \\
rm /x/.maude/plugin/care-redclear.json'
assert_exit "$RC" "2" "an escaped backslash before a newline is not a continuation"
test_start "redclear: a real continuation in the stem is still joined"
run_gate 'echo x > /x/.maude/plugin/care-red\
clear.json'
assert_exit "$RC" "2" "a real continuation in the stem is still joined"

# round 16 (2026-11-03): the review on 17bdbdd, the join never drops a marker
test_start "redclear: two adjacent quoted spans making the name are refused (review on 17bdbdd)"
run_gate 'echo x > /x/.maude/plugin/'"'"'care-red'"'"''"'"'clear.json'"'"''
assert_exit "$RC" "2" "two adjacent quoted spans making the name are refused (review on 17bdbdd)"
test_start "redclear: two adjacent empty quotes before the name are refused"
run_gate 'echo x > /x/.maude/plugin/'"'"''"'"'""care-redclear.json'
assert_exit "$RC" "2" "two adjacent empty quotes before the name are refused"
test_start "redclear: a name quoted whole, with a marker pair elsewhere, is refused"
run_gate 'echo '"'"''"'"' '"'"''"'"' > /x/.maude/plugin/"care-redclear.json"'
assert_exit "$RC" "2" "a name quoted whole, with a marker pair elsewhere, is refused"

# ── Newline-separated commands must still block (CMD_START bypass — fixed 2026-06-30) ──
# A command on its own line is a real, separate command. maude_strip_quotes / maude_unquote
# flattened '\n'→' ' before matching, so the CMD_START anchor (which treats ; & | ( ` as a
# boundary but NOT a space) saw the gated command mid-line and passed it. The flatten now uses
# ';' so a newline reads as a command boundary. Covers yellow + RED command keys + a RED path key.
test_start "gate blocks newline-separated git push"
run_gate "$(printf 'echo hi\ngit push origin main')"
assert_exit "$RC" "2" "newline git-push blocks"

test_start "gate blocks newline-separated git push --force (RED key)"
run_gate "$(printf 'echo hi\ngit push --force origin main')"
assert_exit "$RC" "2" "newline force-push blocks"

test_start "gate blocks newline-separated rm -rf / (RED path key)"
run_gate "$(printf 'echo hi\nrm -rf /')"
assert_exit "$RC" "2" "newline rm-rf-root blocks"

test_start "gate blocks newline + indented git push"
run_gate "$(printf 'echo hi\n  git push origin main')"
assert_exit "$RC" "2" "newline-indented git-push blocks"

# ── Path traversal / .. resolution integration tests (Task 3) ─────────────────
test_start "gate blocks rm -rf /tmp/.. (resolves to root)"
run_gate "rm -rf /tmp/.."
assert_exit "$RC" "2" "trailing-dotdot blocked"

test_start "gate does NOT block rm -rf /tmp/x/../safe (resolves off-root)"
run_gate "rm -rf /tmp/x/../safe"
assert_exit "$RC" "0" "mid-dotdot allowed"

# ── Task 4: transparent command-position prefix bypasses (#6/#7/#8) ──────────

# positives — should now block
test_start "gate blocks /bin/rm -rf / (absolute-path invocation #6)"
run_gate "/bin/rm -rf /"
assert_exit "$RC" "2" "abs-path rm"

test_start "gate blocks command rm -rf / (#7)"
run_gate "command rm -rf /"
assert_exit "$RC" "2" "command-builtin rm"

test_start "gate blocks FOO=1 rm -rf / (#8)"
run_gate "FOO=1 rm -rf /"
assert_exit "$RC" "2" "env-assign rm"

test_start "gate blocks FOO=1 git push --force (#8 generalises to all patterns)"
run_gate "FOO=1 git push --force"
assert_exit "$RC" "2" "env-assign force-push"

test_start "gate blocks /usr/bin/git push (#6 generalises)"
run_gate "/usr/bin/git push origin main"
assert_exit "$RC" "2" "abs-path git push"

# false-block traps — must still PASS (exit 0)
test_start "gate does NOT block rmdir"
run_gate "rmdir /tmp/emptydir"
assert_exit "$RC" "0" "rmdir allowed"

test_start "gate does NOT block /usr/bin/rmdir"
run_gate "/usr/bin/rmdir /tmp/emptydir"
assert_exit "$RC" "0" "abs rmdir allowed"

test_start "gate does NOT block a command named mycommand"
run_gate "mycommand --recursive /tmp"
assert_exit "$RC" "0" "mycommand allowed"

print_summary
teardown_test_env
exit $FAILED
