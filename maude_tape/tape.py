"""The tape — primary durable memory. Stdlib sqlite backend (the floor substrate)."""
from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from typing import Callable

_WS = re.compile(r"\s+")  # any run of Unicode whitespace -> one space (see check_draft)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS rejections (
    id      INTEGER PRIMARY KEY,
    phrase  TEXT NOT NULL,
    reason  TEXT,
    source  TEXT
);
CREATE TABLE IF NOT EXISTS canon (
    id            INTEGER PRIMARY KEY,
    topic         TEXT,
    text          TEXT NOT NULL,
    source        TEXT,
    authority     TEXT DEFAULT 'user-verbatim',
    superseded_by INTEGER              -- NULL = current truth
);
CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY,
    ts         REAL,
    topic      TEXT,
    text       TEXT NOT NULL,
    source     TEXT,
    authority  TEXT DEFAULT 'agent-inference',
    importance REAL DEFAULT 0.5,
    status     TEXT DEFAULT 'buffered'   -- buffered | consolidated | forgotten
);
"""

# Higher rank leads at recall — the user's own words always outrank a rendering of them.
_AUTHORITY_RANK = {"user-verbatim": 3, "user-paraphrase": 2, "agent-inference": 1}


@dataclass(frozen=True)
class Hit:
    """A rejected phrasing found in a draft — carries WHY, so Claude learns, not just blocks."""
    phrase: str
    reason: str
    source: str


@dataclass(frozen=True)
class Entry:
    """A canon memory — one of the user's verbatim words, or a rendering of them."""
    id: int
    topic: str
    text: str
    source: str
    authority: str
    superseded: bool


@dataclass(frozen=True)
class Event:
    """A short-term buffer item — raw work awaiting consolidation or forgetting."""
    id: int
    ts: float
    topic: str
    text: str
    source: str
    authority: str
    importance: float
    status: str


@dataclass(frozen=True)
class RestReport:
    """What one turn of the cycle did at rest — the autolearning + forget accounting."""
    consolidated: list[int]
    forgotten: list[int]


@dataclass(frozen=True)
class Brief:
    """The video played at wake — current truth, nothing cut."""
    canon_texts: list[str]
    rejection_count: int
    identity: list[str]


@dataclass(frozen=True)
class Breach:
    """Autohealing finding: a rejected phrasing loose on a real surface."""
    surface: str
    phrase: str
    reason: str
    source: str


@dataclass(frozen=True)
class CadenceFlag:
    """A voice-gate finding the phrase list can't catch: robotic CADENCE, not a fixed phrase.
    Carries WHY, like Hit — so Claude learns the tell, not just gets blocked by it."""
    tell: str
    why: str


class Tape:
    def __init__(
        self,
        db_path: str | os.PathLike,
        embedder: Callable[[str], list[float]] | None = None,
        judge: Callable[[str], list[tuple[str, str]]] | None = None,
    ):
        # embedder: text -> vector. Injected so the loop is testable and substrate-agnostic —
        # a fake in tests, a BYO embedding client in production. None = a home with no embedding
        # service wired; semantic recall degrades to empty rather than guessing.
        # judge: draft -> [(tell, why), ...]. The same seam for the voice gate's model tier —
        # a wired model reads cadence the phrase list can't see; None = no model, degrade to
        # the deterministic floor. The plugin ships neither appliance.
        self._conn = sqlite3.connect(db_path)
        self._conn.executescript(_SCHEMA)
        self._embedder = embedder
        self._judge = judge
        self._migrate()
        self._conn.commit()

    def _migrate(self) -> None:
        """Primary durable state — evolve in place, never drop (unlike the disposable vault)."""
        cols = {row[1] for row in self._conn.execute("PRAGMA table_info(canon)")}
        if "embedding" not in cols:
            self._conn.execute("ALTER TABLE canon ADD COLUMN embedding TEXT")

    def reject(self, phrase: str, *, reason: str, source: str) -> None:
        """Record a phrasing the user rejected, so it can never reach the page again."""
        self._conn.execute(
            "INSERT INTO rejections (phrase, reason, source) VALUES (?, ?, ?)",
            (phrase, reason, source),
        )
        self._conn.commit()

    @staticmethod
    def _cosine(a: list[float], b: list[float]) -> float:
        num = sum(x * y for x, y in zip(a, b))
        na = math.sqrt(sum(x * x for x in a))
        nb = math.sqrt(sum(y * y for y in b))
        return num / (na * nb) if na and nb else 0.0

    def recall_semantic(self, query: str, *, k: int = 5) -> list[Entry]:
        """Recall by MEANING: embed the query, rank current canon by cosine similarity. The
        pgvector ceiling swaps in behind this method — same signature, same result, faster at scale.
        Degrades to empty when no embedder is wired (a bare home) — never a guess."""
        if self._embedder is None:
            return []
        qv = self._embedder(query)
        scored: list[tuple[float, Entry]] = []
        for r in self._conn.execute(
            "SELECT id, topic, text, source, authority, embedding FROM canon "
            "WHERE superseded_by IS NULL AND embedding IS NOT NULL"
        ):
            score = self._cosine(qv, json.loads(r[5]))
            scored.append((score, Entry(id=r[0], topic=r[1], text=r[2],
                                        source=r[3], authority=r[4], superseded=False)))
        scored.sort(key=lambda pair: -pair[0])
        return [entry for _, entry in scored[:k]]

    def recall_keyword(self, query: str, *, k: int = 5) -> list[Entry]:
        """The recall FLOOR — find current canon by the words in the query. No embedder, no FTS
        extension: pure sqlite + stdlib, so it works on any home. This is what recall degrades TO
        when no embedder is wired — real recall, by words instead of meaning, slower at scale than
        the semantic (or future FTS) tiers that ride on top of it. Rightful degradation, never empty."""
        terms = [t for t in re.findall(r"\w+", query.lower()) if t]
        if not terms:
            return []
        scored: list[tuple[int, int, Entry]] = []
        for r in self._conn.execute(
            "SELECT id, topic, text, source, authority FROM canon WHERE superseded_by IS NULL"
        ):
            low = r[2].lower()
            score = sum(1 for t in terms if t in low)
            if score:
                scored.append((score, _AUTHORITY_RANK.get(r[4], 0),
                               Entry(id=r[0], topic=r[1], text=r[2],
                                     source=r[3], authority=r[4], superseded=False)))
        scored.sort(key=lambda s: (-s[0], -s[1], s[2].id))
        return [e for _, _, e in scored[:k]]

    def recall_relevant(self, query: str, *, k: int = 5) -> list[Entry]:
        """One door over the two recall engines — the recall a caller reaches for by default.
        Recall by MEANING when an embedder is wired and the canon is embedded; otherwise — a
        bare home, or a home that wired the embedder after canon was already written — degrade
        to keyword recall by the words in the query. Rightful degradation: the appliance changes
        the QUALITY of recall (meaning over words, faster at scale), never WHETHER recall happens.
        A home that holds the answer by word is never handed an empty result."""
        if self._embedder is not None:
            hits = self.recall_semantic(query, k=k)
            if hits:
                return hits
        return self.recall_keyword(query, k=k)

    def list_rejections(self) -> list[Hit]:
        """Every phrasing the user has rejected — the never-render list the wake brief carries."""
        return [
            Hit(phrase=p, reason=r, source=s)
            for p, r, s in self._conn.execute(
                "SELECT phrase, reason, source FROM rejections ORDER BY id"
            )
        ]

    def check_draft(self, text: str) -> list[Hit]:
        """Deterministic recall: which rejected phrasings appear in this draft, in order recorded."""
        # Whitespace-normalised on BOTH sides. A literal substring test only ever caught one
        # space shape, so a rejected phrase wrapped across a newline — or pasted carrying a
        # non-breaking space — passed with exit 0, which is how bad text actually shipped.
        # Python's \s is Unicode-aware (nbsp, em space, narrow nbsp all collapse), and this can
        # only match MORE of what the owner already rejected, never fewer.
        haystack = _WS.sub(" ", text.lower())
        hits: list[Hit] = []
        for phrase, reason, source in self._conn.execute(
            "SELECT phrase, reason, source FROM rejections ORDER BY id"
        ):
            if not phrase.strip():
                continue  # '' is a substring of everything: one empty row would block every draft
            if _WS.sub(" ", phrase.lower()).strip() in haystack:
                hits.append(Hit(phrase=phrase, reason=reason, source=source))
        return hits

    def judge_draft(self, text: str) -> list[CadenceFlag]:
        """The model tier of the voice gate: a wired judge reads the draft for robotic CADENCE
        the deterministic check_draft can't see — concede→pivot→reframe, rule-of-three, essay-bot
        connectives — because cadence is not a phrase, so no phrase list ever matches it. Degrades
        to [] when no judge is wired (a bare home); check_draft remains the deterministic floor.
        The judge is BYO like the embedder — the plugin ships none, and never guesses without one."""
        if self._judge is None:
            return []
        return [CadenceFlag(tell=tell, why=why) for tell, why in self._judge(text)]

    def remember(
        self,
        text: str,
        *,
        topic: str,
        source: str,
        authority: str = "user-verbatim",
        supersedes: int | None = None,
    ) -> int:
        """Encode a canon memory and return its id. If it corrects an older entry, that entry
        is marked superseded (kept, never deleted) — reconsolidation, not duplication."""
        cur = self._conn.execute(
            "INSERT INTO canon (topic, text, source, authority) VALUES (?, ?, ?, ?)",
            (topic, text, source, authority),
        )
        new_id = cur.lastrowid
        if self._embedder is not None:
            self._conn.execute(
                "UPDATE canon SET embedding = ? WHERE id = ?",
                (json.dumps(self._embedder(text)), new_id),
            )
        if supersedes is not None:
            self._conn.execute(
                "UPDATE canon SET superseded_by = ? WHERE id = ?", (new_id, supersedes)
            )
        self._conn.commit()
        return new_id

    def consolidate_correction(
        self, *, rejected: str, reason: str, corrected_to: str, topic: str, source: str
    ) -> int:
        """Promote a correction from the moment it happens to durable canon, one transaction:
        record the rejected phrasing, and supersede whatever the user's words are correcting."""
        self.reject(rejected, reason=reason, source=source)
        superseding = self.recall(topic)  # current entries, captured before the new insert
        new_id = self.remember(corrected_to, topic=topic, source=source)
        for entry in superseding:
            self._conn.execute(
                "UPDATE canon SET superseded_by = ? WHERE id = ?", (new_id, entry.id)
            )
        self._conn.commit()
        return new_id

    def recall(self, topic: str, *, include_superseded: bool = False) -> list[Entry]:
        """Recall the current truth for a topic, the user's own words first. History on request."""
        rows = self._conn.execute(
            "SELECT id, topic, text, source, authority, superseded_by FROM canon WHERE topic = ?",
            (topic,),
        ).fetchall()
        entries = [
            Entry(id=r[0], topic=r[1], text=r[2], source=r[3],
                  authority=r[4], superseded=r[5] is not None)
            for r in rows
        ]
        if not include_superseded:
            entries = [e for e in entries if not e.superseded]
        entries.sort(key=lambda e: (-_AUTHORITY_RANK.get(e.authority, 0), e.id))
        return entries

    # --- short-term buffer + the forget loop ------------------------------------

    def capture(
        self, text: str, *, topic: str, source: str,
        importance: float = 0.5, authority: str = "agent-inference",
    ) -> int:
        """Encode a raw event into the short-term buffer (the work of the day)."""
        cur = self._conn.execute(
            "INSERT INTO events (ts, topic, text, source, authority, importance, status) "
            "VALUES (?, ?, ?, ?, ?, ?, 'buffered')",
            (time.time(), topic, text, source, authority, importance),
        )
        self._conn.commit()
        return cur.lastrowid

    def _event(self, row) -> Event:
        return Event(id=row[0], ts=row[1], topic=row[2], text=row[3],
                     source=row[4], authority=row[5], importance=row[6], status=row[7])

    def event(self, event_id: int) -> Event:
        """Retrieve any event by id — including forgotten ones (archived, never deleted)."""
        row = self._conn.execute(
            "SELECT id, ts, topic, text, source, authority, importance, status "
            "FROM events WHERE id = ?", (event_id,)
        ).fetchone()
        return self._event(row) if row else None

    def buffered(self) -> list[Event]:
        """The live buffer: events still awaiting consolidation or forgetting."""
        rows = self._conn.execute(
            "SELECT id, ts, topic, text, source, authority, importance, status "
            "FROM events WHERE status = 'buffered' ORDER BY id"
        ).fetchall()
        return [self._event(r) for r in rows]

    def forget(self, *, min_importance: float = 0.3) -> list[int]:
        """Archive low-value buffer noise (status→forgotten). Never deletes — a memory that
        can't show what it dropped can't be trusted about what it kept."""
        rows = self._conn.execute(
            "SELECT id FROM events WHERE status = 'buffered' AND importance < ?",
            (min_importance,),
        ).fetchall()
        ids = [r[0] for r in rows]
        for eid in ids:
            self._conn.execute("UPDATE events SET status = 'forgotten' WHERE id = ?", (eid,))
        self._conn.commit()
        return ids

    # --- the grand loop: wake → work → REST → wake ------------------------------

    def rest(self, *, consolidate_at: float = 0.6, forget_below: float = 0.3) -> RestReport:
        """Close the cycle: promote the day's signal to canon (autolearning), archive the noise
        (forget). What sits between the thresholds stays buffered for another day's evidence."""
        consolidated: list[int] = []
        for e in self.buffered():
            if e.importance >= consolidate_at:
                self.remember(e.text, topic=e.topic, source=e.source, authority=e.authority)
                self._conn.execute(
                    "UPDATE events SET status = 'consolidated' WHERE id = ?", (e.id,)
                )
                consolidated.append(e.id)
        self._conn.commit()
        forgotten = self.forget(min_importance=forget_below)
        return RestReport(consolidated=consolidated, forgotten=forgotten)

    def wake(self) -> Brief:
        """Play the video: the current truth (superseded scenes excluded), the count of lines
        never to render, and who the tape knows it is."""
        canon_texts = [
            r[0] for r in self._conn.execute(
                "SELECT text FROM canon WHERE superseded_by IS NULL ORDER BY id"
            )
        ]
        (rejection_count,) = self._conn.execute("SELECT COUNT(*) FROM rejections").fetchone()
        identity = [e.text for e in self.recall("maude-identity")]
        return Brief(canon_texts=canon_texts, rejection_count=rejection_count, identity=identity)

    def audit(self, surfaces: dict[str, str]) -> list[Breach]:
        """Autohealing: reconcile the record against reality — any rejected phrasing still live
        on a real surface is a breach to flag (and heal). The loop that never ran tonight."""
        breaches: list[Breach] = []
        for surface, text in surfaces.items():
            for hit in self.check_draft(text):
                breaches.append(Breach(surface=surface, phrase=hit.phrase,
                                       reason=hit.reason, source=hit.source))
        return breaches
