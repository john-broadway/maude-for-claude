"""CLI for maude_marker. stdlib only.

    python3 -m maude_marker gen <key> <count> [--state PATH]
    python3 -m maude_marker verify <key> <token> [--state PATH] [--ledger PATH]
    python3 -m maude_marker next <key> [--state PATH]
    python3 -m maude_marker status [--state PATH]

WHERE `gen` MUST RUN
--------------------
`gen` prints the links. Whoever sees that output can authorize. So it must run
where Claude cannot read the output: a terminal OUTSIDE Claude Code.

    bash <plugin>/hooks/scripts/maude-marker.sh gen sole-copy-target 20

Use the wrapper, not `python3 -m` directly: bare `-m` fails with "No module named
maude_marker" unless PYTHONPATH already points at the plugin root, which is how
this instruction was first handed out broken. The wrapper resolves it.

The `!` prompt inside Claude Code is NOT outside: it runs in the session and the
harness lands its output in the conversation (its own words for the `!` prefix).
Until 2026-10-08 every instruction here said to run `gen` there, and the refusal
below, which fires there because the session's environment is inherited, told the
person to do the thing they had just done. The refusal was right; its text was a
loop. Only the HEAD is written to the state file, and the head is spent by
construction, so `verify` and the clear line are fine at the `!` prompt: a spent
link is worthless.

If Claude ever runs `gen` through the Bash tool, the links land in the transcript
and the chain is void from that moment. The gate refuses to help with that: `gen`
exits non-zero when it detects it is running under a Claude Code hook/tool
environment. That check is a guard rail, not a wall (an env var can be unset), and
it is documented as such rather than oversold.

WHICH LINK IS NEXT
------------------
The chain spends in ORDER. `gen` numbers the links in that order, #1 first;
`next <key>` names the one to present now; a refused link, an accepted one and
`status` say it too. A chain generated before the order was recorded was printed
bottom-up, so its next link is #remaining of that list, and `next` says so.
"""

import hashlib
import os
import sys

from . import chain

DEFAULT_STATE = os.path.join(
    os.environ.get("MAUDE_USER_DIR") or os.path.expanduser("~/.claude/maude"),
    "markers.json",
)
DEFAULT_LEDGER = os.path.join(
    os.environ.get("MAUDE_USER_DIR") or os.path.expanduser("~/.claude/maude"),
    "marker-ledger.jsonl",
)


def _scripts_dir():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(root, "hooks", "scripts")


def _wrapper_path():
    """Absolute path to hooks/scripts/maude-marker.sh, derived from this file.

    Printed instead of `python3 -m maude_marker`, which fails with "No module
    named maude_marker" from any shell that has not already exported PYTHONPATH.
    A user-facing instruction that does not run is worse than none: it costs the
    reader a round trip and teaches them the tool is broken. Learned 2026-07-30
    by handing John exactly that line.
    """
    return os.path.join(_scripts_dir(), "maude-marker.sh")


def _clear_red_path():
    """The script a link is pasted INTO. `verify` alone spends a link and writes no
    token; the clear script verifies and then opens the gate, so that is the line
    the person needs."""
    return os.path.join(_scripts_dir(), "maude-clear-red.sh")


def _arg(argv, flag, default):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _looks_like_agent_context():
    """True if we appear to be running inside a Claude tool call.

    Deliberately conservative and deliberately honest: these vars are set by the
    harness, and an agent that wanted to could unset them. This stops the ACCIDENT
    (Claude helpfully running gen and burning the chain into a transcript), not a
    determined bypass. The `!` prompt inherits them too, and that is correct: its
    output lands in the conversation as well.
    """
    for var in ("CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT", "CLAUDE_CODE_SESSION_ID"):
        if os.environ.get(var):
            return True
    return False


def _hint_line(state, key):
    """One line naming the next link, from the head alone."""
    h = chain.next_hint(state, key)
    if h is None:
        return "next: no chain for %s" % key
    if h["order"] == "malformed":
        return ("next: unknown, the chain state for %s is malformed (remaining=%r, count=%r); "
                "nothing here was written by gen or verify" % (key, h["remaining"], h["count"]))
    if h["next"] is None:
        return "next: none, the chain for %s is exhausted (0 remaining)" % key
    if h["order"] == "spend":
        return "next: link #%d of %d (%d remaining)" % (h["next"], h["count"], h["remaining"])
    return ("next: link #%d of your list (%d remaining; a list printed before the order was "
            "recorded is numbered bottom-up, so the next link is always #remaining)"
            % (h["next"], h["remaining"]))


def _status_next(state, key):
    h = chain.next_hint(state, key)
    if h is None or h["next"] is None:
        return "?" if h and h["order"] == "malformed" else "none"
    return "#%d" % h["next"]


def cmd_gen(argv):
    if len(argv) < 2:
        print("usage: gen <key> <count> [--state PATH]", file=sys.stderr)
        return 2
    key, count = argv[0], int(argv[1])
    state = _arg(argv, "--state", DEFAULT_STATE)

    if _looks_like_agent_context() and os.environ.get("MAUDE_MARKER_GEN_FORCE") != "1":
        print(
            "marker: refusing to generate here. This shell runs inside Claude Code (its\n"
            "environment says so), and what it prints lands in the conversation, the `!`\n"
            "prompt included: the links would be in the transcript and the chain void from\n"
            "that moment. Open a terminal outside Claude Code and run there:\n\n"
            "    bash %s gen %s %d\n\n"
            "(verify and the clear line are fine at the `!` prompt: a spent link is worthless.)"
            % (_wrapper_path(), key, count),
            file=sys.stderr,
        )
        return 3

    seed = os.urandom(32)
    links = []
    cur = hashlib.sha256(seed).hexdigest()
    for _ in range(count):
        links.append(cur)
        cur = hashlib.sha256(cur.encode()).hexdigest()
    head = cur

    chain.init(state, key, head, count=count, order="spend")

    # Durable enforcement record. The gate refuses a RED key whenever the house is
    # marker-managed, so deleting markers.json can no longer downgrade it to the
    # --john path (redteam attack B: point the state at nothing, get a clearance).
    try:
        d = os.path.dirname(os.path.abspath(state)) or "."
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, ".marker-enforced"), "a") as fh:
            fh.write("%s\n" % key)
    except OSError:
        print("marker: WARNING could not write the enforcement record; deleting the\n"
              "        state file would silently re-open the --john fallback.", file=sys.stderr)

    print("key:   %s" % key)
    print("state: %s   (head only — safe on disk)" % state)
    print("links: %d, numbered in the order you spend them: #1 first, then #2, and so on."
          % count)
    print("Each works exactly once. Keep these somewhere Claude cannot read. Nothing here is")
    print("recoverable from the state file, and nothing can be regenerated once this window is gone.")
    print()
    # The last link generated is the head's preimage, so it is spent FIRST: print it as #1.
    for i, link in enumerate(reversed(links), 1):
        print("  #%-3d %s" % (i, link))
    print()
    print("To authorize, paste the next link into the line Claude shows you (/maude:conscience %s):" % key)
    print("  ! bash %s %s --marker <link>" % (_clear_red_path(), key))
    print("Which link is next, any time:  bash %s next %s" % (_wrapper_path(), key))
    return 0


def cmd_verify(argv):
    if len(argv) < 2:
        print("usage: verify <key> <token>", file=sys.stderr)
        return 2
    key, token = argv[0], argv[1]
    state = _arg(argv, "--state", DEFAULT_STATE)
    ledger = _arg(argv, "--ledger", DEFAULT_LEDGER)
    ok, reason = chain.verify_and_consume(state, key, token, ledger=ledger)
    if ok:
        print("marker: accepted for %s (%s)" % (key, reason))
        print(_hint_line(state, key))
        return 0
    print("marker: REFUSED for %s — %s" % (key, reason), file=sys.stderr)
    print(_hint_line(state, key), file=sys.stderr)
    return 1


def cmd_next(argv):
    if len(argv) < 1:
        print("usage: next <key> [--state PATH]", file=sys.stderr)
        return 2
    key = argv[0]
    state = _arg(argv, "--state", DEFAULT_STATE)
    line = _hint_line(state, key)
    if chain.next_hint(state, key) is None:
        print("marker: %s (state: %s)" % (line, state), file=sys.stderr)
        return 1
    print(line)
    return 0


def cmd_status(argv):
    state = _arg(argv, "--state", DEFAULT_STATE)
    data = chain._read_state(state)
    if not data:
        print("marker: no chain state at %s" % state)
        return 1
    for key, entry in sorted(data.get("chains", {}).items()):
        print("  %-22s remaining=%-4s next=%-5s head=%s…" % (
            key, entry.get("remaining"), _status_next(state, key), str(entry.get("head"))[:12]))
    return 0


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmds = {"gen": cmd_gen, "verify": cmd_verify, "next": cmd_next, "status": cmd_status}
    fn = cmds.get(argv[0])
    if not fn:
        print("marker: unknown command %r" % argv[0], file=sys.stderr)
        return 2
    return fn(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
