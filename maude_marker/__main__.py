"""CLI for maude_marker. stdlib only.

    python3 -m maude_marker gen <key> <count> [--state PATH]
    python3 -m maude_marker verify <key> <token> [--state PATH] [--ledger PATH]
    python3 -m maude_marker status [--state PATH]

WHERE `gen` MUST RUN
--------------------
`gen` prints the links. Whoever sees that output can authorize. So it must run
where Claude cannot read the output:

    ! bash <plugin>/hooks/scripts/maude-marker.sh gen sole-copy-target 20

Use the wrapper, not `python3 -m` directly: bare `-m` fails with "No module named
maude_marker" unless PYTHONPATH already points at the plugin root, which is how
this instruction was first handed to John broken. The wrapper resolves it.

The leading `!` runs it in John's own shell. The links print to his terminal and
never enter Claude's context or any file Claude reads. Only the HEAD is written to
the state file, and the head is spent by construction.

If Claude ever runs `gen` through the Bash tool, the links land in the transcript
and the chain is void from that moment. The gate refuses to help with that: `gen`
exits non-zero when it detects it is running under a Claude Code hook/tool
environment. That check is a guard rail, not a wall (an env var can be unset), and
it is documented as such rather than oversold.
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


def _wrapper_path():
    """Absolute path to hooks/scripts/maude-marker.sh, derived from this file.

    Printed instead of `python3 -m maude_marker`, which fails with "No module
    named maude_marker" from any shell that has not already exported PYTHONPATH.
    A user-facing instruction that does not run is worse than none: it costs the
    reader a round trip and teaches them the tool is broken. Learned 2026-07-30
    by handing John exactly that line.
    """
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(root, "hooks", "scripts", "maude-marker.sh")


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
    determined bypass.
    """
    for var in ("CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT", "CLAUDE_CODE_SESSION_ID"):
        if os.environ.get(var):
            return True
    return False


def cmd_gen(argv):
    if len(argv) < 2:
        print("usage: gen <key> <count> [--state PATH]", file=sys.stderr)
        return 2
    key, count = argv[0], int(argv[1])
    state = _arg(argv, "--state", DEFAULT_STATE)

    if _looks_like_agent_context() and os.environ.get("MAUDE_MARKER_GEN_FORCE") != "1":
        print(
            "marker: refusing to generate inside an agent context — the links would\n"
            "land in the transcript and the chain would be void. Run it in your own\n"
            "shell with a leading ! instead:\n\n"
            "    ! bash %s gen %s %d\n" % (_wrapper_path(), key, count),
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

    chain.init(state, key, head, count=count)

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
    print("links: %d. SPEND FROM THE BOTTOM UP. Each one works exactly once." % count)
    print("Keep these somewhere Claude cannot read. Nothing here is recoverable from")
    print("the state file, and nothing can be regenerated once this window is gone.")
    print()
    for i, link in enumerate(links, 1):
        print("  %3d  %s" % (i, link))
    print()
    print("To authorize, hand the LAST unspent link to the gate:")
    print("  ! bash %s verify %s <link>" % (_wrapper_path(), key))
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
        return 0
    print("marker: REFUSED for %s — %s" % (key, reason), file=sys.stderr)
    return 1


def cmd_status(argv):
    state = _arg(argv, "--state", DEFAULT_STATE)
    data = chain._read_state(state)
    if not data:
        print("marker: no chain state at %s" % state)
        return 1
    for key, entry in sorted(data.get("chains", {}).items()):
        print("  %-22s remaining=%-4s head=%s…" % (
            key, entry.get("remaining"), str(entry.get("head"))[:12]))
    return 0


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmds = {"gen": cmd_gen, "verify": cmd_verify, "status": cmd_status}
    fn = cmds.get(argv[0])
    if not fn:
        print("marker: unknown command %r" % argv[0], file=sys.stderr)
        return 2
    return fn(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
