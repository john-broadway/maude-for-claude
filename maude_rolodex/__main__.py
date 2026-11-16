"""The Rolodex command line: index, show, approve, revoke, live. Stdlib only.

This is the ONLY place the environment is read: $HOME, $CLAUDE_PROJECT_DIR,
the cwd and the clock. Everything below it takes `home`, `project` and `now`.
Exit codes: 0 ok; 2 a refusal (one signed line on stderr); 3 is the wrapper's
(no python3).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time

from maude_rolodex import calls, index, match, store
from maude_rolodex.page import render_cue


def _parser() -> argparse.ArgumentParser:
    def opts(p, default):
        p.add_argument("--home", default=default, help="default: $HOME")
        p.add_argument("--project", default=default, help="default: $CLAUDE_PROJECT_DIR or the cwd")

    top = argparse.ArgumentParser(prog="maude-rolodex", description="Maude's Rolodex")
    opts(top, None)
    sub = top.add_subparsers(dest="verb", required=True)
    for verb, helptext, many in (
            ("index", "list what is callable in this project", False),
            ("show", "print a trade's pending and approved pages", "one"),
            ("approve", "approve pending pages: approve <slug>@<64-hex hash from show> ... (the user's own line)", True),
            ("revoke", "revoke approved pages (the user's own line)", True),
            ("live", "rebuild what is on call in this project", False),
            ("cue", "the hook's verb: the prompt on stdin; print the one approved line, or nothing", False),
            ("tally", "count cues and calls in this project's trace", False)):
        p = sub.add_parser(verb, help=helptext)
        opts(p, argparse.SUPPRESS)   # allowed after the verb too, without clobbering the top value
        if verb == "cue":
            p.add_argument("--seen", default=None, help="this session's seen file")
        if verb == "tally":
            p.add_argument("--since", default=None, help="YYYY-MM-DD: leave out older trace days")
            p.add_argument("--notice", action="store_true",
                           help="print the trades cued and not called three sessions running")
        if many == "one":
            p.add_argument("slug")
        elif many:
            p.add_argument("slugs", nargs="+", metavar="slug")
    return top


_SEEN_MAX = 64 * 1024


def _seen(path) -> set:
    """Slugs already cued this session; a missing or odd file is an empty set."""
    if not path:
        return set()
    try:
        with open(path, "rb") as f:
            raw = f.read(_SEEN_MAX + 1)
    except OSError:
        return set()
    if len(raw) > _SEEN_MAX:
        return set()
    return {w for w in raw.decode("ascii", "replace").split("\n") if w}


def cue(home: str, project: str, prompt: str, seen_path) -> str:
    """The one line Maude says for this prompt, plus `slug<TAB>kind<TAB>name`, or "".

    Rows come only from pages re-hashed against their approval, parsed and validated
    (store.live_pages); the line is rendered from the winning page. A winner already
    cued this session says nothing, and the next-best does not step in."""
    pages = dict(store.live_pages(home, project, check_recipes=False))
    if not pages:
        return ""
    won = match.match(prompt, [match.row(s, p) for s, p in sorted(pages.items())])
    if won is None or won.slug in _seen(seen_path):
        return ""
    page = pages[won.slug]
    if page.pick_kind == "recipe" and not store.recipe_files_ok(home, page):
        return ""
    if seen_path:
        try:
            fd = os.open(seen_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                os.write(fd, (won.slug + "\n").encode("ascii"))
            finally:
                os.close(fd)
        except OSError:
            return ""                          # no seen record, no cue: never twice by accident
    return f"{render_cue(page)}\n{won.slug}\t{page.pick_kind}\t{page.pick_name}"


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _refresh(home: str, project: str) -> None:
    store.derive_live(home, project, index.build(home, project))


def _inventory(home: str, project: str):
    """This project's inventory: re-walked only when the house's signature moved."""
    sig = index.signature(home, project)
    path = index.inventory_path(home, project)
    try:
        stored = store.inventory_sig_path(home, project).read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError):
        stored = ""
    rows = index.read(path) if stored == sig else None
    if rows is None:
        rows = index.build(home, project)
        index.write(rows, path)
        store.write_signature(home, project, sig)
    return rows


def _live_line(home: str, project: str) -> str:
    """Rebuild what is on call here; one brief line, or "" when nothing is approved."""
    changed, gone = store.derive_live(home, project, _inventory(home, project))
    if not store.status(home):
        return ""
    n = len(store.live_pages(home, project))
    line = f"  Rolodex: {n} trade(s) on call"
    if changed:
        line += "; changed since approved: " + ", ".join(changed)
    if gone:
        line += "; pick gone: " + ", ".join(gone)
    return line


def _run(args, home: str, project: str) -> int:
    verb = args.verb
    if verb == "index":
        rows = index.build(home, project)
        index.write(rows, index.inventory_path(home, project))
        store.write_signature(home, project, index.signature(home, project))
        print(f"**Maude:** indexed {len(rows)} callable providers.")
    elif verb == "show":
        print(store.show(home, args.slug))
    elif verb == "approve":
        items = [tuple(a.partition("@")[::2]) for a in args.slugs]   # slug@hash, as show printed
        for line in store.approve(home, items, _now()):              # one transaction, or nothing
            print(line)
        try:                                   # on call here now, not at the next session start
            _refresh(home, project)
        except Exception as e:
            why = _one_line(e) if isinstance(e, store.StoreError) else e.__class__.__name__
            print(f"**Maude:** approved, but not yet on call in this project: {why}. "
                  "It goes on call at the next session start.", file=sys.stderr)
            return 2
    elif verb == "revoke":
        store.revoke(home, args.slugs, _now())   # off call in every project, same transaction
        print("**Maude:** revoked " + ", ".join(dict.fromkeys(args.slugs)) + ".")
    elif verb == "live":
        line = _live_line(home, project)
        if line:
            print(line)
    elif verb == "cue":
        try:
            prompt = sys.stdin.buffer.read(64 * 1024).decode("utf-8", "replace")
            out = cue(home, project, prompt, args.seen)
        except Exception:                     # the cue is quiet on any doubt
            out = ""
        if out:
            print(out)
    elif verb == "tally":
        since = args.since
        if since is not None and not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", since):
            raise store.StoreError("--since wants a date like 2026-11-10")
        trace_dir = os.path.join(project, ".maude", "plugin", "trace")
        if args.notice:
            for slug in calls.missed_streaks(trace_dir, 3, home, store.known(home)):
                print(slug)
        else:
            cued, called = calls.tally(trace_dir, since, home, store.known(home))
            print(f"cued {cued}, called {called}")
    return 0


def _one_line(err) -> str:
    return " ".join(str(err).split()) or err.__class__.__name__


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    home = args.home or os.environ.get("HOME") or ""
    project = args.project or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        if not home:
            raise store.StoreError("there is no home: set $HOME or pass --home")
        return _run(args, os.path.abspath(home), os.path.abspath(project))
    except store.StoreError as e:
        if args.verb == "cue":
            return 0
        print(f"**Maude:** {_one_line(e)}", file=sys.stderr)
        return 2
    except Exception as e:      # never a traceback, never message text (it may carry page bytes)
        if args.verb == "cue":
            return 0
        print(f"**Maude:** the Rolodex could not do that: {e.__class__.__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
