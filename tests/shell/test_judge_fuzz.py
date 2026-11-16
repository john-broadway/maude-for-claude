"""Fuzz maude_shell.judge: a red command, dressed and buried, still reads as red.

The judge is the gate's shell reader. A miss here is a false pass when the regex tables
miss too, and a crash or a slow read is the same thing in the hook: no key, and the
command runs. So the properties are:

  1. RED STAYS RED. Every generated command runs a red-key command (force-push, rm -rf /,
     a public publish, ...). judge_read must report a red key; past the judge's payload depth
     cap that key is parser-depth, which nothing clears.
  2. YELLOW NEVER HIDES RED. A yellow command beside the red one (the 965d025 class) does
     not take its place: the red key is in the hits, wherever the yellow one sits.
  3. NO CRASH, NO STALL. Mangled text never raises out of judge_read, and no read takes
     longer than SLOW seconds (the hook cuts the judge at 2 s and then passes on the tables).

Stdlib random only, fixed seed: CI sees the same cases every run.
    MAUDE_FUZZ_ITERS=20000 MAUDE_FUZZ_SEED=7 PYTHONPATH=. pytest tests/shell/test_judge_fuzz.py -q
A failure prints the seed, the case number and the text as a Python repr; feed the text to
`python3 -m maude_shell.judge` to see the read.
"""
import os
import random
import re
import subprocess
import time

import pytest

from maude_shell import judge as J
from maude_shell.judge import judge_read

HOME = "/srv/oracle"   # a synthetic home; not home-shaped, so the ship audit reads it as the fixture it is
PROJ = "/work/projects"
SOLE = ["/srv/keep"]

ITERS = int(os.environ.get("MAUDE_FUZZ_ITERS", "400"))
SEED = int(os.environ.get("MAUDE_FUZZ_SEED", "20261031"))
SLOW = float(os.environ.get("MAUDE_FUZZ_SLOW", "0.5"))

# The gate's red list (maude_red_keys + the keys nothing clears), kept beside the gate's.
RED = {"rm-rf-root", "rm-rf-glob", "sudo-rm-rf", "rm-rf-sole-copy", "sole-copy-target",
       "public-publish", "force-push", "filter-repo", "filter-branch", "infra-destructive",
       "drop-table", "parser-depth"}

# Red commands the judge claims to read (its docstring), as word lists. The command word
# is first so the dressers below can quote it apart from its arguments.
RED_SEEDS = [
    ["git", "push", "--force"], ["git", "push", "-f", "origin", "main"],
    ["git", "push", "--force-with-lease"], ["git", "push", "origin", "+main"],
    ["git", "filter-repo", "--force"], ["git", "filter-branch", "--tree-filter", "true"],
    ["rm", "-rf", "/"], ["rm", "-fr", "/"], ["rm", "-rf", "~"], ["rm", "-rf", "$HOME"],
    ["rm", "-rf", PROJ], ["rm", "-rf", SOLE[0]], ["rm", "-rf", "*"],
    ["twine", "upload", "dist/*"], ["uv", "publish"], ["hf", "upload", "me/model", "."],
    ["gh", "release", "create", "v1.0.0"],
]
YELLOW = ["git push", "git push origin main", "git commit --amend --no-edit", "git reset --hard"]
BENIGN = ["echo ok", "ls -la", "true", "cd /tmp", "git status", "date", ":", "printf x"]


def _sq(s):
    """Single-quote s for bash."""
    return "'" + s.replace("'", "'\\''") + "'"


def _dq(s):
    """Double-quote s for bash, escaping what double quotes expand."""
    return '"' + "".join("\\" + c if c in '"\\$`' else c for c in s) + '"'


# ── dressing the command word (same word to bash, different text) ─────────────
def dress_word(rng, w):
    forms = [w, _sq(w), _dq(w), "\\" + w, "$'" + w + "'"]
    if len(w) > 1:
        k = rng.randrange(1, len(w))
        forms += [w[:k] + "''" + w[k:], w[:k] + '""' + w[k:], w[:k] + "\\" + w[k:]]
    return rng.choice(forms)


def dress_arg(rng, a):
    if a in ("~", "*", "$HOME") or a.startswith("+"):
        return {"$HOME": rng.choice(["$HOME", "${HOME}"])}.get(a, a)  # quoting these changes them
    return rng.choice([a, a, _sq(a), _dq(a)])


def render(rng, words):
    head = dress_word(rng, words[0])
    rest = [dress_arg(rng, a) for a in words[1:]]
    if words[:2] == ["git", "push"] and rng.random() < 0.15:
        return "{git,push} " + " ".join(rest[1:])  # brace expansion: still git push
    return " ".join([head] + rest)


# ── wrappers: each runs the rest of its words ─────────────────────────────────
# External wrappers run a program by name. Builtins (exec, command, time) and busybox (rm
# only: it has no git) are handled in wrap(); an external one cannot run a builtin like eval.
WRAPS = ["sudo", "sudo -u root", "env", "env X=1", "env -u HOME", "nice", "nice -n 5", "nohup",
         "setsid", "timeout 5", "timeout -s KILL 5m", "stdbuf -o0", "ionice -c 3", "doas",
         "sudo -nu root", "sudo -iu root", "env -iu HOME", "timeout -sKILL 5", "nice -n5",
         "ionice -c3", "env -uHOME", "sudo -E -u root",
         # the bypass list (feat/gate-bypasses)
         "strace -f", "strace -o /tmp/t", "ltrace -e malloc", "unshare -m", "pkexec",
         "pkexec --user root", "systemd-run --scope", "nsenter -t 1 -m", "setpriv --reuid 0",
         "runuser -u root --", "chrt -f 10", "taskset 0x1", "taskset -c 0", "chroot /",
         "flock /tmp/l", "flock -w 5 /tmp/l", "sudo --us root"]


BUILTIN_WRAPS = ["exec", "command", "time"]


def wrap(rng, cmd):
    """(text, still wrappable). A builtin wrapper ends the chain: `env exec x` is not shell."""
    if rng.random() < 0.15:
        return rng.choice(BUILTIN_WRAPS) + " " + cmd, False
    if rng.random() < 0.1 and _word0(cmd) == "rm":
        return "busybox " + cmd, True
    return rng.choice(WRAPS) + " " + cmd, True


def _word0(cmd):
    """The command word, unquoted (enough for the generator's own dressings)."""
    w = cmd.split(" ", 1)[0]
    return w.replace("'", "").replace('"', "").replace("\\", "").replace("$", "")


# ── grouping: the command still runs ──────────────────────────────────────────
def group(rng, cmd):
    if "`" in cmd or "\\" in cmd:
        # an unescaped backtick inside backticks ends the first one, and backticks strip the
        # backslash from \$ and \\, so `sh -c "\$(x)"` would run x in the outer shell
        return "x=$( %s )" % cmd
    return rng.choice([
        "( %s )", "{ %s; }", "x=$( %s )", "x=`%s`", "if true; then %s; fi",
        "for x in a; do %s; done", "case x in x) %s;; esac", "! %s",
        "while true; do %s; break; done", "f() { %s; }; f",
    ]) % cmd


# ── payloads: a shell reads the text and runs it (each one is a depth level) ──
def payload(rng, cmd):
    """(text, kind). sh is dash on many boxes: no $'..', no {a,b}, and its echo eats
    backslashes, so sh only reads text without them. kind: "simple" (a command word reads
    it), "eval" (a builtin: no external wrapper may run it), "fed" (stdin carries it: no
    later redirect may replace that stdin)."""
    sh = "sh" if not any(x in cmd for x in ("$'", "{", "\\")) else "bash"
    return rng.choice([
        lambda c: ("bash -c " + _sq(c), "simple"), lambda c: (sh + " -c " + _dq(c), "simple"),
        lambda c: ("eval " + _sq(c), "eval"), lambda c: ("echo " + _sq(c) + " | " + sh, "fed"),
        lambda c: ("bash <<< " + _sq(c), "fed"), lambda c: ("bash <<'EOF'\n" + c + "\nEOF", "fed"),
        # the bypass list (feat/gate-bypasses)
        lambda c: ("bash <(echo " + _sq(c) + ")", "simple"),
        lambda c: ("echo " + _sq(c) + " | bash /dev/stdin", "fed"),
        lambda c: ("echo " + _sq(c) + " | source /dev/stdin", "fed"),
        lambda c: ("cat <<< " + _sq(c) + " | " + sh, "fed"),
        lambda c: ("yes " + _sq(c) + " | head -1 | " + sh, "fed"),
        lambda c: ("echo " + _sq(c) + " | tee /dev/null | " + sh, "fed"),
        lambda c: ("{ echo " + _sq(c) + "; } | " + sh, "fed"),
        lambda c: ("echo " + _sq(c) + " |& " + sh, "fed"),
        lambda c: ("echo " + _sq(c) + " | xargs -0 " + sh + " -c", "fed"),
        lambda c: ("$SHELL -c " + _sq(c), "simple"), lambda c: ('"$BASH" -c ' + _sq(c), "simple"),
        lambda c: ("su -c " + _sq(c) + " root", "simple"),
        lambda c: ("runuser root -c " + _sq(c), "simple"),
        lambda c: ("script -qc " + _sq(c) + " /dev/null", "simple"),
        lambda c: ("flock /tmp/l -c " + _sq(c), "simple"),
        lambda c: ("trap " + _sq(c) + " EXIT", "eval"),
        lambda c: ("ssh host " + _sq(c), "simple"),
        lambda c: ("find / -maxdepth 0 -exec " + sh + " -c " + _sq(c) + " \\;", "simple"),
        lambda c: ("git -c alias.x=" + _sq("!" + c) + " x", "simple"),
    ])(cmd)


# ── neighbours: the red command keeps company and still runs ──────────────────
def neighbour(rng, cmd, other):
    conn = rng.choice(["; ", " && ", " || ", " | ", "\n", " & "])
    left = rng.random() < 0.5  # other runs first
    if conn == " || " and left:
        other = "false"  # `x || R` runs R only when x fails
    if conn == " && " and other == "false":
        other = "true"
    if conn == " | " and left and ("f() {" in cmd or cmd.startswith(("time ", "! "))):
        conn = "; "  # a pipe stage is a subshell (f is defined there) and time/! open a pipeline
    return other + conn + cmd if left else cmd + conn + other


def noise(rng, cmd):
    # no `</dev/null`: after a here-string or a pipe it replaces the stdin carrying the payload
    return rng.choice([cmd, cmd + " >/dev/null", cmd + " 2>&1", "  " + cmd + "  "])


def generate(rng):
    """One case: (text, payload_depth). The red command is in an executed position.

    A wrapper takes a simple command only (`sudo { x; }` is not shell), so the generator
    tracks whether the text may still take one: a builtin wrapper, an eval, a fed shell or
    any compound ends that."""
    cmd = render(rng, rng.choice(RED_SEEDS))
    depth, wrappable, fed = 0, True, False
    for _ in range(rng.randint(1, 4)):
        step = rng.choice(["wrap", "group", "payload", "neighbour", "noise"])
        if step == "payload":
            if depth > J.DEPTH:
                continue
            if depth == J.DEPTH and rng.random() < 0.7:
                continue  # mostly stay inside the cap; cross it on purpose the rest of the time
            if not bash_parses(cmd):
                continue  # bash -n on the outer text never looks inside a payload body
            cmd, kind = payload(rng, cmd)
            depth, wrappable, fed = depth + 1, kind == "simple", kind == "fed"
            if cmd.endswith("\nEOF"):
                break  # a heredoc closer must stand alone on its line: nothing joins after it
        elif step == "wrap":
            if wrappable:
                cmd, wrappable = wrap(rng, cmd)
        elif step == "group":
            cmd, wrappable, fed = group(rng, cmd), False, False
        elif step == "neighbour":
            cmd, wrappable, fed = neighbour(rng, cmd, rng.choice(BENIGN + YELLOW)), False, False
        elif wrappable and not fed:
            cmd = noise(rng, cmd)
    return cmd, depth


def bash_parses(text):
    """bash -n: the case is a command bash would run, not text the generator mangled."""
    return subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True).returncode == 0


def red_ok(text, depth):
    """None when the property holds, else the reason."""
    t0 = time.perf_counter()
    hits, whole = judge_read(text, home=HOME, proj=PROJ, sole=SOLE)
    took = time.perf_counter() - t0
    if took > SLOW:
        return "slow read: %.2fs" % took
    if any(k in RED for _, k, _ in hits):
        return None
    return "no red key (whole=%s): %r" % (whole, [(k, w) for _, k, w in hits])


REJECTED = {"made": 0, "rejected": 0}


def generate_valid(rng):
    """generate() until bash -n takes it. A heredoc closer, `| !`: some joins are not shell,
    and bash is the judge of that. The rejection rate is held below a ceiling, so a
    generator that mostly makes junk fails loudly instead of testing nothing."""
    for _ in range(50):
        text, depth = generate(rng)
        REJECTED["made"] += 1
        if bash_parses(text):
            return text, depth
        REJECTED["rejected"] += 1
    raise AssertionError("50 generated cases in a row were not shell")


def run_red(iters, seed):
    rng = random.Random(seed)
    bad = []
    for i in range(iters):
        text, depth = generate_valid(rng)
        why = red_ok(text, depth)
        if why:
            bad.append("seed=%d case=%d depth=%d %s\n    text=%r" % (seed, i, depth, why, text))
    return bad


def test_red_stays_red():
    REJECTED.update(made=0, rejected=0)
    bad = run_red(ITERS, SEED)
    assert REJECTED["rejected"] <= REJECTED["made"] * 0.25, REJECTED
    assert not bad, "%d of %d red cases read short:\n%s" % (len(bad), ITERS, "\n".join(bad[:15]))


def test_yellow_never_hides_red():
    rng = random.Random(SEED + 1)
    bad, skipped = [], 0
    for i in range(ITERS):
        red = render(rng, rng.choice(RED_SEEDS))
        if rng.random() < 0.5:
            red, _ = wrap(rng, red)
        if rng.random() < 0.5:
            red = group(rng, red)
        y = rng.choice(YELLOW)
        conn = rng.choice(["; ", " && ", "\n", " | "])
        for text in (y + conn + red, red + conn + y):
            if not bash_parses(text):
                skipped += 1
                continue  # `| ! x` and kin: not shell, so not a case
            hits, _ = judge_read(text, home=HOME, proj=PROJ, sole=SOLE)
            if not any(k in RED for _, k, _ in hits):
                bad.append("seed=%d case=%d hits=%r\n    text=%r" % (SEED + 1, i, [k for _, k, _ in hits], text))
    assert skipped <= ITERS * 2 * 0.05, "%d of %d yellow cases were not shell" % (skipped, ITERS * 2)
    assert not bad, "%d yellow-beside-red cases lost the red key:\n%s" % (len(bad), "\n".join(bad[:15]))


MANGLE = list("'\"`$(){}[];&|<>\\\n\t #!*?~=") + ["$(", "<<", "<<<", "&&", "||", ";;", "${", "$'"]


def test_mangled_text_never_crashes_or_stalls():
    rng = random.Random(SEED + 2)
    bad = []
    for i in range(ITERS * 3):
        text, _ = generate_valid(rng)
        chars = list(text)
        for _ in range(rng.randint(1, 8)):
            pos = rng.randrange(len(chars) + 1)
            op = rng.random()
            if op < 0.5:
                chars.insert(pos, rng.choice(MANGLE))
            elif op < 0.8 and chars:
                del chars[min(pos, len(chars) - 1)]
            else:
                chars.insert(pos, chr(rng.randrange(0x20, 0x2FFF)))
        text = "".join(chars)
        if rng.random() < 0.1:
            text = text * rng.randint(2, 20)  # length
        t0 = time.perf_counter()
        try:
            judge_read(text, home=HOME, proj=PROJ, sole=SOLE)
        except Exception as e:  # noqa: BLE001 - any escape is the finding
            bad.append("seed=%d case=%d %s: %s\n    text=%r" % (SEED + 2, i, type(e).__name__, e, text[:300]))
            continue
        took = time.perf_counter() - t0
        if took > SLOW:
            bad.append("seed=%d case=%d slow %.2fs\n    text=%r" % (SEED + 2, i, took, text[:300]))
    assert not bad, "%d mangled cases crashed or stalled:\n%s" % (len(bad), "\n".join(bad[:15]))


def test_deep_nesting_never_claims_a_whole_read():
    """Past the cap the read is the parser-depth hit: unread alone let the hook pass it."""
    for n in range(J.DEPTH + 1, J.DEPTH + 6):
        text = "rm -rf /"
        for _ in range(n):
            text = "bash -c " + _sq(text)
        hits, whole = judge_read(text, home=HOME, proj=PROJ, sole=SOLE)
        assert any(k in RED for _, k, _ in hits), (n, text, hits, whole)


# ── planted controls: break the judge on purpose and watch the fuzzer see it ──
def test_control_force_push_blindness_is_caught(monkeypatch):
    monkeypatch.setattr(J, "_push_forces", lambda *a, **k: False)
    bad = run_red(ITERS, SEED)
    assert any(re.search(r"push.*(--force|-f |\+main)", b) for b in bad), "fuzzer missed a judge that cannot see --force"


def test_control_wrapper_blindness_is_caught(monkeypatch):
    monkeypatch.setattr(J, "WRAPPERS", {k: v for k, v in J.WRAPPERS.items() if k != "nice"})
    bad = run_red(ITERS, SEED)
    assert any(re.search(r"(?<!io)nice ", b) for b in bad), "fuzzer missed a judge that cannot see through nice"


def test_control_slow_read_is_caught(monkeypatch):
    """Proves red_ok's timer only; the hook's own 2 s cut is tested in tests/test-gate-parser.sh."""
    real = J.judge_read

    def slow(*a, **k):
        time.sleep(SLOW + 0.05)
        return real(*a, **k)

    monkeypatch.setattr(J, "judge_read", slow)
    monkeypatch.setitem(globals(), "judge_read", slow)
    assert red_ok("rm -rf /", 0).startswith("slow read")


@pytest.mark.parametrize("text", ["rm -rf /", "git push --force", "twine upload dist/*"])
def test_seed_sanity(text):
    """The oracle itself: a plain red seed passes it."""
    assert red_ok(text, 0) is None
