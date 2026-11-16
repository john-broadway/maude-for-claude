"""Print file:line for every shipped python launch that can import from the cwd.

Used by tests/test-safe-launch.sh: python3 -I tests/launch_guard.py <plugin root>

Shell-like files (hooks, scripts, commands, agents, skills, hooks.json): an interpreter
word (python, python3, python3.N, $PY) used as a command whose first argument is an
option other than -I (-m, -c, -S, a bare - for stdin) or a heredoc. Continuation lines
are joined first; comment lines are skipped. In maude_*/*.py: a quoted string that tells
a person to run `python3 -m maude_*` (a printed hint), outside docstring openers and
comments.
"""
import os
import re
import sys

INTERP = re.compile(r'(?<![\w.$-])(?:python3?(?:\.\d+)?|"?\$\{?PY\}?"?)(?=[ \t]|$)')
SKIP_BEFORE = ("command -v", "-v", "which")


def logical_lines(text):
    raw = text.split("\n")
    i = 0
    while i < len(raw):
        start, line = i + 1, raw[i]
        while line.endswith("\\") and i + 1 < len(raw):
            i += 1
            line = line[:-1] + " " + raw[i].lstrip()
        i += 1
        yield start, line


def shell_like(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    for start, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        for m in INTERP.finditer(line):
            before = line[:m.start()].rstrip()
            if before.endswith(SKIP_BEFORE):
                continue
            rest = line[m.end():].split()
            first = rest[0] if rest else ""
            if first == "-I":
                continue
            if first.startswith("-") or first.startswith("<<"):
                yield start
                break


def py_hints(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            k = line.find("python3 -m maude_")
            t = line.strip()
            if k < 0 or t.startswith(("#", '"""', "'''")):
                continue
            if '"' in line[:k] or "'" in line[:k]:
                yield n


def main(root):
    files = []
    for d, ext in (("hooks/scripts", ""), ("scripts", ""), ("commands", ".md"), ("agents", ".md")):
        full = os.path.join(root, d)
        if os.path.isdir(full):
            files += [os.path.join(full, f) for f in sorted(os.listdir(full))
                      if f.endswith(ext) and not f.endswith(".py")
                      and os.path.isfile(os.path.join(full, f))]
    for d, _, fs in sorted(os.walk(os.path.join(root, "skills"))):
        files += [os.path.join(d, f) for f in sorted(fs) if f.endswith((".md", ".sh"))]
    hooks_json = os.path.join(root, "hooks", "hooks.json")
    if os.path.isfile(hooks_json):
        files.append(hooks_json)
    for f in files:
        for n in shell_like(f):
            print(f"{os.path.relpath(f, root)}:{n}")
    for name in sorted(os.listdir(root)):
        pkg = os.path.join(root, name)
        if not (name.startswith("maude_") and os.path.isdir(pkg)):
            continue
        for d, _, fs in sorted(os.walk(pkg)):
            for f in sorted(fs):
                if f.endswith(".py"):
                    for n in py_hints(os.path.join(d, f)):
                        print(f"{os.path.relpath(os.path.join(d, f), root)}:{n}")


if __name__ == "__main__":
    main(sys.argv[1])
