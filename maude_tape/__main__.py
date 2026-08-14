"""CLI: python3 -m maude_tape {seed,wake,check,capture,reject,remember,rest,audit}.

The bridge Maude's bash hooks call so the tape fires on its own — wake plays it, check
gates a draft (exit 2 = blocked), rest closes the loop, audit heals drift on live surfaces.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys

from .tape import Tape


def _read(text_arg: str | None) -> str:
    return text_arg if text_arg is not None else sys.stdin.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="maude_tape")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for name in ("wake", "rest"):
        sp = sub.add_parser(name)
        sp.add_argument("--db", required=True)

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
        with open(args.source, encoding="utf-8") as fh:
            spec = json.load(fh)
        for op in spec.get("ops", []):
            kind = op.get("op")
            if kind == "remember":
                tape.remember(op["text"], topic=op["topic"], source=op["source"],
                              authority=op.get("authority", "user-verbatim"))
            elif kind == "correct":
                tape.consolidate_correction(
                    rejected=op["rejected"], reason=op["reason"],
                    corrected_to=op["corrected_to"], topic=op["topic"], source=op["source"])
            elif kind == "reject":
                tape.reject(op["phrase"], reason=op["reason"], source=op["source"])
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
        if brief.canon_texts:
            print("\nHIS WORDS (his rendering — use verbatim, never re-render):")
            for text in brief.canon_texts:
                print(f"  • {text}")
        if rejections:
            print(f"\nNEVER RENDER ({len(rejections)}):")
            for hit in rejections:
                print(f"  ✗ {hit.phrase!r} — {hit.reason}")
        if brief.identity:
            print("\nWHO I AM:")
            for text in brief.identity:
                print(f"  • {text}")
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
            print(f"✗ REJECTED: {hit.phrase!r} — {hit.reason} [{hit.source}]")
        rc = 2 if hits else 0  # fail closed: a rejected line blocks

        _emit_voice_report()
        return rc

    if args.cmd == "capture":
        eid = tape.capture(_read(args.text), topic=args.topic,
                           source=args.source, importance=args.importance)
        print(f"captured event {eid}")
        return 0

    if args.cmd == "reject":
        tape.reject(args.phrase, reason=args.reason, source=args.source)
        print(f"rejected {args.phrase!r}")
        return 0

    if args.cmd == "remember":
        rid = tape.remember(_read(args.text), topic=args.topic, source=args.source)
        print(f"remembered {rid}")
        return 0

    if args.cmd == "rest":
        report = tape.rest()
        print(f"rest: consolidated {len(report.consolidated)}, forgot {len(report.forgotten)}")
        return 0

    if args.cmd == "audit":
        with open(args.surfaces, encoding="utf-8") as fh:
            surfaces = json.load(fh)
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
