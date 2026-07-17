"""Walk a memory dir and (re)build the vault. Stdlib only — no pyyaml."""
from __future__ import annotations

import os
import pathlib
import re

from . import db

_LINK_RE = re.compile(r"\[\[([^\]]+)\]\]")


def _frontmatter(text: str) -> tuple[dict, str]:
    """Return (fields, body). Fields empty if no leading '---' block."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    block = text[3:end]
    body = text[end + 4:].lstrip("\n")
    fields: dict[str, str] = {}
    for line in block.splitlines():
        m = re.match(r"\s*([A-Za-z_]+):\s*(.*)$", line)
        if m:
            fields[m.group(1)] = m.group(2).strip()
    return fields, body


def parse_note(path: pathlib.Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    fields, body = _frontmatter(text)
    name = fields.get("name") or path.stem
    description = fields.get("description")
    if not description:
        description = next(
            (ln.strip() for ln in text.splitlines() if ln.strip()), ""
        )
    note_type = fields.get("type", "")
    superseded = fields.get("superseded_by", "").strip()
    if not superseded and fields.get("status", "").strip().lower() == "superseded":
        superseded = "superseded"
    links = ",".join(sorted(set(_LINK_RE.findall(text))))
    return {
        "name": name,
        "description": description,
        "type": note_type,
        "body": body if fields else text,
        "links": links,
        "superseded": superseded,
    }


def build(mem_dir: str | os.PathLike, db_path: str | os.PathLike) -> int:
    mem_dir = pathlib.Path(mem_dir)
    conn = db.connect(db_path)
    conn.execute("DELETE FROM notes")
    conn.execute("DELETE FROM notes_fts")
    count = 0
    for md in sorted(mem_dir.rglob("*.md")):
        try:
            note = parse_note(md)
            mtime = md.stat().st_mtime
        except (OSError, UnicodeError):
            # One unreadable file (broken symlink, permission error, bad
            # encoding) shouldn't abort the whole build — skip it and keep
            # going; count only what actually got ingested.
            continue
        rel = str(md.relative_to(mem_dir))
        conn.execute(
            "INSERT OR REPLACE INTO notes"
            "(path,name,description,type,body,mtime,links,superseded)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (rel, note["name"], note["description"], note["type"],
             note["body"], mtime, note["links"], note["superseded"]),
        )
        # A superseded note stays in `notes` (history) but never enters FTS —
        # it can no longer page. Mark, don't erase: the markdown is untouched.
        if not note["superseded"]:
            conn.execute(
                "INSERT INTO notes_fts(path,name,description,body) VALUES (?,?,?,?)",
                (rel, note["name"], note["description"], note["body"]),
            )
        count += 1
    conn.commit()
    conn.close()
    return count
