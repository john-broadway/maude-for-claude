#!/usr/bin/env bash
# SessionStart: (re)build Maude's memory vault. Silent + non-blocking.
#
# Rebuilds the SQLite/FTS5 vault (maude_vault/) from the auto-memory dir every
# session so maude-page.sh (UserPromptSubmit) always pages against fresh
# notes. Pure python3 stdlib underneath — no pip install, no daemon. Wipe +
# reinsert (see maude_vault.ingest.build); the DB is fully disposable at
# <project>/.maude/plugin/vault.db (already gitignored).
#
# Degrades silently: missing python3 or missing mem dir -> exit 0, no output.
# Never blocks a session on a build failure (maude_vault's own errors are
# swallowed too — a broken build just means paging returns no hits).
set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

command -v python3 >/dev/null 2>&1 || exit 0

MEM="$(maude_mem_dir)"
[ -d "$MEM" ] || exit 0

DB="$(maude_project_dir)/.maude/plugin/vault.db"
mkdir -p "$(dirname "$DB")" 2>/dev/null

PYTHONPATH="$CLAUDE_PLUGIN_ROOT" python3 -m maude_vault build \
  --mem-dir "$MEM" --db "$DB" >/dev/null 2>&1
exit 0
