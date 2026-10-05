#!/usr/bin/env bash
# Maude session-start hook — degradative brief across every reachable memory source.
# Reads: Anthropic auto-memory, .remember/, user-global home, house-map.
# Never blocks startup. Each missing tier is silently skipped.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

PROJ="$(maude_project_dir)"
MEM="$(maude_mem_dir)"
USER_DIR="$(maude_user_dir)"
REMEMBER="$PROJ/.remember"
MAP="$(maude_map_path)"

# ── Once-per-session housekeeping ────────────────────────────────────────────
# SessionStart is the once-per-start hook (it fires at each start/resume/clear/
# compact, not per turn), so it's the natural chokepoint for:
#   1. Pruning append-only artifacts (trace JSONL, pre-compact snapshots, undo blobs)
#      past the retention window — they grew unbounded before. The sweep runs LAST,
#      after the brief is printed and billed (see the bottom of this file).
#   2. A single jq-missing notice. Without jq the irreversible-command gate is
#      fail-OPEN (silently disabled), and drift-watch / tier-1 / watch-list
#      nudges are off too. This is a SAFETY notice, not cosmetic — so it must
#      fire even when there's no memory to brief (i.e. before the early-exit).
if ! command -v jq >/dev/null 2>&1; then
  printf 'Maude: jq not found — the irreversible-command gate is OFF this session (fail-open), and drift-watch, tier-1, and watch-list nudges are disabled. Install jq to restore them.\n' >&2
fi
# Probed by executing, not presence: Windows resolves python3 to the Microsoft
# Store alias stub and a CLT-less macOS ships a shim — both are "present" and
# run nothing. Named once here; the organs themselves sit out quietly.
if ! maude_python3_ok; then
  printf 'Maude: python3 is missing or not working on this box — the vault, the tape, and the eye sit out this session. Install python 3 (on Windows: real python, not the Store alias) to restore them.\n' >&2
fi
case "${MAUDE_RUN_GOVERNOR:-on}" in
  off|OFF|0|false|no|NO)
    printf 'Maude: run-governor is OFF this session (MAUDE_RUN_GOVERNOR=%s) — no run-length checkpoints or pauses.\n' "$MAUDE_RUN_GOVERNOR" >&2
    ;;
esac

# Collect signals across every available tier — degradative, each independent.
NOW_LINE=""
REMEMBER_HANDOFF=""
PATTERN_HINT=""
LETTER_LINE=""
HAS_MAP=""
TOPIC_COUNT=0

# Tier 1: Anthropic auto-memory live buffer
# Append-only, oldest-first: the newest entry is the LAST header, never the first
# (the wake read the first one as "now" until 2026-09-06).
if [ -f "$MEM/now.md" ]; then
  NOW_LINE="$(grep -E '^## [0-9]{2}:[0-9]{2}' "$MEM/now.md" | tail -1 | head -c 200)"
  [ -z "$NOW_LINE" ] && NOW_LINE="$(head -1 "$MEM/now.md" | head -c 200)"
fi

# Tier 1b: the remember plugin's live buffer ($REMEMBER/now.md) — updated continuously,
# so usually FRESHER than the Anthropic now.md (which can lag an hour+). Surface its
# NEWEST entry as "where you left off", so the wake path reads CURRENT state instead of a
# lagging source while the fresh capture sits unread. (The continuity gap the live
# dogfood exposed: session-start was reading the stale buffer and an empty handoff while
# this file held the freshest summary.) Entries are oldest-first; newest is at the bottom.
# SCOPE: under an umbrella root (one shared .remember/ across projects), the newest entry
# is workspace-WIDE — it may name a different project than the current focus. Intended:
# one session spans the whole workspace, so "the latest thing done anywhere" is where you
# left off. In a single-project .remember/, it's naturally that project's latest.
# THIS LANE's newest entry (2026-09-25). Entry headers are "## HH:MM | <label>", the
# label being the writer's branch slot; with remember's REMEMBER_BRANCH_CMD pointed at
# scripts/maude-lane it is the lane, named by the same maude_session_label this reads
# with. Unset, every entry said "unknown" and the wake greeted one lane with another's
# line. So: the newest entry labelled with this lane; else the newest entry, saying
# whose it is ("workspace-wide" for unlabelled) and that this lane has none yet.
# The session's lane, once, for both readers below: a namespaced name, because a bare LANE
# picked up whatever the environment held (lens 2: LANE=pacioli relabelled the line).
_MAUDE_LANE="$(maude_session_label "")"
LEFTOFF_LINE=""
LEFTOFF_SRC="workspace-wide"
if [ -s "$REMEMBER/now.md" ]; then
  # No awk interval expressions ({n,m}): mawk before 20200717 has none and matched nothing,
  # so the line vanished silently (lens 2, I3). CRs are dropped; the body and the label are
  # cut inside awk at a character boundary, never mid-sequence.
  LEFTOFF_PICK="$(LC_ALL=C awk -v lane="$_MAUDE_LANE" '
    function cut(x, n) { if (length(x) <= n) return x; x = substr(x, 1, n); sub(/[\300-\377][\200-\277]*$/, "", x); return x }
    { gsub(/\r/, "") }
    /^## [0-9][0-9]?:[0-9][0-9]/ {
      n++; lbl = ""
      if (index($0, "|")) { lbl = substr($0, index($0, "|") + 1); gsub(/^[ \t]+|[ \t]+$/, "", lbl) }
      L[n] = lbl; B[n] = ""; next
    }
    n && B[n] == "" && $0 !~ /^[ \t]*$/ && $0 !~ /^--$/ { B[n] = $0 }
    END {
      if (!n) exit
      for (i = n; i >= 1; i--) if (tolower(L[i]) == tolower(lane) && B[i] != "") { print cut(L[i], 80) "\t" cut(B[i], 240); exit }
      for (i = n; i >= 1; i--) if (B[i] != "") {
        src = L[i]; if (src == "" || src == "unknown") src = "workspace-wide"
        print cut(src, 60) "; none yet for " cut(lane, 20) "\t" cut(B[i], 240); exit
      }
    }' "$REMEMBER/now.md" 2>/dev/null)"
  if [ -n "$LEFTOFF_PICK" ]; then
    LEFTOFF_SRC="${LEFTOFF_PICK%%	*}"
    LEFTOFF_LINE="${LEFTOFF_PICK#*	}"
  fi
fi

# Tier 2: remember plugin's handoff file (the dense, intentional signal from last session)
# The handoff file is append-only under the house law: the LAST "## Next" block is the
# last handoff (grep -m1 read the first of thirty-one and labelled it "Last" until
# 2026-09-06). The line carries the file's own age, so a stale handoff says so.
#
# THIS LANE's handoff, whole enough to act on (2026-09-25). One file holds every lane's
# handoffs, each opening "# Handoff … (<lane> lane …)". One line from the last "## Next"
# anywhere was the wrong subject twice over: another lane's, and when the newest block had
# no "## Next", the block before it, whose Next ("fix pmg dropping orderby") its own later
# trap said NOT to do. So: the last block whose HEADER names this lane (the tmux session
# name, maude_session_label), else the newest block, labelled whose it is; from its State
# (else its Next, else its body) onward, so a block's Traps ride along. Capped at
# HANDOFF_CAP bytes: past ~3.5 KB the harness parks the whole brief in a file unread.
# A file with no "# Handoff" headers keeps the older last-"## Next" reading.
REMEMBER_AGE=""
HANDOFF_CAP="${MAUDE_HANDOFF_CAP:-1200}"
case "$HANDOFF_CAP" in ''|*[!0-9]*) HANDOFF_CAP=1200 ;; esac
# Base 10 and bounded: "08" was a bash arithmetic error (value too great for base), "0300"
# silently octal 192 (lens 4). Five digits is past any sane cap.
[ "${#HANDOFF_CAP}" -gt 5 ] && HANDOFF_CAP=99999
HANDOFF_CAP=$((10#$HANDOFF_CAP))
# LC_ALL=C: bytes, not characters. Under gawk in a UTF-8 locale (the default awk on Fedora
# and Arch) length/substr count characters, so every cap here was a character cap, up to
# ~3x in bytes, and the byte classes below would read as code points (lens 3, I-D).
_maude_handoff() {  # <cap>
  LC_ALL=C awk -v lane="$_MAUDE_LANE" -v cap="$1" '
    # The lane is whatever stands before " lane" inside the header parentheses, compared
    # whole: a charset regex read "ma.ude+ lane" as "ude" and "my lane" as "my", and told a
    # lane that its own block belonged to nobody (lens 5). The bare "<token> lane" form is
    # kept for headers written without parentheses. (No apostrophes in here: the program is
    # a single-quoted shell string.)
    function lane_of(h,  l, x) {
      l = tolower(h)
      if (match(l, /\([^()]* lane[,)]/)) {
        # The LAST comma item before " lane": "(opus 5, sur lane)" is sur, not "opus 5, sur"
        # (lens 6: five live headers read wrong the other way).
        x = substr(l, RSTART + 1, RLENGTH - 7); sub(/^.*, */, "", x); return x
      }
      # Bare form: the words before " lane", each starting with a letter, so a lane of two
      # words ("pierce county lane", live on 09-15) is whole and a date or time before it
      # is not swept in (lens 7). A leading "handoff" is the title, not the lane.
      # The run must start at a token boundary (a space is prepended so a first-column
      # token has one): "07:5xZ maude lane" must read maude, not "xz maude".
      if (match(" " l, /[^a-z0-9_.+:-][a-z][a-z0-9_.+-]*( [a-z][a-z0-9_.+-]*)* lane/)) {
        x = substr(" " l, RSTART + 1, RLENGTH - 6); sub(/^handoff /, "", x); return x
      }
      return ""
    }
    # Cut at a character boundary: drop the trailing lead byte and its continuations, so a
    # partial sequence never prints (at an exact boundary this drops one whole character).
    # Stripping every trailing byte >= 0x80 dropped a whole line of em dashes (lens 2).
    function cut(x, n) { if (length(x) <= n) return x; x = substr(x, 1, n); sub(/[\300-\377][\200-\277]*$/, "", x); return x }
    { gsub(/\r/, ""); L[NR] = $0 }
    /^# Handoff/ { hn++; H[hn] = NR; HL[hn] = lane_of($0) }
    END {
      if (!hn) exit 3
      pick = 0
      for (i = hn; i >= 1; i--) if (HL[i] == tolower(lane)) { pick = i; break }
      mine = (pick > 0); if (!pick) pick = hn
      s = H[pick]; e = (pick < hn) ? H[pick + 1] - 1 : NR
      n = 0; st = 0
      for (j = s + 1; j <= e; j++) if (L[j] ~ /^## Next/) n = j
      for (j = s + 1; j <= e; j++) if (L[j] ~ /^## State/ && (n == 0 || j < n)) st = j
      b = st ? st : (n ? n : s + 1)
      hdr = L[s]; sub(/^# Handoff[^A-Za-z0-9(]*/, "", hdr)
      if (length(hdr) > 200) hdr = cut(hdr, 200) "…"
      if (!mine) hdr = hdr " [newest; none yet for " cut(lane, 20) "]"
      print hdr
      # Every PRINTED byte counts: the 4-space indent and the newline too. Counting the text
      # alone let 400 short lines print 2.5 KB against a 1,200 cap (lens 2, I2).
      used = 0
      for (j = b; j <= e; j++) {
        x = L[j]
        if (x ~ /^[ \t]*$/) continue
        if (used + length(x) + 5 > cap) {
          x = cut(x, cap - used - 8)
          if (length(x) > 0) print "    " x "…"
          break
        }
        print "    " x; used += length(x) + 5
      }
      print "    (full: .remember/remember.md:" s ")"
    }' "$REMEMBER/remember.md" 2>/dev/null
}
if [ -s "$REMEMBER/remember.md" ]; then
  REMEMBER_HANDOFF="$(_maude_handoff "$HANDOFF_CAP")"
  HANDOFF_FROM_BLOCKS=""; [ -n "$REMEMBER_HANDOFF" ] && HANDOFF_FROM_BLOCKS=1
  if [ -z "$REMEMBER_HANDOFF" ]; then
    REMEMBER_HANDOFF="$(grep -A1 '^## Next' "$REMEMBER/remember.md" 2>/dev/null \
      | grep -vE '^## |^--$|^[[:space:]]*$' | tail -1 | head -c 200)"
  fi
  [ -z "$REMEMBER_HANDOFF" ] && REMEMBER_HANDOFF="$(head -3 "$REMEMBER/remember.md" | tail -1 | head -c 200)"
  # The chosen block's own date when its header carries one: every lane appends here, so
  # the file's mtime read "today" beside a ten-day-old handoff.
  # The header's LAST date: a date in a reference comes first ("session 2026-09-01 ref").
  HANDOFF_DATE="$(printf '%s\n' "$REMEMBER_HANDOFF" | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)"
  REMEMBER_AGE_D=""
  [ -n "$HANDOFF_DATE" ] && REMEMBER_AGE_D="$(maude_days_between "$HANDOFF_DATE" "$(date +%Y-%m-%d)")"
  # A block whose header carries a date in some OTHER shape ("09/20/2026") is "undated",
  # never the shared file's mtime, which read it as "today" (lens 5). A header with no
  # date at all (the old one-title shape, "# Handoff") still reads the file's mtime.
  # Date-shaped = a four-digit year at one end ("09/20/2026", "2026.09.25"); "v1.2.34" is
  # a version, not a date, and read as one it said "undated" for a header with no date (lens 6).
  if [ -n "$HANDOFF_FROM_BLOCKS" ] && [ -z "$HANDOFF_DATE" ] \
     && printf '%s\n' "$REMEMBER_HANDOFF" | head -1 | grep -Eq '(^|[^0-9.A-Za-z])([0-9]{1,2}[/.][0-9]{1,2}[/.][0-9]{4}|[0-9]{4}[/.][0-9]{1,2}[/.][0-9]{1,2})([^0-9.]|$)'; then
    REMEMBER_AGE="undated"
  else
    case "$REMEMBER_AGE_D" in ''|*[!0-9-]*)
      REMEMBER_AGE_D=$(( ( $(date +%s) - $(maude_mtime "$REMEMBER/remember.md") ) / 86400 )) ;;
    esac
    if [ "$REMEMBER_AGE_D" -lt 1 ]; then REMEMBER_AGE="today"; else REMEMBER_AGE="${REMEMBER_AGE_D}d ago"; fi
  fi
fi

# Tier 3: cross-project patterns (her own home base) — one scar per wake, rotating.
# Day-of-year cycles through the entry HEADINGS: every pattern gets airtime and none
# pins forever (the old basename-grep locked onto any entry whose BODY contained the
# project name — e.g. a path — and truncated it mid-sentence into what read like a
# live alert). A ## heading is a complete dated sentence; history stays history.
if [ -s "$USER_DIR/patterns.md" ]; then
  PATTERN_HINT="$(awk -v day="$(date +%j | sed 's/^0*//')" '
    /^## / { h[n++] = substr($0, 4) }
    END { if (n > 0) print h[day % n] }
  ' "$USER_DIR/patterns.md" 2>/dev/null | head -c 200)"
fi

# Tier 3b: her letter to her next self (written at /maude:rest — read-only here,
# like every hook). First non-header, non-blank line is the essence; the wake/brief
# commands read the whole letter.
LETTER_LINE=""
if [ -s "$USER_DIR/letter-from-maude.md" ]; then
  LETTER_LINE="$(grep -m1 -v -E '^#|^[[:space:]]*$' "$USER_DIR/letter-from-maude.md" 2>/dev/null | head -c 160)"
fi

# Tier 4: house-map status. The map is a dated document ("# Walked: YYYY-MM-DD"); the
# tick used to throw that date away and assert a currency the file never claimed. Now
# the tick carries the date the map claims and the age of the file, and past a week it
# names the re-walk. A presence check is not a currency check.
MAP_NOTE=""
if [ -f "$MAP" ]; then
  HAS_MAP="✓"
  MAP_WALKED="$(grep -m1 -oE '^# Walked: [0-9]{4}-[0-9]{2}-[0-9]{2}' "$MAP" 2>/dev/null | sed 's/^# Walked: //')"
  if [ -n "$MAP_WALKED" ]; then
    MAP_AGE_D=$(( ( $(date +%s) - $(maude_mtime "$MAP") ) / 86400 ))
    MAP_NOTE=" walked $MAP_WALKED, ${MAP_AGE_D}d old"
    [ "$MAP_AGE_D" -gt 7 ] && MAP_NOTE="$MAP_NOTE; /maude:found"
  else
    MAP_NOTE=", undated"
  fi
fi

# Tier 5: simple count of memory files in Anthropic dir
[ -d "$MEM" ] && TOPIC_COUNT="$(find "$MEM" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')"

# She ALWAYS greets — her once-per-session voice is a RAIL, not a condition. Even on
# a pristine project (no memory, no map) her name lands, with a /maude:found nudge.
# (Previously an early-exit-on-nothing stayed silent here; removed so the greeting can
# never be skipped — the guaranteed once-per-session presence the plugin promises.)

# Compose brief — terse, one stanza per signal that fired.
# Greet by the user's local clock when the timezone is known (house-map);
# stay time-neutral otherwise — never assert a time-of-day from the box clock.
# Maude's one JOHN-facing line: what she caught since he last looked. Watermark-based
# (last_digest_iso in care.json) so it never re-prints across SessionStart's resume/
# clear/compact re-fires. Computed before the brief so the catch leads the stanza.
DIGEST_LINE="$(maude_digest_line)"

# Continuity guard: warn at the top if the last save is stale vs real trace activity —
# the closing loop so a forgotten /maude:rest degrades continuity loudly, not silently.
CONTINUITY_LINE="$(maude_continuity_guard)"

# Cushion line (issue #36): render the last flip's stamp — count + age, one line.
# No re-scan at wake (the flip walks every repo; too heavy for session-start);
# absent stamp = the nudge, so the ritual can't quietly reapply its own problem
# ("nobody checks the places nobody sweeps") to itself.
CUSHION_LINE=""
CUSHION_STAMP="$(maude_self_dir)/cushions-last"
if [ -f "$CUSHION_STAMP" ]; then
  read -r C_EPOCH C_COUNT < "$CUSHION_STAMP" 2>/dev/null
  # Both fields must be non-empty and numeric — the ':' probe catches a missing
  # field (leading/trailing colon) that bare concatenation would let slip.
  case "${C_EPOCH}:${C_COUNT}" in
    *[!0-9:]*|:*|*:) : ;;  # malformed stamp → say nothing rather than something wrong
    *)
      C_AGE_D=$(( ( $(date +%s) - C_EPOCH ) / 86400 ))
      if [ "$C_AGE_D" -lt 1 ]; then C_WHEN="today"; else C_WHEN="${C_AGE_D}d ago"; fi
      C_PL="s"; [ "$C_COUNT" = "1" ] && C_PL=""
      CUSHION_LINE="Cushions: $C_COUNT value candidate$C_PL — last flipped $C_WHEN." ;;
  esac
else
  CUSHION_LINE="Cushions: never flipped — /maude:cushions when you have a minute."
fi

# A background lens leaves a PENDING stamp at launch (redteam-watch); if its session ends
# first, nothing promotes it and nothing says so (the 23rd lens, 2026-09-06: the next
# wake read a 477-byte stub as "running"). Name a pending entry older than ten minutes:
# a live lens in a sibling session is younger than that; a dead one only gets older.
# Expired gate tokens are pruned once per session. The prune at a reservation only runs when
# that key's token is LIVE, so a store holding nothing but expired rows was never cleaned and
# the PostToolUse cheap exit stayed dead on any box that had ever been given a clear (the
# 27th lens, MINOR-2). Both files, best effort, never blocking.
if command -v jq >/dev/null 2>&1; then
  _NOWS=$(date +%s)
  for _tf in "$(maude_self_dir)/care.json" "$(maude_redclear_file)"; do
    [ -s "$_tf" ] || continue
    jq -e --argjson now "$_NOWS" '(.gate_cleared // {}) | if type=="object" then to_entries else [] end
      | any((.value.until? // 0 | if type == "number" then . else 0 end) <= $now)' "$_tf" >/dev/null 2>&1 || continue
    maude_care_set "$_tf" --argjson now "$_NOWS" \
      '.gate_cleared = ((.gate_cleared // {}) | if type == "object" then . else {} end
         | with_entries(select((.value.until? // 0 | if type == "number" then . else 0 end) > $now)))' >/dev/null 2>&1 \
      && maude_log_trace "gate" "pruned expired tokens from $(basename "$_tf")"
  done
fi

PENDING_LINE=""
_CARE_FILE="$(maude_self_dir)/care.json"
if [ -s "$_CARE_FILE" ] && command -v jq >/dev/null 2>&1; then
  _CUT_EPOCH=$(( $(date +%s) - 600 ))
  # Through the shared helper: `date -d` is GNU-only and test-portability refuses it here.
  # A box with neither `date -d` nor `date -r` cannot tell a pending entry's age; then
  # every pending entry is named ("~" sorts after any ISO time). The line exists because
  # a dead lens is visible only if something says so: loud, never silent (MINOR-4).
  _CUT="$(maude_epoch_iso "$_CUT_EPOCH" 2>/dev/null)" || _CUT="~"
  if [ -n "$_CUT" ]; then
    # Every entry's own type is guarded too: one malformed entry used to silence the line
    # for every good one beside it, which is the failure this line exists to prevent (the
    # 25th lens, MINOR-1). Oldest first, and the others' subjects are named rather than
    # counted (MINOR-2: "and 4 more" withheld exactly what the reader needed).
    PENDING_LINE="$(jq -r --arg cut "$_CUT" '
      # Total: jq raises on join over a non-scalar, and one bad entry took the whole line
      # down — silence, in the line whose only job is not to be silent (the 26th lens,
      # IMPORTANT-5). Bounded: the byte cut used to end mid-sha, and a truncated ref reads
      # exactly like a whole one (MINOR-5).
      # Bounded per SUBJECT as well as per entry: this hook writes up to 64 refs on one
      # pending entry, so bounding the number of subjects still let one of them run the line
      # past its budget and end mid-sha, and a truncated ref reads exactly like a whole one
      # (the 27th lens, IMPORTANT-4).
      # TOTAL IN THE SUBJECT TOO. An empty refs array joined to the empty string and the
      # sentence lost the only noun it had: "its stamp on  is pending" — which is what
      # this box printed at the wake on 2026-09-07. refs:[] is not a corrupt entry, it is
      # what the stamp writes whenever a brief names no literal sha, so the empty case is
      # ordinary. A reader given a blank subject cannot tell "named nothing" from "the
      # line broke"; say which.
      def refstr: (if type == "array"
                   then ((map(tostring) | .[0:4] | join(",")) + (if length > 4 then " +\(length - 4)" else "" end))
                   else (. // "" | tostring) end)
                  | if ((gsub(",";"") | gsub(" ";"")) == "") then "an unnamed subject" else . end;
      [(.redteam_pending // {}) | if type=="object" then to_entries[] else empty end
       | select((.value | type) == "object")
       | select(((.value.ts // "") | tostring) < $cut)]
      | sort_by((.value.ts // "") | tostring)
      | if length == 0 then empty
        else "A lens dispatched at \(.[0].value.ts // "?") (session \(.[0].value.sid // "?")) never reported; its stamp on \((.[0].value.refs) | refstr) is pending"
             + (if length > 1
                then " (and \(length - 1) more, on " + ([.[1:5][] | (.value.refs | refstr)] | join(" · "))
                     + (if length > 5 then " and \(length - 5) other" + (if length == 6 then "" else "s" end) else "" end) + ")."
                else "." end) end' "$_CARE_FILE" 2>/dev/null)"
    # Bounding the ref COUNT per subject is not bounding the LINE: four subjects at four
    # 40-character shas passes the budget before a word of prose, and a byte cut lands
    # mid-sha where a fragment reads exactly like a whole reference (the 28th lens,
    # IMPORTANT-4). Cut on a separator, and always close the sentence.
    if [ "${#PENDING_LINE}" -gt 700 ]; then
      _PL="$(printf '%.700s' "$PENDING_LINE")"
      case "$_PL" in
        *" · "*) _PL="${_PL% · *}" ;;
        *,*)     _PL="${_PL%,*}" ;;
      esac
      PENDING_LINE="$_PL … (truncated; /maude:notice has the rest)."
    fi
  fi
fi

GREETING="$(maude_greeting)"
# Composed into a variable so the brief's bill can be logged (#49) — the
# emission itself is unchanged.
# Her mark, drawn by her, above the greeting (John, 2026-09-26: "wake brief banner, hers to
# draw" · "Maude for Claude" · "go back to your original MAUDE then put in txt for Claude
# below align right"). Plain 7-bit ASCII, five lines, 145 bytes, inside the brief so the
# budget counts it and the spend line bills it. MAUDE_BANNER=off hides it; nothing else moves.
_maude_banner() {
  case "${MAUDE_BANNER:-on}" in off|OFF|0|false|FALSE|no|NO) return 0 ;; esac   # the spellings MAUDE_RUN_GOVERNOR takes
  cat <<'EOF'
  __  __                _
 |  \/  | __ _ _  _ __| |___
 | |\/| |/ _` | || / _` / -_)
 |_|  |_|\__,_|\_,_\__,_\___|
                   for Claude
EOF
}
_maude_brief() {
  _maude_banner
  [ -n "$GREETING" ] && printf '%s ' "$GREETING"
  printf 'Maude here.'
  [ -n "$HAS_MAP" ] && printf ' (house-map ✓%s)' "$MAP_NOTE"
  printf '\n'
  [ -n "$DIGEST_LINE" ] && printf '  %s\n' "$DIGEST_LINE"
  [ -n "$CONTINUITY_LINE" ] && printf '  %s\n' "$CONTINUITY_LINE"
  [ -n "$PENDING_LINE" ] && printf '  %s\n' "$PENDING_LINE"
  [ -n "$LEFTOFF_LINE" ] && printf '  Where you left off (%s): %s\n' "$LEFTOFF_SRC" "$LEFTOFF_LINE"
  [ -n "$REMEMBER_HANDOFF" ] && printf '  Last handoff (.remember, %s): %s\n' "$REMEMBER_AGE" "$REMEMBER_HANDOFF"
  [ -n "$NOW_LINE" ]          && printf '  Anthropic now: %s\n' "$NOW_LINE"
  [ -n "$PATTERN_HINT" ]      && printf '  Cross-project pattern: %s\n' "$PATTERN_HINT"
  [ -n "$LETTER_LINE" ]       && printf '  Letter from my last self: %s\n' "$LETTER_LINE"
  [ "$TOPIC_COUNT" -gt 0 ]    && printf '  %s memory file(s) on hand.\n' "$TOPIC_COUNT"
  [ -n "$CUSHION_LINE" ]      && printf '  %s\n' "$CUSHION_LINE"
  [ -z "$HAS_MAP" ] && printf '  No house-map yet — run /maude:found.\n'
}
BRIEF="$(_maude_brief 2>/dev/null)"
# The WHOLE brief has a budget, not only the handoff: with every other line at its own cap
# the brief measured 3,858 bytes against the ~3.5 KB that lands inline (lens 3, I-D). Past
# MAUDE_BRIEF_MAX (default 3,300, leaving room for the chores line printed after it) the
# handoff, the one elastic line, is re-cut by the overrun, never below 150 bytes of body.
BRIEF_MAX="${MAUDE_BRIEF_MAX:-3300}"
case "$BRIEF_MAX" in ''|*[!0-9]*) BRIEF_MAX=3300 ;; esac
[ "${#BRIEF_MAX}" -gt 5 ] && BRIEF_MAX=99999
BRIEF_MAX=$((10#$BRIEF_MAX))
# One pass, from the handoff BODY's actual size (the header and pointer lines are not under
# the cap): a lower cap on a body already under its cap cut nothing, and measuring the whole
# block let a long header keep the cap above the body. The body's printed bytes never exceed
# its cap (every printed byte is counted), so cutting the cap by the overrun cuts the brief
# by at least that much, down to the floor.
_BRIEF_BYTES="$(printf '%s\n' "$BRIEF" | wc -c | tr -d ' ')"
if [ -n "$REMEMBER_HANDOFF" ] && [ "$_BRIEF_BYTES" -gt "$BRIEF_MAX" ]; then
  if [ -n "$HANDOFF_FROM_BLOCKS" ]; then
    _BODY="$(printf '%s\n' "$REMEMBER_HANDOFF" | sed '1d;$d' | wc -c | tr -d ' ')"
  else
    _BODY="$(printf '%s' "$REMEMBER_HANDOFF" | wc -c | tr -d ' ')"   # the line's bytes, no newline: the cut counts the same
  fi
  _CAP="$HANDOFF_CAP"; [ "$_BODY" -lt "$_CAP" ] && _CAP="$_BODY"
  _CAP=$(( _CAP - (_BRIEF_BYTES - BRIEF_MAX) ))
  [ "$_CAP" -lt 150 ] && _CAP=150
  if [ -n "$HANDOFF_FROM_BLOCKS" ]; then
    REMEMBER_HANDOFF="$(_maude_handoff "$_CAP")"
  else
    # The headerless shape is one line; the same budget cuts it the same way. It was
    # exempt, so the whole-brief budget was a no-op on the older file shape (lens 5).
    # The ellipsis (3 bytes) is inside the cap, as the block cut counts it.
    REMEMBER_HANDOFF="$(printf '%s\n' "$REMEMBER_HANDOFF" | LC_ALL=C awk -v cap="$_CAP" '
      { x = $0; if (length(x) > cap) { x = substr(x, 1, cap - 3); sub(/[\300-\377][\200-\277]*$/, "", x); x = x "…" } print x; exit }')"
  fi
  BRIEF="$(_maude_brief 2>/dev/null)"
fi
# At the floor and still over: said in the trace, not in silence (lens 4). The brief itself
# is not cut further; its other lines are each capped already.
_BRIEF_BYTES="$(printf '%s\n' "$BRIEF" | wc -c | tr -d ' ')"
[ "$_BRIEF_BYTES" -gt "$BRIEF_MAX" ] && \
  maude_log_trace "session-start" "brief $_BRIEF_BYTES bytes over MAUDE_BRIEF_MAX $BRIEF_MAX"
printf '%s\n' "$BRIEF"
# #49: the brief is injected context — log its bill (hook + bytes, no content).
maude_log_spend "session-start" "$(printf '%s' "$BRIEF" | wc -c | tr -d ' ')"

# The closet sweep runs AFTER the brief has been printed and billed. It used to run
# first, and on a big store it ate the whole hook budget: her greeting, the one
# once-per-session presence the plugin promises, never landed (2026-09-06).
maude_retention_sweep

# Chore brief — the ledger makes the labor visible (one line, silent when idle).
CHORES="$DIR/../../scripts/maude-chores.sh"
if [ -f "$CHORES" ]; then
  bash "$CHORES" detect >/dev/null 2>&1
  CHORE_LINE="$(bash "$CHORES" brief 2>/dev/null)"
  [ -n "$CHORE_LINE" ] && printf '  %s\n' "$CHORE_LINE"
fi

exit 0
