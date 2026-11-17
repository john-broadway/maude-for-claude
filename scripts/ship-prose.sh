#!/usr/bin/env bash
# ship-prose.sh: the leak shapes that are only leaks in PROSE, shared by ship.sh's audit and
# tests/test-ship-prose-calibration.sh. Sourced; defines one function.
#
# Two shapes the house's reviews kept finding in public text (2026-11-16): a memory note's
# file name, and a session id quoted as provenance. Both occur legitimately in code and
# fixtures (a gate that names a lane file, test JSON with a fake id), so they are read only
# in prose: every line of a Markdown file, and the comment lines of shell and python files
# (first non-blank character #). A docstring is not read; a name there is the private
# list's to catch. Patterns are assembled by concatenation so this file can ship itself.

# ship_prose_hits <path>: reads the lines of <path>'s kind from stdin, prints how many are
# prose lines carrying either shape.
ship_prose_hits() {
  local kinds note sess
  kinds='proj'; kinds="${kinds}ect|feed"; kinds="${kinds}back|now|user|refer"; kinds="${kinds}ence"
  note="(^|[^A-Za-z0-9_-])($kinds)_[A-Za-z0-9][A-Za-z0-9_.-]*\\.md|\\[\\[($kinds)_[A-Za-z0-9]"
  note="${note}|letter-from-cl"; note="${note}aude-[0-9]{4}-"
  sess='[Ss]ess'; sess="${sess}ion([_-]?[Ii][Dd])?[[:space:]:=\`'\"(_-]+([A-Za-z]+[[:space:]]+)?[0-9a-fA-F]{8,}([^0-9A-Za-z]|\$)"
  case "$1" in
    *.md) grep -cE "$note|$sess" ;;
    *.sh|*.py|*.bash) grep -E '^[[:space:]]*#' | grep -cE "$note|$sess" ;;
    *) cat >/dev/null; printf '0\n' ;;
  esac
}
