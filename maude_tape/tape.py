"""The tape — primary durable memory. Stdlib sqlite backend (the floor substrate)."""
from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import time
from dataclasses import dataclass, field
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
CREATE TABLE IF NOT EXISTS voice (
    id       INTEGER PRIMARY KEY,
    ts       REAL,
    text     TEXT NOT NULL,
    source   TEXT,
    register TEXT DEFAULT 'chat',
    session  TEXT,
    sha      TEXT UNIQUE                 -- sha256(normalized text|original ts): resumed
);                                       -- sessions copy history, so dupes collapse here
CREATE TABLE IF NOT EXISTS voice_profile (
    id   INTEGER PRIMARY KEY CHECK (id = 1),   -- one row: derived, regenerable, never
    ts   REAL,                                 -- hand-edited; recompute owns it whole
    json TEXT NOT NULL
);
"""

# Higher rank leads at recall — the user's own words always outrank a rendering of them.
_AUTHORITY_RANK = {"user-verbatim": 3, "user-paraphrase": 2, "agent-inference": 1}


def looks_secretish(text: str) -> bool:
    """One credential guard for every write into this file's two stores. Imported lazily so
    the wake/check hot paths never pay for compiling the pattern table."""
    from .voice import looks_secretish as _impl
    return _impl(text)


def _refuse_secrets(where: str, **fields) -> None:
    """Refuse a credential shape in ANY of a store row's string fields.

    Not "the text field". Every field. `check` prints a rejection's SOURCE verbatim and
    `pending` prints an event's TOPIC verbatim, so a credential parked in a label replays
    exactly like one parked in the body. Three review rounds running, the guard was written
    as a hand-picked list of fields and a different one was missed each time; the fix is to
    stop picking. Callers pass everything they are about to store.
    """
    for name, value in fields.items():
        if isinstance(value, str) and looks_secretish(value):
            raise ValueError(
                f"refusing to {where}: the {name} carries a credential shape. This is "
                "replayed back verbatim later — name the shape, not the value."
            )


def _score(importance) -> float | None:
    """The importance as a number we can compare, or None if it isn't one.

    SQLite silently stores a NaN REAL as NULL, so a row can come back holding something no
    threshold can be tested against. Every comparison site reads through here and treats
    None as 'unscoreable' — which routes to his eyes, never to canon and never to the bin.
    One such row used to raise TypeError inside rest() and pending() on every later call,
    for the whole tape, with the SessionEnd hook swallowing the traceback.
    """
    try:
        value = float(importance)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


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
    # Rows the canon door refused for a reason the consolidate predicate did not predict.
    # Empty in every ordinary cycle; never silently dropped when it is not.
    refused: list[int] = field(default_factory=list)


@dataclass(frozen=True)
class Brief:
    """The video played at wake — current truth, nothing cut."""
    canon_texts: list[str]
    rejection_count: int
    identity: list[str]
    # (text, authority) for the same rows as canon_texts, in the same order. The plain
    # list stayed for existing callers; the replay surface needs the authority, because
    # printing an inference he approved under "HIS WORDS" hands his voice to Claude's
    # wording — the exact thing this whole gate exists to prevent, one inch further on.
    canon_entries: list[tuple[str, str]] = field(default_factory=list)


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
        busy_timeout: float = 5.0,
    ):
        # embedder: text -> vector. Injected so the loop is testable and substrate-agnostic —
        # a fake in tests, a BYO embedding client in production. None = a home with no embedding
        # service wired; semantic recall degrades to empty rather than guessing.
        # judge: draft -> [(tell, why), ...]. The same seam for the voice gate's model tier —
        # a wired model reads cadence the phrase list can't see; None = no model, degrade to
        # the deterministic floor. The plugin ships neither appliance.
        # busy_timeout: how long sqlite waits on a locked db (connect AND statements).
        # The 5.0 default suits gates, which may honestly wait; an OBSERVER passes a
        # short one — voice-capture's "never block a prompt" is a promise about the
        # CLOCK as much as the exit code (fix-review finding on ce6ae91: a locked db
        # stalled the hook 5s before failing open).
        self._conn = sqlite3.connect(db_path, timeout=busy_timeout)
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
        """Record a phrasing the user rejected, so it can never reach the page again.

        Refuses a credential shape in EITHER field. This is the third store, and the one
        left out of the 2026-08-16 review brief — so four reviewers checked canon, voice
        and events and none checked here. wake() prints both phrase and reason verbatim at
        every wake, which makes an unguarded rejection the loudest leak of the four.
        """
        _refuse_secrets("reject", phrase=phrase, reason=reason, source=source)
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
        is marked superseded (kept, never deleted) — reconsolidation, not duplication.

        Refuses a credential shape, like capture() and the voice path. This is the LAST
        checkpoint before canon and the one that matters most: canon replays into context at
        every wake, so a token that lands here is re-read forever. Every write to canon comes
        through this method, which is why the check lives here and not at each caller.
        """
        _refuse_secrets("remember", text=text, topic=topic, source=source,
                        authority=authority)
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
        """Encode a raw event into the short-term buffer (the work of the day).

        Refuses a credential shape at ingest, the same way the voice path has since v0.28.0.
        This store is the more dangerous of the two: canon plays at every wake and `pending`
        prints the text back, so a captured error line carrying a token would replay it into
        context forever. Loud, not silent — capture is a deliberate act, so the caller can
        reword and try again (voice-capture stays an observer and must never block a prompt).
        """
        _refuse_secrets("capture", text=text, topic=topic, source=source,
                        authority=authority)
        if _score(importance) is None:
            raise ValueError(
                f"refusing to capture: importance {importance!r} is not a finite number. "
                "A stored NaN comes back as NULL and blinds the whole buffer."
            )
        if not 0.0 <= float(importance) <= 1.0:
            raise ValueError(
                f"refusing to capture: importance {importance!r} is outside 0..1. "
                "The thresholds live in that range; a score beyond it means nothing."
            )
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

    _SQLITE_MAX_INT = 2 ** 63 - 1
    _SQLITE_MIN_INT = -(2 ** 63)

    def event(self, event_id: int) -> Event:
        """Retrieve any event by id — including forgotten ones (archived, never deleted).

        An id outside SQLite's signed-64-bit range is simply absent, not an error: Python
        ints are unbounded and the C binding raises OverflowError, which is not a ValueError
        and so escaped the CLI's handler as a bare traceback on exit 1.
        """
        if not isinstance(event_id, int) or not (
            self._SQLITE_MIN_INT <= event_id <= self._SQLITE_MAX_INT
        ):
            return None
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

    def refused(self) -> list[Event]:
        """Rows the canon door turned away during a rest cycle. They are not buffered any
        more (nothing will retry them) and they are not archived (nobody chose that), so
        they belong on his list until he does something about them."""
        rows = self._conn.execute(
            "SELECT id, ts, topic, text, source, authority, importance, status "
            "FROM events WHERE status = 'refused' ORDER BY id"
        ).fetchall()
        return [self._event(r) for r in rows]

    def forget(self, *, min_importance: float = 0.3) -> list[int]:
        """Archive low-value buffer noise (status→forgotten). Never deletes — a memory that
        can't show what it dropped can't be trusted about what it kept.

        Archives only what the AGENT produced. His own words are never binned on a score the
        agent gave them: under-scoring something he actually said used to move it to
        'forgotten', where no command lists it and only its raw id could find it again. Those
        stay buffered and show up in pending() instead — his to keep or reject, not ours.
        """
        ids = [
            e.id for e in self.buffered()
            if not self._is_users_own(e.authority)
            and (score := _score(e.importance)) is not None
            and score < min_importance
        ]
        for eid in ids:
            self._conn.execute("UPDATE events SET status = 'forgotten' WHERE id = ?", (eid,))
        self._conn.commit()
        return ids

    # --- the grand loop: wake → work → REST → wake ------------------------------

    @staticmethod
    def _is_users_own(authority: str) -> bool:
        """True only for words the user actually said. Anything the agent merely inferred —
        or any authority we don't recognise — needs his word before it becomes canon."""
        return _AUTHORITY_RANK.get(authority, 0) > _AUTHORITY_RANK["agent-inference"]

    def _auto_consolidates(self, e: Event, consolidate_at: float) -> bool:
        """Will rest() move this buffered row into canon by itself?

        ONE predicate, read by both rest() and pending(), because the two must never
        disagree about a row: anything rest() will not take has to appear on the list he is
        shown. They used to answer separately, and a row the canon door refused stayed
        buffered while pending() still counted it as consolidatable — visible to nothing.
        """
        if not self._is_users_own(e.authority):
            return False                       # his choice, not mine
        score = _score(e.importance)
        if score is None or score < consolidate_at:
            return False
        return not looks_secretish(e.text)     # the canon door would refuse it

    def pending(self, *, consolidate_at: float = 0.6) -> list[Event]:
        """Everything the buffer is holding that rest() cannot resolve on its own — the list
        to put in front of him. Two kinds land here: what the agent merely inferred (never
        auto-promoted at any score), and his own words scored under the bar (which rest won't
        consolidate and forget won't archive). Both would otherwise sit unseen forever, and a
        tape whose promise is 'nothing cut' cannot hold a memory nothing can see."""
        return ([e for e in self.buffered()
                 if not self._auto_consolidates(e, consolidate_at)]
                + self.refused())

    def promote(self, event_id: int) -> int:
        """His hand on the door: move one buffered event into canon. Refuses anything not
        currently buffered, so you can only promote what was on the list he was shown, and
        only once. Authority is preserved on purpose — he approved the agent's wording, which
        does not make the words his.

        What this is NOT: the only way into canon. remember() and seed write there directly,
        and nothing here can tell his hand on this command from an agent running it. This
        gate binds the honest flow — it is not proof against an agent that mislabels an
        event's authority or drives the CLI itself.
        """
        e = self.event(event_id)
        if e is None:
            raise ValueError(f"no such event: {event_id}")
        if e.status != "buffered":
            raise ValueError(f"event {event_id} is already {e.status}, not pending")
        new_id = self.remember(e.text, topic=e.topic, source=e.source, authority=e.authority)
        self._conn.execute(
            "UPDATE events SET status = 'consolidated' WHERE id = ?", (event_id,)
        )
        self._conn.commit()
        return new_id

    def dismiss(self, event_id: int) -> None:
        """His 'no'. Archives one buffered or refused event (status -> forgotten).

        pending() showed him a list whose only verb was promote, so he could say yes and
        had no way to say anything else — and a refused row could not be promoted at all,
        making it a dead end the list kept inviting him to act on. Archived, never deleted,
        like everything else the buffer lets go of.
        """
        e = self.event(event_id)
        if e is None:
            raise ValueError(f"no such event: {event_id}")
        if e.status not in ("buffered", "refused"):
            raise ValueError(f"event {event_id} is already {e.status}, not on your list")
        self._conn.execute(
            "UPDATE events SET status = 'forgotten' WHERE id = ?", (event_id,)
        )
        self._conn.commit()

    def rest(self, *, consolidate_at: float = 0.6, forget_below: float = 0.3) -> RestReport:
        """Close the cycle: consolidate the day's signal to canon, archive the noise (forget).

        Only the USER's own words consolidate on their own — writing down what he said is not
        a judgement call. An agent inference NEVER auto-promotes, however high the agent
        scored it, because an importance score is the agent's opinion of itself and an opinion
        is not a mandate. Those wait in pending() for promote(). What sits between the
        thresholds stays buffered for another day's evidence."""
        consolidated: list[int] = []
        refused: list[int] = []
        for e in self.buffered():
            if not self._auto_consolidates(e, consolidate_at):
                continue                       # everything else is on his list — pending()
            try:
                self.remember(e.text, topic=e.topic, source=e.source, authority=e.authority)
            except ValueError:
                # A refusal at the canon door must not end the cycle for the whole tape —
                # and must not vanish either. _auto_consolidates knows only the refusal the
                # door raises TODAY, so an unexpected one gets its own durable status and
                # stays on his list. Leaving it 'buffered' would hide it: the predicate
                # would still call it consolidatable and pending() would not show it.
                self._conn.execute(
                    "UPDATE events SET status = 'refused' WHERE id = ?", (e.id,)
                )
                refused.append(e.id)
                continue
            self._conn.execute(
                "UPDATE events SET status = 'consolidated' WHERE id = ?", (e.id,)
            )
            consolidated.append(e.id)
        self._conn.commit()
        forgotten = self.forget(min_importance=forget_below)
        return RestReport(consolidated=consolidated, forgotten=forgotten, refused=refused)

    def wake(self) -> Brief:
        """Play the video: the current truth (superseded scenes excluded), the count of lines
        never to render, and who the tape knows it is."""
        rows = self._conn.execute(
            "SELECT text, authority FROM canon WHERE superseded_by IS NULL ORDER BY id"
        ).fetchall()
        canon_texts = [r[0] for r in rows]
        canon_entries = [(r[0], r[1] or "agent-inference") for r in rows]
        (rejection_count,) = self._conn.execute("SELECT COUNT(*) FROM rejections").fetchone()
        identity = [e.text for e in self.recall("maude-identity")]
        return Brief(canon_texts=canon_texts, rejection_count=rejection_count,
                     identity=identity, canon_entries=canon_entries)

    def audit(self, surfaces: dict[str, str]) -> list[Breach]:
        """Autohealing: reconcile the record against reality — any rejected phrasing still live
        on a real surface is a breach to flag (and heal). The loop that never ran tonight."""
        breaches: list[Breach] = []
        for surface, text in surfaces.items():
            for hit in self.check_draft(text):
                breaches.append(Breach(surface=surface, phrase=hit.phrase,
                                       reason=hit.reason, source=hit.source))
        return breaches
