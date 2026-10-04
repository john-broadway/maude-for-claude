#!/usr/bin/env bash
# tests/test-no-maintainer-name.sh — what Maude says must fit ANY user's house.
#
# A user on their own machine got a RED-gate refusal that told them to ask the
# maintainer, by first name. The plugin is public: whoever installed it IS the
# account owner, so every line that reaches a user's screen (hook output) or
# Claude's prompt (commands/agents/skills, CLI usage text) must say "the account
# owner" / "the user", never a person's name. Comments and CHANGELOG history may
# keep attribution; they reach no one at runtime.
#
# The scanned surface:
#   - hooks/scripts/*.sh and scripts/*.sh, every line that is not a comment
#   - commands/ agents/ skills/ markdown, minus the Authors attribution line
#   - the module docstring of every maude_*/__main__.py (printed as usage text)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

NAME_RE='John'   # whole word via grep -w; -P is absent on stock macOS grep

# Print file:line for every user-facing line naming the maintainer, under a root.
scan() {
  local root="$1" f
  for f in "$root"/hooks/scripts/*.sh "$root"/scripts/*.sh; do
    [ -f "$f" ] || continue
    grep -nwE "$NAME_RE" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done
  for f in "$root"/commands/*.md "$root"/agents/*.md "$root"/skills/*.md "$root"/skills/*/*.md; do
    [ -f "$f" ] || continue
    grep -nwE "$NAME_RE" "$f" | grep -v 'Authors:' | sed "s|^|$f:|"
  done
  for f in "$root"/maude_*/__main__.py; do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PY'
import ast, re, sys
doc = ast.get_docstring(ast.parse(open(sys.argv[1]).read())) or ""
for i, line in enumerate(doc.splitlines(), 1):
    if re.search(r"\bJohn\b", line):
        print(f"{sys.argv[1]}:doc{i}:{line}")
PY
  done
}

# Control: a planted leak in each surface MUST be caught, or the scan proves nothing.
CTRL="$(mktemp -d "${TMPDIR:-/tmp}/maude-name-ctrl.XXXXXX")"
mkdir -p "$CTRL/hooks/scripts" "$CTRL/commands" "$CTRL/maude_x"
printf '#!/bin/bash\n# John may appear in a comment\necho "ask John"\n' > "$CTRL/hooks/scripts/a.sh"
printf 'present John this line\n' > "$CTRL/commands/c.md"
printf '"""Usage: runs in John'"'"'s shell."""\n' > "$CTRL/maude_x/__main__.py"

test_start "control: a planted name is caught on every surface"
HITS="$(scan "$CTRL")"
assert_eq "$(printf '%s\n' "$HITS" | grep -c .)" "3" "three planted leaks, three hits"

test_start "control: a name inside a comment is not flagged"
assert_not_contains "$HITS" "comment" "comment line left alone"
rm -rf "$CTRL"

test_start "no user-facing line in the plugin names the maintainer"
HITS="$(scan "$ROOT")"
if [ -z "$HITS" ]; then _pass; else _fail "maintainer name in user-facing text:
$HITS"; fi

print_summary
exit "$FAILED"
