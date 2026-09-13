"""CLI: python3 -m maude_rules schema [--brief] [--asks] [--count] PATH...

Exit 1 when any finding-level hit exists, 0 otherwise, 2 on usage error (no `schema`
subcommand, no paths, or an unrecognized flag). Never raises on a bad file: an
unreadable path prints `PATH: unreadable` and counts as no findings.

`--count` prints `PATH: N table(s)` and nothing else, always exiting 0: it answers
what the linter READ, not what it thinks, so a caller can say how many tables a
green run actually looked at. It wins over --brief when both are given.

`--brief` distinguishes a file with no findings (`PATH: clean`) from a file with
nothing to find (`PATH: no CREATE TABLE found`). They are not the same claim, and
calling an ALTER-only migration clean is a pass the linter never earned."""
from __future__ import annotations

import sys

from .schema import lint, format_line, extract_tables

_USAGE = "usage: python3 -m maude_rules schema [--brief] [--asks] [--count] PATH..."
_KNOWN_FLAGS = {"--brief", "--asks", "--count"}


def _read(path: str) -> str | None:
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", errors="replace")
    except OSError:
        return None


def main(argv: list[str]) -> int:
    if not argv or argv[0] != "schema":
        print(_USAGE, file=sys.stderr)
        return 2
    rest = argv[1:]
    unknown = [a for a in rest if a.startswith("-") and a not in _KNOWN_FLAGS]
    if unknown:
        print(_USAGE, file=sys.stderr)
        return 2
    brief = "--brief" in rest
    asks = "--asks" in rest
    count = "--count" in rest
    paths = [a for a in rest if not a.startswith("-")]
    if not paths:
        print(_USAGE, file=sys.stderr)
        return 2
    any_finding = False
    for path in paths:
        text = _read(path)
        if text is None:
            print(f"{path}: unreadable")
            continue
        if count:
            print(f"{path}: {len(extract_tables(text))} table(s)")
            continue
        hits = lint(text)
        shown = [h for h in hits if h.level == "finding" or asks]
        found = [h for h in hits if h.level == "finding"]
        any_finding = any_finding or bool(found)
        if brief:
            if not found and not extract_tables(text):
                print(f"{path}: no CREATE TABLE found")
            elif not found:
                print(f"{path}: clean")
            else:
                named = "; ".join(format_line(h) for h in found[:2])
                more = f"; +{len(found) - 2} more" if len(found) > 2 else ""
                print(f"{path}: {len(found)} finding(s): {named}{more}")
        else:
            for h in shown:
                tag = "" if h.level == "finding" else "ask: "
                print(f"{path}: {tag}{format_line(h)}")
    return 0 if count else (1 if any_finding else 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
