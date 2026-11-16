"""A Rolodex page: parse it, validate it, render its cue. Stdlib only.

A page is `key: value` lines until the first line that is exactly `---`;
everything after is free notes and is never parsed.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

_KINDS = ("skill", "agent", "mcp", "recipe", "own")
_SINGLE = ("trade", "what", "cue")  # required, once
_OPTIONAL_SINGLE = ("pin",)  # at most once
_KEYS = _SINGLE + _OPTIONAL_SINGLE + ("when", "provider", "pick", "avoid", "also")
_PAD = " \t"
_NEEDS_PROVIDER = ("skill", "agent", "mcp")
_PIN_RE = re.compile(r"[0-9a-f]{64}")
_WORD_RE = re.compile(r"[a-z0-9]+")
_CUE_LINE_MAX = 200
_RENDERED_MAX = 300
_WORDS_MIN, _WORDS_MAX = 2, 6


class PageError(Exception):
    """The page cannot be read: the shape is wrong, not just the content."""


def words(text: str) -> list[str]:
    """ASCII-lowercase runs of [a-z0-9]; every other character separates."""
    lowered = "".join(c.lower() if c.isascii() else " " for c in text)
    return _WORD_RE.findall(lowered)


@dataclass
class Page:
    trade: str
    what: str
    phrases: list[list[str]]
    providers: list[tuple[str, str, str, str]]
    pick_kind: str
    pick_name: str
    pick_why: str
    avoid: list[tuple[str, str, str]]
    cue: str
    pin: str = ""
    when_text: list[str] = field(default_factory=list)
    also: list[tuple[str, str]] = field(default_factory=list)


def _split(value: str, parts: int, key: str) -> list[str]:
    got = [p.strip(_PAD) for p in value.split("|", parts - 1)]
    if len(got) != parts:
        raise PageError(f"{key}: needs {parts} fields separated by |")
    return got


def parse(data: bytes) -> Page:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise PageError(f"page is not valid UTF-8: {e.reason}") from None
    if text.startswith("\ufeff"):
        text = text[1:]
    # Split on "\n" only: str.splitlines() also splits on control characters,
    # which would let a hidden one end the header early.
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    seen: dict[str, str] = {}
    when_text: list[str] = []
    providers: list[tuple[str, str, str, str]] = []
    avoid: list[tuple[str, str, str]] = []
    picks: list[tuple[str, str, str]] = []
    also: list[tuple[str, str]] = []
    for raw in lines:
        line = raw.rstrip(_PAD)
        if line == "---":
            break
        if not line.strip(_PAD):
            continue
        key, sep, value = line.partition(":")
        key, value = key.strip(_PAD), value.strip(_PAD)
        if not sep or key not in _KEYS:
            raise PageError(f"unknown or malformed line: {line[:40]!r}")
        if key in _SINGLE + _OPTIONAL_SINGLE:
            if key in seen:
                raise PageError(f"{key}: given more than once")
            seen[key] = value
        elif key == "when":
            when_text.append(value)
        elif key == "provider":
            k, n, src, prov = _split(value, 4, key)
            providers.append((k, n, src, prov))
        elif key == "also":
            path, pin = _split(value, 2, key)
            also.append((path, pin))
        elif key == "pick":
            k, n, why = _split(value, 3, key)
            picks.append((k, n, why))
        else:
            n, why, prov = _split(value, 3, key)
            avoid.append((n, why, prov))
    for key in _SINGLE:
        if key not in seen:
            raise PageError(f"{key}: missing")
    if len(picks) != 1:
        raise PageError("pick: needs exactly one")
    kind, name, why = picks[0]
    if kind not in _KINDS:
        raise PageError(f"pick: kind {kind!r} is not one of {', '.join(_KINDS)}")
    return Page(seen["trade"], seen["what"], [words(w) for w in when_text], providers,
                kind, name, why, avoid, seen["cue"], seen.get("pin", ""), when_text, also)


def render_cue(page: Page) -> str:
    return (f"**Maude:** I know who handles that: {page.trade} -> "
            f"{page.pick_name} ({page.pick_kind}). {page.cue}")


def _not_printable_ascii(text: str) -> bool:
    """Allowlist, not a denylist: invisible and look-alike characters cannot be enumerated."""
    return any(not 0x20 <= ord(c) <= 0x7E for c in text)


def _text_fields(page: Page) -> list[tuple[str, str]]:
    """Every free-text value on the page, labelled for error messages."""
    out = [("trade", page.trade), ("what", page.what), ("cue", page.cue), ("pin", page.pin),
           ("pick kind", page.pick_kind), ("pick name", page.pick_name), ("pick why", page.pick_why)]
    out += [("when", w) for w in page.when_text]
    out += [("provider", part) for prov in page.providers for part in prov]
    out += [("also", part) for pair in page.also for part in pair]
    out += [("avoid", part) for av in page.avoid for part in av]
    return out


def validate(page: Page) -> list[str]:
    """Reasons the page cannot be approved; empty means approvable."""
    errs: list[str] = []
    if not page.phrases:
        errs.append("when: needs at least one phrase")
    for ph in page.phrases:
        if not _WORDS_MIN <= len(ph) <= _WORDS_MAX:
            errs.append(f"when: a phrase must be {_WORDS_MIN} to {_WORDS_MAX} words, got {len(ph)}")
    for label, value in _text_fields(page):
        if _not_printable_ascii(value):
            errs.append(f"{label}: must be printable ASCII only (control or invisible character)")
    for label, value in (("trade", page.trade), ("cue", page.cue), ("pick name", page.pick_name)):
        if not value:
            errs.append(f"{label}: is empty")
    if page.pick_name == "-" and page.pick_kind != "own":
        errs.append("pick name: is empty ('-' is only for own)")
    if page.pick_kind == "recipe":
        if not _PIN_RE.fullmatch(page.pin):
            errs.append("pin: a recipe needs a sha256 pin of exactly 64 lowercase hex characters")
        if not page.pick_name.startswith(("/", "~/")):
            errs.append("path: a recipe's name must be a path starting with / or ~/")
    elif page.pin:
        errs.append("pin: only a recipe may carry a pin")
    if page.also and page.pick_kind != "recipe":
        errs.append("also: only a recipe may name companion files")
    for path, pin in page.also:
        if not path.startswith(("/", "~/")):
            errs.append("path: an also file must be a path starting with / or ~/")
        if not _PIN_RE.fullmatch(pin):
            errs.append("pin: an also file needs a sha256 pin of exactly 64 lowercase hex characters")
    if page.pick_kind in _NEEDS_PROVIDER and not any(
            p[0] == page.pick_kind and p[1] == page.pick_name for p in page.providers):
        errs.append(f"provider: a {page.pick_kind} pick needs a provider line naming the same kind and name")
    if len(page.cue.encode("utf-8")) > _CUE_LINE_MAX:
        errs.append(f"cue: longer than {_CUE_LINE_MAX} bytes")
    if len(render_cue(page).encode("utf-8")) > _RENDERED_MAX:
        errs.append(f"rendered cue: longer than {_RENDERED_MAX} bytes")
    return errs
