"""maude_redact, in python: the same masks as `_maude-common.sh`, line by line as sed runs them.

The shell function is the reference (tests/recall/test_redact.py holds the two to the same
output on its fixtures and on generated edge cases). Rules, in sed's order, on each line:
URL credentials, known secret prefixes, JWTs, bounded-octet IPv4 (a trailing dot is an edge
when no digit follows; twice, as the shell does:
one pass cannot re-match an adjacent quad whose leading edge the previous match consumed),
then a private-key block: from a BEGIN … PRIVATE KEY line through its END line, the BEGIN
line becomes [redacted-key] and the rest is dropped; with no END line it runs to the end.
Shape-only and fail-closed: a four-part version number with valid octets is masked too.
Where the two cannot agree, python masks more: its space class is ASCII only, so a URL whose
user or password holds U+2028 or U+3000 is masked here and left whole by the shell under a
UTF-8 locale (the shell's residual, named in the test).
"""
from __future__ import annotations

import re

_OCTET = r"(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])"
_IP = rf"(?:{_OCTET}\.){{3}}{_OCTET}"
_SUBS = (
    # sed's [:space:] is narrower than python's \s (which takes \x1c-\x1f, \x85, \xa0, …):
    # spelled out, so the negated class masks at least what the shell masks (lens 3)
    (re.compile(r"(https?://)[^/:@ \t\n\r\f\v]+:[^/@ \t\n\r\f\v]+@"), r"\1[redacted-creds]@"),
    (re.compile(r"(?:sk-|ghp_|gho_|ghu_|ghs_|github_pat_|xox[abprs]-|AKIA|AIza)[A-Za-z0-9_-]{8,}"),
     "[redacted-secret]"),
    (re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"), "[redacted-jwt]"),
    (re.compile(rf"(^|[^0-9.]){_IP}($|[^0-9.]|\.$|\.[^0-9])"), r"\1[redacted-ip]\2"),
    (re.compile(rf"(^|[^0-9.]){_IP}($|[^0-9.]|\.$|\.[^0-9])"), r"\1[redacted-ip]\2"),
)
_BEGIN = re.compile(r"-----BEGIN[A-Z ]*PRIVATE KEY-----")
_END = re.compile(r"-----END[A-Z ]*PRIVATE KEY-----")


def redact(text: str) -> str:
    out = []
    in_key = False
    lines = text.split("\n")  # sed splits on newline only, never \r, \x0b, \x1c, \x85
    last_nl = lines[-1] == ""  # the text ended with a newline (or was empty)
    if last_nl:
        lines.pop()
    for n, body in enumerate(lines):
        nl = "\n" if (n < len(lines) - 1 or last_nl) else ""
        for rx, rep in _SUBS:
            body = rx.sub(rep, body)
        if not in_key and _BEGIN.search(body):
            # sed's range: the BEGIN line opens it; a range whose END sits on the same
            # line still spans to the NEXT END line (sed checks the end only on later lines)
            in_key = True
            out.append("[redacted-key]" + nl)
            continue
        if in_key:
            if _END.search(body):
                in_key = False
            if "-----BEGIN" in body:  # sed's `/-----BEGIN/!d` spares ANY such line in the range
                out.append("[redacted-key]" + nl)
            continue
        out.append(body + nl)
    return "".join(out)
