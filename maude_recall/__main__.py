"""CLI: python3 -m maude_recall {build,recall}.

build  — sync the sources' words (the vault and its cards, the tape, and with --attic DIR the
         past sessions' transcripts: maude_recall/attic.py), learn her word table when they
         changed, then embed what is new or changed (cards first) on the house's embedder
         (the probe's record in care.json) until --budget seconds. One build at a time: a
         second finds the lock held and exits 0 at once. Started detached at session start.
recall — the best hits for a query, one JSON object per line, each naming its rung.
replay — the replay set (maude_recall/replay.py) through recall(): one line per question with
         the note rank of its target, then the totals. Fair by default: each question on the
         store as it was before the day he asked it (--whole scores on everything, hindsight
         included). Exit 2 on a broken or empty set.
Silent and exit 0 on a missing source; loud only on a real error.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import sqlite3
import sys

from maude_recall import sources
from maude_recall.store import Store
from maude_tape.embedder import EmbedError


def _embedder(care: str | None) -> dict | None:
    try:
        with open(care, encoding="utf-8") as fh:
            e = json.load(fh).get("embedder")
    except (OSError, ValueError, TypeError, AttributeError):
        return None
    if isinstance(e, dict) and isinstance(e.get("url"), str) and isinstance(e.get("dim"), int):
        return {"url": e["url"], "model": str(e.get("model") or "embedding"), "dim": e["dim"]}
    return None


@contextlib.contextmanager
def build_lock(db: str | os.PathLike):
    """Yields True when this process holds the build lock, False when another does."""
    path = os.fspath(db) + ".build.lock"
    try:
        import fcntl
    except ImportError:  # no fcntl (Windows): one build at a time by O_EXCL
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            yield False
            return
        try:
            yield True
        finally:
            os.close(fd)
            os.unlink(path)
        return
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="maude_recall")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--db", required=True)
    b.add_argument("--vault-db")
    b.add_argument("--tape-db")
    b.add_argument("--attic")
    b.add_argument("--care")
    b.add_argument("--budget", type=float, default=600.0)
    r = sub.add_parser("recall")
    r.add_argument("--db", required=True)
    r.add_argument("--care")
    r.add_argument("--k", type=int, default=5)
    r.add_argument("--ns")
    r.add_argument("query")
    p = sub.add_parser("replay")
    p.add_argument("--db", required=True)
    p.add_argument("--set", required=True)
    p.add_argument("--tape-db")
    p.add_argument("--care")
    p.add_argument("--window", type=int, default=200)
    p.add_argument("--whole", action="store_true")
    p.add_argument("--vault-git")
    p.add_argument("--embed-budget", type=float, default=120.0, help="seconds a cut may spend embedding its cards")
    args = ap.parse_args(argv)

    if args.cmd == "replay":
        from maude_recall import replay
        if not os.path.exists(args.db):
            print(f"maude_recall: no store at {args.db}; build it first", file=sys.stderr)
            return 2
        try:
            rows = replay.load(args.set, args.tape_db)
            if args.whole:
                store = Store(args.db)
                try:
                    results = replay.run(store, rows, emb=_embedder(args.care), window=args.window)
                finally:
                    store.close()
            else:
                results = replay.run_fair(args.db, rows, emb=_embedder(args.care), window=args.window,
                                          vault_git=args.vault_git, embed_budget=args.embed_budget)
        except (replay.ReplayError, OSError, sqlite3.Error) as exc:
            print(f"maude_recall: replay: {exc}", file=sys.stderr)
            return 2
        try:
            totals = replay.summary(results)
        except replay.ReplayError as exc:
            print(f"maude_recall: replay: {exc}", file=sys.stderr)
            return 2
        for r in results:
            print(json.dumps({"rank": r.rank, "rung": r.rung, "unanswerable": r.unanswerable,
                              "held": list(r.held),
                              "cut": r.cut, "target": list(r.row.target),
                              "why": r.row.why, "top": list(r.top),
                              "question": r.row.query[:120]}, ensure_ascii=False))
        print(json.dumps(totals))
        return 0

    if args.cmd == "build":
        with build_lock(args.db) as mine:
            if not mine:
                return 0
            store = Store(args.db)
            if args.vault_db:
                store.sync("vault", sources.vault_items(args.vault_db))
                store.sync("card", sources.vault_cards(args.vault_db))
            if args.tape_db:
                store.sync("tape", sources.tape_items(args.tape_db))
            if args.attic:
                from maude_recall import attic
                for ns, rows in attic.items(args.attic).items():
                    store.sync(ns, rows)
            store.learn_table()
            store.sweep_vectors()
            emb = _embedder(args.care)
            if emb:
                try:
                    store.embed_pending(emb, budget=args.budget)
                except EmbedError as exc:
                    print(f"maude_recall: embedding stopped: {exc}", file=sys.stderr)
            store.close()
        return 0

    if not os.path.exists(args.db):
        return 0
    store = Store(args.db)
    for h in store.recall(args.query, args.k, ns=args.ns, emb=_embedder(args.care)):
        print(json.dumps({"ns": h.ns, "key": h.key, "rung": h.rung, "rungs": list(h.rungs), "score": h.score,
                          "text": h.text[:300]}, ensure_ascii=False))
    store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
