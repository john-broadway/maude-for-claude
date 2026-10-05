"""Query the vault: text -> FTS5 -> ranked top-K -> formatted. Stdlib only."""
from __future__ import annotations

import os
import pathlib
import re
import sqlite3
import time

_TOKEN_RE = re.compile(r"\w{3,}")
_MAX_INPUT_CHARS = 2000
_MAX_TOKENS = 32

# Words that carry no recall signal. The proven failure mode (2026-07-14): an
# OR-of-everything query let "the"/"with"/"what" pull letters and dailies
# into every recall. Curated small on purpose — err toward keeping a word.
_STOPWORDS = frozenset("""
about after all also and any are because been before being but can cant come
could did does doing dont down each even for from get going got had has have
her here hers him his how into its just like made make many more most much
nor not now off once only other our ours out over own said same she should
some still such than that the their theirs them then there these they this
those through too under until very was wants way well were what when where
which while who whom why will with would you your yours
""".split())

# Overfetch by BM25, then re-rank in python where mtime/type can weigh in.
_OVERFETCH = 4

_SEARCH = """
SELECT f.path, f.name, f.description,
       snippet(notes_fts, 3, '[', ']', '…', 10) AS snippet,
       bm25(notes_fts) AS rank,
       n.mtime, n.type
FROM notes_fts f JOIN notes n ON n.path = f.path
WHERE notes_fts MATCH ?
ORDER BY rank
LIMIT ?
"""

# Durable rule-notes outrank ambient prose (letters/dailies carry no type).
_TYPE_WEIGHT = {"feedback": 1.4, "user": 1.4, "reference": 1.25, "project": 1.15}

# RELEVANCE, NOT ANY MATCH (2026-09-25). One OR of every token with no floor paged five
# notes on every prompt, matched on words like "fix" (in 72% of this vault's notes). Once a
# vault is big enough for word frequency to mean anything (_DF_MIN_NOTES pageable notes):
#   - ambient prose is not paged: names starting with MAUDE_PAGE_SKIP_PREFIXES (letters,
#     daily logs, archives: read at arrival, found by prefix);
#   - a query word in more than _COMMON_DF of the pageable notes is COMMON: it counts as
#     evidence only where a note's NAME carries it ("gitea" is in 41% of notes, and
#     feedback_gitea-is-canon must still answer "is gitea canon");
#   - a RARE word counts anywhere in the note;
#   - a hit needs evidence in its name or description, and at least half the query's
#     rare words (never fewer than two pieces of evidence); a lone rare word (or a one-word
#     query) must hit the name, or the head if the word is very rare (_RARE_DF); a query of
#     common words only needs a note named for every one of them;
#   - nothing clears: nothing is paged.
# EVERY judgement goes through the FTS index, so stemming and tokenizing are the index's
# own: a regex over bodies disagreed with it ("dogfooding" found by stem, then refused by
# the regex; "liveness" counted as "live"), and cost most of a second on a long paste.
_DF_MIN_NOTES = 100
_COMMON_DF = 0.30
_RARE_DF = 0.05
_SKIP_DEFAULT = "letter-from-,today-,archive_"
# Words of the imperative, not of any topic: "run the tests AGAIN", "TRY it with the other
# ONE", "TELL me". Their frequency sits among real topic words ("again" 16%, "try" 10%, as
# "customer" 10%), so no threshold separates them; they carry no subject. Big vaults only.
_INSTRUCTION_WORDS = frozenset("""
again try tell one please okay yes yeah keep going next looks look good sure thanks
let lets also want need
""".split())


def _skip_prefixes() -> tuple[str, ...]:
    return tuple(p for p in os.environ.get("MAUDE_PAGE_SKIP_PREFIXES", _SKIP_DEFAULT).split(",")
                 if p)


def _pageable_sql(skip: tuple[str, ...]) -> tuple[str, list[str]]:
    """SQL (on notes n) that is true for a note the pager may serve; filtered BEFORE any
    LIMIT, so skipped notes never crowd live ones out of the window."""
    if not skip:
        return "1", []
    return " AND ".join("substr(n.name, 1, ?) != ?" for _ in skip), [
        v for p in skip for v in (len(p), p)]


def _phrase(t: str) -> str:
    return '"' + t.replace('"', "") + '"'


def _goodness(rank: float, mtime: float | None, note_type: str | None,
              now: float) -> float:
    """Bigger = better. bm25() is smaller-is-better, so flip its sign, then
    boost durable types and decay with age (penalty doubles at ~3 months)."""
    age_days = max(0.0, (now - (mtime or 0.0)) / 86400.0)
    recency_penalty = 1.0 + age_days / 90.0
    return (-rank) * _TYPE_WEIGHT.get(note_type or "", 1.0) / recency_penalty


def fts_query(text: str) -> str | None:
    # Bound both the input (a huge paste shouldn't be re-scanned in full —
    # this hook fires on EVERY prompt) and the token count, and dedupe with
    # dict.fromkeys instead of an `in`-list scan (that was O(n^2)).
    bounded = text[:_MAX_INPUT_CHARS]
    tokens = [
        t for t in dict.fromkeys(_TOKEN_RE.findall(bounded.lower()))
        if t not in _STOPWORDS
    ][:_MAX_TOKENS]
    if not tokens:
        return None
    return " OR ".join(f'"{t}"' for t in tokens)


def _relevant(conn: sqlite3.Connection, query: str, where: str, args: list,
              pageable: int) -> list:
    """The big-vault path: candidate rows that clear the relevance rules above."""
    tokens = [t for t in dict.fromkeys(_TOKEN_RE.findall(query[:_MAX_INPUT_CHARS].lower()))
              if t not in _STOPWORDS and t not in _INSTRUCTION_WORDS][:_MAX_TOKENS]

    def paths(match: str) -> set[str]:
        return {r[0] for r in conn.execute(
            f"SELECT f.path FROM notes_fts f JOIN notes n ON n.path = f.path "
            f"WHERE notes_fts MATCH ? AND {where}", [match, *args])}

    anywhere, in_name, in_head = {}, {}, {}
    for t in tokens:
        anywhere[t] = paths(_phrase(t))
        if not anywhere[t]:
            continue
        in_name[t] = paths("{name} : " + _phrase(t))
        in_head[t] = paths("{name description} : " + _phrase(t))
    live = [t for t in tokens if anywhere[t]]
    if not live:
        return []
    df = {t: len(anywhere[t]) / pageable for t in live}
    rare = [t for t in live if df[t] <= _COMMON_DF]

    def evidence(p: str) -> set[str]:
        return {t for t in live if p in (anywhere[t] if df[t] <= _COMMON_DF else in_name[t])}

    # One rare word left (the rest common): it is the question's subject, and must stand
    # where the note says what it is. A lone COMMON word pages nothing: "fix it" paged five
    # notes named for "fix" (in 63% of notes), the very noise this floor exists to cut.
    lone = rare[0] if len(rare) == 1 else None
    very_rare = [t for t in rare if df[t] <= _RARE_DF]
    rarest = min(df.values())
    accepted = set()
    for p in set().union(*(anywhere[t] if df[t] <= _COMMON_DF else in_name[t] for t in live)):
        ev = evidence(p)
        if rare:
            # At least one RARE word among the evidence: common words in a name must not
            # stand in for the question's subject ("fix the recall noise" paged a note named
            # "...fixed..." whose body said "noise", lens round 2).
            ok = (any(t in ev for t in rare) and any(p in in_head[t] for t in ev)
                  and len(ev) >= max(2, -(-len(rare) // 2)))
        else:
            # Only common words: an instruction ("run the tests again"), not a question about
            # a note, unless a note is NAMED for every one of them.
            ok = len(live) >= 2 and all(p in in_name[t] for t in live)
        if not ok and lone is not None:
            ok = p in in_name[lone] or (df[lone] <= _RARE_DF and p in in_head[lone])
        if not ok:
            # A very rare word in the NAME is the subject by itself, whatever else is asked:
            # "gaslighting after a demo" found nothing when "demo" (8%) was not in the note.
            # Only the question's RAREST word may stand alone, though: note names here are
            # sentences, so "the coffee maker doesnt turn on" paged "john-doesnt-do-git" on
            # a filler word while "coffee", rarer and absent from it, was the subject
            # (lens round 3).
            ok = any(p in in_name[t] for t in very_rare if df[t] <= rarest)
        if ok:
            accepted.add(p)
    if not accepted:
        return []
    # Rank exactly the accepted notes: a LIMIT window over the whole OR dropped a short note
    # that three common words' matches outranked (feedback_gitea-is-canon, live).
    match = " OR ".join(_phrase(t) for t in live)
    acc = sorted(accepted)
    return conn.execute(
        _SEARCH.replace("WHERE notes_fts MATCH ?",
                        f"WHERE notes_fts MATCH ? AND f.path IN ({','.join('?' * len(acc))})"),
        [match, *acc, len(acc)]).fetchall()


def page(db_path: str | os.PathLike, query: str, k: int = 5,
         now: float | None = None,
         mem_dir: str | os.PathLike | None = None,
         exclude: frozenset[str] | set[str] = frozenset()) -> list[dict]:
    """Hits for a query. With mem_dir, each hit is checked against the file on disk and
    marked stale when the file is newer than its index row: the mirror is rebuilt at
    SessionStart only, and served a body 849 s behind the file with no signal until then
    (the memory lens, 2026-09-06). A missing file is stale too: it cannot be current."""
    if not pathlib.Path(db_path).exists():
        return []
    match = fts_query(query)
    if match is None:
        return []
    if now is None:
        now = time.time()
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        skip = _skip_prefixes()
        where, args = _pageable_sql(skip)
        # Superseded notes are kept in `notes` but never enter FTS; a join without MATCH reads
        # the content table, so they are excluded here by their column (lens round 2).
        pageable = conn.execute(
            f"SELECT count(*) FROM notes n WHERE n.superseded = '' AND {where}",
            args).fetchone()[0]
        if pageable < _DF_MIN_NOTES:
            # A small vault ranks exactly as it always did: frequency means nothing there
            # (a word in 2 of 2 notes is "in 100%"), and there is little noise to cut.
            # Notes this session was shown are dropped AFTER this window, so the window
            # widens by their count, or recall fell silent with notes left (lens, 2026-10-04).
            rows = conn.execute(_SEARCH, (match, k * _OVERFETCH + len(exclude))).fetchall()
        else:
            rows = _relevant(conn, query, where, args, pageable)
        conn.close()
    except sqlite3.Error:
        return []
    ranked = sorted(rows, key=lambda r: _goodness(r[4], r[5], r[6], now),
                    reverse=True)
    # A note already shown this session is not shown again, and the next one takes its
    # place (2026-10-04: three notes repeated on nearly every prompt of a 17h session).
    ranked = [r for r in ranked if r[1] not in exclude]
    hits = []
    for r in ranked[:k]:
        hit = {"path": r[0], "name": r[1], "description": r[2], "snippet": r[3]}
        if mem_dir is not None:
            try:
                on_disk = os.stat(os.path.join(os.fspath(mem_dir), r[0])).st_mtime
                hit["stale"] = on_disk > (r[5] or 0.0) + 1e-6
            except OSError:
                # Gone since the build: stale, and said in its own word. A "changed"
                # label sent the person to a file that was not there (MINOR-6).
                hit["stale"] = True
                hit["missing"] = True
        hits.append(hit)
    return hits


_DESC_MAX = 140


def _clean(text: str | None, cap: int) -> str:
    """Collapse all whitespace runs (incl. newlines) to single spaces and
    cap length, so embedded content (e.g. a note containing "[SYSTEM]: ..."
    lines) can never break out of its bullet/indent and masquerade as a
    top-level directive."""
    flat = " ".join((text or "").split())
    if len(flat) > cap:
        flat = flat[:cap] + "…"
    return flat


_SNIPPET_MAX = 300


def format_hits(hits: list[dict], snippets: bool = False) -> str:
    # One line per note: its name and what it is. The FTS snippet line, with its [bracketed]
    # match marks, read as noise to John (2026-10-04) and the name is the pointer anyway. The
    # eye, which reads the notes rather than a person, asks for its snippets back.
    if not hits:
        return ""
    lines = ["Maude — from the vault:"]
    for h in hits:
        description = _clean(h["description"], _DESC_MAX)
        if h.get("missing"):
            stale = " (deleted since the index was built)"
        elif h.get("stale"):
            stale = " (changed since the index was built)"
        else:
            stale = ""
        lines.append(f"- [[{h['name']}]]{stale} — {description}")
        if snippets and h.get("snippet"):
            lines.append(f"    {_clean(h['snippet'], _SNIPPET_MAX)}")
    return "\n".join(lines)
