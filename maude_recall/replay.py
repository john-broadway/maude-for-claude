"""The replay set: his real questions, the note that should have come up, scored by rank.

Design B5 (docs/specs/2026-10-24-seeing-gap-design.md). No change to recall lands without
moving this set. The set holds his verbatim words and his private note names, so it lives in
the locked house (`.maude/plugin/replay/recall.jsonl`), never in this repo.

One JSON object per line:
  {"sha": "<tape voice sha>", "target": ["<note path>", ...], "why": "<one line>"}
`sha` reads his line from the tape, so it is never retyped (a cleaned-up spelling would test
a question he never asked). A test fixture may give `"text"` instead. `target` is every note
that answers the question; the row's rank is the best of them.

Scored by NOTE, not chunk: the store keys vault items `path#i`, and several chunks of one
note would otherwise fill the top slots. A target the store does not hold, a sha the tape
does not hold, or an empty set is a broken set, never an honest miss: it raises.

Fair by default (`run_fair`): each row is scored on a copy of the store holding only items
dated before the UTC day he asked it, with her table relearned on that cut. Learning on the
record of the very conversation being replayed is hindsight: on 2026-10-30 it turned ranks
of 132 into 12 and 7. What "dated" means is the source's: a tape line and an attic turn
carry when they were said; a vault note carries its file's LAST CHANGE (mtime). So an old
note edited after he asked is dropped whole, and a note kept on the cut still holds its
current text. "Unanswerable" therefore means "the target note's last change is on or after
the cut", not "written after he spoke": reported as such and left out of the totals, never
counted a miss. Items with no date (ts 0) count as always there. A set where every row is
unanswerable is a broken set (exit 2), as an empty one is.

With `vault_git` (the memory dir is a git repository), the vault at each cut is rebuilt
from the last commit before it instead: the notes as they stood then, so a note later edited
to quote his line is scored on its earlier text, and "unanswerable" means the note was not
in the house yet by git (git's birth date can only be later than the true one: harder,
never easier). No commit before the cut makes that day's rows unanswerable.

The copies live in a `.replay-*` directory beside the store, inside the locked house (never
/tmp), owner-only; a run killed mid-copy leaves one behind there, and the next run removes
any it finds. Each distinct day costs one full copy and one relearn (~1 min on the real
house), with a progress line on stderr.
"""
from __future__ import annotations

import datetime
import glob
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass

from maude_recall.store import Store, _model_key
from maude_tape.embedder import EmbedError


class ReplayError(ValueError):
    pass


@dataclass(frozen=True)
class Row:
    query: str
    target: tuple[str, ...]
    why: str
    asked: float | None = None  # when he typed it (UTC epoch): from the tape, or the row's "asked"
    kind: str = ""  # optional label (lesson, record, context, ...): the totals are also given per kind


@dataclass(frozen=True)
class Result:
    row: Row
    rank: int | None  # 1-based note rank of the best target; None = not in the window
    rung: str | None  # the rung that found that target
    top: tuple[str, ...]  # the first notes that came up, for the reader
    cut: float | None = None  # the fair cut it was scored on; None = the whole store
    unanswerable: bool = False  # no target's last change is before the cut
    held: tuple[str, ...] = ()  # the targets the cut still holds (fair runs only)


def load(set_path: str | os.PathLike, tape_db: str | os.PathLike | None = None) -> list[Row]:
    rows = []
    tape = sqlite3.connect(f"file:{os.fspath(tape_db)}?mode=ro", uri=True) if tape_db else None
    try:
        with open(set_path, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except ValueError as exc:
                    raise ReplayError(f"line {n}: not JSON ({exc})") from None
                target = obj.get("target")
                if isinstance(target, str):
                    target = [target]
                if not target or not all(isinstance(t, str) and t for t in target):
                    raise ReplayError(f"line {n}: no target")
                if obj.get("sha"):
                    if tape is None:
                        raise ReplayError(f"line {n}: a sha needs --tape-db")
                    got = tape.execute("SELECT text, ts FROM voice WHERE sha = ?", (obj["sha"],)).fetchone()
                    if not got:
                        raise ReplayError(f"line {n}: sha {obj['sha'][:12]} is not on the tape")
                    try:
                        flag = tape.execute("SELECT flag FROM voice_flags WHERE sha = ?", (obj["sha"],)).fetchone()
                    except sqlite3.OperationalError:
                        flag = None  # a tape from before the flags
                    if flag:
                        raise ReplayError(f"line {n}: sha {obj['sha'][:12]} is flagged {flag[0]}: not his line")
                    query, asked = got[0], got[1]
                elif isinstance(obj.get("text"), str):
                    query, asked = obj["text"], obj.get("asked")
                else:
                    raise ReplayError(f"line {n}: neither sha nor text")
                if not query.strip():
                    raise ReplayError(f"line {n}: blank question")
                if asked is not None and (isinstance(asked, bool) or not isinstance(asked, (int, float))):
                    raise ReplayError(f"line {n}: asked must be a UTC epoch number")
                rows.append(Row(query, tuple(target), str(obj.get("why") or ""),
                                float(asked) if asked is not None else None, str(obj.get("kind") or "")))
    finally:
        if tape is not None:
            tape.close()
    if not rows:
        raise ReplayError("the replay set is empty; zero misses on nothing proves nothing")
    return rows


def _notes(store: Store, ns: str) -> set[str]:
    return {key.split("#", 1)[0] for (key,) in store._db.execute("SELECT key FROM items WHERE ns = ?", (ns,))}


def run(store: Store, rows: list[Row], *, emb: dict | None = None, ns: str = "vault",
        window: int = 200, top: int = 3) -> list[Result]:
    held = _notes(store, ns)
    for row in rows:
        missing = [t for t in row.target if t not in held]
        if missing:
            raise ReplayError(f"target not in the store: {', '.join(missing)}")
    out = []
    for row in rows:
        order: list[str] = []
        rung_of: dict[str, str] = {}
        for h in store.recall(row.query, window, ns=ns, emb=emb):
            path = h.key.split("#", 1)[0]
            if path not in rung_of:
                rung_of[path] = h.rung
                order.append(path)
        ranks = [order.index(t) + 1 for t in row.target if t in rung_of]
        best = min(ranks) if ranks else None
        rung = rung_of[order[best - 1]] if best else None
        out.append(Result(row, best, rung, tuple(order[:top])))
    return out


def _day(ts: float) -> float:
    return ts - ts % 86400


def _vault_at(mem_git: str | os.PathLike, cut: float, tmp: str) -> tuple[list, list] | None:
    """The vault's (items, cards) as the memory repo held them at the last commit before
    `cut`, or None when there is no such commit."""
    from maude_recall import sources
    from maude_vault import ingest
    when = datetime.datetime.fromtimestamp(cut, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rev = subprocess.run(["git", "-C", os.fspath(mem_git), "rev-list", "-n1", f"--before={when}", "HEAD"],
                         capture_output=True, text=True)
    if rev.returncode != 0:
        raise ReplayError(f"not a git repository: {mem_git}")
    commit = rev.stdout.strip()
    if not commit:
        return None
    tar = subprocess.run(["git", "-C", os.fspath(mem_git), "archive", commit], capture_output=True)
    if tar.returncode != 0:
        raise ReplayError(f"git archive failed at {commit[:12]}")
    mem = os.path.join(tmp, "mem")
    os.makedirs(mem, mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(tar.stdout)) as tf:
        members = [m for m in tf.getmembers() if m.isfile() and not m.name.startswith("/") and ".." not in m.name.split("/")]
        if hasattr(tarfile, "data_filter"):  # 3.12+ (and backports): refuse links and odd paths
            tf.extractall(mem, members=members, filter="data")
        else:
            tf.extractall(mem, members=members)
    vdb = os.path.join(tmp, "vault.db")
    os.close(os.open(vdb, os.O_CREAT | os.O_WRONLY, 0o600))
    ingest.build(mem, vdb)
    items, cards = sources.vault_items(vdb), sources.vault_cards(vdb)
    for root, dirs, files in os.walk(mem):
        for f in files:
            os.chmod(os.path.join(root, f), 0o600)
    return items, cards


def run_fair(db_path: str | os.PathLike, rows: list[Row], *, emb: dict | None = None,
             ns: str = "vault", window: int = 200, top: int = 3,
             vault_git: str | os.PathLike | None = None, embed_budget: float = 120.0) -> list[Result]:
    """Each row on a copy of the store cut before the UTC day he asked it, her table
    relearned there and, with an embedder, the cut's cards embedded there (up to
    `embed_budget` seconds a cut; a card whose text differs from today's has no vector
    otherwise, and the card rung would score a partial vault). The vectors so made are kept
    in `<store>.vcache` beside the store, owner-only, so the next cut and the next run pay
    only for what is new. One copy per distinct day, made and removed in turn."""
    for i, row in enumerate(rows, 1):
        if row.asked is None:
            raise ReplayError(f"row {i}: a fair replay needs when he asked it (a sha, or \"asked\")")
    if not os.path.isfile(db_path):
        raise ReplayError(f"no store at {db_path}")
    src = sqlite3.connect(f"file:{os.fspath(db_path)}?mode=ro", uri=True)  # never Store(): it writes schema
    try:
        held = {k.split("#", 1)[0] for (k,) in src.execute("SELECT key FROM items WHERE ns = ?", (ns,))}
    finally:
        src.close()
    for row in rows:
        missing = [t for t in row.target if t not in held]
        if missing:
            raise ReplayError(f"target not in the store: {', '.join(missing)}")
    house = os.path.dirname(os.path.abspath(db_path))
    for stale in glob.glob(os.path.join(house, ".replay-*")):  # left by a killed run
        shutil.rmtree(stale, ignore_errors=True)
    out: dict[int, Result] = {}
    days = sorted({_day(r.asked) for r in rows})
    for n, cut in enumerate(days, 1):
        print(f"maude_recall: replay: cut {n} of {len(days)}", file=sys.stderr)
        with tempfile.TemporaryDirectory(prefix=".replay-", dir=house) as tmp:
            os.chmod(tmp, 0o700)
            path = os.path.join(tmp, "cut.db")
            os.close(os.open(path, os.O_CREAT | os.O_WRONLY, 0o600))  # owner-only before a byte lands
            src = sqlite3.connect(f"file:{os.fspath(db_path)}?mode=ro", uri=True)
            dst = sqlite3.connect(path)
            src.backup(dst)
            src.close()
            dst.close()
            with _closing(Store(path)) as st:
                if vault_git is not None:
                    then = _vault_at(vault_git, cut, tmp)
                    st.sync("vault", then[0] if then else [])
                    st.sync("card", then[1] if then else [])
                late = st._db.execute("SELECT ns, key FROM items WHERE ts >= ?", (cut,)).fetchall()
                for ins, key in late:
                    st._drop(ins, key)
                st._db.commit()
                if st._meta("table"):
                    st.learn_table()  # relearn on the cut: never a table that saw the answer
                if emb is not None:
                    # fail closed: a cut scored on a partial card vault is the artifact this step
                    # removes, so a down embedder or a budget that ran out ends the run (lens, 11-02)
                    try:
                        st.embed_pending(emb, budget=embed_budget, ns="card", cache=f"{os.fspath(db_path)}.vcache")
                    except EmbedError as exc:
                        raise ReplayError(f"cut {n}: the embedder failed ({exc}); no number from a partial card vault") from None
                    left = st.pending(emb, "card")
                    if left:
                        raise ReplayError(f"cut {n}: {left} cards still unembedded after {embed_budget:g} s; raise --embed-budget")
                    chunks = st._db.execute("SELECT count(*) FROM items i JOIN vectors v ON v.hash = i.hash "
                                            "WHERE v.model = ? AND i.ns = ?", (_model_key(emb), ns)).fetchone()[0]
                    print(f"maude_recall: replay: cut {n}: every card embedded; {chunks} {ns} chunks carry a vector "
                          f"(the semantic rung sees those alone)", file=sys.stderr)
                have = _notes(st, ns)
                for i, row in enumerate(rows):
                    if _day(row.asked) != cut:
                        continue
                    kept = tuple(t for t in row.target if t in have)
                    if not kept:
                        out[i] = Result(row, None, None, (), cut, True)
                        continue
                    r = run(st, [Row(row.query, kept, row.why, row.asked, row.kind)],
                            emb=emb, ns=ns, window=window, top=top)[0]
                    out[i] = Result(row, r.rank, r.rung, r.top, cut, False, kept)
    return [out[i] for i in range(len(rows))]


class _closing:
    def __init__(self, store):
        self.store = store

    def __enter__(self):
        return self.store

    def __exit__(self, *exc):
        self.store.close()


def summary(results: list[Result]) -> dict:
    unanswerable = sum(1 for r in results if r.unanswerable)
    scored = [r for r in results if not r.unanswerable]
    if not scored:
        raise ReplayError(f"every row is unanswerable ({unanswerable}); zero misses on nothing proves nothing")
    out = {"unanswerable": unanswerable, **_totals(scored)}
    kinds = sorted({r.row.kind for r in results if r.row.kind})
    if kinds:
        out["by_kind"] = {k: {"unanswerable": sum(1 for r in results if r.row.kind == k and r.unanswerable),
                              **(_totals([r for r in scored if r.row.kind == k])
                                 if any(r.row.kind == k for r in scored) else {"rows": 0})}
                          for k in kinds}
    return {"rows": out.pop("rows"), **out}


def _totals(results: list[Result]) -> dict:
    n = len(results)
    return {
        "rows": n,
        "at1": sum(1 for r in results if r.rank == 1),
        "at5": sum(1 for r in results if r.rank and r.rank <= 5),
        "missed": sum(1 for r in results if r.rank is None),
        "mrr": round(sum(1.0 / r.rank for r in results if r.rank) / n, 4),
    }
