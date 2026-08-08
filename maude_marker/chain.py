"""One-time markers Claude cannot mint. hashlib only, no third-party imports.

THE PROBLEM THIS SOLVES
-----------------------
Maude's RED gate keys are meant to be John's hand alone. As of 2026-07-30 they
were not: an audit reproduced two routes by which Claude minted his own RED
clearance from one allow-listed Bash call, because the provenance check was a grep
of the caller's command string for the clear-script's own filename. Copy the
scripts directory, rename the script, and the check passes.

That is not a bug in the grep. It is structural. Claude runs as root in this house.
Anything he can READ in order to verify, he can read in order to forge:

  - a shared HMAC secret: he reads it, he signs anything
  - a stored "authorized: true" flag: he writes it
  - a token file: he writes it
  - Ed25519: not available, and would not help, because the stdlib-only floor
    (a locked decision) means no signing library ships with the plugin

A HASH CHAIN escapes this, with hashlib alone. Off-box, John generates:

    L0 = sha256(seed), L1 = sha256(L0), ... LN = sha256(L(N-1)),  HEAD = sha256(LN)

He keeps L0..LN (his links, spent newest-first) and gives Maude only HEAD.
To authorize, he presents LN. Maude checks sha256(LN) == HEAD, then stores LN as
the new head. Next time he presents L(N-1).

Claude, holding the head, can compute sha256(head) and every further FORWARD hash
-- all of them already-spent or never-valid. To forge the next authorization he
would have to invert sha256. This is why the head is safe to keep on the same disk
Claude owns, and it is the only property in this file that matters.

WHAT THIS DOES NOT DO
---------------------
It does not stop a determined Claude from editing the gate that calls it, or from
removing the hook. That layer is the harness deny-rules, which are John's hand by
construction. This closes the REFLEXIVE self-authorization the audit reproduced;
it is not a sandbox. Do not claim more for it than that.
"""

import fcntl
import hashlib
import json
import os
import tempfile
import time

TOKEN_LEN = 64  # sha256 hex


def _lock_path(state_path):
    return state_path + ".lock"


def _read_state(state_path):
    """Return the state dict, or None if unreadable/corrupt. Never raises.

    A corrupt state file must REFUSE, not fail open. Returning None here is what
    makes that happen: every caller treats None as "no chain".
    """
    try:
        with open(state_path, "r") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("chains"), dict):
        return None
    return data


def _write_state_atomic(state_path, data):
    d = os.path.dirname(os.path.abspath(state_path)) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".markers-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=1, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, state_path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _fingerprint(token):
    """A short digest of a token, for the ledger.

    A spent link is worthless, but writing secrets into logs is a habit worth not
    forming: the ledger proves WHICH link was presented without reproducing it.
    """
    # errors="surrogatepass" so a non-UTF8 argv token (surrogate-escaped by Python)
    # cannot raise here. A redteam found a 64-byte 0xff token crashed instead of
    # being refused, which also meant the attempt never reached the ledger.
    try:
        raw = ("fp:" + token).encode("utf-8", errors="surrogatepass")
    except (UnicodeError, TypeError):
        raw = repr(token).encode("utf-8", errors="replace")
    return hashlib.sha256(raw).hexdigest()[:12]


def _ledger_append(ledger, row):
    if not ledger:
        return
    try:
        d = os.path.dirname(os.path.abspath(ledger)) or "."
        os.makedirs(d, exist_ok=True)
        # Append-only by construction: mode "a", one line, never a rewrite.
        with open(ledger, "a") as fh:
            fh.write(json.dumps(row, sort_keys=True) + "\n")
    except OSError:
        # A ledger that cannot be written must not turn a refusal into a pass, and
        # must not turn a valid authorization into a crash. Record nothing, carry on.
        pass


def init(state_path, key, head, count):
    """Register the HEAD of a chain for `key`. Never stores an unspent link.

    Takes the SAME lock as verify_and_consume. It did not, and a redteam showed the
    consequence: init() was a lock-free read-modify-write of the whole chains dict,
    so a concurrent init for ANY unrelated key could lost-update another key's head
    back to its previous value and re-validate an already-spent link. Measured: one
    link accepted twice while 12 unrelated gens ran. That breaks the only guarantee
    this file makes, which is that a link works exactly once.
    """
    if not isinstance(head, str) or len(head) != TOKEN_LEN:
        raise ValueError("head must be a sha256 hex digest")
    lock = _lock_path(state_path)
    os.makedirs(os.path.dirname(os.path.abspath(lock)) or ".", exist_ok=True)
    with open(lock, "a+") as lfh:
        fcntl.flock(lfh.fileno(), fcntl.LOCK_EX)
        try:
            data = _read_state(state_path) or {"chains": {}}
            data["chains"][key] = {
                "head": head,
                "remaining": int(count),
                "initialized": int(time.time()),
            }
            _write_state_atomic(state_path, data)
        finally:
            fcntl.flock(lfh.fileno(), fcntl.LOCK_UN)


def head(state_path, key):
    """Current head for `key`, or None. Safe for Claude to read: it is spent."""
    data = _read_state(state_path)
    if not data:
        return None
    entry = data["chains"].get(key)
    return entry.get("head") if isinstance(entry, dict) else None


def verify_and_consume(state_path, key, token, ledger=None):
    """Verify one link and spend it. Returns (ok, reason).

    Fails CLOSED on every uncertainty: missing state, corrupt state, unknown key,
    exhausted chain, malformed token, replay, or any hash mismatch.
    """
    def _refuse(reason, remaining=None):
        _ledger_append(ledger, {
            "ts": int(time.time()),
            "key": key,
            "ok": False,
            "reason": reason,
            "fp": _fingerprint(token if isinstance(token, str) else ""),
            "remaining": remaining,
        })
        return False, reason

    if not isinstance(token, str) or len(token) != TOKEN_LEN:
        return _refuse("malformed token")

    lock = _lock_path(state_path)
    try:
        os.makedirs(os.path.dirname(os.path.abspath(lock)) or ".", exist_ok=True)
        lfh = open(lock, "a+")
    except OSError:
        # No lock means no safe read-modify-write. Refuse rather than race.
        return _refuse("cannot acquire marker lock")

    try:
        # Exclusive and blocking: two sessions presenting the same link must
        # serialize, so exactly one of them can spend it.
        fcntl.flock(lfh.fileno(), fcntl.LOCK_EX)

        data = _read_state(state_path)
        if data is None:
            return _refuse("no chain state (unconfigured or corrupt)")

        entry = data["chains"].get(key)
        if not isinstance(entry, dict) or not isinstance(entry.get("head"), str):
            return _refuse("unconfigured key: no chain for this key")

        current = entry["head"]
        remaining = int(entry.get("remaining", 0))

        if token == current:
            return _refuse("replay: that link was already spent", remaining)
        if remaining <= 0:
            return _refuse("chain exhausted: no links remain", remaining)
        if hashlib.sha256(token.encode()).hexdigest() != current:
            # Includes every forward hash Claude can derive from the head.
            return _refuse("invalid link: not a preimage of the current head", remaining)

        entry["head"] = token
        entry["remaining"] = remaining - 1
        entry["last_spent"] = int(time.time())
        _write_state_atomic(state_path, data)

        _ledger_append(ledger, {
            "ts": int(time.time()),
            "key": key,
            "ok": True,
            "reason": "consumed",
            "fp": _fingerprint(token),
            "remaining": entry["remaining"],
        })
        return True, "consumed"
    finally:
        try:
            fcntl.flock(lfh.fileno(), fcntl.LOCK_UN)
        finally:
            lfh.close()
