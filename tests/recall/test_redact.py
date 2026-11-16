"""maude_recall.redact against the shell's maude_redact: the same output, byte for byte.

The shell function in hooks/scripts/_maude-common.sh is the reference. Every secret-shaped
string is assembled from parts at run time, so no scanner-shaped literal is committed.
"""
from __future__ import annotations

import pathlib
import random
import shutil
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from maude_recall.redact import redact

COMMON = ROOT / "hooks" / "scripts" / "_maude-common.sh"


def j(*parts):
    return "".join(parts)


def shell(text: str) -> str:
    return subprocess.run(["bash", "-c", f'. "{COMMON}" >/dev/null 2>&1; maude_redact'],
                          input=text.encode(), capture_output=True, check=True).stdout.decode()


needs_shell = pytest.mark.skipif(not shutil.which("bash") or not shutil.which("sed"), reason="no bash/sed")

TAIL = "abcdefgh12345678ABCDEF"
SK = j("sk", "-", TAIL)
BEGIN = lambda kind: j("-----", "BEGIN ", kind, "PRIVATE", " KEY-----")
END = lambda kind: j("-----", "END ", kind, "PRIVATE", " KEY-----")
CASES = [
    j("key ", SK, " end"),
    j("t ", "github", "_pat_", TAIL, " end"),
    j("t ", "xo", "xb-", TAIL, " end"),
    j("id ", "AK", "IA", "ABCDEFGH12345678IJKL", " end"),
    j("k ", "AI", "za", TAIL, " end"),
    j("tok ", "ey", "J", "abcDEF123.", "ey", "Jpayload456.sigGHI789 end"),
    "just a normal sentence about keys and tokens",
    "built ledger at 192.0.2.71",
    "Chrome version 120.0.6099.109",
    "Windows 10.0.19045.3803",
    j("two quads 10.0.", "0.1 10.0.", "0.2 and 1.2.", "3.4,5.6.", "7.8"),   # assembled: private-shaped quads are the subject
    j("edge 10.0.", "0.1.5 and v1.2.", "3.4 and 255.255.", "255.255 and 256.1.", "1.1"),
    j("https://", "user", ":", "pa55", "@", "example.com/x and http://", "a", ":", "b", "@", "h"),
    "no newline at the end 192.0.2.9",
    "a sentence ends at 192.0.2.71. Then more.",
    j("note\r", BEGIN(""), "\rMIIsecret\r", END(""), "\rafter\nnext line\n"),
    j("keep this\u2028", BEGIN(""), "\nbody\n", END(""), "\n"),
    j(END(""), "\x0bTRAILING"),
    j("x\n", BEGIN(""), "\nbody"),
    j("at 192.0.2.71.\nand 10.0.", "0.1.5 stays and 1.2.", "3.4.b goes"),
    j("a\n", BEGIN("RSA "), "\nMIIabc\nxyz\n", END("RSA "), "\nafter\n"),
    j(BEGIN(""), "\nnever ends\nstill key\n"),
    j("x ", BEGIN("EC "), " y\nz\n", END("EC "), "\nkept\n"),
    j(BEGIN(""), " ", END(""), "\nstill inside\n", END(""), "\nout\n"),
    "",
    "\n\n",
    "unicode ünïcödé 192.0.2.1 and tabs\t" "203.0.113.9\n",
]


@needs_shell
@pytest.mark.parametrize("text", CASES)
def test_matches_the_shell(text):
    assert redact(text) == shell(text)


def shell_each(texts, locale):
    """maude_redact on each text separately, in one bash: NUL between records, so a key
    block left open in one text can never swallow the next (lens 3)."""
    import os
    script = (f'. "{COMMON}" >/dev/null 2>&1; '
              "while IFS= read -r -d '' rec; do printf '%s' \"$rec\" | maude_redact; printf '\\0'; done")
    env = dict(os.environ, LC_ALL=locale)
    out = subprocess.run(["bash", "-c", script], input="\0".join(texts).encode() + b"\0",
                         capture_output=True, check=True, env=env).stdout.decode()
    return out.split("\0")[:-1]


PIECES = ["1", "25", "255", "256", "0", ".", ".", " ", "a", "x", ":", "@", "/", "\n", "-",
          "http://", "https://", j("ey", "J"), j("sk", "-"), j("AK", "IA"), "_", "Z9",
          BEGIN(""), END(""), "\t", "v", "\r", "\x0b", "\x0c", "\x1c", "\x1f", "\x85", "\xa0",
          "\u2028", "\u3000", "\u0660"]


@needs_shell
@pytest.mark.parametrize("locale", ["C.UTF-8", "C"])
def test_matches_the_shell_on_generated_text(locale):
    rng = random.Random(1971)
    texts = ["".join(rng.choice(PIECES) for _ in range(rng.randint(1, 40))) for _ in range(3000)]
    got = shell_each(texts, locale)
    assert len(got) == len(texts)
    bad = [(t, r, g) for t, r, g in zip(texts, map(redact, texts), got) if r != g]
    assert not bad, bad[:3]


@needs_shell
@pytest.mark.parametrize("space", ["\x1c", "\x1f", "\x85", "\xa0", "\u2028", "\u3000"])
def test_odd_spaces_inside_url_credentials_are_masked(space):
    text = j("http://us", space, "er:pw", "123@h")
    assert "[redacted-creds]" in redact(text)  # python's class is ASCII-space only: it always masks
    shell_out = shell_each([text], "C.UTF-8")[0]
    if space in ("\u2028", "\u3000"):
        # Named residual of the SHELL: under a UTF-8 locale sed's [:space:] takes these two, so
        # maude_redact leaves such a URL whole. Python masks more, never less.
        assert shell_out == text
    else:
        assert redact(text) == shell_out


def test_masks_without_the_shell():
    assert "[redacted-secret]" in redact(j("key ", SK, " end")) and SK not in redact(j("key ", SK, " end"))
    assert redact("at 192.0.2.71\n") == "at [redacted-ip]\n"
    assert redact("Chrome 120.0.6099.109") == "Chrome 120.0.6099.109"
