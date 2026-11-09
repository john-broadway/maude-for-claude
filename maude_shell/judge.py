"""Judge a parsed command against the gate's command keys.

The gate's regex tables stay; this runs beside them and can only add a block, never
take one away. It covers the keys whose meaning is in the words of one command: the
git keys (push, force-push, reset --hard, commit --amend, filter-repo, filter-branch,
--no-verify, --no-gpg-sign), the public publishes, and the rm -rf family. The red
backstops and the sole-copy TARGET table stay on the regex. Scope and tiers:
docs/gate-threat-model.md.

    python3 -m maude_shell.judge [--proj DIR] [--sole PATH]...   (command on stdin)

prints one line per key hit, "block KEY WORDS" (KEY first, then the words it read), in the
order the commands run, then "unreadable" if the text does not parse, "opaque" if a payload
it runs was not read, or "pass"
when all of it was read and nothing hit. Exit 0 always. Every hit, not the first: a token is per key,
so a yellow hit read first must not hide a red one after it (the commit security review
on 965d025). The gate ranks them; the red list lives in one place, the gate's.

Python 3.8 floor, stdlib only.
"""
import os
import posixpath
import re
from itertools import combinations

from . import parse

DEPTH = 3  # wrapped payloads read, the same cap as the gate's maude_wrapped_match
SHELLS = {"bash", "sh", "dash", "zsh", "ksh", "mksh", "ash"}

# Wrappers that run the rest of their words as a command. For each: the options that
# take a separate argument. An option not listed is read as taking none.
WRAPPERS = {
    "command": set(),
    "builtin": set(),
    "exec": {"-a"},
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "sudo": {"-u", "--user", "-g", "--group", "-C", "--close-from", "-h", "--host", "-p", "--prompt",
             "-U", "--other-user", "-r", "--role", "-t", "--type", "-T", "--command-timeout",
             "-D", "--chdir", "-R", "--chroot"},
    "doas": {"-u", "-C"},
    "nohup": set(),
    "setsid": set(),
    "time": set(),
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "--pid", "-P", "--pgid", "-u", "--uid"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "xargs": {"-a", "--arg-file", "-d", "--delimiter", "-E", "-I", "-L", "--max-lines", "-n",
              "--max-args", "-P", "--max-procs", "-s", "--max-chars", "--process-slot-var"},
    "busybox": set(),
    # the bypass list (feat/gate-bypasses): tracers, namespaces, privilege and scheduling
    "strace": {"-e", "-o", "-p", "-s", "-u", "-E", "-a", "-b", "-I", "-P", "-S", "-X", "-O", "-U",
               "--trace-fds", "--inject", "--fault", "--read", "--write", "--raw", "--abbrev",
               "--verbose", "--kvm", "--const-print-style", "--stack-trace-frame-limit",
               "--output", "--signal", "--trace", "--user", "--env", "--attach", "--columns",
               "--status", "--trace-path", "--string-limit", "--summary-columns", "--detach-on"},
    "ltrace": {"-e", "-o", "-p", "-s", "-u", "-a", "-n", "-A", "-D", "-F", "-l", "-x", "-w",
               "--output", "--where", "--library", "--align", "--indent", "--config"},
    "unshare": {"-S", "--setuid", "-G", "--setgid", "-R", "--root", "-w", "--wd", "--propagation",
                "--map-user", "--map-group", "--map-users", "--map-groups", "--monotonic", "--boottime"},
    "pkexec": {"--user"},
    "systemd-run": {"-p", "--property", "-u", "--unit", "-E", "--setenv", "-M", "--machine", "-H",
                    "--host", "--description", "--slice", "--uid", "--gid", "--working-directory",
                    "--nice", "--on-active", "--on-calendar", "--timer-property", "--path-property",
                    "--socket-property", "--on-boot", "--on-startup", "--on-unit-active",
                    "--on-unit-inactive", "--service-type", "--json", "--expand-environment"},
    "nsenter": {"-t", "--target", "-S", "--setuid", "-G", "--setgid"},
    "setpriv": {"--reuid", "--regid", "--ruid", "--euid", "--rgid", "--egid", "--groups", "--inh-caps",
                "--ambient-caps", "--bounding-set", "--securebits", "--pdeathsig", "--selinux-label",
                "--apparmor-profile"},
    "runuser": {"-u", "--user", "-g", "--group", "-G", "--supp-group", "-s", "--shell", "-w",
                "--whitelist-environment"},
    "chrt": {"-T", "-P", "-D", "--sched-runtime", "--sched-period", "--sched-deadline"},
    "taskset": {"-c", "--cpu-list"},
    "chroot": {"--userspec", "--groups"},
    "flock": {"-w", "--timeout", "--wait", "-E", "--conflict-exit-code"},
}
# Wrappers with words between their options and the command: chroot NEWROOT, flock LOCKFILE,
# taskset MASK, chrt PRIORITY (taskset -c LIST takes the list as its option's value).
POSITIONAL = {"chroot": 1, "flock": 1, "taskset": 1, "chrt": 1}
# runuser without -u/--user is su's form (USER, then -c TEXT): cluster 3 reads it
TIMEOUT_DURATION = re.compile(r"[0-9.]+[smhd]?$")
# A home the reader left unknown (the text names HOME somewhere) still spelled as home.
HOME_WORD = re.compile(r"(~|\$HOME|\$\{HOME\})(/.*)?$")

GIT_ARG_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                "--config-env", "--super-prefix", "--list-cmds"}
GIT_NO_RUN = {"--version", "-v", "--help", "-h", "--html-path", "--man-path", "--info-path"}

PUBLISH = {("gh", "release", "create"), ("gh", "release", "upload"), ("twine", "upload"),
           ("uv", "publish"), ("hf", "upload"), ("huggingface-cli", "upload")}


def judge(text, home=None, proj="", sole=(), depth=DEPTH):
    """Return the first hit ("block", key, words), ("pass", None, None) or ("unreadable", None, None)."""
    hits = judge_all(text, home=home, proj=proj, sole=sole, depth=depth)
    if hits is None:
        return ("unreadable", None, None)
    return hits[0] if hits else ("pass", None, None)


def judge_all(text, home=None, proj="", sole=(), depth=DEPTH):
    """Every hit ("block", key, words), in run order; [] for a pass, None when unreadable."""
    hits, whole = judge_read(text, home=home, proj=proj, sole=sole, depth=depth)
    return hits if whole else None


# One top-level read's state: a memo of bodies already judged, and a budget of text the
# reader will take in. Bodies re-read through shells, scopes and depth grew a 20-line
# command to 9 s (the judge fuzzer on 9dce826); the hook cuts the judge at 2 s, and a cut
# passes. Past the budget the read is parser-depth, which nothing clears.
READ_BUDGET = 400000
_READ = {"left": None, "memo": None}


def judge_read(text, home=None, proj="", sole=(), depth=DEPTH):
    """(hits, whole): every hit, and whether all of the text was read.

    Not whole: the text does not parse, or a payload body it runs was not read (it does
    not parse, it is only known at run time, or it sits past the depth cap). The gate
    refuses a yellow token for a command not read whole, since the unread part may hold
    a red key (lens on 25c9ad2, BLOCKING-1; lens 3 on 652bbd9, MAJOR-2). Text nested past
    the reader's cap is the parser-depth hit, which nothing clears.
    """
    top = _READ["left"] is None
    if top:
        _READ["left"], _READ["memo"] = READ_BUDGET, {}
        LAST["kind"] = None
    try:
        memo_key = (text, home, proj, tuple(sole), depth)
        if memo_key in _READ["memo"]:
            hits, whole = _READ["memo"][memo_key]
            return list(hits), whole
        _READ["left"] -= len(text)
        if _READ["left"] < 0:
            return [("block", "parser-depth", ["(more text than the reader reads)"])], False
        got = _judge_read(text, home, proj, sole, depth, LAST)   # every level: a body that does not parse is unreadable
        _READ["memo"][memo_key] = (list(got[0]), got[1])
        return got
    finally:
        if top:
            _READ["left"], _READ["memo"] = None, None


# Why the LAST top-level read was not whole, for the CLI: "unreadable" when text at any
# level does not parse (a stray quote, a construct the reader does not know, in the command
# or in a literal body it runs), "opaque" when every level parsed and a payload is known
# only at run time (eval "$x", a shell fed by a pipe, a body past the cap). The gate refuses
# the first outright when the tables keyed nothing, and refuses only a yellow token on the
# second, where the wrapped-payload walk and its whisper stand (2026-11-04: one rule for
# both turned `eval "$x"` red; "opaque" for a literal body that did not parse let
# `bash -c $'shopt -s extglob\nls !(x)\nenv -C /tmp git push --force'` through: the
# commit review on 2178e43). Unreadable wins over opaque, at whatever level it was found.
LAST = {"kind": None}


def _judge_read(text, home, proj, sole, depth, why=None):
    if home is None:
        home = os.environ.get("HOME", "")  # the rm rules need the same home the reader expanded
    unread = []  # a payload body not read whole lands here: its text is the command's too
    tree = parse(text, home=home)
    if tree["ok"]:
        hits, seen = [], set()
        for h in _judge_tree(tree, home, proj, sole, depth, unread):
            if (h[1], tuple(h[2])) not in seen:  # one per key and words: nesting cannot multiply them
                seen.add((h[1], tuple(h[2])))
                hits.append(h)
        if unread and why is not None:
            # unreadable wins, in whatever order the entries came (the commit security
            # review on 2747b8b: set once by the first entry, an opaque payload ahead of an
            # overflowed combination left the read opaque, which passes with no key)
            if any(u.startswith("(unreadable") for u in unread):
                why["kind"] = "unreadable"
            elif why["kind"] is None:
                why["kind"] = "opaque"
        return hits, not unread
    if why is not None:
        why["kind"] = "unreadable"
    if tree.get("error") == "nested too deep":
        return [("block", "parser-depth", ["(nested too deep to read)"])], False
    return [], False


class _Scope(list):
    """A tree's commands, with its feeders' text read once however many shells ask
    (the commit security review on 23fdb50)."""
    feeds = None


def _judge_tree(tree, home, proj, sole, depth, unread):
    commands = tree["commands"]
    scope = _Scope(commands)
    hits = []
    for i, cmd in enumerate(commands):
        # every stage before this one in its pipeline, nearest last (|& pipes too)
        pipe, j = [], i - 1
        while j >= 0 and commands[j]["sep"] in ("|", "|&"):
            pipe.insert(0, commands[j])
            j -= 1
        hits.extend(_command(cmd, pipe, home, proj, sole, depth, unread, scope))
    return hits


def _command(cmd, pipe, home, proj, sole, depth, unread, scope=()):
    words, dyn = cmd["words"], cmd["dynamic"]
    # Two readings of a command holding a word known only at run time. CONSUMED: the word
    # fills its slot (a command word, a wrapper's option or operand, a git option-argument),
    # as the judge always read it. VANISHED: the word is gone and the slots shift, a glued
    # word left as its literal residue, which is what bash runs when the expansion comes out
    # empty (`timeout $x 5 git push --force` runs `timeout 5 git push --force`; `${x}git
    # push` runs `git push`). Every hit of either counts. A read in which a run-time word
    # stood where the command word stands (after the wrappers), or among git's options, is
    # not whole (opaque: no yellow token opens it): such a word can be a wrapper or an
    # alias that changes what runs. One consumed as an option's value or an operand (`git
    # -C $d push`, `timeout $x 5 git push`) leaves the read whole: the slot constrains it,
    # its value is tier C, and what runs when it is empty was read. Before 2026-11-05 the consumed reading
    # alone said "no command here" for `$x git push` and passed it; the first cut of the fix
    # skipped the command word but let an operand slot consume the word (the lens on
    # 4b3cd91, finding 1), and iterated a fixpoint that went quadratic (finding 5).
    seen = []
    start, sudo = _unwrap(words, dyn, seen=seen)
    alt, alt_sudo = _unwrap(words, dyn, abbrev=False)
    hits = _judge_at(cmd, start, sudo, pipe, home, proj, sole, depth, unread, scope, seen)
    if alt is not None and alt != start:
        # an abbreviated long option may or may not take a value (--us is --user, --qu is a
        # flag): judge both readings, each at its own start in the whole words, so the chain
        # and sudo stay (the commit security reviews on 9dce826 and ef8d92e)
        hits = hits + _judge_at(cmd, alt, alt_sudo, pipe, home, proj, sole, depth, unread, scope, seen)
    # the run-time words before the verb, read by a walk that passes over a run-time
    # command word the way bash does when it is empty: `$x env -C $d rm -rf /` reaches
    # `rm`, with `$x` (bare: it can only vanish or be a wrapper, which is opaque) and `$d`
    # (a slot: an option's value or an operand, empty or filled) both on the way
    bare, slot, opt, gitopt, unplaced, cmdpos = _region(cmd)
    if unplaced:
        # a run-time word before the verb that discovery could not place (past its eight
        # passes or eight option words): its states are not read, so the read is unreadable
        # and the gate refuses it when nothing keys (the commit security review on 7bde3f2)
        unread.append("(unreadable: a run-time word before the verb the reader could not place)")
    # Two run-time words before the verb, one empty and one not, is a reading of its own:
    # `$x sudo -u $u rm -rf /` with x unset and u set runs `sudo -u <u> rm -rf /`, which
    # neither all-vanished (`sudo -u rm`: -u takes rm) nor all-kept (opaque, no key) is
    # (lens 2 on fa4225c, findings 1 and 2). A bare run-time word before the verb is empty
    # in every view (not empty, it is a wrapper the reader cannot see: opaque); a slot word
    # is empty or filled; a word among a wrapper's options, or git's, is empty or an option
    # that takes the next word (`sudo $x root rm -rf /` with x = -u runs `sudo -u root rm
    # -rf /`: the commit security review on 2747b8b); every combination of the slot and
    # option words is a view, up to four of them (sixteen views); past that the read is
    # unreadable, which the gate refuses when no key is found (the commit security review
    # on 57dc1ed: the two extremes alone left an unkeyed pass).
    for view in _views(cmd, bare, slot, opt, unread):
        vw, vd = view["words"], view["dynamic"]
        vs, vsudo = _unwrap(vw, vd)
        va, vas = _unwrap(vw, vd, abbrev=False)
        hits = hits + _judge_at(view, vs, vsudo, pipe, home, proj, sole, depth, unread, scope)
        if va is not None and va != vs:
            hits = hits + _judge_at(view, va, vas, pipe, home, proj, sole, depth, unread, scope)
    # …or stood among git's options in any reading (`git -c $x a=b $y push`: `$y`, read
    # once `$x` is empty, can be `-c alias.push=…`)
    # …or where a command word stands in ANY reading (`timeout $x 5 $y git push`: the
    # consumed read takes `$x` as the duration and `5` as the command and never sees `$y`;
    # the eat view takes `$y` as the duration, a slot, so it is not `bare`; with x empty
    # `$y` is the command word, and whatever y holds runs under the token: lens 4 on
    # dd9d405, finding 3; `cmdpos` is bare before the slot and option words are taken out)
    if any(dyn[k] for k in seen if 0 <= k < len(dyn)) or gitopt or cmdpos:
        unread.append("(a run-time word where a command word, an option or an operand stands)")
    return hits


COMBINE_CAP = 4  # run-time slot words before the verb whose empty/filled states are combined


def _region(cmd):
    """The run-time words before the verb, as (bare, slot, opt, gitopt, unplaced, cmdpos) index lists: bare, a word
    where a command word stands (it vanishes when empty; filled, it is a wrapper the reader
    cannot see; cmdpos, every word that stood there in ANY reading, slot or option in
    another or not: such a read is never whole); slot, an option's value or an operand (a duration, a lock, a user, a git
    `-C` directory), empty or filled; opt, a word among a wrapper's options or git's
    (empty, or an option that takes the next word); gitopt, those of opt among git's
    global options (a read with one is never whole); unplaced, a run-time word some walk
    reached but none placed (the read is then unreadable). Read by a walk over the residue view
    (a glued `${x}nice` read as `nice`) that passes over a bare run-time command word, as
    bash does when it comes out empty, and goes on through a wrapper's options past a
    run-time word among them (the commit security review on 57dc1ed: the walk once
    stopped there)."""
    empty = cmd.get("empty") or [""] * len(cmd["words"])
    bare, slot, opt, gitopt = [], [], [], []
    reach = [-1]  # the furthest typed index any walk read

    def walk(words, dyn, m):
        b, sl, o, g = [], [], [], []
        start, _, r = _unwrap_walk(words, dyn, True, skip_dyn=True, bare=b, slot=sl, opt=o)
        if start is not None and words[start].rsplit("/", 1)[-1] == "git":
            rest = list(range(start + 1, len(words)))
            _git(words, dyn, rest, bare=g, slot=sl)
            # the reach: the subcommand's index, never an argument's
            j = 0
            while j < len(rest) and (words[rest[j]].startswith("-") or dyn[rest[j]]):
                j += 2 if (not dyn[rest[j]] and words[rest[j]] in GIT_ARG_OPTS) else 1
            r = max(r, rest[min(j, len(rest) - 1)] if rest else r)
        if 0 <= r < len(m):
            reach[0] = max(reach[0], m[r])
        bare.extend(m[k] for k in b)
        slot.extend(m[k] for k in sl)
        opt.extend(m[k] for k in o + g)
        gitopt.extend(m[k] for k in g)

    # the residue view first, every run-time word standing; then, since a word behind a
    # slot's value is reached only once that value is empty (`git -c $x a=b $y push`: `$y`
    # is read past `a=b`), the view with every word found so far empty, again, until no
    # new word is found: at most one pass per run-time word before the verb, each linear
    words = [empty[k] if d and empty[k] else w for k, (w, d) in enumerate(zip(cmd["words"], cmd["dynamic"]))]
    dyn = [d and not empty[k] for k, d in enumerate(cmd["dynamic"])]
    walk(words, dyn, list(range(len(words))))
    alldyn = {k for k, d in enumerate(cmd["dynamic"]) if d}
    found = set()
    for _ in range(min(len(alldyn), 8)):
        now = set(bare) | set(slot) | set(opt)
        if now <= found or len(set(slot)) + len(set(opt)) > COMBINE_CAP:
            break  # nothing new, or past the cap: the read is unreadable from here
        found |= now
        keep = frozenset(alldyn - found)
        views = [_vanished(cmd, keep)]
        # …and the views where an option-area word found so far takes the next word: a word
        # behind that pair is reached only there (`sudo $x root -u $u rm`: the commit
        # security review on 7bde3f2); the first eight such words
        # …with every subset of them taking at once: a word behind TWO such pairs (`sudo
        # $a r $b r $c r rm -rf /`, a=b=c=-u) is reached only where both take, and one
        # behind a pair whose neighbour must stay empty (`sudo $a $b r $c r $d r rm -rf /`:
        # `$d` is reached where b and c take and a does not) only by that subset; one pair
        # per view left them unfound, the read stalled with no key, and the cap never
        # counted a word discovery had not found (lens 4 on dd9d405, and the commit
        # security review on 07bedea). At most fifteen views per pass: past the cap the
        # read is unreadable whatever else discovery would find, so it stops there.
        o = sorted(set(opt))
        for r in range(1, len(o) + 1):
            for c in combinations(o, r):
                views.append(_vanished(cmd, keep, frozenset(c)))
        for view in views:
            if view is not None:
                walk(view["words"], view["dynamic"], view["map"])
    opt, slot, cmdpos = sorted(set(opt)), sorted(set(slot)), sorted(set(bare))
    # a word an option takes or an operand slot holds, or one among the options, is not
    # bare: bare is what is left, the command-position words, empty in every view
    bare = sorted(set(bare) - set(opt) - set(slot))
    # a glued word with a residue (`--user=$u`, `${x}git`) is placed by its residue: the walk
    # reads it as the option or the command it stands for, its value tier C
    placed = set(bare) | set(slot) | set(opt) | {k for k in alldyn if empty[k]}
    unplaced = sorted(k for k in alldyn if k <= reach[0] and k not in placed)
    return bare, slot, opt, sorted(set(gitopt)), unplaced, cmdpos


def _views(cmd, bare, slot, opt, unread):
    """The vanished readings of a command: every bare run-time word before the verb
    empty; every slot word empty or filled; every option-area word empty or an option
    that takes the next word; in every combination up to COMBINE_CAP slot and option
    words (all empty first); past the cap the read is unreadable (the gate refuses it
    when nothing keys) and the two extremes are read. A run-time word past the verb is
    empty in every view (an argument's value is tier C; emptying it only adds a hit).
    None of these when there is no run-time word."""
    dyn, empty = cmd["dynamic"], cmd.get("empty")
    if not empty or not any(dyn):
        return []
    both = [(k, "slot") for k in slot] + [(k, "opt") for k in opt]
    if len(both) > COMBINE_CAP:
        unread.append("(unreadable: more run-time operands before the verb than the reader combines)")
        chosen = [(), tuple(both)]
    else:
        chosen = [c for r in range(len(both) + 1) for c in combinations(both, r)]
    out = []
    for c in chosen:
        keep = frozenset(k for k, kind in c if kind == "slot")
        eat = frozenset(k for k, kind in c if kind == "opt")
        view = _vanished(cmd, keep, eat)
        if view is not None:
            out.append(view)
    return out


def _vanished(cmd, keep=frozenset(), eat=frozenset()):
    """The command as bash runs it when every run-time expansion but those in `keep`
    comes out empty: a bare run-time word is gone, a glued one is its literal residue
    (the parser's `empty` reading), the shell variables kept; a word in `keep` stands as
    typed; a word in `eat` is an option that takes the next word, and both are gone. None
    when nothing is left. The words as typed stay on `said`, with `map` from each view
    index back to the typed index."""
    empty = cmd.get("empty")
    words, dyn, glob, m = [], [], [], []
    skip = False
    for k, (w, d, g) in enumerate(zip(cmd["words"], cmd["dynamic"], cmd["glob"])):
        if skip:
            skip = False
            continue
        if k in eat:
            skip = True
            continue
        if d and k not in keep:
            if not empty[k]:
                continue
            w, d = empty[k], w in SHELL_VARS or empty[k] in SHELL_VARS
        words.append(w)
        dyn.append(d)
        glob.append(g)
        m.append(k)
    if not words:
        return None
    return dict(cmd, words=words, dynamic=dyn, glob=glob, said=cmd["words"], map=m)


def _judge_at(cmd, start, sudo, pipe, home, proj, sole, depth, unread, scope, seen=None):
    words, dyn, glob = cmd["words"], cmd["dynamic"], cmd["glob"]
    if start is None:
        return []
    # the block line: the words as typed. A hit in a vanished view prints the whole typed
    # command, since the words it dropped are the reason (`$x timeout $t git push --force`,
    # not `$t git push --force`: lens 2 on fa4225c); a hit in the consumed reading prints
    # from the command word, the wrappers before it not printed, as before.
    said = cmd.get("said", words)
    lead = 0 if "map" in cmd else start
    name = "bash" if words[start] in SHELL_VARS else words[start].rsplit("/", 1)[-1]
    rest = list(range(start + 1, len(words)))
    chain = words[:start]
    if name in ("source", "."):
        return _sourced(cmd, pipe, words, dyn, rest, home, proj, sole, depth, unread, scope)
    if name in TEXT_CMDS or (name == "git" and any(words[k].lower().startswith("alias.") for k in rest)):
        got = _carried(name, cmd, pipe, words, dyn, rest, home, proj, sole, depth, unread, scope, sudo)
        if got is not None:
            if name == "find":
                # the deletes are read as the rm they are; the label says what was typed
                # (`find / -delete`, not a made-up `rm -rf /`: lens 2 on fa4225c, finding 3)
                got = [(kind, key, said[lead:]) for kind, key, _ in got]
            if name == "git":
                # git ignores an alias that shadows a builtin (alias.push=status; push -f still
                # pushes): the alias read only adds to the plain read (the push review on acce506)
                key = _git(words, dyn, rest, seen)
                got = got + ([("block", key, said[lead:])] if key else [])
            return got
    if name == "git":
        key = _git(words, dyn, rest, seen)
    elif name == "rm":
        key = _rm(words, dyn, glob, rest, sudo, home, proj, sole)
    elif name in SHELLS or name == "eval":
        return _payload(name, cmd, pipe, words, dyn, rest, home, proj, sole, depth, unread, chain, scope)
    else:
        key = _publish(name, words, dyn, rest)
    if key:
        return [("block", key, said[lead:])]
    return []


def _unwrap(words, dyn, abbrev=True, seen=None):
    """Index of the word that is the command after its wrappers, and whether sudo was one.
    None when the command word is only known at run time, or there is none. With `seen`
    a list, a run-time word the walk stopped at is appended: it can be a wrapper that
    changes what runs, so the read is not whole. A run-time word a wrapper consumed as an
    option's value or an operand (a duration, a lock, a user) is not: the slot constrains
    it, and its value is tier C."""
    start, sudo, reach = _unwrap_walk(words, dyn, abbrev)
    if seen is not None and start is None and 0 <= reach < len(words) and dyn[reach]:
        seen.append(reach)  # the walk stopped at a run-time command word
    elif (seen is not None and start is not None and 0 <= reach < len(words) and dyn[reach]
          and words[start].rsplit("/", 1)[-1] == "runuser"):
        # runuser's su form took a run-time word as the USER (`runuser $x -u root git
        # push`): the word can be an option (`-c`, `--shell`) that changes what runs, and
        # with x empty the words after it run as typed; the read is not whole (lens 4 on
        # dd9d405, finding 3)
        seen.append(reach)
    return start, sudo


def _unwrap_walk(words, dyn, abbrev, skip_dyn=False, bare=None, slot=None, opt=None):
    """(start, sudo, reach): the command word's index or None, whether sudo was a wrapper,
    and the furthest index the walk read. With skip_dyn a run-time command word is passed
    over, as bash does when it comes out empty, its index put on `bare`; a run-time word
    a wrapper takes as an option's value or an operand goes on `slot` (the region of the
    vanished readings)."""
    i, sudo = 0, False

    def took(k):  # a run-time word in a slot the wrapper filled
        if slot is not None and 0 <= k < len(words) and dyn[k]:
            slot.append(k)
    while i < len(words):
        if words[i] in SHELL_VARS:
            return i, sudo, i  # $SHELL -c x runs a shell: read it as bash (the bypass list, 2026-10-31)
        if dyn[i]:
            if skip_dyn:
                if bare is not None:
                    bare.append(i)
                i += 1
                continue
            return None, sudo, i  # the command word is known only at run time: the vanished reading reads on
        name = words[i].rsplit("/", 1)[-1]
        if name == "uv" and i + 1 < len(words) and words[i + 1] == "run" and not dyn[i + 1]:
            i = _skip_opts(words, dyn, i + 2, {"--with", "--python", "-p", "--project", "--directory",
                                                "--env-file", "--package", "--extra", "--group", "--index"})
            continue
        if name not in WRAPPERS:
            return i, sudo, i
        if name == "command" and any(w in ("-v", "-V") for w in words[i + 1:i + 3]):
            return None, sudo, i  # a lookup, not a run
        if name in ("sudo", "doas", "pkexec", "runuser"):
            sudo = True
        opts_at = i + 1
        i = _skip_opts(words, dyn, i + 1, WRAPPERS[name], abbrev, skip_dyn, opt, slot,
                       cmdpos=bare if (skip_dyn and POSITIONAL.get(name, 0) == 0 and name != "timeout") else None)
        opts = words[opts_at:i]
        if name == "flock" and i + 1 < len(words) and (
                words[i + 1] in ("-c", "--command") or words[i + 1].startswith("--command=")):
            return opts_at - 1, sudo, i + 1  # flock LOCK -c TEXT (its optstring stops at LOCK): cluster 3
        if name in ("taskset", "chrt") and any(o in ("-p", "--pid") or (o[:1] == "-" and o[1:2] != "-" and "p" in o)
                                               for o in opts):
            return None, sudo, i  # a running pid's settings, not a command run
        if name == "runuser" and not any(_names_user(o) for o in opts):
            return opts_at - 1, sudo, i  # su's form: USER then -c TEXT (cluster 3)
        skip = POSITIONAL.get(name, 0)
        if name == "taskset" and any(o in ("-c", "--cpu-list") or o.startswith("--cpu-list=") for o in opts):
            skip = 0  # -c LIST: the option took the list, which stands in for the mask
        while skip and i < len(words):
            took(i)
            i, skip = i + 1, skip - 1  # its place makes it the operand, run-time or not
        if name == "env":
            # an assignment word, its value run-time or its name (`$x=1`: an assignment when
            # x is a name, tier C): not a command word (lens 3 on 2747b8b, findings 3 and 4)
            while i < len(words) and (re.match(r"[A-Za-z_][A-Za-z0-9_]*=", words[i]) or (dyn[i] and re.match(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?=", words[i]))):
                took(i)  # a slot when its value or name is run-time
                i += 1
        elif name == "timeout" and i < len(words) and (dyn[i] or TIMEOUT_DURATION.match(words[i])):
            took(i)
            i += 1
    return None, sudo, len(words) - 1


SHELL_VARS = {"$SHELL", "${SHELL}", "$BASH", "${BASH}"}
STDIN_FILES = {"/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}
# filters that pass their input on, with the options that take a value
PASS = {"cat": set(), "tee": set(), "head": {"-n", "-c", "--lines", "--bytes"},
        "tail": {"-n", "-c", "--lines", "--bytes"}, "sort": {"-k", "-t", "-o", "-S", "-T", "--key"},
        "uniq": {"-f", "-s", "-w"}}
FEEDERS = {"echo", "printf", "/bin/echo", "/usr/bin/echo", "/bin/printf", "/usr/bin/printf"}


def _fed(feeder, args):
    """(text, exact): the words an echo or printf is handed, and whether that is surely what it
    writes. Not exact: echo with a backslash (-e, or xpg_echo / a POSIX sh even without it),
    printf with a % or a backslash in its format (\\055, %s). The words are still read, since
    a key in them blocks, and an unkeyed command not read whole passes the hook: unread alone
    would open what reading closes (the lens on 81dbe48, the commit security review on 8a49a8b)."""
    if feeder == "echo":
        while args and re.match(r"-[neE]+$", args[0]):
            args = args[1:]
        text = " ".join(args)
        return text, "\\" not in text
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        return "", True
    if "%" in args[0] or "\\" in args[0]:
        return " ".join(args), False  # every word: %s puts the arguments in the output
    return args[0], True  # no conversion: the format is the whole output, the rest is ignored

ENV_SAFE = {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug", "-"}
ENV_VALUE = {"-u", "--unset", "-C", "--chdir"}


def _rewrites(chain):
    """Whether a wrapper chain may change the words of the command it runs: xargs adds its
    stdin, env -S (or any env option not known safe, -iS, --split=) splits a string into
    new ones. Fail closed: an env option off the safe list counts as a rewrite."""
    in_env, skip = False, False
    for w in chain:
        name = w.rsplit("/", 1)[-1]
        if skip:
            skip = False
            continue
        if name == "xargs":
            return True
        if name == "env":
            in_env = True
            continue
        if in_env and w.startswith("-"):
            if w in ENV_VALUE:
                skip = True
            elif w in ENV_SAFE or w.startswith(("--unset=", "--chdir=")):
                pass
            elif w[:2] == "--":
                return True  # --split-string and its abbreviations, or one not known
            else:
                # a short group, letter by letter: i 0 v are flags, u C take the rest or the
                # next word, anything else (S, an unknown letter) counts as a rewrite
                for c, ch in enumerate(w[1:], start=2):
                    if ch in "uC":
                        skip = c == len(w)
                        break
                    if ch not in "i0v":
                        return True
        elif in_env and "=" not in w:
            in_env = False  # the next wrapper's word
    return False


def _skip_opts(words, dyn, i, takes_arg, abbrev=True, skip_dyn=False, bare=None, slot=None, cmdpos=None):
    def took(k):  # a run-time word an option takes as its value
        if slot is not None and k < len(words) and dyn[k]:
            slot.append(k)

    while i < len(words) and ((dyn[i] and (skip_dyn or words[i].startswith("-"))) or (not dyn[i] and words[i].startswith("-") and words[i] != "-")):
        if dyn[i] and not words[i].startswith("-"):
            # a run of run-time words in the option area: each is an option word (empty, or
            # an option that takes the next word), recorded once for the run (a scan per
            # word went quadratic: lens 3 on 2747b8b); past the run the options go on when an
            # option follows, else the operand rules read the run's first word too
            n = i
            while n < len(words) and dyn[n] and not words[n].startswith("-"):
                if bare is not None:
                    bare.append(n)
                if cmdpos is not None:
                    # …and, for a wrapper whose first non-option word is its command, the
                    # command word itself (`nice $y -n 5 git push`: y set runs `<y> -n 5 git
                    # push`), so the read is never whole; reached through timeout's duration
                    # take the consumed walk never saw it (lens 5 on 1cd56d1)
                    cmdpos.append(n)
                n += 1
            if not (n < len(words) and words[n].startswith("-") and words[n] != "-"):
                break
            i = n
            continue
        w = words[i]
        if dyn[i]:
            # an option with its value glued or after `=` (`-n$n`, `--user=$u`, `-nu$u`): the
            # value is tier C, the option takes no further word (lens 3 on 2747b8b, finding 3);
            # a slot: filled as typed, empty as its residue (`-n` then takes the next word)
            took(i)
            i += 1
            continue
        i += 1
        if w == "--":
            break
        if w in takes_arg:
            took(i)
            i += 1
        elif abbrev and w[:2] == "--" and "=" not in w and len(w) > 2 and any(
                t[:2] == "--" and t.startswith(w) for t in takes_arg):
            took(i)
            i += 1  # --us for --user: getopt takes an unambiguous abbreviation (the commit security review on 23fdb50)
        elif w[:2] != "--" and len(w) > 2:
            # a short group, -nu root: the first letter that takes an argument ends the group;
            # with letters after it they are the argument (-n10), alone it takes the next word
            # (the commit security review on d31b9f5: `sudo -nu root rm -rf /` read root as the command)
            for c, ch in enumerate(w[1:], start=2):
                if "-" + ch in takes_arg:
                    if c == len(w):
                        took(i)
                        i += 1
                    break
    return i


def _git(words, dyn, rest, seen=None, bare=None, slot=None):
    j = 0
    while j < len(rest):
        w = words[rest[j]]
        if dyn[rest[j]] and w.startswith("-") and "=" in w:
            if slot is not None:
                slot.append(rest[j])  # a slot: filled as typed, empty as `--git-dir=`
            j += 1  # `--git-dir="$d"`: an option with its value after `=`, the value tier C (lens 3 on 2747b8b, finding 4)
            continue
        if dyn[rest[j]]:
            if seen is not None:
                seen.append(rest[j])  # it can be `-c alias.push=…`: the read is not whole
            if bare is None:
                return None  # an option word known only at run time: the vanished reading reads on
            bare.append(rest[j])  # the region: empty, the options go on (the commit security review on 57dc1ed)
            j += 1
            continue
        if w in GIT_NO_RUN:
            return None
        if not w.startswith("-"):
            break
        if w in GIT_ARG_OPTS:
            if slot is not None and j + 1 < len(rest) and dyn[rest[j + 1]]:
                slot.append(rest[j + 1])  # the option's value, run-time: a slot
            j += 2
        else:
            j += 1
    if j >= len(rest):
        return None
    sub = words[rest[j]]
    args = [words[k] for k in rest[j + 1:] if not dyn[k]]
    if "--help" in args or "-h" in args:
        return None  # usage text, nothing runs
    if sub == "push":
        if any(_push_forces(a) for a in args):
            return "force-push"
    elif sub == "reset" and "--hard" in args:
        return "reset-hard"
    elif sub == "commit" and "--amend" in args:
        return "commit-amend"
    elif sub == "filter-repo":
        return "filter-repo"
    elif sub == "filter-branch":
        return "filter-branch"
    if "--no-verify" in args:
        return "no-verify"
    if "--no-gpg-sign" in args:
        return "no-gpg-sign"
    if sub == "push":
        return "git-push"
    return None


def _push_forces(a):
    if a in ("--force", "-f") or a.startswith("--force-with-lease"):
        return True
    if a.startswith("+") and len(a) > 1:
        return True  # a +refspec forces that ref
    if re.match(r"-[A-Za-z0-9]+$", a):
        for ch in a[1:]:
            if ch == "f":
                return True
            if ch == "o":
                return False  # -o takes the rest as its argument
    return False


def _rm(words, dyn, glob, rest, sudo, home, proj, sole):
    recursive, targets, opts, git_word = False, [], True, False
    for k in rest:
        w = words[k]
        if opts and w == "--":
            opts = False
            continue
        if opts and w.startswith("-") and w != "-" and not dyn[k]:
            if w == "--recursive" or (w[:2] != "--" and ("r" in w or "R" in w)):
                recursive = True
            continue
        if not dyn[k]:
            if ".git" in w.split("/"):
                git_word = True  # /x/.git/../* normalises past the .git it deletes (lens 2 on 8a49a8b)
            targets.append((_canon(w), glob[k]))
        elif home and HOME_WORD.match(w):
            # The reader marks ~ and $HOME unknown when the text names HOME at all, since the
            # command may set it. `env -u HOME rm -rf ~`, `HOME=/x rm -rf ~`: the shell expands
            # them before env or the prefix runs, so they are this home (the judge fuzzer,
            # 2026-10-31). A command that really moves HOME first is read as this home too:
            # a false block, never a false pass.
            targets.append((_canon(home + (HOME_WORD.match(w).group(2) or "")), glob[k]))
    if not recursive:
        return None
    for t, g in targets:
        if t == "/" or (g and _parent(t) == "/" and _all_glob(t)):
            return "rm-rf-root"
    for t, g in targets:
        if g and _all_glob(t) and _parent(t) in ("", ".", _canon(home or "")):
            return "rm-rf-glob"
    if sudo:
        return "sudo-rm-rf"
    if git_word:
        return "rm-rf-sole-copy"
    proj = _canon(proj)
    deep = [p for p in [_canon((home or "") + "/.claude")] + [_canon(s) for s in sole] if p.startswith("/")]
    for t, _ in targets:
        if ".git" in t.split("/"):
            return "rm-rf-sole-copy"
        if not t.startswith("/"):
            continue
        if proj and (t == proj or _parent(t) == proj or _under(proj, t)):
            return "rm-rf-sole-copy"
        for p in deep:
            if t == p or _under(t, p) or _under(p, t):
                return "rm-rf-sole-copy"  # the copy itself, inside it, or a directory holding it
    return None


def _under(path, root):
    """True when path sits below root (both canonical and absolute)."""
    return path.startswith(root.rstrip("/") + "/")


def _canon(path):
    path = re.sub(r"/+", "/", path)
    if re.search(r"(^|/)\.\.?(/|$)", path):
        # /tmp/../* is /*, ~/./* is home's every file (the lens on 81dbe48), x/../* is * (the
        # commit security review on 8a49a8b). Lexical, as the shell hands rm the words; a
        # symlinked step may land elsewhere, never the safe way round.
        path = posixpath.normpath(path)
    return path if path == "/" else path.rstrip("/")


def _parent(path):
    if "/" not in path:
        return ""
    head = path.rsplit("/", 1)[0]
    return head or "/"


def _all_glob(path):
    last = path.rsplit("/", 1)[-1]
    return bool(last) and set(last) <= {"*"}


def _publish(name, words, dyn, rest):
    static = [words[k] for k in rest if not dyn[k] and not words[k].startswith("-")]
    for shape in PUBLISH:
        if shape[0] == name and tuple(static[:len(shape) - 1]) == shape[1:]:
            return "public-publish"
    return None


def _payload(name, cmd, pipe, words, dyn, rest, home, proj, sole, depth, unread, chain=(), scope=()):
    """A shell or eval runs text as a command: read that text, depth-capped. A body it
    cannot read (past the cap, or known only at run time) goes on unread."""
    if depth <= 0:
        # Past the cap the text runs and nothing read it. Unread alone let an unkeyed command
        # pass with no token at all (the lens on 81dbe48: four nested bash -c around rm -rf /
        # ran), so it is the parser-depth hit, which nothing clears.
        unread.append("(past the depth cap)")
        return [("block", "parser-depth", ["(a payload nested past the reader's cap)"])]
    bodies = []
    if name == "eval":
        if any(dyn[k] for k in rest):
            unread.append("(eval of a run-time word)")
        if rest:
            bodies.append(" ".join(words[k] for k in rest))  # literal text read for keys either way
    else:
        # bash's options: -X and +X clusters, long --options, and the ones that take a value
        # (-o/+o/-O/+O, one word for each o or O in a cluster, as in -eo or -oc, and --rcfile/--init-file). -s
        # makes stdin the program, so a word after it is an argument, not a script file
        # (lens 4 on 13c95f8: `bash -s x`, `bash +e`, `bash -o pipefail` read as a script).
        j, seen_c, from_stdin = 0, False, False
        while j < len(rest):
            w = words[rest[j]]
            if dyn[rest[j]] and w.startswith("<(") and w.endswith(")"):
                break  # bash <(echo x): a script file the judge can read
            if dyn[rest[j]] and seen_c and w[:1] not in ("-", "+"):
                break  # bash -c "$SHELL -c 'x'": the program, read below for keys
            if dyn[rest[j]]:
                unread.append("(a run-time shell option)")
                return []
            if w == "--":
                j += 1
                break
            if w in ("-", "+") or w[:1] not in ("-", "+"):
                break
            if w in ("--rcfile", "--init-file"):
                j += 2
                continue
            if w[:2] == "--":
                j += 1
                continue
            if w[0] == "-" and "c" in w[1:]:
                seen_c = True  # -c, -lc, -ec: the program is the first word after the options
            if w[0] == "-" and "s" in w[1:]:
                from_stdin = True
            j += 1 + sum(ch in "oO" for ch in w[1:])  # every o/O in a cluster takes a word: -oc, -oo
        xargs = any(w.rsplit("/", 1)[-1] == "xargs" for w in chain)
        script = words[rest[j]] if j < len(rest) else None
        if seen_c:
            # after every option and its value: `bash -c -o pipefail 'x'` runs x, not pipefail
            # (security review on the lens-4 fold)
            if script is not None and dyn[rest[j]]:
                # read its literal text for keys, never whole: "$SHELL -c 'x'" inside a -c
                # program was passed unread (the bypass-list hunt, 2026-10-31)
                unread.append("(a run-time -c program)")
                bodies.append(script)
            elif script is not None:
                bodies.append(script)
                if xargs:
                    # xargs puts its input in the program (-I) or after it: always read the
                    # pipe, never whole (the commit security review on 7d9f824)
                    _stdin_bodies(pipe, bodies, unread)
                    _scope_bodies(scope, bodies, unread)
                    unread.append("(xargs hands its input to a shell)")
            elif xargs:
                _stdin_bodies(pipe, bodies, unread)  # xargs sh -c: its input is the program
                _scope_bodies(scope, bodies, unread)
                unread.append("(xargs hands its input to sh -c)")
        elif script is not None and script.startswith("<(") and script.endswith(")") and dyn[rest[j]]:
            _procsub_bodies(script, home, bodies, unread)  # bash <(echo x)
        elif from_stdin or script is None or script == "-" or script in STDIN_FILES:
            # no program file (or /dev/stdin): the shell reads its stdin
            _own_stdin_bodies(cmd, home, bodies, unread)
            if pipe:
                # a here-string or heredoc wins over the pipe; its words are still read for
                # keys (reading only adds), but an unknown pipe it ignores is not unread
                _stdin_bodies(pipe, bodies, [] if _own_stdin(cmd) else unread)
            if not _own_stdin(cmd):
                # a group drops the pipe (`{ echo x; } | sh` parses as a bare sh): every
                # feeder in the command is read for keys (the commit security review on 7d9f824)
                _scope_bodies(scope, bodies, unread)
                if not pipe:
                    unread.append("(a shell reading a stdin the reader cannot see)")
    return _judge_bodies(bodies, home, proj, sole, depth, unread)


BODY_CAP = 128  # bodies one command may hand the reader; past it the read is cut


def _judge_bodies(bodies, home, proj, sole, depth, unread):
    if len(set(bodies)) > BODY_CAP:
        # too much text to read in the hook's time: fail closed (the commit security review on 23fdb50)
        unread.append("(more payloads than the reader reads)")
        return [("block", "parser-depth", ["(more payloads than the reader reads)"])]
    hits, seen = [], set()
    for body in bodies:
        if body in seen:
            continue  # the pipe walk and the scope read can find one feeder twice
        seen.add(body)
        got, whole = judge_read(body, home=home, proj=proj, sole=sole, depth=depth - 1)
        hits.extend(h for h in got if (h[1], tuple(h[2])) not in seen)
        seen.update((h[1], tuple(h[2])) for h in got)  # one hit per key and words: bounded
        if not whole:
            unread.append(body)  # a body is the command's text too (lens 2 on 98a4413)
    return hits


TEXT_CMDS = {"su", "runuser", "script", "flock", "watch", "trap", "ssh", "find"}
SSH_ARG_OPTS = set("bcDEeFIiJLlmOopQRSWwB")
FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}


def _names_user(o):
    """runuser -u/--user in any spelling: a short group holding u, or an abbreviation of
    --user (the commit security review on 23fdb50)."""
    if o[:2] == "--":
        name = o[2:].split("=", 1)[0]
        return len(name) >= 2 and "user".startswith(name)
    return o[:1] == "-" and "u" in o[1:]


CARRY = {  # command: (options that take a value, the long options that carry the command)
    "su": ({"-s", "--shell", "-g", "--group", "-G", "--supp-group", "-w", "--whitelist-environment"},
           ("--command", "--session-command")),
    "runuser": ({"-s", "--shell", "-g", "--group", "-G", "--supp-group", "-w", "--whitelist-environment",
                 "-u", "--user"}, ("--command", "--session-command")),
    "script": ({"-E", "--echo", "-I", "--log-in", "-O", "--log-out", "-B", "--log-io", "-T",
                "--log-timing", "-m", "--logging-format"}, ("--command",)),
}
WATCH_ARG_OPTS = {"-n", "--interval", "-q", "--equexit"}


def _c_index(args, takes, longs):
    """Every place the -c text may be: indexes into args or literals (glued -cTEXT,
    --command=TEXT). Short groups letter by letter, stopping at a letter that takes a value;
    long options as getopt_long matches them (an exact name, else a prefix of any length);
    a prefix naming both a command option and a value option is read both ways; after --,
    su hands the rest to the shell, so a -c there is the text (the commit security reviews
    on 9dce826 and ef8d92e). su and runuser take options after their operand: all scanned."""
    found, i, user = [], 0, False
    while i < len(args):
        w = args[i]
        if w == "--":
            # su hands the rest to the shell: read it with bash's own option reader (the
            # commit security review on 91730fa). Before any operand, the first word after
            # -- is the user (the commit security review on 4e66f8a).
            found.append(("shell", i + 1))
            if not user:
                found.append(("shell", i + 2))  # the next word may be the user: read both ways
            break
        if w[:2] == "--":
            name, eq, val = w[2:].partition("=")
            opt = "--" + name
            cmds = [cl for cl in longs if cl == opt or cl.startswith(opt)] if name else []
            vals = [t for t in takes if t[:2] == "--" and (t == opt or t.startswith(opt))] if name else []
            if opt in takes and opt not in longs:
                cmds = []  # an exact value option is that option
            if cmds:
                found.append(("lit", val) if eq else ("idx", i + 1))
            i += 2 if (not eq and (cmds or vals)) else 1
            continue
        if w[:1] == "-" and len(w) > 1:
            step = 1
            for pos, ch in enumerate(w[1:], start=1):
                if ch == "c":
                    rest = w[pos + 1:]
                    found.append(("lit", rest) if rest else ("idx", i + 1))
                    step = 1 if rest else 2
                    break
                if "-" + ch in takes:
                    step = 1 if w[pos + 1:] else 2
                    break
            i += step
            continue
        if w != "-":
            user = True  # an operand: su's USER (a bare - is the login option; the commit security review on 1c81015)
        i += 1
    return found


FIND_WHOLE = {"-depth", "-d", "-maxdepth", "-mindepth", "-xdev", "-mount", "-ignore_readdir_race",
              "-noleaf", "-print", "-print0", "-daystart", "-follow", "-nowarn", "-warn", "-true"}


FIND_ARG1 = {"-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex",
             "-lname", "-ilname", "-newer", "-anewer", "-cnewer", "-user", "-group", "-uid", "-gid",
             "-perm", "-mtime", "-mmin", "-atime", "-amin", "-ctime", "-cmin", "-size", "-type",
             "-xtype", "-links", "-inum", "-samefile", "-fprint", "-fprint0", "-fls", "-maxdepth",
             "-mindepth", "-fstype", "-used", "-context", "-printf", "-regextype"}
FIND_ARG2 = {"-fprintf"}
FIND_FLAGS = FIND_WHOLE | {"-empty", "-readable", "-writable", "-executable", "-nouser", "-nogroup",
                           "-prune", "-quit", "-ls", "-delete", "-print", "-false"}


def _find_narrows(tests, dyns):
    """Whether find's tests surely leave files out. Fail closed (the commit security reviews
    on 2e26962 and 4e66f8a): the expression is walked as find reads it, each primary taking
    its operands; an unknown primary, any -o, -or, !, -not or parenthesis, a run-time word,
    and a -name whose pattern has no run of two literal letters or digits outside a [...]
    class ('*.pyc' yes; '*', '*.*', '[a-z][a-z]' no) all count as taking everything."""
    n, narrows = 0, False
    while n < len(tests):
        w = tests[n]
        if dyns[n] or w in ("-o", "-or", "!", "-not", "(", ")", "-a", "-and", ","):
            return False
        if w in FIND_EXEC or w == "-delete":
            if not narrows:
                return False  # an action before any narrowing test acts on every file (1c81015)
            n += 1
            continue
        if w in FIND_ARG1 or w in FIND_ARG2:
            k = 1 if w in FIND_ARG1 else 2
            vals = tests[n + 1:n + 1 + k]
            if len(vals) < k or any(dyns[n + 1:n + 1 + k]):
                return False
            if w in ("-name", "-iname") and "[" not in vals[0] and "]" not in vals[0]:
                # a bracket class is not parsed: never narrowing (1c81015)
                if re.search(r"[A-Za-z0-9]{2,}", re.sub(r"\\.", "", vals[0])):
                    narrows = True
            n += 1 + k
            continue
        if w in FIND_FLAGS:
            n += 1
            continue
        return False  # a primary the walker does not know: take everything
    return narrows


def _find_tests(expr, dyns):
    """find's expression words and their run-time flags, outside -exec … ; (those words are
    the command's, not find's tests)."""
    out, od, n = [], [], 0
    while n < len(expr):
        if expr[n] in FIND_EXEC:
            out.append(expr[n])  # the action stays, in order; its own words do not
            od.append(False)
            while n < len(expr) and expr[n] not in (";", "+"):
                n += 1
        else:
            out.append(expr[n])
            od.append(dyns[n])
        n += 1
    return out, od


def _carried(name, cmd, pipe, words, dyn, rest, home, proj, sole, depth, unread, scope, sudo=False):
    """Commands that carry text another shell runs (the bypass list, cluster 3): su -c,
    runuser USER -c, script -c, flock LOCK -c, watch WORDS, trap TEXT, ssh HOST WORDS, find
    -exec / -delete, git -c alias.NAME=… NAME. Words are rejoined as eval's are; a run-time
    word keeps its spelling, so the reread marks it unread. None: nothing carried."""
    args = [words[k] for k in rest]
    q = [words[k] if dyn[k] else _sq(words[k]) for k in rest]  # rejoinable spellings
    bodies = []
    if name in CARRY or name == "flock":
        if name == "flock":
            # LOCK where _unwrap found it: one option reader (the commit security review on ef8d92e)
            at = None
            for ab in (True, False):  # an abbreviation read both ways, as _command does
                n = (_skip_opts(words, dyn, rest[0], WRAPPERS["flock"], ab) - rest[0]) if rest else 0
                if n + 1 < len(args) and args[n + 1] in ("-c", "--command"):
                    at = at or ("idx", n + 2)
                elif n + 1 < len(args) and args[n + 1].startswith("--command="):
                    at = at or ("lit", args[n + 1][len("--command="):])
        else:
            at = _c_index(args, *CARRY[name])
        if name == "flock":
            at = [at] if at else []
            if not at:
                unread.append("(flock's text not located)")
                return None
        if not at:
            if name in ("su", "runuser"):
                # no -c: a login shell that reads its stdin
                _own_stdin_bodies(cmd, home, bodies, unread)
                if pipe:
                    _stdin_bodies(pipe, bodies, [] if _own_stdin(cmd) else unread)
                if not _own_stdin(cmd):
                    _scope_bodies(scope, bodies, unread)
            else:
                return None
        for kind, where in at:
            if kind == "shell":
                # q keeps a run-time word's own spelling, so the reread marks it unread
                bodies.append(" ".join(["bash"] + q[where:]))
            elif kind == "lit":
                bodies.append(where)
            elif where < len(args):
                if dyn[rest[where]]:
                    unread.append("(a run-time program another shell runs)")  # as bash -c "$x"
                bodies.append(args[where])  # its literal text is read for keys either way
    elif name == "watch":
        i = 0
        while i < len(args) and args[i].startswith("-") and args[i] != "--":
            i += 2 if args[i] in WATCH_ARG_OPTS else 1
        i += 1 if args[i:i + 1] == ["--"] else 0
        if i < len(args):
            bodies.append(" ".join(words[k] if dyn[k] else words[k] for k in rest[i:]))  # sh -c of its words
    elif name == "trap":
        i = 1 if args[:1] == ["--"] else 0
        if i < len(args) and not args[i].startswith("-"):
            if dyn[rest[i]]:
                unread.append("(a run-time trap)")
            else:
                bodies.append(args[i])
    elif name == "ssh":
        i = 0
        while i < len(args) and args[i].startswith("-") and args[i] != "--":
            w, step = args[i], 1
            for pos, ch in enumerate(w[1:], start=1):
                if ch in SSH_ARG_OPTS:
                    step = 1 if w[pos + 1:] else 2  # getopt: the rest of the word, or the next one
                    break
            i += step
        i += 1 if args[i:i + 1] == ["--"] else 0
        if i + 1 < len(args):
            bodies.append(" ".join(words[k] for k in rest[i + 1:]))  # the remote shell runs the rest
        elif i < len(args) and pipe:
            _stdin_bodies(pipe, bodies, unread)  # echo x | ssh host: the remote shell reads it
    elif name == "find":
        starts, i = [], 0
        while i < len(args) and (args[i] in ("-H", "-L", "-P", "-D") or re.match(r"-O\d*$", args[i])):
            i += 2 if args[i] == "-D" else 1  # -D DEBUGOPTS takes a value (the push review on acce506)
        if i < len(args) and args[i] == "--":
            i += 1  # -- ends find's leading options; start paths follow (the review on dadcd8b)
        while i < len(args) and not args[i].startswith(("-", "(", "!")):
            starts.append(q[i])
            i += 1
        starts = starts or ["."]
        expr, qexpr = args[i:], q[i:]
        # A test (-name, -type, -mtime …) picks some files: then -delete and {} are paths
        # under the start, not the start (the lens on ef8d92e: find / -name core -delete read
        # as rm -rf /). With no test, find takes every file, the start with it.
        picks = _find_narrows(*_find_tests(expr, [dyn[k] for k in rest[i:]]))
        under = (lambda t: t.rstrip("'").rstrip("/") + "/x'" if t.endswith("'") else t + "/x") if picks else (lambda t: t)
        pre = "sudo " if sudo else ""  # sudo find: the deletes are root's (the lens on ef8d92e)
        if "-delete" in expr:
            # no test: the tree goes, start and all; a test: matched files, one by one
            bodies.extend(pre + ("rm -f " if picks else "rm -rf ") + under(t) for t in starts)
        n = 0
        while n < len(expr):
            if expr[n] in FIND_EXEC:
                m = n + 1
                while m < len(expr) and expr[m] not in (";", "+"):
                    m += 1
                for t in starts:
                    # {} wherever it sits in a word (the commit security review on 9dce826)
                    t = under(t).strip("'")
                    bodies.append(pre + " ".join(_sq(expr[x].replace("{}", t)) if "{}" in expr[x]
                                                 else qexpr[x] for x in range(n + 1, m)))
                n = m
            n += 1
        if not bodies:
            return None
    elif name == "git":
        got = _git_alias(args)
        if got is None:
            return None
        bodies.extend(got)
    if depth <= 0:
        unread.append("(past the depth cap)")
        return [("block", "parser-depth", ["(a payload nested past the reader's cap)"])]
    return _judge_bodies(bodies, home, proj, sole, depth, unread)


def _sq(w):
    return "'" + w.replace("'", "'\\''") + "'"


def _git_alias(args):
    """git -c alias.NAME=VALUE … NAME ARGS, as shell texts to read: the invoked alias expanded
    up to five times (an alias of an alias), and every alias value on the line besides, since
    a !shell alias's own git calls see them all (GIT_CONFIG_PARAMETERS). None when no alias
    is invoked. Names compare case-insensitively, as git's do."""
    aliases, j = {}, 0
    while j < len(args):
        w = args[j]
        if w in GIT_NO_RUN or not w.startswith("-"):
            break
        if w == "-c" and j + 1 < len(args):
            k, _, v = args[j + 1].partition("=")
            if k.lower().startswith("alias."):
                aliases[k[len("alias."):].lower()] = v
        j += 2 if w in GIT_ARG_OPTS else 1
    if j >= len(args) or args[j].lower() not in aliases:
        return None
    texts = [v[1:] if v.startswith("!") else "git " + v for v in aliases.values()]
    sub, extra, seen = args[j].lower(), [_sq(a) for a in args[j + 1:]], set()
    while sub in aliases and sub not in seen and len(seen) < 5:
        seen.add(sub)
        value = aliases[sub]
        if value.startswith("!"):
            texts.append(" ".join([value[1:]] + extra))
            break
        words = value.split()
        if not words:
            break
        sub, extra = words[0].lower(), [_sq(w) for w in words[1:]] + extra
        texts.append(" ".join(["git", words[0]] + extra))
    return texts


def _sourced(cmd, pipe, words, dyn, rest, home, proj, sole, depth, unread, scope=()):
    """source/. run a file in this shell. A file on disk is tier C (a script written and run
    later); stdin spelled as a file and <(…) are text the judge can find (the bypass list)."""
    if depth <= 0:
        unread.append("(past the depth cap)")
        return [("block", "parser-depth", ["(a payload nested past the reader's cap)"])]
    k = 0
    if k < len(rest) and words[rest[k]] == "--":
        k += 1
    if k >= len(rest):
        return []
    f, bodies = words[rest[k]], []
    if dyn[rest[k]] and f.startswith("<(") and f.endswith(")"):
        _procsub_bodies(f, home, bodies, unread)
    elif not dyn[rest[k]] and f in STDIN_FILES:
        _own_stdin_bodies(cmd, home, bodies, unread)
        if pipe:
            _stdin_bodies(pipe, bodies, [] if _own_stdin(cmd) else unread)
        if not _own_stdin(cmd):
            _scope_bodies(scope, bodies, unread)
    else:
        return []
    return _judge_bodies(bodies, home, proj, sole, depth, unread)


def _own_stdin(cmd):
    return bool(cmd["heredocs"]) or any(
        r["op"] in ("<<<", "<>") or (r["op"] == "<" and r["target"] not in STDIN_FILES) for r in cmd["redirects"])


def _own_stdin_bodies(cmd, home, bodies, unread):
    """The text a command's own stdin carries: heredocs, here-strings, `< <(…)`."""
    bodies.extend(h["body"] for h in cmd["heredocs"])
    for r in cmd["redirects"]:
        if r["op"] == "<<<":
            if r["dynamic"]:
                unread.append("(a run-time here-string)")
            else:
                bodies.append(r["target"])
        elif r["op"] in ("<", "<>"):
            t = r["target"]
            if r["dynamic"] and t.startswith("<(") and t.endswith(")"):
                _procsub_bodies(t, home, bodies, unread)  # sh < <(echo x)
            elif t not in STDIN_FILES:
                unread.append("(a shell reading a file on stdin)")


def _stdin_bodies(pipe, bodies, unread):
    """Walk back from the stage nearest a shell to the text it writes: through cat, tee,
    head, tail, sort, uniq (they pass their input on) to an echo, a printf, yes, a heredoc or
    a here-string. Anything else (tr, sed, base64, curl) is text the judge cannot know: tier C
    for an encoding, residual 1 for the rest. An echo's read is never whole (bfebd78)."""
    k = len(pipe) - 1
    while k >= 0:
        st = pipe[k]
        words, dyn = st["words"], st["dynamic"]
        bodies.extend(h["body"] for h in st["heredocs"])
        at = _unwrap(words, dyn)[0] if words else None
        raw = words[at] if at is not None else ""
        name = raw.rsplit("/", 1)[-1]
        if raw in FEEDERS:
            if _rewrites(words[:at]):
                unread.append("(a shell fed by a rewritten echo)")
            elif any(dyn):
                unread.append("(a run-time echo into a shell)")
            else:
                text, _ = _fed(name, words[at + 1:])
                bodies.append(text)
                unread.append("(an echo into a shell: its output may not be its words)")
            return
        if raw in ("yes", "/usr/bin/yes", "/bin/yes"):
            if any(dyn):
                unread.append("(a run-time yes into a shell)")
            else:
                bodies.append(" ".join(words[at + 1:]) or "y")
            return
        if name in PASS and raw in (name, "/bin/" + name, "/usr/bin/" + name):
            if st["heredocs"]:
                return
            here = [r for r in st["redirects"] if r["op"] in ("<<<", "<", "<>")]
            if here:
                for r in here:
                    if r["op"] == "<<<":
                        if r["dynamic"]:
                            unread.append("(a run-time here-string)")
                        else:
                            bodies.append(r["target"])
                    elif r["dynamic"] and r["target"].startswith("<(") and r["target"].endswith(")"):
                        unread.append("(a process substitution into a filter)")
                    else:
                        unread.append("(a file into a shell)")
                return
            if any(dyn[at + 1:]) or _file_args(name, words[at + 1:]):
                unread.append("(a file into a shell)")
                return
            if name not in ("cat", "tee") or any(w.startswith("-") for w in words[at + 1:] if name == "cat"):
                # head -c, sort, uniq, cat -v change the text: read on, never whole (the commit
                # security review on 7d9f824)
                unread.append("(a filter that changes the text into a shell)")
            k -= 1
            continue
        if not st["heredocs"]:
            unread.append("(a shell fed by a pipe)")  # curl … | bash: its text is unknown
        return
    unread.append("(a shell fed by the session's stdin)")


def _scope_bodies(scope, bodies, unread):
    """Every text a feeder in the command writes: echo, printf, yes, heredocs, here-strings.
    Read for keys whenever a shell reads stdin, since a group or compound can hide which
    one reaches it. Reading only adds; an echo's read is never whole, nor is a run-time one.
    Read once per tree (_Scope)."""
    feeds = getattr(scope, "feeds", None)
    if feeds is None:
        fb, fu = [], []
        for st in scope:
            words, dyn = st["words"], st["dynamic"]
            fb.extend(h["body"] for h in st["heredocs"])
            for r in st["redirects"]:
                if r["op"] == "<<<":
                    if r["dynamic"]:
                        fu.append("(a run-time here-string in a command whose shell reads stdin)")
                    else:
                        fb.append(r["target"])
            at = _unwrap(words, dyn)[0] if words else None
            if at is None:
                continue
            raw = words[at]
            if raw in FEEDERS or raw in ("yes", "/usr/bin/yes", "/bin/yes"):
                if any(dyn):
                    fu.append("(a run-time feeder in a command whose shell reads stdin)")
                elif raw in FEEDERS:
                    fb.append(_fed(raw.rsplit("/", 1)[-1], words[at + 1:])[0])
                    fu.append("(an echo in a command whose shell reads stdin)")
                else:
                    fb.append(" ".join(words[at + 1:]) or "y")
        feeds = (fb, fu)
        if isinstance(scope, _Scope):
            scope.feeds = feeds
    bodies.extend(feeds[0])
    unread.extend(feeds[1])


def _file_args(name, args):
    """Whether a passthrough filter names a file to read (so its output is not its input)."""
    if name == "tee":
        return False  # tee's words are files it writes
    takes, i = PASS[name], 0
    while i < len(args):
        w = args[i]
        if w == "--":
            return any(a != "-" for a in args[i + 1:])
        if w.startswith("-") and w != "-":
            i += 2 if w in takes else 1
            continue
        if w != "-":
            return True
        i += 1
    return False


def _procsub_bodies(word, home, bodies, unread):
    """<(…): the text its last stages write, one pipeline at a time. Its commands run as well,
    and the tree walk judges them already."""
    tree = parse(word[2:-1], home=home)
    if not tree["ok"]:
        unread.append("(a process substitution the reader cannot parse)")
        return
    stages = []
    for c in tree["commands"]:
        if c["context"] != "top":
            continue
        stages.append(c)
        if c["sep"] not in ("|", "|&"):
            _stdin_bodies(stages, bodies, unread)
            stages = []
    if stages:
        _stdin_bodies(stages, bodies, unread)
    _scope_bodies(tree["commands"], bodies, unread)  # groups and compounds hide the last writer


def main(argv):
    import os
    import sys
    # The gate's wrapper asks for a first line, "read", before any reading: a judge that
    # started and died (a crash on crafted text, a kill under load) then leaves output
    # behind, and the wrapper refuses what it did not finish, where a python3 that never
    # started leaves none and the tables' verdict stands. Off by default: the CLI's
    # output is its verdict lines alone.
    if os.environ.get("MAUDE_JUDGE_MARK"):
        sys.stdout.write("read\n")
        sys.stdout.flush()
    # Two options, read by hand: argparse costs an import on every Bash call the gate sees.
    proj, sole = "", []
    for opt, val in zip(argv[::2], argv[1::2]):
        if opt == "--proj":
            proj = val
        elif opt == "--sole":
            sole.append(val)
    # bytes that are not UTF-8 are replaced, not fatal: the answer must always be one line
    text = sys.stdin.buffer.read().decode("utf-8", "replace")
    hits, whole = judge_read(text, proj=proj, sole=sole)
    seen = set()
    for _, k, words in hits:
        if k in seen:
            continue  # one line per key: a token is per key, and the output stays bounded
        seen.add(k)
        said = " ".join(words).replace("\n", "\\n")
        sys.stdout.write("block %s %s\n" % (k, said[:200]))
    if not whole:
        # after any hits: "opaque" for a payload not read, "unreadable" for text not parsed
        sys.stdout.write("opaque\n" if LAST["kind"] == "opaque" else "unreadable\n")
    elif not hits:
        sys.stdout.write("pass\n")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
