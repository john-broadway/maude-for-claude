#!/usr/bin/env bash
# Maude rules-watch hook — the design-law rail.
#
#   classify  (PostToolUse · Write/Edit/MultiEdit, called from maude-post-tool-use.sh)
#             Decide the class of the written file (ui | schema | memory), whisper the law
#             ONCE per class per session, record the touch, run the schema linter on a schema
#             file, and STAMP when a written file NAMES the laws (heading + canonical alias).
#   check     (PreToolUse · Bash, called from maude-bash-watch.sh)
#             On `git commit`: for each class touched this session and never named this
#             session, whisper once, re-armed by a later touch; re-run the linter over the
#             touched schema files and whisper the open count when it changes.
#
# ALWAYS exits 0. Whisper, never block. Silent without jq. Per session (sid), like redteam-watch.
#
# WHY THIS EXISTS
# John, 2026-09-03: "maude needs to make sure claude follows rules. especially the 30 ux ones.
# the codd rule for db desing including 1nf 2nf and 3nf. at a minium" · "there is also the laws
# of memory human and machine" · "its also for everything we develop" · "and for the users".
# The laws live on a website and in textbooks and nothing consulted them at the moment a schema
# or a button was written. Knowledge in a file is a diary; a hook is a rail.
#
# THE ASYMMETRY
# A missed class costs one whisper. A false NAMING stamp is a false all-clear. So classification
# is allowed to be a little generous and the stamp is not: it needs a heading that names the
# rulebook AND at least one canonical alias from it, in a FILE. Never a commit message: `-m
# "fitts"` is the cheapest false all-clear there is and nobody reviews it.
#
# WHY THE STAMP IS SECTION-SCOPED
# A document can honestly carry a rulebook's name in one section and an unrelated mention of a
# law's name in another (a changelog line, a footnote) without either governing the other. The
# alias only counts between the heading that opens the rulebook's section and the next line
# that opens at the same or shallower "#" depth (or end of file) — never anywhere in the file.
#
# WHY "touched AND never named", not "since the last stamp"
# Redteam asks "edits since the last review" because a review follows the work. A design
# precedes the build, so the naming stamp legitimately comes BEFORE every edit; copying the
# redteam predicate would whisper falsely on the normal order.
#
# HONEST SEAM: for a schema the rail catches objective shapes (no key, a repeating group, a fact
# hung on the wrong key). For UI and memory it catches ABSENCE, the law never named, and hands
# presence to the adversarial lens. It cannot tell a named law from an honoured one, and says so.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

[ "${MAUDE_RULES:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

MODE="${1:-}"
INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0

RULES_DIR="${MAUDE_RULES_DIR:-$DIR/../../rules}"
MAUDE_ROOT="$(cd "$DIR/../.." && pwd)"
CARE="$(maude_self_dir)/care.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOC_RE="$(maude_doc_re)"
COMMIT_RE="$(maude_commit_re)"
# DOC_RE answers "never a touch" for a wide set: json, yml, toml, lock, csv, svg, png,
# pdf, LICENSE and friends. It is the wrong answer to "may stamp". A stamp is a claim
# that a DESIGN named the laws it holds to, and only prose carries a design, so a
# config file's own words can never mint one, and a lockfile or a binary is never even
# opened. PROSE_RE is that narrower question, asked second.
PROSE_RE='\.(md|markdown|txt|rst|adoc)$'

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-8)"
[ -n "$SID" ] || SID="default"

# python3 gate routes through maude_python3_ok (an EXECUTE probe, not presence) — every hook
# in this house does, since the Store-alias / no-CLT-tools shape passes `command -v` and then
# fails at the call site. _maude-common.sh is sourced above, unconditionally, so the helper is
# always defined here; no presence-test fallback (that shape is swept and lint-guarded).
_python_ok() { maude_python3_ok; }

# care.json writer scoped to this session. Usage: _set '<jq program using $sid $ts and extra args>' [--arg k v ...]
# mkdir first: maude_care_ensure cannot seed a file into a directory that does not exist,
# and maude_care_set's mktemp lands in the same place. In a project whose .maude/plugin has
# never been created, every write silently failed to record, so the whispered flag never
# landed and the same class whispered on every single write.
_set() { local prog="$1"; shift; mkdir -p "$(dirname "$CARE")" 2>/dev/null; maude_care_ensure "$CARE"; maude_care_set "$CARE" --arg sid "$SID" --arg ts "$NOW" "$@" "$prog"; }
_get() { jq -r --arg sid "$SID" "$1" "$CARE" 2>/dev/null; }

# `.value.ts?` swallows the error when a named entry is not an object; a session with no
# usable timestamp yields "" and sorts below any cutoff, so it is pruned rather than kept
# forever on a technicality.
RULES_NEWEST_DEF='def newest:
  ( [ (.last_touch // {}), (.whispered // {}), (.checked // {}) ]
    | map(select(type == "object") | to_entries[] | .value) )
  + [ (.named // {}) | select(type == "object") | to_entries[] | .value.ts? ]
  | map(select(type == "string")) | max // "";
'

# Drop every session whose NEWEST timestamp, across last_touch, whispered, named.*.ts
# and checked, is more than seven days old, plus any entry carrying no timestamp at all.
# Without this, care.json accumulates every sid that ever worked in this tree and a lane
# that ran once in April is still an unnamed class in September. ISO strings in this one
# fixed shape compare correctly with `<`, so the cutoff is one string. The cutoff itself
# goes through maude_epoch_iso: `date -u -d '7 days ago'` is GNU-only and would hand BSD
# an empty string, which compares below everything and would prune the whole store.
# Reads first and writes only when something is actually stale, so the common case costs
# one jq read and no rewrite of care.json.
RULES_STALE_DAYS="${MAUDE_RULES_STALE_DAYS:-7}"
rules_prune_stale() {
  [ -f "$CARE" ] || return 0
  local now cut stale
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  cut="$(maude_epoch_iso "$((now - RULES_STALE_DAYS * 86400))")" || return 0
  [ -n "$cut" ] || return 0
  stale="$(jq -r --arg cut "$cut" "$RULES_NEWEST_DEF"'
    (.rules // {}) | to_entries[]
    | select((.value | type) != "object" or (.value | newest) < $cut) | .key' "$CARE" 2>/dev/null)"
  [ -n "$stale" ] || return 0
  maude_care_set "$CARE" --arg cut "$cut" "$RULES_NEWEST_DEF"'
    .rules = ((.rules // {}) | with_entries(select((.value | type) == "object" and (.value | newest) >= $cut)))' \
    && maude_log_trace "rules" "pruned stale session(s) older than ${RULES_STALE_DAYS}d"
}
rules_is_fixture() {
  case "/$1" in */tests/*|*/fixtures/*) return 0 ;; esac
  case "$(basename "$1")" in test_*|*_test.*|*.spec.*) return 0 ;; esac
  return 1
}

rules_class_by_path() {
  local p="$1" b ext stem
  b="$(basename "$p")"; ext="${b##*.}"; stem="${b%.*}"
  case "$ext" in
    html|htm|css|scss|sass|less|vue|svelte|jsx|tsx|astro|qml|j2|jinja|hbs|ejs|erb|tmpl) printf 'ui'; return ;;
    sql|prisma|dbml) printf 'schema'; return ;;
  esac
  case "/$p/" in
    */ui/*|*/components/*|*/views/*|*/templates/*|*/pages/*) printf 'ui'; return ;;
    */migrations/*|*/alembic/*|*/schema/*) printf 'schema'; return ;;
    */memory/*|*/.remember/*) printf 'memory'; return ;;
  esac
  case "$stem" in memory|cache|store|tape|vault) printf 'memory'; return ;; esac
}

# Identifiers match with boundaries: a cache-expiry marker never matches "throttle", and a
# cache-policy one never matches "lru_cache".
#
# EVERY MARKER BELOW IS WRITTEN DISARMED: one letter of each literal sits in a one-character
# bracket, so `<b[u]tton` matches a real button tag and does not match itself. This function
# scans text and this script IS text: spelled out plainly, writing this file classified it by
# its own patterns, which is the trap that springs when you document it. Do not "tidy" the
# brackets away; a test writes this whole file through classify and would go red.
#
# The ORM markers are extension-gated. They are ordinary identifiers in prose and in other
# languages, so matching them in any file at all meant any text that merely mentioned one was
# a schema. A raw create-table statement stays any-file: a schema inside a string literal is
# a schema whatever the host language is. (That sentence avoids the two words in sequence for
# the same reason the brackets exist above: writing them here would classify this file.)
rules_class_by_content() {
  local c="$1" file="${2:-}" b ext
  b="$(basename "$file")"; ext="${b##*.}"
  printf '%s' "$c" | grep -qiE 'CREATE[[:space:]]+TABLE' && { printf 'schema'; return; }
  case "$ext" in
    py|php|js|ts|rb)
      printf '%s' "$c" | grep -qE '(^|[^[:alnum:]_])(Co[l]umn\(|models\.M[o]del|SQ[L]Model|Schema::c[r]eate\()' && { printf 'schema'; return; } ;;
    sh|bash|zsh)
      # A terminal is a UI. A script that prints to the person's stderr is a speaking
      # surface, and the thirty laws apply to what it says: this rail classified app.css
      # and was silent on every hook that whispers (the UX lens, 2026-09-06, D6). The
      # marker is disarmed the same way the others are; this file's own whispers make it
      # a UI surface, which is the one honest class for it.
      printf '%s' "$c" | grep -qE '(printf|echo).*>[&]2' && { printf 'ui'; return; } ;;
  esac
  printf '%s' "$c" | grep -qE '<b[u]tton|<f[o]rm|<i[n]put|(^|[^[:alnum:]_])(onC[l]ick|addEventL[i]stener\(|Im[G]ui|im[g]ui|tk[i]nter|QW[i]dget)' && { printf 'ui'; return; }
  printf '%s' "$c" | grep -qiE '(^|[^[:alnum:]_])(l[r]u|t[t]l|ev[i]ct[a-z]*|conso[l]idat[a-z]*|rete[n]tion|supe[r]sed[a-z]*|forg[e]tting)([^[:alnum:]_]|$)' && { printf 'memory'; return; }
}

# Record a touch of CLASS by FILE and whisper the law once per class per session. One
# place, called from the classify path and from the prose path's Format exception.
# Remove then append, never `unique`: unique SORTS, so the fifty-path window kept the
# last fifty paths in the ALPHABET rather than the last fifty touched, and a re-touch
# did not move a file forward at all.
rules_record_touch() {  # <class> <file>
  local class="$1" file="$2"
  _set '.rules[$sid].touched[$c] = (((((.rules[$sid].touched[$c] // []) - [$f]) + [$f])) | .[-50:]) | .rules[$sid].last_touch[$c] = $ts' \
    --arg c "$class" --arg f "$file"
  if [ -z "$(_get '.rules[$sid].whispered["'"$class"'"] // ""')" ]; then
    rules_whisper_touch "$class" "$(basename "$file")"
    _set '.rules[$sid].whispered[$c] = $ts' --arg c "$class"
    maude_log_trace "rules" "whispered class=$class file=$file"
  fi
}

rules_book() { case "$1" in ui) printf 'laws-of-ux.json' ;; schema) printf 'codd-and-normal-forms.json' ;; memory) printf 'laws-of-memory.json' ;; esac; }

# A prose file (MEMORY.md included) is where a stamp lives, and it is never a touch. The wider
# doc set (json, yml, lock, csv, svg, png, pdf) is never a touch either, and never a stamp:
# only a design can name the laws a design holds to. A design doc named test_*.md, or living
# under tests/ or fixtures/, is a fixture and can never stamp, checked before anything else.

# Section-scoped extraction: from a heading line matching $2 (a lowercase ERE) to the next
# line that opens at the same or shallower "#" depth, or EOF. $1 is content ALREADY
# lowercased (awk here has no portable case-fold, so casing is normalized before this runs).
# A fenced code block is inert throughout: a `#`-shaped line inside a fence never closes or
# opens a section, and no fenced line is ever emitted as section text — a code sample that
# happens to quote a rulebook's heading or a law's name names nothing. CommonMark allows a
# fence to open indented up to three spaces, so the fence test walks the leading spaces (same
# counting shape as hcount below) rather than matching only column zero — a doc indented by
# one, two, or three spaces still hides its fenced content; four or more is no longer a fence.
# The heading phrase matches on WORD BOUNDARIES: line start or a non-alphanumeric before it,
# a non-alphanumeric or end of line after. Without that, `## Redux laws` opened the UX section
# on the `ux laws?` alternative and every UX alias below it stamped a class nobody had named.
# The rulebooks' own `heading` fields are untouched; the boundary is added here, where the
# pattern is assembled.
rules_extract_section() {
  awk -v re="$2" '
    function hcount(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
    function is_fence(s,   sp) {
      sp = 0
      while (sp <= 3 && substr(s, sp + 1, 1) == " ") sp++
      return (sp <= 3 && substr(s, sp + 1, 3) == "```")
    }
    {
      line = $0
      if (is_fence(line)) { infence = !infence; next }
      if (infence) { next }
      is_h = (line ~ /^#+[ \t]/)
      if (is_h) { d = hcount(line) }
      if (insec && is_h && d <= depth) { insec = 0 }
      if (!insec && is_h && line ~ ("^#+[ \t]+(.*[^[:alnum:]])?(" re ")([^[:alnum:]]|$)")) {
        insec = 1; depth = d
        print line
        next
      }
      if (insec) print line
    }
  ' <<< "$1"
}

# STAMP: heading naming the rulebook AND at least one canonical alias, BOTH inside the same
# section of the written content.
rules_stamp() {
  local content="$1" file="$2" class book heading aliases_re named section lc_content
  lc_content="$(printf '%s\n' "$content" | tr '[:upper:]' '[:lower:]')"
  for class in ui schema memory; do
    book="$RULES_DIR/$(rules_book "$class")"
    [ -f "$book" ] || continue
    heading="$(jq -r '.heading // ""' "$book" 2>/dev/null)"
    [ -n "$heading" ] || continue
    section="$(rules_extract_section "$lc_content" "$heading")"
    [ -n "$section" ] || continue
    # One sed over the whole alias stream, not one maude_ere_escape fork per alias: that
    # was a process per law per book on every prose write, thirty of them for the UX book
    # alone. The expression is maude_ere_escape's own, applied line by line, so an alias
    # carrying a parenthesis or an apostrophe escapes exactly as it did.
    aliases_re="$(jq -r '.laws[].aliases[]' "$book" 2>/dev/null \
      | sed -E '/^$/d; s/[][\*^$()+?{|]/\\&/g' | tr '\n' '|' | sed 's/|$//')"
    [ -n "$aliases_re" ] || continue
    named="$(printf '%s\n' "$section" | grep -oiE "(^|[^[:alnum:]])($aliases_re)([^[:alnum:]]|$)" 2>/dev/null \
      | sed -E 's/^[^[:alnum:]]//; s/[^[:alnum:]]$//' | tr '[:upper:]' '[:lower:]' | sort -u | head -20 | jq -R . | jq -sc .)"
    [ -n "$named" ] && [ "$named" != "[]" ] || continue
    _set '.rules[$sid].named[$c] = {ts:$ts, file:$f, laws:$laws}' --arg c "$class" --arg f "$file" --argjson laws "$named" \
      && maude_log_trace "rules" "named class=$class file=$file"
  done
}

rules_whisper_touch() {
  case "$1" in
    ui)     printf 'Maude: %s is a UI surface. The thirty Laws of UX apply: name the ones this holds to, by name, in the design. /maude:rules ux lists them.\n' "$2" >&2 ;;
    schema) printf "Maude: %s declares a schema. Codd's rules and third normal form are the floor: name the forms each table holds to. /maude:rules db lists them.\n" "$2" >&2 ;;
    memory) printf 'Maude: %s is a memory surface. The laws of memory, human and machine, apply: name the ones this holds to. /maude:rules memory lists them.\n' "$2" >&2 ;;
  esac
}

# `python3 -m` prepends the CWD to sys.path AHEAD of PYTHONPATH, so a project that
# happens to carry its own maude_rules/ directory would be the package this runs, and
# whatever it printed would be spoken as Maude. Two belts, because either one alone
# has a hole: PYTHONSAFEPATH=1 drops that implicit entry (python 3.11+, the floor
# below which only the second belt applies), and launching the interpreter from
# $MAUDE_ROOT makes the implicit entry the plugin's own root even on 3.10 and older.
# The file must then be named ABSOLUTELY, because the interpreter no longer stands in
# the directory the path was relative to.
rules_lint_brief() {  # $1 path → prints the summary after "PATH: " or nothing
  _python_ok || return 0
  [ -f "$1" ] || return 0
  local abs line
  case "$1" in /*) abs="$1" ;; *) abs="$PWD/$1" ;; esac
  line="$(cd "$MAUDE_ROOT" 2>/dev/null && PYTHONSAFEPATH=1 PYTHONPATH="$MAUDE_ROOT" python3 -m maude_rules schema --brief "$abs" 2>/dev/null | head -1)"
  [ -n "$line" ] || return 0
  printf '%s' "${line#"$abs": }"
}

case "$MODE" in
  classify)
    rules_prune_stale
    FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)"
    [ -n "$FILE" ] || exit 0
    CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // (([.tool_input.edits[]?.new_string] | join("\n")) // "")' 2>/dev/null)"

    # A stamp can come ONLY from PROSE (PROSE_RE) that is NOT a fixture, checked in that order,
    # before anything else runs. Without this a fixture under tests/ or the rail's OWN script
    # (whose header prose can read as a heading + alias to the extractor) could stamp a class
    # that was never honestly named, which is the false all-clear the whole design guards
    # against. Fixture wins first: a fixture .md is still a fixture, never a stamp source.
    rules_is_fixture "$FILE" && exit 0

    if printf '%s' "$FILE" | grep -qE -- "$DOC_RE"; then
      # Non-prose stops here, BEFORE anything is read from disk: a 20 MB lockfile costs
      # nothing, and a binary never reaches `cat`, whose null bytes make bash warn onto
      # the very stderr the whisper travels on.
      printf '%s' "$FILE" | grep -qE -- "$PROSE_RE" || exit 0
      # An Edit/MultiEdit envelope's new_string is only the replacement fragment — it may
      # carry the alias with no heading in sight, or vice versa. PostToolUse fires AFTER the
      # write has landed, so the file on disk is the one complete copy; read it when present
      # and fall back to the envelope's own content only when the file doesn't exist there.
      if [ -f "$FILE" ]; then
        DOC_CONTENT="$(cat "$FILE" 2>/dev/null)"
      else
        DOC_CONTENT="$CONTENT"
      fi
      rules_stamp "$DOC_CONTENT" "$FILE"
      # Prose is where a stamp lives and is never a classify target, with one exception
      # that is the person's own screen: a command file whose "## Format" section shapes
      # what he reads at wake, at conscience, at rest. That section is a UI surface and
      # the laws apply to it (the UX lens, 2026-09-06, D6: the surface that most needed
      # the laws was the one the rail was structurally unable to name).
      # A HEADING at depth two, outside any code fence: a "## Format" quoted inside a
      # fence is text about a command file, not a section of one, and "### Format" is
      # a subsection of something else (the 23rd lens, MINOR-7).
      if printf '%s\n' "$DOC_CONTENT" | awk '
            /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
            !fence && /^##[[:space:]]+Format[[:space:]]*$/ { found = 1; exit }
            END { exit !found }'; then
        rules_record_touch ui "$FILE"
      fi
      exit 0
    fi

    CLASS="$(rules_class_by_path "$FILE")"
    [ -n "$CLASS" ] || CLASS="$(rules_class_by_content "$CONTENT" "$FILE")"
    [ -n "$CLASS" ] || exit 0
    rules_record_touch "$CLASS" "$FILE"

    if [ "$CLASS" = "schema" ]; then
      SUMMARY="$(rules_lint_brief "$FILE")"
      # A schema-classified file that declares no table at all (an ALTER-only migration,
      # a file of INSERTs) is neither a finding nor a fix. Storing it would make the next
      # real result "a change", and whispering "clean now" would claim a repair that never
      # happened. Nothing said, nothing stored.
      # Written split so this line is not itself the marker rules_class_by_content looks for.
      case "$SUMMARY" in "no CREATE"*" found") SUMMARY="" ;; esac
      if [ -n "$SUMMARY" ]; then
        PREV="$(jq -r --arg sid "$SID" --arg f "$FILE" '.rules[$sid].findings[$f] // ""' "$CARE" 2>/dev/null)"
        if [ "$SUMMARY" != "$PREV" ]; then
          if [ "$SUMMARY" = "clean" ]; then
            [ -n "$PREV" ] && printf 'Maude: %s is clean now.\n' "$(basename "$FILE")" >&2
          else
            printf 'Maude: %s: %s\n' "$(basename "$FILE")" "$SUMMARY" >&2
          fi
          _set '.rules[$sid].findings[$f] = $s' --arg f "$FILE" --arg s "$SUMMARY"
          maude_log_trace "rules" "lint file=$FILE $SUMMARY"
        fi
      fi
    fi
    exit 0
    ;;

  check)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
    printf '%s' "$CMD" | grep -qE -- "$COMMIT_RE" || exit 0
    [ -f "$CARE" ] || exit 0
    # After the commit guard, not before it: this branch is called on EVERY Bash tool
    # call, and a care.json read on each one buys nothing: nothing here reads .rules
    # until a commit does. It is still the first thing the check's own work does.
    rules_prune_stale

    for CLASS in ui schema memory; do
      N="$(_get '.rules[$sid].touched["'"$CLASS"'"] // [] | length')"
      [ "${N:-0}" -gt 0 ] || continue
      [ -z "$(_get '.rules[$sid].named["'"$CLASS"'"].ts // ""')" ] || continue
      LAST="$(_get '.rules[$sid].last_touch["'"$CLASS"'"] // ""')"
      CHECKED="$(_get '.rules[$sid].checked["'"$CLASS"'"] // ""')"
      # Second-resolution timestamps: a touch landing in the SAME second as the last check is
      # not distinguishable from "before" by string compare alone, so treat it as a re-arm
      # rather than silence — skip only when the touch is strictly earlier. The failure mode of
      # guessing wrong here is one extra whisper, never a missed one; that is the safe direction.
      if [ -n "$CHECKED" ] && [ "$LAST" \< "$CHECKED" ]; then continue; fi
      case "$CLASS" in
        ui)     printf 'Maude: %s UI file(s) changed this session and no design names a Law of UX. Name the ones this holds to before you call this done. /maude:rules ux.\n' "$N" >&2 ;;
        schema) printf 'Maude: %s schema file(s) changed this session and no design names a normal form. Name the forms each table holds to before you call this done. /maude:rules db.\n' "$N" >&2 ;;
        memory) printf 'Maude: %s memory file(s) changed this session and no design names a law of memory. Name the ones this holds to before you call this done. /maude:rules memory.\n' "$N" >&2 ;;
      esac
      _set '.rules[$sid].checked[$c] = $ts' --arg c "$CLASS"
      maude_log_trace "rules" "check class=$CLASS touched=$N unnamed"
    done

    # Open schema findings, re-run on disk now; whispered when the count changes.
    if _python_ok; then
      OPEN=0; FILES=0
      while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        rules_is_fixture "$f" && continue
        FILES=$((FILES + 1))
        S="$(rules_lint_brief "$f")"
        case "$S" in
          ""|clean) ;;
          *)
            n="${S%% finding*}"
            case "$n" in ''|*[!0-9]*) n=0 ;; esac
            OPEN=$((OPEN + n))
            ;;
        esac
      done <<EOF_FILES
$(_get '.rules[$sid].touched.schema // [] | .[]')
EOF_FILES
      if [ "$OPEN" -gt 0 ]; then
        KEY="$OPEN/$FILES"
        if [ "$(_get '.rules[$sid].commit_findings // ""')" != "$KEY" ]; then
          printf 'Maude: %s finding(s) still open across %s schema file(s) touched this session. /maude:rules db <path> lists them.\n' "$OPEN" "$FILES" >&2
          _set '.rules[$sid].commit_findings = $k' --arg k "$KEY"
        fi
      fi
    fi
    exit 0
    ;;

  *) exit 0 ;;
esac
