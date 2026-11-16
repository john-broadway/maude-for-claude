"""The store: approve, revoke, show, and what is live. Stdlib only.

Approved pages, the ledger and the live rows are one sqlite file (db.py). Text from
an approved page later reaches a model's context, so every path that lets page text
go on call goes through `parse` then `validate`, and a page that fails either never
goes live and is never approved.

Every function takes `home`, `project` and `now` as arguments; none reads the
environment, expands `~`, or reads the clock or the cwd. Reads are quiet on
doubt (a missing file, a page that no longer validates: skipped); the user's
approve and revoke are loud and all-or-nothing: one transaction each.
"""
from __future__ import annotations

import hashlib
import os
import re
import stat
import sqlite3
import tempfile
from contextlib import contextmanager
from pathlib import Path

from maude_rolodex import db, index
from maude_rolodex.page import Page, PageError, parse, render_cue, validate

_SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,47}")
_HASH_RE = re.compile(r"[0-9a-f]{64}")
_TIME_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
_PAGE_MAX = 64 * 1024
_FILE_MAX = 8 * 1024 * 1024
_SHARED_SOURCES = ("synced", "personal", "project")
# A pick may name only a source the box vouches for in every project. A `project` row is
# the files of whichever repo is open, so a card for one would go on call in any repo
# that carries a skill of the same name (the lens on 176680a, blocking).
_PICK_SOURCES = ("synced", "personal")


class StoreError(Exception):
    """A refusal with a plain one-line reason. Nothing was written."""


# --- paths --------------------------------------------------------------

def _home(home) -> Path:
    h = Path(home) if isinstance(home, (str, os.PathLike)) else None
    if h is None or not h.is_absolute():
        raise StoreError("the home must be an absolute path")
    return h


def rolodex_dir(home) -> Path:
    return _home(home) / ".claude" / "maude" / "rolodex"


def inventory_sig_path(home, project) -> Path:
    return index.inventory_path(_home(home), project).with_suffix(".sig")


def write_signature(home, project, signature: str) -> None:
    """The inventory's signature, beside the inventory, atomically."""
    _atomic_write(inventory_sig_path(home, project), (signature + "\n").encode("ascii"))


def _check_slug(slug) -> str:
    if not isinstance(slug, str) or _SLUG_RE.fullmatch(slug) is None:
        shown = repr(slug)[:60]
        raise StoreError(f"{shown} is not a trade name (a-z, 0-9 and -, 1 to 48 characters, "
                         "starting with a letter or digit)")
    return slug


def _check_now(now) -> str:
    if not isinstance(now, str) or _TIME_RE.fullmatch(now) is None:
        raise StoreError("the time must look like 2026-11-10T10:00:00Z")
    return now


# --- file helpers ---------------------------------------------------------

def _read_regular(path, cap: int, nofollow: bool = False, too_big: str = ""):
    """Bytes of a regular file, or None on any doubt.

    Symlinks are followed unless `nofollow` (a recipe's target may be a link,
    because its hash is what was approved; a page may not). Opened
    non-blocking so a FIFO cannot hang us; a directory, a device, a missing
    file or one longer than `cap` is None.
    """
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
    if nofollow:
        flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except (OSError, ValueError):
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks, size = [], 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            size += len(chunk)
            if size > cap:
                if too_big:
                    raise StoreError(too_big)
                return None
            chunks.append(chunk)
        return b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)


def _read_page(directory: Path, name: str):
    """The one reader for pending pages: no symlink anywhere in the last two steps.

    None when the directory or the file is a symlink, or on any other doubt.
    """
    path = directory / name
    if os.path.islink(directory) or os.path.islink(path):
        return None
    return _read_regular(path, _PAGE_MAX, nofollow=True)


def _real_dir(directory: Path) -> Path:
    """A directory we are about to write into must not be a symlink."""
    if os.path.islink(directory):
        raise StoreError(f"{directory.name}/ is a symbolic link; Maude will not write through it")
    return directory


def _atomic_write(path: Path, data: bytes) -> None:
    """Temp file in the same directory, then os.replace onto the final name."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --- the db --------------------------------------------------------------------

@contextmanager
def _store(home):
    """The open store, as ONE write transaction, rolled back on any exception."""
    try:
        conn = db.open_rw(rolodex_dir(home))
    except db.DbError as e:
        raise StoreError(str(e)) from None
    try:
        try:
            db.begin(conn)
        except sqlite3.Error as e:
            raise StoreError(f"the Rolodex store is busy or locked ({e.__class__.__name__}); "
                             "nothing was written") from None
        try:
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            try:
                conn.execute("ROLLBACK")
            except sqlite3.Error:
                pass
            raise
    except sqlite3.Error as e:
        raise StoreError(f"the Rolodex store refused the change ({e.__class__.__name__}); "
                         "nothing was written") from None
    finally:
        conn.close()


def known(home) -> set[str]:
    """Every slug the ledger has ever named (approved now or once): read-only, quiet on doubt."""
    h = _home(home)
    conn = db.open_ro(rolodex_dir(h))
    if conn is None:
        return set()
    try:
        return set(db.last(conn))
    except sqlite3.Error:
        return set()
    finally:
        conn.close()


def status(home) -> dict[str, str]:
    """slug -> sha of the approved page, for trades whose last ledger row is `approve`."""
    h = _home(home)
    conn = db.open_ro(rolodex_dir(h))
    if conn is None:
        return {}
    try:
        return db.approved(conn)
    except sqlite3.Error:
        return {}
    finally:
        conn.close()


# --- recipes -------------------------------------------------------------------

def _expand(home: Path, path: str):
    if path.startswith("~/"):
        return str(home).rstrip("/") + "/" + path[2:]
    return path if path.startswith("/") else None


def _file_matches(home: Path, path: str, digest: str) -> bool:
    real = _expand(home, path)
    if real is None or not _HASH_RE.fullmatch(digest):
        return False
    data = _read_regular(real, _FILE_MAX)
    return data is not None and _sha(data) == digest


def recipe_files_ok(home, page: Page) -> bool:
    """A recipe's main file and every `also` companion exist and match their hashes."""
    try:
        h = _home(home)
    except StoreError:
        return False
    if page.pick_kind != "recipe":
        return False
    pairs = [(page.pick_name, page.pin)] + list(page.also)
    return all(_file_matches(h, path, digest) for path, digest in pairs)


# --- approve / revoke -------------------------------------------------------------

_PREFIX_RE = re.compile(r"[0-9a-f]{64}")


def _source_ok(source: str) -> bool:
    """A literal (synced, personal, project) or `<plugin>@<marketplace>@<version>`."""
    if source in _SHARED_SOURCES:
        return True
    parts = source.split("@")
    return len(parts) == 3 and all(parts)


def _load_pending(home: Path, slug: str, prefix: str):
    data = _read_page(rolodex_dir(home) / "pending", f"{slug}.md")   # read ONCE; this buffer is used throughout
    if data is None:
        raise StoreError(f"{slug}: there is no readable pending page for it")
    if _sha(data) != prefix:
        raise StoreError(f"{slug}: the pending page changed since it was shown; "
                         "read it again with show, then approve with the new hash")
    try:
        page = parse(data)
    except PageError as e:
        raise StoreError(f"{slug}: the page cannot be read: {e}") from None
    errs = validate(page)
    if errs:
        raise StoreError(f"{slug}: " + "; ".join(errs))
    if page.pick_kind in ("skill", "agent", "mcp"):
        for kind, name, source, _ in page.providers:
            if kind == page.pick_kind and name == page.pick_name and source == "project":
                raise StoreError(f"{slug}: a pick from a project's own files cannot be approved: "
                                 "the card would follow any repo with a provider of that name")
            if kind == page.pick_kind and name == page.pick_name and not _source_ok(source):
                raise StoreError(f"{slug}: the provider source must be synced, personal "
                                 "or <plugin>@<marketplace>@<version>")
    if page.pick_kind == "recipe" and not recipe_files_ok(home, page):
        raise StoreError(f"{slug}: a recipe file is missing, is not a regular file, "
                         "or does not match its pin")
    return data, page


def approve(home, items: list[tuple[str, str]], now: str) -> list[str]:
    """Approve pending pages, all or none: one transaction. `items` are (slug, sha256) pairs.

    The hash is of the page as the user read it (`show` prints it, all 64 hex
    characters); a page edited since is refused. Every check happens before the
    transaction opens. Returns signed messages.
    """
    h = _home(home)
    _check_now(now)
    if not items:
        raise StoreError("name at least one trade to approve")
    checked = [(_check_slug(slug), prefix) for slug, prefix in items]
    for slug, prefix in checked:
        if not isinstance(prefix, str) or _PREFIX_RE.fullmatch(prefix) is None:
            raise StoreError(f"{slug}: approve needs the hash show printed: {slug}@<the 64 "
                             "lowercase hex characters of the pending sha256>")
    loaded: dict[str, tuple[bytes, Page]] = {}
    for slug, prefix in checked:
        data, page = _load_pending(h, slug, prefix)
        if slug in loaded and loaded[slug][0] != data:
            raise StoreError(f"{slug}: the pending page changed since it was shown")
        loaded[slug] = (data, page)
    with _store(h) as conn:
        for slug, (data, _) in loaded.items():
            db.add_approve(conn, slug, data, now)
    return [f"**Maude:** approved {slug}: {page.trade} -> {page.pick_name} ({page.pick_kind})."
            for slug, (_, page) in loaded.items()]


def revoke(home, slugs: list[str], now: str) -> None:
    """Revoke trades, all or none: their ledger rows and their live rows in every project,
    one transaction."""
    h = _home(home)
    _check_now(now)
    if not slugs:
        raise StoreError("name at least one trade to revoke")
    order = list(dict.fromkeys(_check_slug(s) for s in slugs))
    with _store(h) as conn:
        for slug in order:
            db.add_revoke(conn, slug, now)


# --- the live file --------------------------------------------------------------------

def _source_state(expected: str, rows: list[tuple]) -> str:
    """'same', 'moved' or 'gone': rows are the inventory's rows of this kind and name.

    A literal matches only itself. `<plugin>@<marketplace>@<version>` matches the
    same plugin AND marketplace; only the version may differ (`moved`).
    """
    sources = [r[2] for r in rows if len(r) > 2 and isinstance(r[2], str)]
    if expected == "project":
        return "gone"                                  # never on call: see _PICK_SOURCES
    if expected in _PICK_SOURCES:
        return "same" if expected in sources else "gone"
    want = expected.split("@")
    if len(want) != 3 or not all(want):
        return "gone"
    if expected in sources:
        return "same"
    for src in sources:
        got = src.split("@")
        if len(got) == 3 and all(got) and got[:2] == want[:2]:
            return "moved"
    return "gone"


def _inventory_state(page: Page, inventory) -> str:
    rows = [r for r in inventory
            if isinstance(r, (tuple, list)) and len(r) >= 3 and r[0] == page.pick_kind
            and r[1] == page.pick_name]
    prov = next((p for p in page.providers
                 if p[0] == page.pick_kind and p[1] == page.pick_name), None)
    if prov is None or not rows:
        return "gone"
    return _source_state(prov[2], rows)


def derive_live(home, project, inventory_rows) -> tuple[list[str], list[str]]:
    """Rebuild this project's live rows in one transaction; return (changed, gone), sorted."""
    h = _home(home)
    proj = index.project_slug(project)
    changed: list[str] = []
    gone: list[str] = []
    rows: list[tuple[str, str, str]] = []
    with _store(h) as conn:
        for slug, digest in sorted(db.approved(conn).items()):
            data = db.page(conn, digest)
            if data is None:
                continue
            try:
                page = parse(data)
            except PageError:
                continue
            if validate(page) or page.pick_kind == "own":
                continue
            flag = "same"
            if page.pick_kind == "recipe":
                if not recipe_files_ok(h, page):
                    gone.append(slug)
                    continue
            else:
                state = _inventory_state(page, inventory_rows)
                if state == "gone":
                    gone.append(slug)
                    continue
                if state == "moved":
                    changed.append(slug)
                    flag = "moved"
            rows.append((slug, digest, flag))
        db.set_live(conn, proj, rows)
    return sorted(changed), sorted(gone)


def live_pages(home, project, check_recipes: bool = True) -> list[tuple[str, Page]]:
    """(slug, page) on call in this project: read-only, quiet on any doubt.

    Each page is the approved bytes, re-hashed, parsed and validated here; a
    recipe's files are re-checked against their pins. The live row only says
    WHICH pages; it never supplies a word. The cue passes check_recipes=False and
    checks only the one recipe it is about to name."""
    try:
        h = _home(home)
    except StoreError:
        return []
    conn = db.open_ro(rolodex_dir(h))
    if conn is None:
        return []
    try:
        found = db.live(conn, index.project_slug(project))
    except sqlite3.Error:
        return []
    finally:
        conn.close()
    out = []
    for slug, data in found:
        try:
            page = parse(data)
        except PageError:
            continue
        if validate(page) or page.pick_kind == "own":
            continue
        if check_recipes and page.pick_kind == "recipe" and not recipe_files_ok(h, page):
            continue
        out.append((slug, page))
    return out


# --- show ------------------------------------------------------------------------------

def _escape(data: bytes) -> str:
    """Printable ASCII and newline pass; a backslash is doubled; every other byte is \\xNN."""
    out = []
    for b in data:
        if b == 0x5C:
            out.append("\\\\")
        elif b == 10 or 0x20 <= b <= 0x7E:
            out.append(chr(b))
        else:
            out.append(f"\\x{b:02x}")
    return "".join(out)


_FOLD = 75          # every line show prints, prefix included


def _units(data: bytes) -> list[list[str]]:
    """Per line, the escaped text as units: one character, `\\\\`, or `\\xNN`, never split."""
    lines: list[list[str]] = [[]]
    for b in data:
        if b == 10:
            lines.append([])
        elif b == 0x5C:
            lines[-1].append("\\\\")
        elif 0x20 <= b <= 0x7E:
            lines[-1].append(chr(b))
        else:
            lines[-1].append(f"\\x{b:02x}")
    return lines


def _fold(lines: list[list[str]], first: str, more: str) -> list[str]:
    """Each line behind `first`, its continuations behind `more`, none over _FOLD."""
    out = []
    for units in lines:
        seg, prefix = "", first
        for u in units:
            if len(prefix) + len(seg) + len(u) > _FOLD:
                out.append(prefix + seg)
                seg, prefix = "", more
            seg += u
        out.append(prefix + seg)
    return out


def _quoted(data: bytes) -> list[str]:
    """Page text behind `| ` (`|+ ` on continuations), so no row of it can look like a
    line `show` printed."""
    lines = _units(data)
    if len(lines) > 1 and not lines[-1]:
        lines.pop()                                    # the final newline
    return _fold(lines, "| ", "|+ ")


def _on_call(data: bytes) -> list[str]:
    """What goes on call, from the parsed and validated fields of THIS buffer only, each
    behind `> ` (`>+ ` on continuations)."""
    try:
        page = parse(data)
        errs = validate(page)
    except PageError as e:
        errs, page = [str(e)], None
    if errs:
        body = ["nothing: this page cannot be approved (" + errs[0] + ")"]
    else:
        body = [f"trade: {page.trade}", f"pick: {page.pick_kind} {page.pick_name}",
                f"says: {render_cue(page)}"]
        body += [f"when: {' '.join(ph)}" for ph in page.phrases]
        if page.pick_kind == "recipe":
            body.append(f"reads: {page.pick_name}")
            body += [f"also reads: {path}" for path, _ in page.also]
    return ["what goes on call:"] + _fold([_units(line.encode("utf-8", "replace"))[0] for line in body],
                                          "> ", ">+ ")


def _still_validates(data: bytes) -> bool:
    try:
        return not validate(parse(data))
    except PageError:
        return False


def show(home, slug: str) -> str:
    h = _home(home)
    _check_slug(slug)
    pending = _read_page(rolodex_dir(h) / "pending", f"{slug}.md")
    approved, entry = None, None
    conn = db.open_ro(rolodex_dir(h))
    if conn is not None:
        try:
            entry = db.last(conn).get(slug)
            if entry and entry[0] == "approve" and entry[1]:
                approved = db.page(conn, entry[1])
        except sqlite3.Error:
            entry = "unreadable"
        finally:
            conn.close()
    unreadable = entry == "unreadable" or (conn is None and os.path.lexists(db.path(rolodex_dir(h))))
    broken = isinstance(entry, tuple) and entry[0] == "approve" and approved is None
    if pending is None and approved is None:
        if unreadable:
            raise StoreError(f"{slug}: the Rolodex store cannot be read; nothing is on call")
        if broken:
            raise StoreError(f"{slug}: the approved copy no longer matches its hash; it is not on call")
        if isinstance(entry, tuple) and entry[0] == "revoke":
            raise StoreError(f"{slug}: nothing is pending, and the approval was revoked")
        raise StoreError(f"{slug}: there is nothing pending or approved under that name")
    out: list[str] = []
    if pending is not None:
        out += [f"--- pending: {slug} ---", *_on_call(pending), *_quoted(pending)]
    if approved is not None:
        valid = "still validates" if _still_validates(approved) else "does NOT validate: not live"
        out += [f"--- approved: {slug} ---", *_on_call(approved), *_quoted(approved),
                f"**Maude:** the approved copy {valid}."]
    elif unreadable:
        out.append("**Maude:** the Rolodex store cannot be read; nothing is on call.")
    elif broken:
        out.append("**Maude:** the approved copy fails its hash; it is not on call.")
    else:
        out.append("**Maude:** there is no approved copy of this trade.")
    if pending is not None:
        out.append(f"pending sha256: {_sha(pending)}")   # 80 characters: one 80-column row; always last
    return "\n".join(out)
