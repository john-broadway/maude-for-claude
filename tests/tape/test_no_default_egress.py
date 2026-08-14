"""The no-default-egress tripwire. Private & sovereign:
corpus and profile never leave the house, and nothing in this package or its hooks
reaches a network endpoint BY DEFAULT. The plugin ships exactly two BYO sockets —
judge.py and embedder.py — and both refuse to build without an explicit url or env
var (no default endpoint). Every other module, and every hook script, must import or
call none of the machinery that could open one.

The scanners below are plain functions over a root PATH, never hardcoded to the real
package/hooks dir. That is what lets the "teeth" tests plant a violation in a
throwaway temp tree and prove the scanner actually flags it, without ever touching
real source — a gate you never saw refuse is not yet a gate.

DOCUMENTED RESIDUAL (lens 1, 2026-08-13): the AST scan sees literal import statements
only — importlib.import_module("url" + "lib"), __import__, exec-built strings walk
past it. In scope here is the ACCIDENTAL import in good-faith code, which review can
see; a contributor determined to hide egress defeats any static scan, and pretending
otherwise would be a guard that answers the easy question.
"""
from __future__ import annotations

import ast
import pathlib
import re
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from maude_tape.embedder import ENV_URL as EMBED_ENV_URL
from maude_tape.embedder import http_embedder
from maude_tape.judge import ENV_URL as JUDGE_ENV_URL
from maude_tape.judge import http_judge

# The plugin's two declared, documented BYO sockets. Nothing else in maude_tape may
# import network machinery — see the module docstrings on judge.py / embedder.py.
ALLOWED_NETWORK_FILES = {"judge.py", "embedder.py"}

# Root import names that mean "this module can open a socket." Matched on the
# import's TOP-LEVEL name only, so `import urllib.request` and
# `from urllib.request import urlopen` are both caught by the "urllib" root.
_NETWORK_ROOTS = {"urllib", "http", "socket", "requests", "httpx", "aiohttp"}


def find_network_imports(pkg_root: pathlib.Path) -> dict[str, list[str]]:
    """Walk every *.py under pkg_root; return {relative_path: [imported_module, ...]}
    for files importing anything shaped like network machinery.

    A plain function over a path, never hardcoded to the real maude_tape package —
    see test_scanner_flags_a_planted_import_violation below for why that matters.
    """
    hits: dict[str, list[str]] = {}
    for path in sorted(pkg_root.rglob("*.py")):
        try:
            src = path.read_text(encoding="utf-8")
        except OSError:
            continue
        try:
            tree = ast.parse(src, filename=str(path))
        except SyntaxError:
            continue
        found: list[str] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name.split(".")[0] in _NETWORK_ROOTS:
                        found.append(alias.name)
            elif isinstance(node, ast.ImportFrom):
                mod = node.module or ""
                if mod.split(".")[0] in _NETWORK_ROOTS:
                    found.append(mod)
        if found:
            hits[str(path.relative_to(pkg_root))] = found
    return hits


# ─── shell-script scan (hooks/scripts/*.sh) ─────────────────────────────────────
# "curl/wget/nc at start-of-word" — a network COMMAND, not a mid-identifier
# substring ("sync", "func", "wgethost" never match).
_NET_CMD_RE = re.compile(r"(?<![\w.-])(curl|wget|nc)(?![\w-])")


def find_shell_network_commands(scripts_dir: pathlib.Path) -> dict[str, list[tuple[int, str]]]:
    """Walk every *.sh directly under scripts_dir; return {filename: [(line_no, cmd), ...]}
    for curl/wget/nc appearing at start-of-word on a non-comment line.

    Grep-style, not shell-semantics-aware, by design: a
    whole-line comment is skipped, an inline trailing comment is not specially
    stripped, and a command inside a quoted string is still a hit — the caller
    decides what to do with a hit, this function only finds them.
    """
    hits: dict[str, list[tuple[int, str]]] = {}
    for path in sorted(scripts_dir.glob("*.sh")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        found: list[tuple[int, str]] = []
        for i, line in enumerate(lines, start=1):
            if line.strip().startswith("#"):
                continue
            m = _NET_CMD_RE.search(line)
            if m:
                found.append((i, m.group(1)))
        if found:
            hits[path.name] = found
    return hits


def _line_span(lines: list[str], start_text: str, end_text: str) -> range | None:
    """1-indexed inclusive line range from the first line matching start_text
    (stripped, exact) to the next line matching end_text (stripped, exact) after it.
    None if either boundary isn't found. Used to scope an exception to a NAMED
    function/array literal, never to a whole file.
    """
    start = None
    for i, line in enumerate(lines, start=1):
        if line.strip() == start_text:
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines) + 1):
        if lines[j - 1].strip() == end_text:
            return range(start, j + 1)
    return None


# Pre-existing, DOCUMENTED exceptions — not something the voice feature adds or is
# asked to close, and NOT a whole-file exemption (a new curl/wget/nc call added
# anywhere else in either file still goes RED — see the span teeth test below):
#   - _maude-common.sh: maude_tier2_reachable() — an opt-in, LOOPBACK-ONLY
#     liveness probe (the localhost dotted-quad; not spelled here — the ship
#     rail's leak-audit hunts IP shapes and is never overridden), disclosed in
#     PRIVACY.md, called only by
#     maude-probe-tier1.sh at SessionStart, and killable via MAUDE_PROBE=off.
#     It never leaves the box, which is a different claim than "never runs".
#   - maude-bash-watch.sh: the danger-palette PATTERNS array holds the STRING
#     'curl .*\\| *(bash|sh)' — a regex that DETECTS a curl-pipe-shell in a
#     watched command. It is text describing a danger, never an invocation.
_KNOWN_SHELL_EXCEPTIONS: dict[str, tuple[str, str]] = {
    "_maude-common.sh": ("maude_tier2_reachable() {", "}"),
    "maude-bash-watch.sh": ("PATTERNS=(", ")"),
}


def _unexplained_shell_hits(scripts_dir: pathlib.Path) -> dict[str, list[tuple[int, str]]]:
    """find_shell_network_commands, minus hits that fall inside a known, scoped
    exception's line span. What's left is genuinely unexplained.
    """
    raw = find_shell_network_commands(scripts_dir)
    unexplained: dict[str, list[tuple[int, str]]] = {}
    for fname, fhits in raw.items():
        span = None
        if fname in _KNOWN_SHELL_EXCEPTIONS:
            start_text, end_text = _KNOWN_SHELL_EXCEPTIONS[fname]
            lines = (scripts_dir / fname).read_text(encoding="utf-8").splitlines()
            span = _line_span(lines, start_text, end_text)
        remaining = [h for h in fhits if not (span and h[0] in span)]
        if remaining:
            unexplained[fname] = remaining
    return unexplained


# ── the real package / hooks dir ─────────────────────────────────────────────────

def test_only_the_two_byo_sockets_import_network_machinery():
    hits = find_network_imports(ROOT / "maude_tape")
    assert set(hits) <= ALLOWED_NETWORK_FILES, (
        f"unexpected network-machinery import outside judge.py/embedder.py: {hits}"
    )
    # Sanity the scanner isn't vacuously passing: the two BYO sockets DO import
    # urllib, so a scanner that finds nothing at all would be lying about "clean".
    assert "judge.py" in hits and "embedder.py" in hits


def test_judge_refuses_to_build_without_an_endpoint(monkeypatch):
    monkeypatch.delenv(JUDGE_ENV_URL, raising=False)
    with pytest.raises(ValueError):
        http_judge()


def test_embedder_refuses_to_build_without_an_endpoint(monkeypatch):
    monkeypatch.delenv(EMBED_ENV_URL, raising=False)
    with pytest.raises(ValueError):
        http_embedder()


def test_hook_scripts_have_no_unexplained_network_commands():
    unexplained = _unexplained_shell_hits(ROOT / "hooks" / "scripts")
    assert unexplained == {}, f"unexplained curl/wget/nc in hooks/scripts: {unexplained}"


def test_known_shell_exceptions_still_shaped_as_documented():
    # If these ever go empty, either the exception was removed (tighten the
    # allowlist) or its shape changed underneath the span match (the exemption
    # would silently stop covering it, and the test above would go RED first —
    # this test exists so THAT failure reads as "the allowlist rotted", not as
    # a mystery). Not a live-egress assertion; a shape assertion.
    raw = find_shell_network_commands(ROOT / "hooks" / "scripts")
    assert raw.get("_maude-common.sh"), "expected the tier2-probe curl/nc calls to still be there"
    assert raw.get("maude-bash-watch.sh"), "expected the curl-pipe-shell detection string to still be there"


# ── THE TEETH: the scanners must be SEEN to refuse, on planted violations ────────

def test_scanner_flags_a_planted_import_violation(tmp_path):
    pkg = tmp_path / "fake_pkg"
    pkg.mkdir()
    (pkg / "clean.py").write_text("import json\nimport re\n", encoding="utf-8")
    (pkg / "leaky.py").write_text("import urllib.request\n\ndef f():\n    pass\n", encoding="utf-8")

    hits = find_network_imports(pkg)

    assert "leaky.py" in hits
    assert any(name.startswith("urllib") for name in hits["leaky.py"])
    assert "clean.py" not in hits


def test_scanner_ignores_relative_imports_shaped_like_network_roots(tmp_path):
    # A relative import whose target happens to share a name with a network root
    # (e.g. `from .http_helpers import x`) must not false-positive: ast reports
    # the module as "http_helpers", whose split(".")[0] is "http_helpers", not
    # the root "http" — proven here so the allowlist never gets loosened by a
    # false alarm nobody could explain.
    pkg = tmp_path / "fake_pkg2"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("", encoding="utf-8")
    (pkg / "helper.py").write_text("from .http_helpers import x\n", encoding="utf-8")
    (pkg / "http_helpers.py").write_text("x = 1\n", encoding="utf-8")

    hits = find_network_imports(pkg)
    assert hits == {}


def test_scanner_flags_a_planted_violation_elsewhere_in_an_exempted_file(tmp_path):
    # The span exemption is scoped to a NAMED function, not the whole file: a new
    # curl call added ANYWHERE ELSE in _maude-common.sh must still go RED. Proven
    # against a throwaway copy so this never touches the real shared lib.
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    planted = scripts / "_maude-common.sh"
    planted.write_text(
        "#!/usr/bin/env bash\n"
        "maude_tier2_reachable() {\n"
        "  curl -fsS --max-time 2 -o /dev/null \"$1\" 2>/dev/null\n"
        "}\n"
        "\n"
        "maude_some_new_helper() {\n"
        '  curl -fsS "https://not-sanctioned.example/x"\n'  # the planted violation
        "}\n",
        encoding="utf-8",
    )

    unexplained = _unexplained_shell_hits(scripts)

    assert "_maude-common.sh" in unexplained
    lines_hit = [ln for ln, _cmd in unexplained["_maude-common.sh"]]
    assert 7 in lines_hit  # the curl inside maude_some_new_helper, not line 3


def test_shell_scanner_flags_a_planted_network_command(tmp_path):
    scripts = tmp_path / "scripts2"
    scripts.mkdir()
    (scripts / "clean.sh").write_text(
        "#!/usr/bin/env bash\n"
        "# curl is mentioned here only in a comment, never called\n"
        "echo hello\n",
        encoding="utf-8",
    )
    (scripts / "leaky.sh").write_text(
        "#!/usr/bin/env bash\n"
        "curl -s https://example.invalid/exfil\n",
        encoding="utf-8",
    )

    hits = find_shell_network_commands(scripts)

    assert "leaky.sh" in hits
    assert hits["leaky.sh"] == [(2, "curl")]
    assert "clean.sh" not in hits  # the comment-only mention is not a call
