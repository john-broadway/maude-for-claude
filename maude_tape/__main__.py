"""CLI: python3 -m maude_tape {seed,wake,check,capture,reject,remember,rest,pending,promote,audit}.

The bridge Maude's bash hooks call so the tape fires on its own — wake plays it, check
gates a draft (exit 2 = blocked), rest closes the loop, audit heals drift on live surfaces.

`pending` and `promote` are the user's half: rest consolidates HIS words and archives noise,
but an agent inference never reaches canon on a score the agent gave itself. It waits on the
pending list until he promotes it.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys

from .tape import Tape, _score, looks_secretish


def _one_line(text: str) -> str:
    """Render stored content so it can never counterfeit one of our own headers.

    Everything printed by `wake` is injected into a future session's context, and `pending`
    is the screen where his hand is actually asked for. Both echoed stored text raw, so a
    row whose TEXT contained the literal "HIS WORDS (his rendering...)" header rendered as a
    second, authentic-looking block — reached through the entirely honest flow, with this
    release's own vocabulary as the payload. Four rounds guarded which text may ENTER the
    store and one guarded the LABEL on the way out; none had asked whether the content could
    forge the label.

    Anything carrying a line break is escaped to a single line — the `!r` idiom already used
    for rejected phrases two lines below. Content then cannot begin a line of its own, so it
    cannot open a block. Measured against the real tape first: all ten canon rows are single
    line, so this costs the homeowner nothing today and bounds the damage when it does fire.
    """
    return text if text == _sanitised(text) else repr(text)


# Anything that can move a cursor, erase a line, or reorder what a reader sees. ESC is the
# one that matters: \x1b[2K\x1b[1A erases the current line and moves up, so a stored value
# can overwrite the very label naming it as Claude's — the forgery again, through a channel
# a "no line may BEGIN with a header" assertion structurally cannot see, because the escape
# bytes begin the line and the header text does not.
_UNSAFE = frozenset(
    [chr(c) for c in range(0x20)] + [chr(0x7f)] + [chr(c) for c in range(0x80, 0xa0)]
    + ["\u200b", "\u200c", "\u200d", "\u2060", "\ufeff",          # zero-width
       "\u202a", "\u202b", "\u202c", "\u202d", "\u202e",          # bidi overrides
       "\u2066", "\u2067", "\u2068", "\u2069"]
)


def _sanitised(text: str) -> str:
    return "".join(c for c in text if c not in _UNSAFE)


def _read(text_arg: str | None) -> str:
    return text_arg if text_arg is not None else sys.stdin.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="maude_tape")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for name in ("wake", "rest", "pending"):
        sp = sub.add_parser(name)
        sp.add_argument("--db", required=True)

    pr = sub.add_parser("promote")   # his hand on the buffer's door into canon
    pr.add_argument("--db", required=True)
    pr.add_argument("--id", required=True, type=int,
                    help="event id from `pending` — only a buffered event can be promoted")

    di = sub.add_parser("dismiss")   # his 'no' — the list needs both answers
    di.add_argument("--db", required=True)
    di.add_argument("--id", required=True, type=int,
                    help="event id from `pending` — archived, never deleted")

    sd = sub.add_parser("seed")
    sd.add_argument("--db", required=True)
    sd.add_argument("--from", dest="source", required=True,
                    help="path to a JSON seed file: {\"ops\": [...]} — the plugin ships none")

    c = sub.add_parser("check")
    c.add_argument("text", nargs="?", default=None)
    c.add_argument("--db", required=True)
    c.add_argument("--voice", action="store_true",
                   help="append a VOICE REPORT (numbers, never a verdict) after the "
                        "floor output if a voice_profile has been computed. Never "
                        "changes the exit code — the phrase floor alone owns 0/2/3.")

    cap = sub.add_parser("capture")
    cap.add_argument("text", nargs="?", default=None)
    cap.add_argument("--db", required=True)
    cap.add_argument("--topic", required=True)
    cap.add_argument("--source", required=True)
    cap.add_argument("--importance", type=float, default=0.5)
    # Defaults to the agent's own read, which never auto-promotes. Pass user-verbatim (or
    # user-paraphrase) when recording what the USER actually said — his words are not
    # something to make him approve.
    cap.add_argument("--authority", default="agent-inference",
                     choices=("agent-inference", "user-paraphrase", "user-verbatim"))

    rej = sub.add_parser("reject")
    rej.add_argument("--db", required=True)
    rej.add_argument("--phrase", required=True)
    rej.add_argument("--reason", required=True)
    rej.add_argument("--source", required=True)

    rem = sub.add_parser("remember")
    rem.add_argument("text", nargs="?", default=None)
    rem.add_argument("--db", required=True)
    rem.add_argument("--topic", required=True)
    rem.add_argument("--source", required=True)
    # Writes canon directly, so it has always filed as his words. The flag makes that
    # choice sayable instead of implicit; the default keeps existing callers unchanged.
    rem.add_argument("--authority", default="user-verbatim",
                     choices=("agent-inference", "user-paraphrase", "user-verbatim"))

    aud = sub.add_parser("audit")
    aud.add_argument("--db", required=True)
    aud.add_argument("--surfaces", required=True, help="path to JSON {surface_name: text}")

    hv = sub.add_parser("harvest")
    hv.add_argument("--db", required=True)
    hv.add_argument("--transcripts", required=True,
                    help="dir walked recursively for session *.jsonl transcripts")
    hv.add_argument("--register", default="chat",
                    help="voice register tag stored per line (default: chat = typed "
                         "in-session prose; e.g. 'public' for a posted-copy corpus)")

    pf = sub.add_parser("profile")
    pf.add_argument("--db", required=True)

    vc = sub.add_parser("voice-capture")   # the silent hook path: one line on stdin
    vc.add_argument("--db", required=True)
    vc.add_argument("--source", default="hook")
    vc.add_argument("--register", default="chat")
    vc.add_argument("--session", default=None)

    args = parser.parse_args(argv)
    try:
        # voice-capture is an observer on the prompt's critical path: it gets a short
        # lock wait so a busy tape costs milliseconds, not the default five seconds.
        tape = Tape(args.db, busy_timeout=0.8 if args.cmd == "voice-capture" else 5.0)
    except sqlite3.Error as exc:
        # Was an uncaught OperationalError exiting 1, outside the documented {0,2,3}.
        # It failed closed, but a caller could not tell "blocked" from "crashed".
        print(f"tape: cannot open db {args.db!r}: {exc}", file=sys.stderr)
        # voice-capture alone is an OBSERVER, not a gate: its contract is exit 0 on ANY
        # failure so a broken capture can never block a prompt. Every other subcommand
        # keeps the loud 3 — a gate that cannot open its tape must say so.
        return 0 if args.cmd == "voice-capture" else 3

    if args.cmd == "seed":
        if tape.wake().canon_texts:
            print("tape already seeded")
            return 0
        try:
            with open(args.source, encoding="utf-8") as fh:
                spec = json.load(fh)
        except (OSError, ValueError) as exc:
            print(f"seed refused: cannot read {args.source!r}: {exc}", file=sys.stderr)
            return 2
        if not isinstance(spec, dict) or not isinstance(spec.get("ops", []), list):
            print("seed refused: expected an object with an \"ops\" list. Nothing written.",
                  file=sys.stderr)
            return 2
        # Scan the WHOLE file before writing any of it. remember() and reject() each
        # commit on their own, so refusing partway through left the ops before it durable
        # behind a "refused" message — and seed's re-entry guard only asks whether canon
        # is empty, so a rerun would silently skip whatever had already landed.
        for op in spec.get("ops", []):
            if not isinstance(op, dict):
                print(f"seed refused: every op must be an object, got {type(op).__name__}. "
                      "Nothing was written.", file=sys.stderr)
                return 2
            # EVERY string in the op. A key list was hand-picked twice and came up short
            # twice — first missing the rejection fields, then topic/source/authority. The
            # op's own values are the list; stop maintaining a second one beside them.
            for key, value in op.items():
                if isinstance(value, str) and looks_secretish(value):
                    print(f"seed refused: op {op.get('op')!r} carries a credential shape "
                          f"in {key!r}. Nothing was written.", file=sys.stderr)
                    return 2
        for op in spec.get("ops", []):
            kind = op.get("op")
            try:
                if kind == "remember":
                    tape.remember(op["text"], topic=op["topic"], source=op["source"],
                                  authority=op.get("authority", "user-verbatim"))
                    continue
                if kind == "correct":
                    tape.consolidate_correction(
                        rejected=op["rejected"], reason=op["reason"],
                        corrected_to=op["corrected_to"], topic=op["topic"],
                        source=op["source"])
                    continue
            except KeyError as exc:
                # A required field is missing. Was a bare KeyError on exit 1, outside the
                # documented {0,2,3} — the same class the sqlite and OverflowError paths
                # already closed, in the block right beside them.
                print(f"seed refused: op {op.get('op')!r} is missing {exc}",
                      file=sys.stderr)
                return 2
            except ValueError as exc:
                # Backstop only — the pre-scan above is what makes the refusal atomic.
                # If this fires, the door refused for a reason the scan cannot see, and
                # earlier ops in this file ARE already written. Say so.
                print(f"seed refused mid-file: {exc}\n"
                      f"WARNING: ops before this one are already written to {args.db!r}.",
                      file=sys.stderr)
                return 2
            if kind == "reject":
                try:
                    tape.reject(op["phrase"], reason=op["reason"], source=op["source"])
                except ValueError as exc:
                    print(f"seed refused mid-file: {exc}", file=sys.stderr)
                    return 2
            else:
                print(f"unknown seed op: {kind!r}", file=sys.stderr)
                return 2
        print(f"tape seeded from {args.source}")
        return 0

    if args.cmd == "wake":
        brief = tape.wake()
        rejections = tape.list_rejections()
        if not brief.canon_texts and not rejections and not brief.identity:
            return 0  # empty tape (fresh install) — play nothing
        print("=== THE TAPE — play at wake ===")
        # Split by authority. His verbatim words are the only ones that may be replayed as
        # his; a rendering he approved, or an inference he promoted, is Claude's wording and
        # saying otherwise hands his voice away. promote.md already promised authority is
        # preserved — it was true in the table and false on the screen.
        entries = brief.canon_entries or [(t, "user-verbatim") for t in brief.canon_texts]
        his = [t for t, a in entries if a == "user-verbatim"]
        ours = [(t, a) for t, a in entries if a != "user-verbatim"]
        if his:
            print("\nHIS WORDS (his rendering — use verbatim, never re-render):")
            for text in his:
                print(f"  • {_one_line(text)}")
        if ours:
            # Header deliberately does NOT contain the substring "HIS WORDS" — a reader splitting
            # on that string would otherwise land inside this block. Never substring-match.
            print("\nCLAUDE'S WORDING, APPROVED BY HIM (never quote as his):")
            for text, authority in ours:
                print(f"  ◦ {_one_line(text)}  [{authority}]")
        if rejections:
            print(f"\nNEVER RENDER ({len(rejections)}):")
            for hit in rejections:
                print(f"  ✗ {hit.phrase!r} — {_one_line(hit.reason)}")
        if brief.identity:
            print("\nWHO I AM:")
            for text in brief.identity:
                print(f"  • {_one_line(text)}")
        # The queue has to be said where there are ears. `rest` announces it at SessionEnd,
        # into a hook that redirects to /dev/null — so the count was built and never heard.
        # Wake is read. Observer discipline: a broken buffer costs the line, never the tape.
        try:
            waiting = len(tape.pending())
        except Exception:
            waiting = 0
        if waiting:
            print(f"\n{waiting} awaiting your word — see them with /maude:promote")
        return 0

    if args.cmd == "check":
        # A gate that grades nothing approves everything the caller forgot to feed it. There
        # are two ways to grade nothing, and BOTH exit 3: no draft, and no tape to judge it
        # against. Each is pinned by a test_check_* in tests/tape/test_cli.py.
        #
        # RESIDUAL, stated at full breadth: a positional argument naming a path that does not
        # EXIST (a typo) is still graded as literal text and can exit 0. Only paths that exist
        # are caught. Detecting path-SHAPED strings would false-block real drafts, so the bound
        # is: exit 0 means the bytes handed in were graded against a tape holding at least one
        # rejection, and stdin is the only way to be sure those bytes were the draft.
        if args.text is not None and os.path.lexists(args.text):
            # lexists, not isfile: a directory and a DANGLING SYMLINK both answer False to
            # isfile, fell through, and were graded as text. Same silent pass, different shape.
            print(f"check: {args.text!r} is an existing PATH, not a draft. The gate grades the "
                  f"positional argument as TEXT, so this would have graded the path string "
                  f"and passed. Pipe the file instead: "
                  f"python3 -m maude_tape check --db <db> < {args.text}", file=sys.stderr)
            return 3
        draft = _read(args.text)
        if not draft.strip():
            print("check: empty draft, nothing to gate. This is a CALLER error, not a pass. "
                  "Feed the draft on stdin and confirm the byte count you fed it.",
                  file=sys.stderr)
            return 3
        def _emit_voice_report() -> None:
            # Additive only: --voice never touches the exit code. The floor alone owns
            # 0/2/3 — the report is numbers, the floor is the gate.
            if not args.voice:
                return
            from . import voice
            profile = voice.load_profile(tape)
            if profile is None:
                print("voice: no profile stored — run profile first")
            else:
                for line in voice.voice_report_lines(draft, profile):
                    print(line)

        if not tape.list_rejections():
            # sqlite3.connect() CREATES a missing file, so a typo'd --db silently built an
            # empty tape and cleared every draft with no error. A tape that holds nothing to
            # refuse cannot certify anything; saying "clean" there is the lie this prevents.
            print(f"check: the tape at {args.db!r} holds NO rejected phrasings, so it cannot "
                  f"refuse anything and a pass would mean nothing. Check the --db path (a "
                  f"missing file is created empty, not reported) and that it has been seeded.",
                  file=sys.stderr)
            # The voice report is orthogonal to the floor and still prints (a fresh
            # install has a profile long before its first seeded rejection — the numbers
            # are real either way). The 3 stands: nothing was CERTIFIED.
            _emit_voice_report()
            return 3
        hits = tape.check_draft(draft)
        for hit in hits:
            print(f"✗ REJECTED: {hit.phrase!r} — {_one_line(hit.reason)} "
                  f"[{_one_line(hit.source)}]")
        rc = 2 if hits else 0  # fail closed: a rejected line blocks

        _emit_voice_report()
        return rc

    if args.cmd == "capture":
        try:
            eid = tape.capture(_read(args.text), topic=args.topic, source=args.source,
                               importance=args.importance, authority=args.authority)
        except ValueError as exc:
            # Refuse inside the documented {0,2,3}. An uncaught raise exits 1 and reads as
            # a broken tape rather than a guard that did its job.
            print(f"capture refused: {exc}", file=sys.stderr)
            return 2
        print(f"captured event {eid}")
        return 0

    if args.cmd == "dismiss":
        try:
            tape.dismiss(args.id)
        except ValueError as exc:
            print(f"dismiss refused: {exc}", file=sys.stderr)
            return 2
        print(f"dismissed event {args.id} — archived, not deleted")
        return 0

    if args.cmd == "reject":
        try:
            tape.reject(args.phrase, reason=args.reason, source=args.source)
        except ValueError as exc:
            print(f"reject refused: {exc}", file=sys.stderr)
            return 2
        print(f"rejected {args.phrase!r}")
        return 0

    if args.cmd == "remember":
        try:
            rid = tape.remember(_read(args.text), topic=args.topic, source=args.source,
                                authority=args.authority)
        except ValueError as exc:
            # Same contract as capture: refuse inside the documented {0,2,3}, never an
            # uncaught raise on exit 1 that reads as a broken tape.
            print(f"remember refused: {exc}", file=sys.stderr)
            return 2
        print(f"remembered {rid}")
        return 0

    if args.cmd == "rest":
        report = tape.rest()
        waiting = len(tape.pending())
        line = (f"rest: consolidated {len(report.consolidated)}, "
                f"forgot {len(report.forgotten)}")
        if report.refused:
            # Computed and never printed would be a count nobody reads.
            line += f", {len(report.refused)} refused at the canon door"
        # Say it out loud. A queue nobody is told about is just a pile.
        print(line + (f", {waiting} awaiting your word" if waiting else ""))
        return 0

    if args.cmd == "pending":
        waiting = tape.pending()
        if not waiting:
            print("pending: nothing is waiting on you")
            return 0
        print(f"pending: {len(waiting)} awaiting your word — promote with --id <n>")
        for e in waiting:
            # A row can reach this list precisely BECAUSE its score is unreadable (a stored
            # NaN comes back as NULL). Formatting it as a number crashed the one command the
            # ritual runs — the library method survived, so the suite never saw it.
            score = _score(e.importance)
            shown = "unscored" if score is None else f"importance {score:g}"
            if e.status == "refused":
                shown += ", refused at the canon door"
            # This is the screen where his consent is actually asked. wake was split by
            # authority this release; the queue where he JUDGES inference against fact
            # showed his own low-scored words and a pure inference identically.
            print(f"  [{e.id}] {_one_line(e.topic)} ({shown}, {e.authority}) "
                  f"— {_one_line(e.text)}")
        return 0

    if args.cmd == "promote":
        try:
            tape.promote(args.id)
        except ValueError as exc:
            # Fail closed and loud: a promotion that silently did nothing would let him
            # believe he had kept something.
            print(f"promote refused: {exc}", file=sys.stderr)
            return 2
        print(f"promoted event {args.id} into canon")
        return 0

    if args.cmd == "audit":
        try:
            with open(args.surfaces, encoding="utf-8") as fh:
                surfaces = json.load(fh)
        except (OSError, ValueError) as exc:
            print(f"audit: cannot read {args.surfaces!r}: {exc}", file=sys.stderr)
            return 2
        breaches = tape.audit(surfaces)
        for br in breaches:
            print(f"✗ BREACH {br.surface}: {br.phrase!r} live — {br.reason}")
        return 2 if breaches else 0  # fail closed: drift on a real surface is a finding

    if args.cmd == "harvest":
        from . import voice  # lazy: the wake/check hot paths never pay for this import
        return voice.cmd_harvest(args, tape)

    if args.cmd == "profile":
        from . import voice
        return voice.cmd_profile(args, tape)

    if args.cmd == "voice-capture":
        from . import voice
        return voice.cmd_capture(args, tape)

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
