#!/usr/bin/env bash
# Maude rules — print a rulebook as a naming checklist, run the schema linter, or say which
# classes this session touched and never named. Report-first; writes nothing.
#
# Usage: maude-rules.sh ux|db|memory        the checklist, with twins in the other seats by family
#        maude-rules.sh db PATH...          the linter over PATH... (findings and asks); exit 1 on findings
#        maude-rules.sh                     this session's touched / unnamed classes from care.json

set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
COMMON="$ROOT/hooks/scripts/_maude-common.sh"
# shellcheck disable=SC1090
[ -f "$COMMON" ] && . "$COMMON"
RULES_DIR="${MAUDE_RULES_DIR:-$ROOT/rules}"

usage() { printf 'usage: maude-rules.sh ux|db|memory [PATH...]\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'maude-rules: jq is required\n' >&2; exit 2; }

book_for() { case "$1" in ux) printf 'laws-of-ux.json' ;; db) printf 'codd-and-normal-forms.json' ;; memory) printf 'laws-of-memory.json' ;; *) return 1 ;; esac; }

# family -> "seat: name" lines across all three books, for the twin line.
twins_for() {  # $1 family, $2 own class
  jq -r --arg fam "$1" --arg own "$2" -s '
    [.[] | .class as $c | .laws[] | select(.family == $fam and $c != $own) | "\($c): \(.name)"] | join(", ")' \
    "$RULES_DIR"/laws-of-ux.json "$RULES_DIR"/codd-and-normal-forms.json "$RULES_DIR"/laws-of-memory.json 2>/dev/null
}

print_book() {
  local book status class
  book="$RULES_DIR/$(book_for "$1")"
  [ -f "$book" ] || { printf 'maude-rules: missing %s\n' "$book" >&2; exit 2; }
  status="$(jq -r '.status // "canon"' "$book")"
  class="$(jq -r .class "$book")"
  printf '%s (%s laws, read %s)\n' "$(jq -r .name "$book")" "$(jq '.laws | length' "$book")" "$(jq -r .read_on "$book")"
  [ "$status" = "draft" ] && printf 'DRAFT: not canon until John cuts it. Name from it anyway; say it is the draft.\n'
  printf '\n'
  jq -r '.laws[] | "\(.name)\t\(.family)\t\(.ask)"' "$book" | while IFS="$(printf '\t')" read -r name fam ask; do
    printf -- '- %s [%s]: %s\n' "$name" "$fam" "$ask"
    tw="$(twins_for "$fam" "$class")"
    if [ -n "$tw" ]; then printf '    same law elsewhere: %s\n' "$tw"; fi
  done
}

lint_paths() {
  # An EXECUTE probe, not a presence test: the Windows Store alias stub and a macOS
  # without Command Line Tools both answer a presence test and then die at the call.
  maude_python3_ok || { printf 'maude-rules: python3 is missing or not working; the linter needs it\n' >&2; exit 2; }
  local out rc n
  # PYTHONSAFEPATH=1 (python 3.11+) drops the implicit CWD entry `python3 -m` would
  # otherwise put AHEAD of PYTHONPATH, so a project carrying its own maude_rules/ is
  # never the linter this runs. The rail and verify also move the interpreter to the
  # plugin root; this one cannot, because the paths here are the ones the user typed
  # and they are relative to the directory they typed them in.
  out="$(PYTHONSAFEPATH=1 PYTHONPATH="$ROOT" python3 -m maude_rules schema --asks "$@" 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -v ': ask: ' | grep -vc ': unreadable$')"
  [ -z "$out" ] && n=0
  printf '%s finding(s)\n' "$n"
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

session_report() {
  local care sid out
  care="$(maude_self_dir 2>/dev/null)/care.json"
  [ -f "$care" ] || { printf 'no care.json at %s\n' "$care"; return 0; }
  sid="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | cut -c1-8)"
  # A report that prints nothing cannot be told apart from a report that failed to run.
  out="$(jq -r --arg sid "$sid" '
    (.rules // {}) | to_entries[] | select($sid == "" or .key == $sid) | .key as $s | .value as $v
    | (["ui","schema","memory"][] | . as $c
       | ($v.touched[$c] // [] | length) as $n
       | select($n > 0)
       | if ($v.named[$c].ts // "") != "" then "\($s) \($c): named in \($v.named[$c].file) (\($v.named[$c].laws | join(", ")))"
         else "\($s) \($c): \($n) file(s) touched, no law named" end)' "$care" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf 'no class touched this session\n'; fi
}

case "${1:-}" in
  "") session_report ;;
  ux|memory) [ $# -eq 1 ] || usage; print_book "$1" ;;
  db) if [ $# -eq 1 ]; then print_book db; else shift; lint_paths "$@"; fi ;;
  *) usage ;;
esac
