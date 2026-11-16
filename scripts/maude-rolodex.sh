#!/usr/bin/env bash
# maude-rolodex.sh <verb> [args]: the Rolodex CLI (index, show, approve, revoke, live).
#
# Finds the plugin root from its own real location (it may be run through a
# symlink), then starts maude_rolodex through scripts/maude-py.sh, the plugin's
# one launcher: nothing is imported from the directory it is run in, which is
# often a cloned project. With no working python3 it prints a signed message
# and exits 3.
src="${BASH_SOURCE[0]}"
hops=0
while [ -L "$src" ] && [ "$hops" -lt 40 ]; do
  link="$(readlink "$src" 2>/dev/null)"
  [ -n "$link" ] || break
  case "$link" in
    /*) src="$link" ;;
    *) case "$src" in */*) src="${src%/*}/$link" ;; *) src="$link" ;; esac ;;
  esac
  hops=$((hops + 1))
done
case "$src" in */*) dir="${src%/*}" ;; *) dir="." ;; esac
ROOT="$(cd "$dir/.." 2>/dev/null && pwd)"

if ! python3 -I -c 'pass' >/dev/null 2>&1; then
  printf '%s\n' '**Maude:** the Rolodex needs python3, and this house has none that runs.' >&2
  exit 3
fi

exec "${BASH:-bash}" "$ROOT/scripts/maude-py.sh" maude_rolodex "$@"
