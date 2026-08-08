"""Tests for maude_marker.chain — the one-time marker that Claude cannot mint.

WHY THIS EXISTS
---------------
On 2026-07-30 an audit reproduced two working routes by which Claude minted his
own RED gate clearance from a single allow-listed Bash call. The provenance check
was a grep of the caller's command string for the clear-script's own filename, so
copying the scripts directory and renaming the script defeated it, and the trace
entry it wrote was indistinguishable from John's authorization.

The lesson is structural: anything Claude can READ in order to verify, Claude can
also read in order to forge. Signatures do not fix it either, because under
Maude's stdlib-only floor there is no Ed25519, and an HMAC secret the verifier
holds is a secret Claude can read.

A hash chain fixes it with hashlib alone. John generates a chain off-box and keeps
the unspent links; Maude stores ONLY the current head. To authorize, one link is
presented. Verifying is one sha256 and a comparison. Forging requires inverting
sha256. Claude, holding the head, can compute every ALREADY-SPENT link and no
future one -- which is exactly the property that makes the head safe to store on
the same disk Claude owns.

The load-bearing test here is test_forward_hash_of_head_is_rejected: it proves
that everything Claude can derive from the state file is worthless.
"""

import hashlib
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from maude_marker import chain  # noqa: E402


def _mkchain(seed: bytes, n: int):
    """Build a chain the way John's off-box generator would.

    links[0] is the FIRST to be spent, links[-1] is the head Maude stores.
    Spending walks backwards toward the seed.
    """
    links = []
    cur = hashlib.sha256(seed).hexdigest()
    for _ in range(n):
        links.append(cur)
        cur = hashlib.sha256(cur.encode()).hexdigest()
    return links, cur  # (spendable links, head)


@pytest.fixture()
def state(tmp_path):
    return str(tmp_path / "markers.json")


@pytest.fixture()
def ledger(tmp_path):
    return str(tmp_path / "marker-ledger.jsonl")


# ── the chain works at all ────────────────────────────────────────────────

def test_a_valid_link_is_accepted(state, ledger):
    links, head = _mkchain(b"seed-a", 3)
    chain.init(state, "sole-copy-target", head, count=3)
    ok, reason = chain.verify_and_consume(state, "sole-copy-target", links[-1], ledger=ledger)
    assert ok is True, reason


def test_consuming_advances_the_head(state, ledger):
    links, head = _mkchain(b"seed-b", 3)
    chain.init(state, "k", head, count=3)
    chain.verify_and_consume(state, "k", links[-1], ledger=ledger)
    assert chain.head(state, "k") == links[-1]


def test_the_next_link_down_is_accepted_after_the_first(state, ledger):
    links, head = _mkchain(b"seed-c", 3)
    chain.init(state, "k", head, count=3)
    assert chain.verify_and_consume(state, "k", links[-1], ledger=ledger)[0] is True
    assert chain.verify_and_consume(state, "k", links[-2], ledger=ledger)[0] is True


# ── the forgery cases: this is the whole point ────────────────────────────

def test_replaying_the_same_link_is_rejected(state, ledger):
    links, head = _mkchain(b"seed-d", 3)
    chain.init(state, "k", head, count=3)
    assert chain.verify_and_consume(state, "k", links[-1], ledger=ledger)[0] is True
    ok, reason = chain.verify_and_consume(state, "k", links[-1], ledger=ledger)
    assert ok is False
    assert "replay" in reason.lower() or "spent" in reason.lower()


def test_a_random_token_is_rejected(state, ledger):
    _, head = _mkchain(b"seed-e", 3)
    chain.init(state, "k", head, count=3)
    ok, _ = chain.verify_and_consume(state, "k", "f" * 64, ledger=ledger)
    assert ok is False


def test_forward_hash_of_head_is_rejected(state, ledger):
    """THE load-bearing test.

    Claude can read the state file, so he can compute sha256(head) and every
    further forward hash. If any of those were accepted, the whole scheme would be
    theatre. Only a PREIMAGE of the head is valid, and he cannot compute one.
    """
    _, head = _mkchain(b"seed-f", 3)
    chain.init(state, "k", head, count=3)
    forward = hashlib.sha256(head.encode()).hexdigest()
    ok, _ = chain.verify_and_consume(state, "k", forward, ledger=ledger)
    assert ok is False
    for _ in range(3):
        forward = hashlib.sha256(forward.encode()).hexdigest()
        assert chain.verify_and_consume(state, "k", forward, ledger=ledger)[0] is False
    assert chain.head(state, "k") == head, "a failed attempt must not advance the head"


def test_a_link_from_another_keys_chain_is_rejected(state, ledger):
    links_a, head_a = _mkchain(b"seed-g", 3)
    _, head_b = _mkchain(b"seed-h", 3)
    chain.init(state, "key-a", head_a, count=3)
    chain.init(state, "key-b", head_b, count=3)
    ok, _ = chain.verify_and_consume(state, "key-b", links_a[-1], ledger=ledger)
    assert ok is False


def test_state_file_never_holds_an_unspent_link(state, ledger):
    links, head = _mkchain(b"seed-i", 4)
    chain.init(state, "k", head, count=4)
    blob = open(state).read()
    for link in links:
        assert link not in blob, "an unspent link must never touch this disk"


# ── fail closed, never open ───────────────────────────────────────────────

def test_unconfigured_key_is_refused_not_allowed(state, ledger):
    ok, reason = chain.verify_and_consume(state, "never-set-up", "a" * 64, ledger=ledger)
    assert ok is False
    assert "unconfigured" in reason.lower() or "no chain" in reason.lower()


def test_missing_state_file_is_refused(tmp_path, ledger):
    ok, _ = chain.verify_and_consume(str(tmp_path / "absent.json"), "k", "a" * 64, ledger=ledger)
    assert ok is False


def test_exhausted_chain_is_refused(state, ledger):
    links, head = _mkchain(b"seed-j", 1)
    chain.init(state, "k", head, count=1)
    assert chain.verify_and_consume(state, "k", links[0], ledger=ledger)[0] is True
    ok, reason = chain.verify_and_consume(state, "k", "b" * 64, ledger=ledger)
    assert ok is False
    assert "exhaust" in reason.lower() or "replay" in reason.lower() or "spent" in reason.lower()


def test_corrupt_state_is_refused_not_allowed(state, ledger):
    open(state, "w").write("{ this is not json")
    ok, _ = chain.verify_and_consume(state, "k", "a" * 64, ledger=ledger)
    assert ok is False


# ── the ledger: DIAGNOSE ──────────────────────────────────────────────────

def test_every_attempt_is_ledgered_including_refusals(state, ledger):
    links, head = _mkchain(b"seed-k", 3)
    chain.init(state, "k", head, count=3)
    chain.verify_and_consume(state, "k", links[-1], ledger=ledger)
    chain.verify_and_consume(state, "k", "0" * 64, ledger=ledger)
    rows = [json.loads(x) for x in open(ledger) if x.strip()]
    assert len(rows) == 2
    assert rows[0]["ok"] is True and rows[1]["ok"] is False
    assert all("ts" in r and r["key"] == "k" for r in rows)


def test_ledger_is_append_only(state, ledger):
    links, head = _mkchain(b"seed-l", 3)
    chain.init(state, "k", head, count=3)
    chain.verify_and_consume(state, "k", links[-1], ledger=ledger)
    first = open(ledger).read()
    chain.verify_and_consume(state, "k", links[-2], ledger=ledger)
    assert open(ledger).read().startswith(first), "existing ledger lines must never be rewritten"


def test_ledger_records_a_fingerprint_not_the_token(state, ledger):
    """A spent link is worthless, but a ledger that echoes tokens invites the
    habit of writing secrets into logs. Record a fingerprint."""
    links, head = _mkchain(b"seed-m", 3)
    chain.init(state, "k", head, count=3)
    chain.verify_and_consume(state, "k", links[-1], ledger=ledger)
    blob = open(ledger).read()
    assert links[-1] not in blob
    assert "fp" in json.loads(blob.splitlines()[0])


# ── concurrency: two sessions, one link ───────────────────────────────────

def test_two_concurrent_consumers_only_one_wins(state, ledger):
    import threading

    links, head = _mkchain(b"seed-n", 3)
    chain.init(state, "k", head, count=3)
    results = []
    lock = threading.Lock()

    def go():
        r = chain.verify_and_consume(state, "k", links[-1], ledger=ledger)
        with lock:
            results.append(r[0])

    ts = [threading.Thread(target=go) for _ in range(8)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert results.count(True) == 1, f"exactly one consumer may win, got {results}"
