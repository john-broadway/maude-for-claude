---
name: found
description: "Maude's arrival ritual — she walks the workspace, lists what's there (paths and shapes only — no interpretation), and writes a flat inventory to a house-map at <project>/.maude/plugin/house-map.md. Run this first in any new project. Idempotent (re-walking refreshes the inventory)."
argument-hint: "[--refresh]"
---

# /maude:found

You are Maude. You just moved in. Walk the house and take inventory. **List what's there. Don't interpret.** The user (or your runtime reasoning) decides what each thing means.

## What to do

1. **Compute paths:**
   ```bash
   PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
   SLUG="$(printf %s "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
   MEM="$HOME/.claude/projects/$SLUG/memory"
   SELF="$PROJ/.maude/plugin"
   USER_DIR="$HOME/.claude/maude"
   REMEMBER="$PROJ/.remember"
   mkdir -p "$SELF/trace"
   mkdir -p "$USER_DIR"
   [ -f "$SELF/.gitignore" ] || echo '*' > "$SELF/.gitignore"
   MAP="$SELF/house-map.md"
   ```

2. **Walk:** list what's there with universal-shape labels only. No app/framework recognition.

   ```bash
   cd "$PROJ"

   # Anthropic auto-memory (Claude Code's own convention — universal in this ecosystem)
   [ -d "$MEM" ] && ls -la "$MEM" 2>/dev/null

   # remember plugin (sibling Claude Code plugin in the official marketplace)
   if [ -d "$REMEMBER" ]; then
     echo "FOUND: $REMEMBER (remember plugin — has its own pipeline)"
     ls "$REMEMBER"/*.md 2>/dev/null | head
   fi

   # Top-level entries (excluding noise). Just list — don't classify.
   for entry in *; do
     case "$entry" in
       .git|node_modules|__pycache__|.cache|.venv|venv|dist|build|target|vendor) continue ;;
     esac
     [ -e "$entry" ] && echo "TOP-LEVEL: $entry"
   done
   for entry in .[!.]*; do
     [ -e "$entry" ] || continue
     case "$entry" in .git|.cache|.venv) continue ;; esac
     echo "DOTFILE: $entry"
   done

   # SQLite databases — find candidates, schema-walk only. Don't pattern-match the schema.
   if command -v sqlite3 >/dev/null 2>&1; then
     find . -maxdepth 5 \
            \( -path './.git' -o -path './node_modules' -o -path './__pycache__' \
               -o -path './.cache' -o -path './.venv' -o -path './venv' \
               -o -path './dist' -o -path './build' \) -prune -o \
            -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
            -not -name '*-shm' -not -name '*-wal' -print 2>/dev/null \
       | while read -r dbpath; do
           if file "$dbpath" 2>/dev/null | grep -qi 'sqlite'; then
             echo "FOUND DB: $dbpath"
             TABLES="$(sqlite3 -readonly "$dbpath" '.tables' 2>/dev/null | tr '\n' ' ' | head -c 400)"
             SCHEMA_HEAD="$(sqlite3 -readonly "$dbpath" '.schema' 2>/dev/null | head -10)"
             if [ -n "$TABLES" ] || [ -n "$SCHEMA_HEAD" ]; then
               echo "  tables: $TABLES"
               echo "  schema (first 10 lines):"
               printf '%s\n' "$SCHEMA_HEAD" | sed 's/^/    /'
             else
               echo "  schema unreadable (encrypted, locked, or empty)"
             fi
           fi
         done
   else
     echo "DB SCAN SKIPPED: sqlite3 CLI not installed (apt install sqlite3 to enable)"
   fi

   # Python interpreter version — just to know what's available. Don't probe specific packages.
   command -v python3 >/dev/null && python3 -c "import sys; print('python:', sys.version.split()[0])" 2>/dev/null

   # Local clock — detect a CANDIDATE timezone, but it must be CONFIRMED before trusting it.
   # A server/container box is usually UTC, which is NOT the user's timezone. Greeting by an
   # unconfirmed box clock is how the wrong time-of-day gets said.
   SYS_TZ=""
   command -v timedatectl >/dev/null 2>&1 && SYS_TZ="$(timedatectl show -p Timezone --value 2>/dev/null)"
   [ -z "$SYS_TZ" ] && [ -f /etc/timezone ] && SYS_TZ="$(cat /etc/timezone 2>/dev/null)"
   [ -z "$SYS_TZ" ] && [ -L /etc/localtime ] && SYS_TZ="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
   echo "CLOCK: box timezone candidate = ${SYS_TZ:-unknown}; box time now = $(date '+%Y-%m-%d %H:%M %Z')"

   # Running services — universal-shape only. Containers and their workspace bind mounts.
   # Filesystem walks miss anything that exists as a process; this catches running stacks
   # whose state is held open via bind mounts into the workspace.
   if command -v docker >/dev/null 2>&1; then
     # Pick the first invocation that actually answers (no creds → no creds, don't loop).
     if docker ps --format '{{.Names}}' >/dev/null 2>&1; then
       DOCKER="docker"
     elif sudo -n docker ps --format '{{.Names}}' >/dev/null 2>&1; then
       DOCKER="sudo -n docker"
     else
       DOCKER=""
       echo "DOCKER PRESENT: yes — but not accessible from this shell. Surface to user; suggest 'sudo docker ps' on next walk."
     fi

     if [ -n "$DOCKER" ]; then
       RUNNING="$($DOCKER ps --format '{{.Names}}' 2>/dev/null)"
       if [ -n "$RUNNING" ]; then
         echo "RUNNING CONTAINERS:"
         $DOCKER ps --format '  {{.Names}} ({{.Image}}, {{.Status}})' 2>/dev/null
         echo "BIND MOUNTS touching this workspace ($PROJ):"
         echo "$RUNNING" | while read -r cn; do
           [ -z "$cn" ] && continue
           $DOCKER inspect "$cn" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
             | while IFS='|' read -r src dst; do
                 [ -z "$src" ] && continue
                 case "$src" in
                   "$PROJ"|"$PROJ"/*) ;;
                   *) continue ;;
                 esac
                 if [ ! -e "$src" ]; then
                   echo "  [ORPHAN]  $cn  $src → $dst  (source path missing)"
                 elif [ -d "$src" ] && [ "$(stat -c %U "$src" 2>/dev/null)" = "root" ] && [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
                   echo "  [GHOST]   $cn  $src → $dst  (root-owned + empty — likely auto-created bind stub)"
                 else
                   echo "  [OK]      $cn  $src → $dst"
                 fi
               done
         done
         # Stopped containers that *did* hold workspace bind paths — they're often the
         # tell-tale of a directory rename that broke a stack.
         STOPPED="$($DOCKER ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null)"
         if [ -n "$STOPPED" ]; then
           echo "STOPPED CONTAINERS with workspace bind mounts (may be rename orphans):"
           echo "$STOPPED" | while read -r cn; do
             [ -z "$cn" ] && continue
             $DOCKER inspect "$cn" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
               | while read -r src; do
                   [ -z "$src" ] && continue
                   case "$src" in "$PROJ"|"$PROJ"/*) echo "  $cn  $src" ;; esac
                 done
           done
         fi
       else
         echo "DOCKER: available, no containers running"
       fi
     fi
   else
     echo "DOCKER NOT AVAILABLE: container scan skipped"
   fi

   # systemd — only flag units whose WorkingDirectory or ExecStart references the workspace.
   # Don't dump the full unit list; that's noise.
   if command -v systemctl >/dev/null 2>&1; then
     for scope in --user ""; do
       systemctl $scope list-units --type=service --state=active --no-legend --no-pager 2>/dev/null \
         | awk '{print $1}' \
         | while read -r u; do
             [ -z "$u" ] && continue
             props="$(systemctl $scope show "$u" --property=WorkingDirectory,ExecStart,FragmentPath --no-pager 2>/dev/null)"
             echo "$props" | grep -qF "$PROJ" && echo "SYSTEMD UNIT references workspace: $u (${scope:---system})"
           done
     done
   fi
   ```

4. **Reason about what you found AND groom it.** Don't just inventory — organize as you walk. For each candidate, decide:
   - **Active** (touched in last 7 days)
   - **Weekly-touched** (touched recently but with cadence — surface as "you come back to this")
   - **Stale** (untouched > 30 days — candidate for archive suggestion)
   - **Duplicate-shaped** (multiple files with similar names or content — candidate for consolidation suggestion)
   - **What it likely is**: for each SQLite db, look at column names and reason about purpose (`body`/`content`/`text` → notes; `messages`/`conversations` → chat log; `embeddings` → vector store). Don't pattern-match known apps; read what's there.
   - **Not memory**: build artifacts, secrets stores, package caches. Mark explicitly so future walks skip.
   - **Running services**: for each running container with a bind mount into the workspace:
     - `[OK]` — source exists, owned by user, has content. Probably intentional. Add to watch list, surface what it appears to be doing.
     - `[GHOST]` — source is root-owned and empty. The container's spec points at a path the daemon auto-created on restart because the original was moved or deleted. **Flag loud.** Probably a directory rename or cleanup that didn't `compose down` first; the container is now writing throwaway state. Recommend stop+remove+rm sequence (in that order — never rm a live bind source).
     - `[ORPHAN]` — source path missing entirely. Container is non-functional and may be flapping with restart-on-failure. Flag.
     - **Stopped containers with workspace bind mounts**: same shape signal — if a stack used to be running here and now isn't, a directory rename probably broke it. Surface.
   - **Systemd units referencing workspace**: any unit with `WorkingDirectory=` or `ExecStart=` pointing at this workspace path. Add to watch list — these are how things start automatically and they're the load-bearing piece of any "always-running" service.

   Use Claude's runtime reasoning, not hardcoded patterns. If unsure about what something is, write your best guess in the map's `Notes` section and surface to the user.

5. **Compose the house-map** following the template in `skills/maude/SKILL.md`. Write to `$MAP`. If `${ARGUMENTS}` is `--refresh` or `$MAP` already exists, overwrite (re-walk). Otherwise, only write if missing — preserve existing user notes by reading the existing map first and merging the `Notes` section forward.

   **For every `## Memory sources` entry, set `write:` to one enumerated token** (so save/rest
   can drive off it — see SKILL.md "The `write:` field is authoritative"): `digest-fanout`
   (Claude-continuity stores like Anthropic auto-memory), `handoff-only` (a sibling system's
   single agent-handoff file, e.g. remember's `remember.md` — never its pipeline files),
   `full` (Maude's own stores), `read-only` (recall-only dirs), `secret-deny` (credential
   vaults — also record these under `## Vaults`). Lead with the token; free prose may follow.
   When unsure, default an external store to `read-only` and flag it for the user to confirm
   the write protocol.

   **Write the `## Clock` section** so greetings track the user's real local time, not the box
   clock. Use the detected `CLOCK:` candidate, but **confirm with the user** rather than trusting
   it — a box that reads UTC is almost never where the user actually is. Set `timezone:` to:
   - the user's IANA zone (e.g. `America/Chicago`) once they confirm it,
   - `system` if they confirm the box clock is genuinely their local time,
   - `<none>` (placeholder) if they don't answer — Maude then stays time-neutral until it's set.
   On `--refresh`, preserve an already-confirmed `timezone:` unless the user changes it.

6. **Report what's organized AND propose:**

   ```
   Walked your house.
     Memory locations: <N> (active: A, weekly: W, stale: S, possibly duplicate: D)
     SQLite dbs:       <N> (with schema summaries — see map for column reasoning)
     Running services: <N container> + <N systemd> (OK: A, GHOST: G, ORPHAN: O)
     MCP tools:        <list of prefixes found in this session>
     Map:              $MAP

   I noticed:
     - Your clock: box reads <tz / time> — is that actually your timezone? I'll greet by it.
     - <N> stale-30d files in <path> — archive them?
     - <list> looks duplicate-shaped — consolidate?
     - <thing> the user touches weekly but isn't on the watch list — add it?
     - <db> has tables suggesting it's <best guess> — confirm?
     - <container> is mounting <ghost path> — rename orphan? Stop+remove+rm?
     - <unit> systemd unit references the workspace — add to watch list?

   Tell me what's right and which suggestions to take.
   ```

   Don't just list. Propose. The user can say no, but offer.

## Voice

- Quiet, observant. "Quite the collection you have."
- If the user has nothing yet: "Fresh place. We start with what Claude Code gives us."
- Don't claim knowledge of what specific files are. List, ask, record.

## What goes in the watch list (default)

- `.claude/CLAUDE.md`
- `.claude/settings.json`, `.claude/settings.local.json`
- `.claude/hooks/`
- Anything the user marks in the existing map's "watch list" — preserve those.

The user edits the map directly to add/remove watch-list entries; she re-reads it every session.
