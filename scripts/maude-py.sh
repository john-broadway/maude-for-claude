#!/usr/bin/env bash
# maude-py.sh <package> [args...]: run one of the plugin's python packages
# (maude_tape, maude_marker, ...) from any directory.
#
# Finds the plugin root from its own real location (it may be run through a
# symlink), then starts python3 in isolated mode (-I: the working directory and
# PYTHONPATH are left off sys.path) with the plugin root put first by name. The
# working directory is often a cloned project, and nothing is imported from it.
# The same launch the hooks use (MAUDE_PY_BOOT in hooks/scripts/_maude-common.sh).
#
# With no working python3 it prints a signed message and exits 3.
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

case "${1:-}" in
  maude_[a-z]*) ;;
  *) printf '%s\n' "**Maude:** maude-py.sh runs one of her packages: maude-py.sh maude_<name> [args]" >&2; exit 2 ;;
esac
if [ ! -d "$ROOT/$1" ]; then
  printf '%s\n' "**Maude:** no package $1 under $ROOT" >&2
  exit 2
fi
if ! python3 -I -c 'pass' >/dev/null 2>&1; then
  printf '%s\n' '**Maude:** this needs python3, and this house has none that runs.' >&2
  exit 3
fi

exec python3 -I -c 'import os, sys
if not os.path.isabs(sys.argv[1]):
    sys.exit("maude: the plugin root must be an absolute path")
sys.path.insert(0, sys.argv[1])
import runpy
mod = sys.argv[2]
sys.argv = [mod] + sys.argv[3:]
runpy.run_module(mod, run_name="__main__", alter_sys=True)' "$ROOT" "$@"
