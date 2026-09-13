#!/usr/bin/env bash
# Maude UNDO rail — the sixth trust-spine pillar, and the gate's other half.
#
#   capture-write  — before Write/Edit/MultiEdit, store the file's current bytes.
#                    file_path is IN the payload, so this tier needs no parsing and
#                    has no ceiling. (PreToolUse, called from maude-pre-tool-use.sh.)
#   capture-bash   — before a destructive Bash, store the bytes of every target it
#                    can identify. BEST-EFFORT. (PreToolUse, from maude-bash-watch.sh.)
#   list           — what is recoverable, and what is NOT.
#   restore <n>    — put entry n back, snapshotting the current bytes first so the
#                    undo is itself undoable.
#
# ALWAYS exits 0 on the capture paths. A safety net that can block the work is not a
# safety net. (list/restore may exit 1 — they are invoked by a human, not a hook.)
#
# WHY THE GATE IS NOT ENOUGH, AND WHY THIS IS NOT A BACKUP
# A gate must let ordinary work through or it gets switched off inside a day, and a
# gate that is off protects nothing. UNDO catches what the gate deliberately allows.
# It is NOT a backup: local, gitignored, size-capped, pruned. PBS and git remain the
# real backups. It reverses FILES, not a command's other side effects.
#
# THE HONEST SEAM — this pillar can LIE BY EXISTING.
# A gate that fails is loud: you are blocked and you know it. An UNDO that quietly
# missed a file is silent until the night you reach for it and it is not there. So
# every skip is RECORDED with a reason and SURFACES in `list`. Tier 2 inherits the
# gate's measured ceiling — relative paths after a cd, $VAR-indirected targets, xargs,
# interpreter one-liners, heredoc-fed shells. It does not pretend otherwise.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

# jq parses the payload and writes the ledger. Without it the rail is inert, matching
# the rest of the plugin's soft-jq dependency.
command -v jq >/dev/null 2>&1 || exit 0

SUB="${1:-}"

UNDO_DIR="$(maude_self_dir)/undo"
LEDGER="$UNDO_DIR/ledger.jsonl"
BLOBS="$UNDO_DIR/blobs"

# WHY A USER-GLOBAL REGISTRY OF STORES
# Hooks receive CLAUDE_PROJECT_DIR; the Bash tool does NOT, so `maude_project_dir`
# falls through to a process-tree/filesystem walk and can land somewhere else. Measured
# on the live box 2026-07-30: the hooks resolved <workspace> and captured 9 entries,
# while the very same script run from a Bash call resolved ~ and answered "nothing
# captured yet". Someone whose file WAS recoverable would have been told it was not —
# which is the one failure this pillar must never have. A capture writes its store path
# here; list/restore fall back to it instead of reporting an empty store they never
# actually found, and always name the store they read.
STORE_REGISTRY="$(maude_user_dir)/undo-stores.txt"

maude_undo_register_store() {
  mkdir -p "$(maude_user_dir)" 2>/dev/null
  grep -qxF "$UNDO_DIR" "$STORE_REGISTRY" 2>/dev/null || \
    printf '%s\n' "$UNDO_DIR" >> "$STORE_REGISTRY" 2>/dev/null
}

# Pick the freshest store among {this process's guess} ∪ {registered}. It must NOT
# short-circuit on a locally-present store: a stale or phantom one would shadow the
# store the hooks are actually writing, and the answer would be confidently wrong
# rather than merely missing.
maude_undo_resolve_store() {
  local best="" bestm=0 d m
  for d in "$UNDO_DIR" $( [ -f "$STORE_REGISTRY" ] && cat "$STORE_REGISTRY" 2>/dev/null ); do
    [ -n "$d" ] && [ -f "$d/ledger.jsonl" ] || continue
    m="$(maude_mtime "$d/ledger.jsonl")"
    [ -n "$m" ] || m=0
    if [ "$m" -gt "$bestm" ] 2>/dev/null; then bestm="$m"; best="$d"; fi
  done
  [ -n "$best" ] || return 1
  UNDO_DIR="$best"; LEDGER="$best/ledger.jsonl"; BLOBS="$best/blobs"
  return 0
}

# A capture only happens when the project dir is KNOWN. Hooks always have
# CLAUDE_PROJECT_DIR; a Bash-tool invocation does not, and `maude_project_dir` then
# falls through to a filesystem walk that can land on $HOME. Creating a store there
# is worse than capturing nothing: the empty phantom becomes a real directory, the
# walk stops at it forever after, and it shadows the store holding the actual work.
# Measured 2026-07-30 — a manual probe minted ~/.maude/plugin/undo exactly this way.
maude_undo_project_is_known() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || [ -n "${MAUDE_PROJECT_DIR_OVERRIDE:-}" ]
}

# Per-file cap. Above this the content is skipped (and the skip recorded) rather than
# silently bloating a local store that nobody prunes by hand.
MAX_BYTES="${MAUDE_UNDO_MAX_BYTES:-1048576}"

# Paths whose CONTENT must never get a second copy at rest. Skipping these loses undo
# coverage exactly where loss hurts, which is the trade taken on purpose: a blob store
# full of cleartext credentials is a worse failure than an unrecoverable edit, and the
# gate already blocks the catastrophic operations on these paths.
maude_undo_is_secret_path() {
  case "$1" in
    */.credentials|*/.credentials/*|*/.ssh/*|*/.gnupg/*) return 0 ;;
    *.env|*.env.*|*.pem|*.key|*.p12|*.pfx|*.keystore)    return 0 ;;
    *id_rsa*|*id_ed25519*|*id_ecdsa*|*secrets.*)         return 0 ;;
  esac
  return 1
}

# Append one ledger line. Built with jq so a path containing quotes, spaces or a
# newline cannot corrupt the ledger.
maude_undo_record() {  # path tool tier blob bytes existed skip
  mkdir -p "$UNDO_DIR" 2>/dev/null
  maude_undo_register_store
  jq -nc --arg p "$1" --arg tool "$2" --arg tier "$3" --arg blob "$4" \
        --arg bytes "$5" --arg existed "$6" --arg skip "$7" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ts:$ts, tool:$tool, path:$p, tier:($tier|tonumber),
      existed:($existed=="true"), bytes:(if $bytes=="" then 0 else ($bytes|tonumber) end)}
     + (if $blob == "" then {} else {blob:$blob} end)
     + (if $skip == "" then {} else {skip:$skip} end)' >> "$LEDGER" 2>/dev/null
}

# Snapshot ONE path. Every capture route funnels through here so the skip rules and
# the store layout have exactly one implementation.
maude_undo_capture_one() {  # path tool tier
  local p="$1" tool="$2" tier="$3" sha bytes

  # Never snapshot our own store — it would recurse and it is not the user's data.
  case "$p" in "$UNDO_DIR"*) return 0 ;; esac

  if maude_undo_is_secret_path "$p"; then
    maude_undo_record "$p" "$tool" "$tier" "" "" "true" "secret-path"; return 0
  fi
  if [ ! -e "$p" ]; then
    # Nothing to store. Recording it is what makes "undo a create" mean "delete it"
    # rather than "write an empty file".
    maude_undo_record "$p" "$tool" "$tier" "" "" "false" ""; return 0
  fi
  if [ ! -f "$p" ] || [ -L "$p" ]; then
    maude_undo_record "$p" "$tool" "$tier" "" "" "true" "not-a-regular-file"; return 0
  fi

  bytes="$(maude_file_size "$p")"
  [ -n "$bytes" ] || bytes=0
  if [ "$bytes" -gt "$MAX_BYTES" ] 2>/dev/null; then
    maude_undo_record "$p" "$tool" "$tier" "" "$bytes" "true" "too-large"; return 0
  fi

  sha="$(maude_file_digest "$p")"
  if [ -z "$sha" ]; then
    maude_undo_record "$p" "$tool" "$tier" "" "$bytes" "true" "unreadable"; return 0
  fi

  mkdir -p "$BLOBS" 2>/dev/null
  # Content-addressed: N edits of one file store the unchanged content once, and
  # reverting to an earlier state costs nothing extra.
  [ -f "$BLOBS/$sha" ] || cp -p "$p" "$BLOBS/$sha" 2>/dev/null
  maude_undo_record "$p" "$tool" "$tier" "$sha" "$bytes" "true" ""
}

case "$SUB" in
  capture-write)
    maude_undo_project_is_known || exit 0
    TARGET="$(jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)"
    [ -n "$TARGET" ] || exit 0
    maude_undo_capture_one "$TARGET" "Write" 1
    exit 0
    ;;

  capture-bash)
    maude_undo_project_is_known || exit 0
    CMD="$(jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
    [ -n "$CMD" ] || exit 0

    # Split into simple commands. A destructive verb only counts in COMMAND position:
    # `echo rm foo` must not trigger a capture sweep.
    # NOTE the trailing newline in the printf. Without it `read` returns non-zero on
    # the final unterminated line and the while body never runs — so a single-command
    # payload (the common case) was silently dropped. Measured, not theorised.
    printf '%s\n' "$CMD" | tr ';&|\n' '\n\n\n\n' | while IFS= read -r seg; do
      # UNQUOTED ON PURPOSE, and this is the load-bearing line of tier 2: `set --`
      # word-splits AND glob-expands in one step, which is where
      # `rm -f <root>/*.png` becomes two concrete paths. PreToolUse runs BEFORE the
      # shell, so the pattern arrives literal and something has to expand it.
      # An earlier version expanded again in an inner `for m in $tok` loop; that loop
      # was dead code, and a mutation proved the test was passing on THIS line while
      # crediting the other one. Disable globbing here and the 2026-07-23 shape stops
      # being covered — tests/test-undo.sh pins exactly that.
      # shellcheck disable=SC2086
      set -- $seg
      [ $# -gt 0 ] || continue
      VERB="$(basename "$1" 2>/dev/null)"
      case "$VERB" in
        rm|mv|shred|truncate|unlink|dd) ;;
        *) continue ;;
      esac
      shift
      for tok in "$@"; do
        case "$tok" in
          -*)     continue ;;          # a flag, not a target
          of=*)   tok="${tok#of=}" ;;  # dd of=<path>
          if=*)   continue ;;          # dd input is read, not destroyed
        esac
        case "$tok" in
          "~"/*) tok="$HOME/${tok#\~/}" ;;
        esac
        # Only absolute paths. A relative target after a `cd` cannot be resolved from
        # here — that is the documented tier-2 ceiling, not an oversight.
        case "$tok" in /*) ;; *) continue ;; esac
        # Already expanded by `set -- $seg` above; a pattern that matched nothing
        # arrives here literal and fails this test, which is the correct outcome.
        [ -e "$tok" ] && maude_undo_capture_one "$tok" "Bash" 2
      done
    done
    exit 0
    ;;

  list)
    if ! maude_undo_resolve_store; then
      # Do NOT say "nothing captured". This process may simply be looking in the wrong
      # place, and "empty" would read as "your file is gone".
      printf 'Maude: no undo store found. I looked in %s and in the registry at %s.\n' \
        "$UNDO_DIR" "$STORE_REGISTRY"
      exit 0
    fi
    printf 'Maude: undo store %s\n' "$UNDO_DIR"
    # Newest first, ten by default: the entry a person needs is the one just clobbered,
    # and sixty lines oldest-first put it last, off the top of his scrollback (the UX
    # lens, 2026-09-06, D7). The index is the ledger line number, so it never shifts;
    # `list --all` shows every line, still newest first. One jq pass over the file,
    # never one fork per line.
    LIMIT=10; [ "${2:-}" = "--all" ] && LIMIT=0
    n="$(grep -c . "$LEDGER" 2>/dev/null)"; [ -n "$n" ] || n=0
    if [ "$n" -gt 0 ]; then
      # Raw lines, numbered by PHYSICAL line: that is what `restore <n>` reads, so the
      # two agree. EVERY row is total: a field of the wrong type used to raise inside the
      # jq program, abort the whole stream at rc 0 with stderr silenced, and drop the
      # OLDEST entries in silence — three rounds of the same failure under a narrower
      # trigger each time (the 23rd lens IMPORTANT-1, the 24th's IMPORTANT-4, the 25th's
      # IMPORTANT-4). A line that is not a JSON OBJECT, or whose path could not name a file
      # (not a string, empty, or only whitespace — three rounds found that one value at a
      # time), is listed as unreadable and the rest stand
      # (one bad line used to abort the whole listing at rc 0 and make `restore last`
      # say nothing was recoverable; a blank line used to shift every number below it
      # so `restore 3` put back the file the listing had called [2] — the 23rd lens,
      # IMPORTANT-1/2). A blank line is no entry and takes no line of the listing.
      jq -rRn '[inputs] | to_entries | reverse | .[]
        | (.key + 1) as $n | (.value | try fromjson catch null) as $v
        | if (.value | length) == 0 then empty
          elif ($v | type) != "object" then "  [" + ($n | tostring) + "] UNREADABLE LINE (not a JSON object) — skipped; the entries around it stand"
          elif (($v.path | type) != "string") or ((($v.path | gsub("[ \\t]"; "")) | length) == 0) then "  [" + ($n | tostring) + "] UNREADABLE LINE (no usable path) — skipped; the entries around it stand"
          else "  [" + ($n | tostring) + "] " + (($v.ts // "?") | tostring) + "  " + (($v.tool // "?") | tostring) + "  " + $v.path
            + (if $v.skip != null then "   NOT RECOVERABLE (" + ($v.skip | tostring) + ")"
               elif ($v.existed | not) then "   (created — undo deletes it)"
               else "   " + (($v.bytes // "?") | tostring) + "b" end) end' "$LEDGER" 2>/dev/null \
        | { if [ "$LIMIT" -gt 0 ]; then head -n "$LIMIT"; else cat; fi; }
      [ "$LIMIT" -gt 0 ] && [ "$n" -gt "$LIMIT" ] && printf '  +%s more: /maude:undo list --all\n' "$((n - LIMIT))"
    else
      printf 'Maude: nothing captured yet — the undo store is empty.\n'
    fi
    exit 0
    ;;

  restore)
    SEQ="${2:-}"
    case "$SEQ" in last|''|*[!0-9]*) ;; esac
    if [ "$SEQ" != "last" ]; then
      case "$SEQ" in ''|*[!0-9]*) printf 'Maude: usage — restore <n> from /maude:undo list, or restore last.\n' >&2; exit 1 ;; esac
    fi
    maude_undo_resolve_store || { printf 'Maude: no undo store found (looked in %s and %s).\n' "$UNDO_DIR" "$STORE_REGISTRY" >&2; exit 1; }
    if [ "$SEQ" = "last" ]; then
      # The newest entry that can be put back; a skip was never captured and is not one.
      # A usable path is part of being recoverable: an empty object at the tail used to
      # capture `restore last` and then die blaming a pruned blob (the 25th lens).
      SEQ="$(jq -rRn '[inputs] | to_entries | map((.value | try fromjson catch null) as $v | select(($v | type) == "object" and $v.skip == null and ($v.path | type) == "string" and ((($v.path | gsub("[ \\t]"; "")) | length) > 0)) | .key + 1) | last // empty' "$LEDGER" 2>/dev/null)"
      [ -n "$SEQ" ] || { printf 'Maude: nothing recoverable to restore.\n' >&2; exit 1; }
    fi
    LINE="$(sed -n "${SEQ}p" "$LEDGER" 2>/dev/null)"
    [ -n "$LINE" ] || { printf 'Maude: no entry %s.\n' "$SEQ" >&2; exit 1; }
    printf '%s' "$LINE" | jq -e 'type == "object" and (.path | type) == "string" and (((.path | gsub("[ \\t]"; "")) | length) > 0)' >/dev/null 2>&1 \
      || { printf 'Maude: entry %s is not readable (a partial line, or no usable path?) — nothing put back.\n' "$SEQ" >&2; exit 1; }

    RPATH="$(printf '%s' "$LINE" | jq -r '.path')"
    RBLOB="$(printf '%s' "$LINE" | jq -r '.blob // ""')"
    # `//` treats false as absent, so a `skip: false` row printed NOT RECOVERABLE and was
    # then acted on. Three readers of this field used three tests and agreed on every value
    # but one: `skip: ""` is not null, so the listing called it a skip, while `tostring` of
    # it is empty and the actor went ahead and overwrote the file (the 28th lens,
    # IMPORTANT-5). PRESENCE is the question, so presence is what all three ask; the text
    # is only for the message.
    RHASSKIP="$(printf '%s' "$LINE" | jq -r 'if .skip == null then "no" else "yes" end')"
    RSKIP="$(printf '%s' "$LINE" | jq -r 'if .skip == null then "" else (.skip | tostring) end')"
    REXISTED="$(printf '%s' "$LINE" | jq -r '.existed')"

    if [ "$RHASSKIP" = yes ]; then
      printf 'Maude: entry %s was never captured (%s) — there is nothing to put back.\n' "$SEQ" "$RSKIP" >&2
      exit 1
    fi

    # The restore is itself a destructive write, so it goes through the same rail
    # first. Undoing an undo has to work, or nobody will risk the first one.
    maude_undo_capture_one "$RPATH" "restore" 1

    if [ "$REXISTED" = "false" ]; then
      rm -f "$RPATH" 2>/dev/null
      printf 'Maude: %s did not exist before that action — removed it.\n' "$RPATH"
      exit 0
    fi

    [ -f "$BLOBS/$RBLOB" ] || { printf 'Maude: the stored content for entry %s is gone (pruned?).\n' "$SEQ" >&2; exit 1; }
    cp -p "$BLOBS/$RBLOB" "$RPATH" 2>/dev/null || { printf 'Maude: could not write %s.\n' "$RPATH" >&2; exit 1; }
    printf 'Maude: restored %s. The version you just replaced is the newest undo entry.\n' "$RPATH"
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
