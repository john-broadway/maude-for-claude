"""A word known only at run time where a command word, a wrapper's option or operand, or a
git option stands.

Bash runs the literal words after it when the expansion comes out empty (an unset `$x`,
a `$(true)`): the word VANISHES and the slots shift, so `git -C $x . push --force` is
`git -C . push --force`. When it does not come out empty it is something the reader
cannot see. The judge reads both: the CONSUMED reading (the word fills its slot, as the
judge always read it) and the VANISHED reading (the word gone, a glued word left as its
literal residue), and takes every hit of either. A read in which a run-time word stood
where the command word stands (after the wrappers), or among git's options, is not whole
(opaque, so no yellow token opens it): such a word can be a wrapper or an alias that
changes what runs. One a slot consumed as an option's value or an operand leaves the read
whole: the slot constrains it, and its value is tier C. Before 2026-11-05 `_unwrap`
returned "no command here" for a run-time command word and the judge said pass: `$x rm
-rf /`, `$x git push --force`, `$x gh release create v1` all ran. The first cut of this
branch read the command word but let an operand slot consume the word (`timeout $x 5 git
push --force` ran; the lens on 4b3cd91, BLOCKING), and iterated a fixpoint over the
wrappers that went quadratic (MAJOR)."""
import os
import time

import pytest

from maude_shell import parse
from maude_shell.judge import judge_read

HOME = "/srv/oracle"   # a synthetic home; not home-shaped, so the ship audit reads it as the fixture it is
PROJ = "/work/projects"
SOLE = ["/srv/keep"]


def read(src):
    return judge_read(src, home=HOME, proj=PROJ, sole=SOLE)


@pytest.mark.parametrize("src,want,whole", [
    # command position: not whole
    ("$x git push", "git-push", False),
    ("$x git push --force", "force-push", False),
    ("${x} git push", "git-push", False),
    ("${x:-} git push --force", "force-push", False),
    ("${x-} git push", "git-push", False),
    ('"$x" git push', "git-push", False),
    ("$1 git push", "git-push", False),
    ("$@ git push", "git-push", False),
    ("$x $y git push", "git-push", False),
    ("$x$y git push", "git-push", False),
    ("$(true) git push", "git-push", False),
    ("`true` git push", "git-push", False),
    ("$((0)) git push", "git-push", False),
    ("$x git reset --hard", "reset-hard", False),
    ("$x git commit --amend", "commit-amend", False),
    ("$x git commit --no-verify -m x", "no-verify", False),
    ("$x gh release create v1", "public-publish", False),
    ("$x rm -rf /", "rm-rf-root", False),
    ("$x rm -rf /srv/keep", "rm-rf-sole-copy", False),
    ("$x sudo rm -rf /", "rm-rf-root", False),
    ("$x command git push", "git-push", False),
    ("$x env git push", "git-push", False),
    ("sudo $x git push", "git-push", False),
    ("true; $x git push", "git-push", False),
    ("x=1 $y git push", "git-push", False),
    ("time $x rm -rf /", "rm-rf-root", False),
    ("! $x rm -rf /", "rm-rf-root", False),
    ("{ $x rm -rf /; }", "rm-rf-root", False),
    ("if $x git push; then :; fi", "git-push", False),
    # among git's options, before the subcommand: not whole (`-c alias.push=…` could be there)
    ("git $x push", "git-push", False),
    ("git $x push --force", "force-push", False),
    ("git $x $y push", "git-push", False),
    ("git ${x:-} push --force", "force-push", False),
    # glued to a literal: the residue is what runs
    ("${x}git push", "git-push", False),
    ("gi${x}t push", "git-push", False),
    ('$x""git push', "git-push", False),
    ("$(true)git push", "git-push", False),
    ("${x}git push --force", "force-push", False),
    ("${x}rm -rf /", "rm-rf-root", False),
    ("${x}sudo rm -rf /", "rm-rf-root", False),
    ("${x}sudo ${y}rm -rf /", "rm-rf-root", False),
    ("${x}command git push", "git-push", False),
    ("${x}${y}git push", "git-push", False),
    ("${x}${y}${z} rm -rf /", "rm-rf-root", False),
    ("${x}/bin/rm -rf /", "rm-rf-root", False),
    ("${x}gh release create v1", "public-publish", False),
    ("${x}env git push --force", "force-push", False),
    ("git ${x}push", "git-push", False),
    ("git pu${x}sh --force", "force-push", False),
    ("git ${x}-C /tmp push", "git-push", False),
    # a wrapper's option or operand slot, or a git option-argument slot: the word vanishes
    # and the slot takes the next word (the lens on 4b3cd91, finding 1). A word a slot
    # consumed leaves the read WHOLE (the slot constrains it; its value is tier C); a word
    # that stood where the command word stands (after sudo's options, after env, nice,
    # xargs, ionice, stdbuf) does not
    ("git -C $x . push --force", "force-push", True),
    ("git -c $x a=b push --force", "force-push", True),
    ("git --git-dir $x .git push --force", "force-push", True),
    ("git -C ${x:-} . reset --hard", "reset-hard", True),
    ("sudo $x -u root rm -rf /", "rm-rf-root", False),
    ("sudo $x -u root git push --force", "force-push", False),
    ("timeout $x 5 git push --force", "force-push", True),
    ("timeout -s KILL $x 5 rm -rf /", "rm-rf-root", True),
    ("timeout ${x:-} 5 gh release create v1", "public-publish", True),
    ("flock $x /tmp/l rm -rf /", "rm-rf-root", True),
    ("flock $x /tmp/l git push --force", "force-push", True),
    ("taskset $x 1 git push --force", "force-push", True),
    ("chrt $x 1 git push --force", "force-push", True),
    ("nice $x -n 5 git push --force", "force-push", False),
    ("env $x -C /tmp git push --force", "force-push", False),
    ("xargs $x -I{} git push --force", "force-push", False),
    ("ionice $x -c 2 git push --force", "force-push", False),
    ("stdbuf $x -o0 git push --force", "force-push", False),
    # glued to $SHELL / $BASH: the shell stays in the residue (finding 2)
    ("$x$SHELL -c 'git push'", "git-push", False),
    ("${x}${SHELL} -c 'git push --force'", "force-push", False),
    ("${x}$BASH -c 'rm -rf /'", "rm-rf-root", False),
    ("$x$SHELL <<<'git push'", "git-push", False),
    ("$x $SHELL -c 'git push'", "git-push", False),
    # TWO run-time words, one vanished and one filling an option's value slot (lens 2 on
    # fa4225c, findings 1 and 2): with x unset and u set bash runs `sudo -u <u> rm -rf /`;
    # neither "all vanished" (`sudo -u rm …`, -u takes rm) nor "all kept" (opaque, no key)
    # is that reading. The words the walk read before the verb are combined.
    ("$x sudo -u $u rm -rf /", "rm-rf-root", False),
    ("$x sudo -u $USER rm -rf /", "rm-rf-root", False),
    ("$x nice -n $n rm -rf /", "rm-rf-root", False),
    ("nice -n $n $x rm -rf /", "rm-rf-root", False),
    ("nice -n $x $y rm -rf /", "rm-rf-root", False),
    ("sudo -u $u $x rm -rf /", "rm-rf-root", False),
    ("$x env -C $d git push --force", "force-push", False),
    ("$x env -C $PWD git push --force", "force-push", False),
    ("env -C $d $x git push --force", "force-push", False),
    ("$x env -C $d rm -rf /", "rm-rf-root", False),
    ("$x xargs -I $y rm -rf /", "rm-rf-root", False),
    ("$x ionice -c $c git push --force", "force-push", False),
    ("$x stdbuf -o $o rm -rf /", "rm-rf-root", False),
    ("$x flock $l rm -rf /", "rm-rf-root", False),
    ("$x taskset $m rm -rf /", "rm-rf-root", False),
    ("$x chrt $p rm -rf /", "rm-rf-root", False),
    ("${x}nice -n $n rm -rf /", "rm-rf-root", False),
    ("${x}sudo -u $u rm -rf /", "rm-rf-root", False),
    ("$x sudo -u $u git push", "git-push", False),
    ("$x sudo -u $u gh release create v1", "public-publish", False),
    ("git -C $d $x push --force", "force-push", False),
    ("env git -C $d $x push --force", "force-push", False),
    ("sudo git -C $d $x push --force", "force-push", False),
    ('"git" -C $d $x push --force', "force-push", False),
    ("env git -C $d $x reset --hard", "reset-hard", False),
    ("$a $b $c $d $e git push", "git-push", False),      # five bare words: always empty, one view
    # the commit security review on 57dc1ed: the region must not end at a run-time word
    # inside a wrapper's option area, nor at the first run-time git option, and past the
    # combining cap the read fails closed
    ("sudo $x -u $u rm -rf /", "rm-rf-root", False),
    ("sudo -n $x -u $u rm -rf /", "rm-rf-root", False),
    ("$a $b $c $d sudo -u $e rm -rf /", "rm-rf-root", False),
    ("$a $b $c $d $e $f sudo -u $g -g $h rm -rf /", "rm-rf-root", False),
    ("git -C $d -c $e $x push --force", "force-push", False),
    ("git $x -C $d push --force", "force-push", False),
    ("env git -C $d -c $e $x push --force", "force-push", False),
    ("timeout $t sudo -u $u rm -rf /", "rm-rf-root", True),
    # the commit security review on 2747b8b: a run-time word among a wrapper's options or
    # git's, filled, can be an option that takes the next word (`sudo $x root rm -rf /`
    # with x = -u runs `sudo -u root rm -rf /`); that state is read too
    ("sudo $x root rm -rf /", "rm-rf-root", False),
    ("sudo $x $y rm -rf /", "rm-rf-root", False),
    ("sudo -n $x root git push --force", "force-push", False),
    ("nice $x 5 rm -rf /", "rm-rf-root", False),
    ("ionice $x 2 git push --force", "force-push", False),
    ("git $x /tmp push --force", "force-push", False),
    ("git -c $x a=b $y /tmp push --force", "force-push", False),
    ("env $x /tmp git push --force", "force-push", False),
    # the commit security review on 7bde3f2: a word reached only once an option-area word
    # has taken the next word (`sudo $x root -u $u rm -rf /`: x = -u, u filled) is found
    # by reading the eat views in discovery too
    ("sudo $x root -u $u rm -rf /", "rm-rf-root", False),
    ("sudo $x root -u $u -g $g rm -rf /", "rm-rf-root", False),
    ("git $x /tmp -C $d push --force", "force-push", False),
    # lens 3 on 2747b8b: a slot glued to its option is filled too (finding 3); every word
    # of a run in the option area is an option word (finding 2, and `sudo $opt root rm`)
    ("nice -n$n rm -rf /", "rm-rf-root", True),
    ("sudo -u$u rm -rf /", "rm-rf-root", True),
    ("sudo -nu$u rm -rf /", "rm-rf-root", True),
    ('nice -n"$n" rm -rf /', "rm-rf-root", True),
    ("env -C$d git push --force", "force-push", True),
    ("env $x=1 git push --force", "force-push", True),
    ("sudo -u$u git push --force", "force-push", True),
    ("sudo $opt root rm -rf /", "rm-rf-root", False),
    ("sudo $a $b root rm -rf /", "rm-rf-root", False),
    # lens 4 on dd9d405 (and the probes beside it): discovery ate one option pair per view,
    # never two together, so the word behind the second pair was never found; the read
    # stalled at depth two, keyed nothing, and the cap never counted what it did not find
    ("sudo $a r $b r $c r rm -rf /", "rm-rf-root", False),
    ("sudo $a r $b r $c r $d r rm -rf /", "rm-rf-root", False),
    ("git -c $a x=y $b x=y $c x=y push --force", "force-push", False),
    ("git -c $a x=y $b x=y $c x=y $d x=y push --force", "force-push", False),
    # lens 4 on dd9d405, finding 3: a positional skip, the duration take or runuser's
    # su form carried the consumed walk past `$x` onto a literal, `$y` was an argument
    # there and the read was called whole; a yellow token opened it
    ("timeout $x 5 $y git push", "git-push", False),
    ("flock $x /tmp/l $y git push", "git-push", False),
    ("taskset $x 1 $y git push", "git-push", False),
    ("chroot $x /r $y git push", "git-push", False),
    ("runuser $x -u root git push", "git-push", False),
    # the commit security review on 07bedea: a word behind a pair whose neighbour must
    # stay empty is reached by that subset of the taking words alone
    ("sudo $a $b r $c r $d r rm -rf /", "rm-rf-root", False),
    # lens 5 on 1cd56d1: a run-time word in the option area of a wrapper whose first
    # non-option word is its command (nice, ionice, stdbuf, sudo, env …), reached through
    # timeout's duration take, was filed as an option word because an option followed it;
    # with x empty bash runs `nice $y -n 5 git push`, and `$y` IS nice's command
    ("timeout $x 5 nice $y -n 5 git push", "git-push", False),
    ("timeout $x 5 ionice $y -c 3 git push", "git-push", False),
    ("timeout $x 5 stdbuf $y -o0 git push", "git-push", False),
    ("timeout $x 5 nice $y -n 5 git reset --hard", "reset-hard", False),
    ("timeout $x 5 env $y -C /tmp git push", "git-push", False),
])

def test_a_run_time_word_where_a_command_word_or_a_slot_stands_keys_the_rest(src, want, whole):
    hits, got = read(src)
    assert want in [h[1] for h in hits], (src, hits)
    assert got is whole, (src, got)


@pytest.mark.parametrize("src,said", [
    ("$x git push", "$x git push"),
    ("$(true) git push", "$(true) git push"),
    ("git $x push", "git $x push"),
    ("${x}git push", "${x}git push"),
    ("git pu${x}sh", "git pu${x}sh"),
    # a hit found in a vanished reading prints the whole typed command: the words it
    # dropped are the reason (lens 2 on fa4225c, finding 4: `$x timeout $t git push --force`
    # printed as `$t git push --force`)
    ("sudo $x git push", "sudo $x git push"),
    ("timeout $x 5 git push --force", "timeout $x 5 git push --force"),
    ("$x timeout $t git push --force", "$x timeout $t git push --force"),
    ("$x env git push", "$x env git push"),
    ("git -C $x . push --force", "git -C $x . push --force"),
    # the words find's deletes are read as are the typed words, not a made-up `rm -rf /`
    # (lens 2 on fa4225c, finding 3)
    ("find / -delete", "find / -delete"),
    ("$x find / -delete", "$x find / -delete"),
])
def test_the_block_line_carries_the_words_as_typed(src, said):
    hits, _ = read(src)
    assert hits and " ".join(hits[0][2]) == said, (src, hits)


@pytest.mark.parametrize("src", [
    "$PYTHON script.py",
    "$CC -o a a.c",
    "$x",
    "$x ls",
    "$(true)",
    "$x git log",
    "git $x status",
    "$CMD push --force",    # tier C before this file: read whole, no key; now no key, not whole
    "$(echo git) push",     # what the substitution prints is tier C still: read as `push`, not whole
    "${CROSS}gcc -o a a.c",  # a glued prefix the house uses: the residue `gcc` keys nothing
    "${x:-git} push",       # a default value is tier C: the residue is empty, `push` keys nothing
])
def test_a_run_time_command_word_with_no_key_after_it_is_opaque_not_keyed(src):
    # the house runs `$CC` and `$PYTHON` by convention: no block, only no yellow token
    hits, whole = read(src)
    assert hits == [], (src, hits)
    assert not whole, src


@pytest.mark.parametrize("src", [
    "echo $X",
    "ls $d",
    "git log $x",
    "git push $remote",
    "command -v $x",
    "git -C $d push",       # -C takes the word as its value: the slot constrains it (tier C)
    "timeout $x 5 ls",      # the duration slot, the same
    "git -C $x . status",
    # lens 3 on 2747b8b, finding 4: a run-time value inside a literal option or assignment
    # word is a value (tier C), and the read is whole: a token opens the push
    'env GIT_SSH_COMMAND="ssh -i $key" git push',
    'env FOO="$v" git push',
    'env -i HOME="$HOME" git push',
    'git --git-dir="$d" push',
    'git --work-tree="$w" push',
    'sudo --user="$u" git push',
    'nice --adjustment="$n" git push',
])
def test_a_run_time_word_past_the_verb_or_filling_a_value_slot_is_read_as_before(src):
    hits, whole = read(src)
    keys = [h[1] for h in hits]
    if src in ("git push $remote", "git -C $d push") or src.endswith(" git push") or src.endswith('" push'):
        assert set(keys) == {"git-push"}, (src, hits)   # one key; a vanished reading may repeat it with the typed words
    else:
        assert keys == [], (src, hits)
    assert whole, (src, hits)


def test_the_parser_gives_each_word_its_empty_reading():
    # the residue of a word with every run-time expansion dropped: what bash runs when
    # each comes out empty; a plain word is its own residue, a bare expansion has none; the
    # substitution's own command is listed first, the outer command is the last one
    c = parse("${x}git $y pu$(true)sh ${z:-force} plain", home=HOME)["commands"][-1]
    assert c["empty"] == ["git", "", "push", "", "plain"]


def test_the_empty_reading_keeps_the_shell_variables():
    # `$x$SHELL -c …` runs a shell when x is empty: $SHELL is not dropped from the residue
    c = parse("$x$SHELL -c 'ls'; ${x}${BASH} -c 'ls'; $x$y", home=HOME)["commands"]
    assert [w["empty"][0] for w in c] == ["$SHELL", "${BASH}", ""]


def test_a_chain_of_glued_wrappers_is_read_in_linear_time():
    # the first cut iterated _unwrap to a fixpoint, one word per pass: 32 KB of
    # `${x}timeout 5 ` took 3.8 s in the judge alone (the lens on 4b3cd91, finding 5)
    src = "${x}timeout 5 " * 2300 + "git push"
    t0 = time.monotonic()
    hits, whole = read(src)
    dt = time.monotonic() - t0
    load = open("/proc/loadavg").read().split()[0] if os.path.exists("/proc/loadavg") else "?"
    assert "git-push" in [h[1] for h in hits] and not whole
    assert dt < 1.5, "%.2f s at loadavg %s" % (dt, load)


def test_past_the_combining_cap_the_read_fails_closed():
    # five run-time operand slots: 32 combinations are not read; the read is unreadable,
    # not an unkeyed pass (the commit security review on 57dc1ed)
    from maude_shell import judge as J
    src = "sudo -u $a -g $b -C $c -h $d -p $e ls"
    hits, whole = read(src)
    assert hits == [] and not whole
    J.judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert J.LAST["kind"] == "unreadable"
    src = "sudo -u $a -g $b -C $c -h $d rm -rf /"   # four: every combination read, keyed, whole
    hits, whole = read(src)
    assert {h[1] for h in hits} == {"rm-rf-root"} and whole


def test_an_unreadable_entry_wins_over_an_opaque_one_whatever_the_order():
    # the commit security review on 2747b8b: the kind was set once, by the first unread
    # entry; an opaque payload ahead of the overflowed combination left the read opaque,
    # which the gate passes with no key, where unreadable is refused
    from maude_shell import judge as J
    for src in ('eval "$x"; sudo -u $a -g $b -C $c -h $d -p $e ls',
                'sudo -u $a -g $b -C $c -h $d -p $e ls; eval "$x"',
                'bash -c "$(sudo -u $a -g $b -C $c -h $d -p $e ls)"'):
        J.judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
        assert J.LAST["kind"] == "unreadable", (src, J.LAST)


def test_a_run_time_word_before_the_verb_discovery_cannot_place_is_unreadable():
    # ten option-area words: past the cap, and discovery stops at eight; the read is
    # unreadable either way, never an unkeyed pass (the commit security review on 7bde3f2)
    from maude_shell import judge as J
    src = "sudo $a $b $c $d $e $f $g $h $i $j root -u $u ls"
    hits, whole = read(src)
    assert hits == [] and not whole
    J.judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
    assert J.LAST["kind"] == "unreadable"


def test_discovery_reads_past_every_eaten_pair_and_the_cap_counts_what_it_finds():
    # lens 4 on dd9d405: `sudo $a r $b r $c r rm -rf /` (a=b=c=-u runs it) passed rc 0,
    # `timeout $t1 5 $t2 5 $t3 5 $t4 5 git push --force` read whole with no key, and
    # five words among git's options read opaque, never unreadable: discovery appended
    # one eat view per option word and never one where every word found so far eats,
    # so the word behind the second pair was never reached. Now every pass also reads
    # the view with all the found words eating; past the cap the read is unreadable.
    from maude_shell import judge as J
    for src in ("sudo $a r $b r $c r $d r $e r rm -rf /",
                "git -c $a x=y $b x=y $c x=y $d x=y $e x=y push --force",
                "timeout $t1 5 $t2 5 $t3 5 $t4 5 git push --force"):
        hits, whole = read(src)
        assert not whole, (src, hits)
        J.judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
        assert J.LAST["kind"] == "unreadable", (src, J.LAST)



def test_an_earlier_opaque_payload_does_not_hide_an_over_cap_read(src=None):
    # lens 3 on 2747b8b, finding 1: with `eval "$x"` ahead, the over-cap shape read opaque
    # (set first, never overridden) and passed with no key
    from maude_shell import judge as J
    for src in ('eval "$x"; nice -n $a nice -n $b nice -n $c nice -n $d timeout $t 5 rm -rf /',
                'bash -c \'eval "$x"\'; sudo -u $a -g $b -C $c -h $d -p $e ls'):
        J.judge_read(src, home=HOME, proj=PROJ, sole=SOLE)
        assert J.LAST["kind"] == "unreadable", (src, J.LAST)


def test_a_run_of_option_area_words_is_read_in_linear_time():
    # lens 3 on 2747b8b, finding 2: a lookahead per word over the run went quadratic
    # (8,000 words: 3.3 s in the judge alone); once per run it is linear
    src = "sudo " + "$x " * 8000 + "-u root rm -rf /"
    t0 = time.monotonic()
    hits, whole = read(src)
    dt = time.monotonic() - t0
    load = open("/proc/loadavg").read().split()[0] if os.path.exists("/proc/loadavg") else "?"
    assert "rm-rf-root" in [h[1] for h in hits], hits   # lens 4: `or not whole` left this half dead
    assert not whole
    assert dt < 1.5, "%.2f s at loadavg %s" % (dt, load)
