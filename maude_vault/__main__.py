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

    args = parser.parse_args(argv)
    if args.cmd == "build":
        n = ingest.build(args.mem_dir, args.db)
        print(f"built {n} notes")
        return 0
    if args.cmd == "page":
        query = args.query if args.query is not None else sys.stdin.read()
        hits = page.page(args.db, query, args.k)
        out = page.format_hits(hits)
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
