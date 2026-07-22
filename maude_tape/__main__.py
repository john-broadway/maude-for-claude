"""CLI: python3 -m maude_tape {seed,wake,check,capture,reject,remember,rest,audit}.

The bridge Maude's bash hooks call so the tape fires on its own — wake plays it, check
gates a draft (exit 2 = blocked), rest closes the loop, audit heals drift on live surfaces.
"""
from __future__ import annotations

import argparse
import json
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

    args = parser.parse_args(argv)
    tape = Tape(args.db)

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
        hits = tape.check_draft(_read(args.text))
        for hit in hits:
            print(f"✗ REJECTED: {hit.phrase!r} — {hit.reason} [{hit.source}]")
        return 2 if hits else 0  # fail closed: a rejected line blocks

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

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
