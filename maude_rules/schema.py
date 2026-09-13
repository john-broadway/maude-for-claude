"""Codd's schema-touching rules and the normal-form floor, over CREATE TABLE text.

What it can see: the shape of a declared schema. What it cannot see: functional
dependencies. So 2NF and 3NF here are name-shape heuristics: 2NF is an ask because a
composite key alone proves nothing about whether every non-key column depends on the
whole key; 3NF is a finding because the shape it matches (`<t>_<attr>` beside `<t>_id`
where table `<t>` has `<attr>`) is the textbook transitive dependency, and a
coincidence of names costs one whisper, not a block. A repeating-group stem that is
`line` or ends in `_line` (`line1/2`, `address_line1/2`) is exempt: the shape is a
repeating group by the book, but firing on every address table swallows the signal, so
this is the one carved-out stem. There is no dialect parser; a CREATE TABLE is found
wherever it appears, in SQL or inside a string literal of any language, but a
statement assembled by string concatenation is not found. A table-level clause is
recognised by SHAPE (a keyword, an optional index name, then a paren), so an
ordinary column named keyword, checksum, indexed_at, uniquely, key_id or check_in
stays a column; `UNIQUE KEY name (cols)` and `UNIQUE INDEX name (cols)` are unique
groups, and bare `KEY name (cols)` / `INDEX name (cols)` are indexes, which say
nothing about uniqueness and are ignored. The residual hole is an unquoted column
literally named `key`, `check`, `index` or `unique` whose type carries a
non-numeric parameter; a numeric one (`key VARCHAR(20)`) is already read as a
column. ORM models, Prisma and DBML are classified by the rail and not read here.
Nothing above third normal form exists in this module.

Rules enforced (level): codd-2 no key (finding) · 1nf repeating group (finding) ·
1nf multi-valued column (ask) · 2nf composite key with non-key columns (ask) ·
3nf transitive column (finding) · codd-10 id with no REFERENCES (finding) · codd-10
integer column named `<x>_by` with no REFERENCES (ask: it names a row, but not which
table) · codd-3 sentinel default (ask). Everything else in Codd's list judges a DBMS, not a
schema, and is not judged here.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

_CREATE = re.compile(
    r"CREATE\s+(?:TEMP(?:ORARY)?\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"
    r"([`\"\[]?[\w.]+[`\"\]]?)\s*\(",
    re.I,
)
_LINE_COMMENT = re.compile(r"--[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_QUOTE_CHARS = "`\"[]"
_MULTI_SUFFIX = ("_list", "_csv", "_json", "_array")
# Whole names, not only suffixes: a column named `json` or `embedding` holds a document or a
# vector, and the rail's first run over Maude's own tables missed both (2026-09-03).
_MULTI_NAMES = {"tags", "emails", "phones", "json", "jsonb", "embedding", "vector", "links"}
_MULTI_TYPES = {"JSON", "JSONB", "ARRAY", "SET"}
_SENTINELS_STR = {"n/a", "none", "null", "unknown"}
_NUM_SUFFIX = re.compile(r"^(.*?)_?(\d+)$")
_CONSTRAINT_NAME = re.compile(
    r"^\s*CONSTRAINT\s+(?:\"[^\"]+\"|`[^`]+`|\[[^\]]+\]|[\w.]+)\s+"
    r"(?=PRIMARY\s+KEY|FOREIGN\s+KEY|UNIQUE|CHECK)",
    re.I,
)
# A table-level clause is a KEYWORD, an optional index name, then a paren. Testing the
# prefix instead ("does it start with KEY") swallowed every ordinary column whose name
# merely began with one of these words (keyword, checksum, indexed_at, uniquely,
# key_id, check_in), which erased a declared PRIMARY KEY and minted a false codd-2.
_TABLE_CLAUSE = re.compile(
    r"^(UNIQUE(\s+(KEY|INDEX))?|PRIMARY\s+KEY|FOREIGN\s+KEY|CHECK|KEY|INDEX)\s*(\w+\s*)?\(",
    re.I,
)
# `key VARCHAR(20)` matches that shape too, with VARCHAR read as the index name. A
# parenthesised list of bare numbers is a type's parameters, never a column list, so it
# sends the part back to the column parser.
_TYPE_PARAMS = re.compile(r"\s*\d+\s*(,\s*\d+\s*)*\)")
_UNIQUE_CLAUSE = re.compile(r"^UNIQUE(\s+(KEY|INDEX))?\s*(\w+\s*)?\((.*?)\)", re.I | re.S)


@dataclass
class Column:
    name: str
    ctype: str
    pk: bool = False
    notnull: bool = False
    unique: bool = False
    references: str | None = None
    default: str | None = None


@dataclass
class Table:
    name: str
    columns: list[Column] = field(default_factory=list)
    pk_cols: list[str] = field(default_factory=list)
    unique_groups: list[list[str]] = field(default_factory=list)  # one list per UNIQUE(...) constraint
    fk: dict[str, str] = field(default_factory=dict)  # column -> referenced table


@dataclass
class Finding:
    table: str
    column: str
    text: str
    rule: str
    level: str  # "finding" | "ask"


def _strip_quotes(ident: str) -> str:
    ident = ident.strip().strip(_QUOTE_CHARS)
    return ident.split(".")[-1].lower()


def _split_top_level(body: str) -> list[str]:
    parts, depth, cur, quote = [], 0, [], None
    for ch in body:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"', "`"):
            quote = ch
            cur.append(ch)
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        parts.append(tail)
    return parts


def _find_body(text: str, start: int) -> str | None:
    depth, quote = 0, None
    for i in range(start, len(text)):
        ch = text[i]
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"', "`"):
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return None


def _parse_column(part: str) -> Column | None:
    tokens = part.split()
    if not tokens:
        return None
    name = _strip_quotes(tokens[0])
    if not re.match(r"^[a-z_][a-z0-9_]*$", name):
        return None
    upper = part.upper()
    ctype = tokens[1].upper().strip(",") if len(tokens) > 1 else ""
    col = Column(name=name, ctype=ctype)
    col.pk = "PRIMARY KEY" in upper
    col.notnull = "NOT NULL" in upper or col.pk
    col.unique = "UNIQUE" in upper
    m = re.search(r"REFERENCES\s+([`\"\[]?[\w.]+[`\"\]]?)", part, re.I)
    if m:
        col.references = _strip_quotes(m.group(1))
    d = re.search(r"DEFAULT\s+('(?:[^']|'')*'|-?\d+(?:\.\d+)?|\w+)", part, re.I)
    if d:
        col.default = d.group(1)
    return col


def _is_table_clause(part: str) -> re.Match | None:
    m = _TABLE_CLAUSE.match(part)
    if m and _TYPE_PARAMS.match(part, m.end()):
        return None
    return m


def _parse_table(name: str, body: str) -> Table:
    table = Table(name=name)
    for part in _split_top_level(body):
        part = _CONSTRAINT_NAME.sub("", part, count=1)
        clause = _is_table_clause(part)
        if clause is not None:
            kind = re.sub(r"\s+", " ", clause.group(1).upper())
            if kind == "PRIMARY KEY":
                inner = re.search(r"\((.*?)\)", part, re.S)
                if inner:
                    table.pk_cols = [_strip_quotes(c) for c in inner.group(1).split(",")]
            elif kind == "FOREIGN KEY":
                m = re.search(r"\((.*?)\)\s*REFERENCES\s+([`\"\[]?[\w.]+[`\"\]]?)", part, re.I | re.S)
                if m:
                    for c in m.group(1).split(","):
                        table.fk[_strip_quotes(c)] = _strip_quotes(m.group(2))
            elif kind.startswith("UNIQUE"):
                # UNIQUE (cols), UNIQUE KEY name (cols), UNIQUE INDEX name (cols) are all
                # one unique group. Bare KEY/INDEX name (cols) is an index and says
                # nothing about uniqueness, so it falls through to no branch at all.
                inner = _UNIQUE_CLAUSE.match(part)
                if inner:
                    table.unique_groups.append([_strip_quotes(c) for c in inner.group(4).split(",")])
            continue
        col = _parse_column(part)
        if col is not None:
            table.columns.append(col)
            if col.pk:
                table.pk_cols.append(col.name)
            if col.references:
                table.fk[col.name] = col.references
    return table


def extract_tables(text: str) -> list[Table]:
    """Every CREATE TABLE in the text, comments stripped, wherever it sits."""
    clean = _BLOCK_COMMENT.sub(" ", _LINE_COMMENT.sub(" ", text or ""))
    tables = []
    for m in _CREATE.finditer(clean):
        body = _find_body(clean, m.end() - 1)
        if body is None:
            continue
        try:
            tables.append(_parse_table(_strip_quotes(m.group(1)), body))
        except Exception:  # noqa: BLE001 - a library that whispers must never raise
            continue
    return tables


def _same_entity(base: str, table: str) -> bool:
    return base == table or base + "s" == table or base + "es" == table or base == table.rstrip("s")


def _check_no_key(t: Table) -> list[Finding]:
    if t.pk_cols:
        return []
    if any(c.unique and c.notnull for c in t.columns):
        return []
    notnull = {c.name for c in t.columns if c.notnull}
    if any(group and all(name in notnull for name in group) for group in t.unique_groups):
        return []
    return [Finding(t.name, "", "no PRIMARY KEY, and no UNIQUE NOT NULL column stands in for one", "codd-2", "finding")]


def _check_repeating_group(t: Table) -> list[Finding]:
    groups: dict[str, list[tuple[int, str]]] = {}
    for c in t.columns:
        m = _NUM_SUFFIX.match(c.name)
        if m and m.group(1):
            groups.setdefault(m.group(1), []).append((int(m.group(2)), c.name))
    out = []
    for stem, members in groups.items():
        if len(members) < 2 or stem == "line" or stem.endswith("_line"):
            continue
        nums = sorted(n for n, _ in members)
        if all(b - a == 1 for a, b in zip(nums, nums[1:])):
            first = min(members)[1]
            names = ", ".join(n for _, n in sorted(members))
            out.append(Finding(t.name, first, f"repeating group {names}: one row per value in its own table", "1nf", "finding"))
    return out


def _check_multivalued(t: Table) -> list[Finding]:
    out = []
    for c in t.columns:
        if c.name.endswith(_MULTI_SUFFIX) or c.name in _MULTI_NAMES or c.ctype.rstrip(",") in _MULTI_TYPES or "[]" in c.ctype:
            out.append(Finding(t.name, c.name, "multi-valued column: if this is relational data it belongs in rows", "1nf", "ask"))
    return out


def _check_partial_dependency(t: Table) -> list[Finding]:
    if len(t.pk_cols) >= 2 and any(c.name not in t.pk_cols for c in t.columns):
        return [Finding(t.name, "", "composite key: state that every non-key column depends on the whole key", "2nf", "ask")]
    return []


def _check_transitive(t: Table, all_tables: list[Table]) -> list[Finding]:
    out = []
    names = {c.name for c in t.columns}
    for c in t.columns:
        m = re.match(r"^([a-z0-9]+)_([a-z0-9_]+)$", c.name)
        if not m or m.group(2) == "id":
            continue
        base, attr = m.group(1), m.group(2)
        if f"{base}_id" not in names:
            continue
        for other in all_tables:
            if other.name == t.name or not _same_entity(base, other.name):
                continue
            if any(oc.name == attr for oc in other.columns):
                out.append(Finding(t.name, c.name, f"beside {base}_id repeats {other.name}.{attr}: transitive dependency", "3nf", "finding"))
                break
    return out


def _check_integrity_in_app(t: Table, all_tables: list[Table]) -> list[Finding]:
    out = []
    for c in t.columns:
        if not c.name.endswith("_id") or c.name in t.fk:
            continue
        base = c.name[:-3]
        if any(o.name != t.name and _same_entity(base, o.name) for o in all_tables):
            out.append(Finding(t.name, c.name, "no REFERENCES: integrity lives in the catalog, not the application", "codd-10", "finding"))
    return out


def _check_reference_named_by(t: Table) -> list[Finding]:
    # `superseded_by`, `created_by`, `replaced_by`: an integer that names a row without saying
    # which table. The `_id` check above needs the target table to exist by name; this one
    # cannot know the target, so it asks. A text column ending in _by names a method.
    out = []
    for c in t.columns:
        if c.name.endswith("_by") and c.name not in t.fk and "INT" in c.ctype:
            out.append(Finding(t.name, c.name, "no REFERENCES: this names a row; say which table, in the catalog", "codd-10", "ask"))
    return out


def _check_sentinel_default(t: Table) -> list[Finding]:
    out = []
    for c in t.columns:
        d = c.default
        if d is None:
            continue
        val = d.strip("'").lower()
        if (d.startswith("'") and val in _SENTINELS_STR) or d == "-1":
            out.append(Finding(t.name, c.name, f"sentinel default {d}: missing information is NULL, systematically", "codd-3", "ask"))
    return out


def lint(text: str) -> list[Finding]:
    """All findings and asks for every CREATE TABLE in the text. Never raises."""
    try:
        tables = extract_tables(text)
        out: list[Finding] = []
        for t in tables:
            out += _check_no_key(t)
            out += _check_repeating_group(t)
            out += _check_multivalued(t)
            out += _check_partial_dependency(t)
            out += _check_transitive(t, tables)
            out += _check_integrity_in_app(t, tables)
            out += _check_reference_named_by(t)
            out += _check_sentinel_default(t)
        return out
    except Exception:  # noqa: BLE001
        return []


def format_line(f: Finding) -> str:
    where = f"{f.table}.{f.column}" if f.column else f.table
    return f"{where}: {f.text} ({f.rule})"
