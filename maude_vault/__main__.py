"""CLI entrypoint: python3 -m maude_vault {build,page}."""
from __future__ import annotations

import argparse
import json
import sys
import time

from . import ingest, page


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="maude_vault")
    sub = parser.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build")
    b.add_argument("--mem-dir", required=True)
    b.add_argument("--db", required=True)

    p = sub.add_parser("page")
    # Optional: a prompt can exceed argv limits (128KiB E2BIG). When omitted,
    # the query is read from stdin instead — same as every sibling hook that
    # feeds Claude Code's hook JSON on stdin.
    p.add_argument("query", nargs="?", default=None)
    p.add_argument("--db", required=True)
    p.add_argument("--k", type=int, default=5)
    p.add_argument("--log", default=None)
    p.add_argument("--seen", default=None,
                   help="a file of note names this session was already shown; they are skipped and the new hits appended")
    p.add_argument("--snippets", action="store_true",
                   help="add each note's matched snippet under it (the eye reads them)")
    p.add_argument("--mem", default=None,
                   help="the markdown dir the index mirrors; with it, a hit whose file is newer than the index is marked stale")

    args = parser.parse_args(argv)
    if args.cmd == "build":
        n = ingest.build(args.mem_dir, args.db)
        print(f"built {n} notes")
        return 0
    if args.cmd == "page":
        query = args.query if args.query is not None else sys.stdin.read()
        seen: set[str] = set()
        if args.seen:
            try:
                with open(args.seen, encoding="utf-8") as f:
                    seen = {line.strip() for line in f if line.strip()}
            except OSError:
                pass
        hits = page.page(args.db, query, args.k, mem_dir=args.mem, exclude=seen)
        if hits and args.seen:
            try:
                with open(args.seen, "a", encoding="utf-8") as f:
                    f.write("".join(h["name"] + "\n" for h in hits))
            except OSError:
                pass
        out = page.format_hits(hits, snippets=args.snippets)
        if out:
            print(out)
        if hits and args.log:
            # The tally the rest-ritual sweeps: what got served, when. Append-
            # only JSONL; any failure is swallowed — logging must never break
            # paging (this runs inside a UserPromptSubmit hook).
            try:
                line = json.dumps({"ts": int(time.time()),
                                   "hits": [h["name"] for h in hits]})
                with open(args.log, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
