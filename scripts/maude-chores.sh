#!/usr/bin/env bash
# scripts/maude-chores.sh — Maude's hands: the chore ledger runner.
# Verbs: detect | dispatch [transcript_path] | run <chore> [args] | brief | stamp <id> <jq…>
# Spec: docs/specs/2026-07-16-chore-ledger-design.md
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../hooks/scripts/_maude-common.sh"

[ "${MAUDE_CHORES:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

CHORE_IDS="c1-missed-save c2-shelves c3-extension c4-claudemd"
SHELF_DAYS="${MAUDE_SHELF_DAYS:-7}"
COUPON_RE='🔴|OPEN:|TODO|NEXT:|unresolved'

chores_ledger() {
  local self; self="$(maude_self_dir)"
  maude_ensure_self_dir >/dev/null 2>&1
  [ -f "$self/chores.json" ] || printf '{}\n' > "$self/chores.json"
  printf '%s' "$self/chores.json"
}

# chore_stamp <id> <jq args…> '<filter>' — atomic mergy update (care_set pattern),
# serialized with a ledger-level flock so concurrent doers can't lose each
# other's writes (read→jq→mv is a lost-update race without it — reviewer
# reproduced 8/15 trials). Blocking flock, not -n: stamps are milliseconds: a
# doer must never lose its write. The lock lives in its own file
# ($ledger.lock) — distinct from the per-chore dispatch lock files
# ($self/.chore-$id.lock) used by verb_dispatch, so the two locking layers
# can never deadlock each other.
chore_stamp() {
  local id="$1"; shift
  local ledger lock tmp; ledger="$(chores_ledger)"; lock="$ledger.lock"; tmp="$ledger.tmp.$$"
  (
    flock 9
    jq "$@" "$ledger" > "$tmp" 2>/dev/null && mv -f "$tmp" "$ledger" || rm -f "$tmp"
  ) 9>"$lock"
}

verb_detect() {
  local now id; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  chores_ledger >/dev/null
  for id in $CHORE_IDS; do
    local fn="chore_detect_${id//-/_}" due=false
    if type "$fn" >/dev/null 2>&1 && "$fn"; then due=true; fi
    chore_stamp "$id" --arg t "$now" --argjson d "$due" \
      ".[\"$id\"] += {last_detect:\$t, due:\$d}"
  done
}

verb_brief() {
  local ledger; ledger="$(chores_ledger)"
  jq -r '
    [ to_entries[] | select(.value.status != null)
      | "\(.key)=\(.value.status)\(if .value.note then " (" + .value.note + ")" else "" end)" ]
    | if length == 0 then empty else "Chores: " + join(" · ") end
  ' "$ledger" 2>/dev/null
}

CHORE_MODEL="${MAUDE_CHORE_MODEL:-haiku}"   # PINNED — doers never inherit the session model
BLINK_TIMEOUT="${MAUDE_CHORE_BLINK_TIMEOUT:-90}"

# chore_blink <prompt-on-stdin> → model output (or empty on failure). Exit != 0 on failure.
chore_blink() {
  local runner="${MAUDE_CHORE_RUNNER_OVERRIDE:-claude}" raw
  if [ "$runner" = "claude" ]; then
    raw="$(MAUDE_EYE_BLINK=1 timeout "$BLINK_TIMEOUT" \
      claude -p --model "$CHORE_MODEL" --safe-mode --no-session-persistence --tools "" 2>/dev/null | head -c 8000)"
  else
    raw="$(MAUDE_EYE_BLINK=1 timeout "$BLINK_TIMEOUT" "$runner" 2>/dev/null | head -c 8000)"
  fi
  [ -n "$raw" ] || return 1
  printf '%s' "$raw"
}

chore_run_c1_missed_save() {
  local transcript="$1" t0 t1 digest tail remember model
  t0="$(date +%s)"
  [ -f "$transcript" ] || { chore_fail c1-missed-save "no transcript"; return 1; }
  # No .remember/ substrate → nothing to write into and nothing to manufacture
  # uninvited (mirrors maude-session-end.sh's guard). Named undone, not failed:
  # this isn't an error, it's a project that never opted into the substrate.
  maude_have_remember || {
    chore_stamp c1-missed-save '.["c1-missed-save"] += {status:"undone", note:"no .remember substrate — save skipped"}'
    return 0
  }
  tail="$(tail -c 60000 "$transcript")"
  digest="$(printf '%s\n\n%s\n' \
    "You are Maude writing the session handoff nobody typed. From this Claude Code transcript tail, write a SHORT handoff digest in exactly this shape - three markdown sections: '## Done' (what shipped/changed, one line each), '## Decided' (rulings made), '## Open' (unfinished threads, next moves). Plain sentences, no praise, max 25 lines total. Output ONLY the digest markdown." \
    "$tail" | chore_blink)" || { chore_fail c1-missed-save "blink failed"; return 1; }
  digest="$(printf '%s' "$digest" | maude_redact)"
  [ -n "$digest" ] || { chore_fail c1-missed-save "empty digest"; return 1; }

  # Never lose human/plugin content: a non-empty remember.md ALWAYS gets an
  # append under a dated heading, never a replace — no mtime/anchor comparison,
  # which used to compare remember.md's own mtime against an anchor that
  # includes remember.md itself in its 3-way max (a fresh human write followed
  # by any touch of another anchor source flipped this into the replace branch
  # and destroyed the handoff — reviewer reproduced it). Only an absent/empty
  # slot gets a plain write.
  remember="$(maude_remember_dir)/remember.md"
  if [ -s "$remember" ]; then
    printf '\n## Maude — %s (the save nobody typed)\n\n%s\n' \
      "$(date -u +%Y-%m-%d)" "$digest" >> "$remember"
  else
    printf '%s\n' "$digest" > "$remember"
  fi
  printf '%s\n' "$digest" > "$(maude_self_dir)/chore-c1-latest.md"

  t1="$(date +%s)"
  model="$CHORE_MODEL"; [ -n "${MAUDE_CHORE_RUNNER_OVERRIDE:-}" ] && model="stub"
  chore_stamp c1-missed-save --arg m "$model" --argjson rt "$((t1 - t0))" \
    '.["c1-missed-save"] += {status:"done", note:"handoff written", cost:{model:$m, runtime_s:$rt}}'
}

chore_fail() {
  chore_stamp "$1" --arg r "$2" ".[\"$1\"] += {status:\"failed\", note:\$r}"
}

verb_run() {
  local id="$1"; shift
  local fn="chore_run_${id//-/_}"
  # Trap catches TERM/INT between commands and any abnormal exit; SIGKILL is
  # uncatchable. Signals arriving while blocked on the blink's foreground
  # child defer to that child's completion, where `timeout` and the `||`
  # failure paths below take over. Stale last_run on the brief is the
  # residual signal for the uncatchable cases.
  trap 'chore_fail_if_unstamped "$id"' EXIT TERM INT
  if type "$fn" >/dev/null 2>&1; then
    "$fn" "$@" || chore_fail_if_unstamped "$id"
  fi
  maude_log_trace "chore" "$id"
}

# Safety net: a doer that crashed before stamping leaves 'dispatched' forever — convert to failed.
chore_fail_if_unstamped() {
  local st; st="$(jq -r ".[\"$1\"].status // \"\"" "$(chores_ledger)")"
  [ "$st" = "dispatched" ] && chore_fail "$1" "doer crashed"
}

# ── C1: the save nobody typed ────────────────────────────────────────────
chore_detect_c1_missed_save() {
  local n thr
  # No .remember/ substrate → never due; nagging every wake for a project that
  # never opted into the substrate is noise, and the doer keeps its own guard
  # as defense in depth (a direct `run c1-missed-save` still no-ops safely).
  maude_have_remember || return 1
  n="$(maude_uncaptured_prompt_count)"
  thr="${MAUDE_CHORE_SAVE_THRESHOLD:-6}"
  [ "${n:-0}" -ge "$thr" ]
}

# ── C2: the coupon-cut (clip + stage) ────────────────────────────────────
# Aging dailies she can SEE: .remember/ (may re-roll later) + auto-memory (read-only).
c2_pile_candidates() {
  local rem mem
  rem="$(maude_remember_dir)"; mem="$(maude_mem_dir)"
  [ -d "$rem" ] && find "$rem" -maxdepth 1 -type f -name 'today-*.md' -mtime +"$SHELF_DAYS" 2>/dev/null
  [ -d "$mem" ] && find "$mem" -maxdepth 1 -type f -name 'today-*.md' -mtime +"$SHELF_DAYS" 2>/dev/null
}

chore_detect_c2_shelves() { [ -n "$(c2_pile_candidates | head -1)" ]; }

chore_run_c2_shelves() {
  local t0 t1 self coupons keys staged anchor f m clipped=0 stagedn=0
  t0="$(date +%s)"; self="$(maude_self_dir)"
  coupons="$self/coupons.md"; keys="$self/coupons.keys"; staged="$self/chore-c2-staged.txt"
  anchor="$(maude_capture_anchor_epoch)"
  : > "$staged"; touch "$coupons" "$keys"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Coupon-cut: live markers not yet clipped — dedup against the keys sidecar
    # by EXACT whole-line match (-x), not substring containment. Substring
    # containment against coupons.md's display text would silently drop a
    # distinct SHORTER marker that happens to be contained in an already-clipped
    # longer one (e.g. "TODO fix login" swallowed by a prior "TODO fix login
    # page thoroughly and add tests") — a live marker lost, exactly what the
    # coupon-cut exists to prevent. No count cap on markers per file: aged
    # files never change, so a cap would be permanent silent loss, not
    # deferral — a pathological single line is bounded to 400 chars instead.
    while IFS= read -r line; do
      grep -qxF -- "$line" "$keys" 2>/dev/null || {
        printf '%s\n' "$line" >> "$keys"
        printf -- '- %s: %s\n' "$(basename "$f")" "$line" >> "$coupons"
        clipped=$((clipped+1)); }
    done < <(grep -hE "$COUPON_RE" "$f" 2>/dev/null | cut -c1-400)
    # Stage for re-roll ONLY .remember/ dailies that are covered (anchor newer).
    case "$f" in
      "$(maude_remember_dir)"/today-*.md)
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        if [ "$anchor" -gt "$m" ]; then printf '%s\n' "$f" >> "$staged"; stagedn=$((stagedn+1)); fi ;;
    esac
  done < <(c2_pile_candidates)

  # Re-roll (rigid until known): opt-in, verbatim, verified, logged.
  if [ "${MAUDE_REROLL:-off}" = "on" ]; then
    local arch rolled=0 dest
    arch="$(maude_remember_dir)/archive"
    mkdir -p "$arch" 2>/dev/null
    if [ ! -d "$arch" ]; then
      printf '%s ARCHIVE-DIR-UNCREATABLE %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arch" \
        >> "$self/chore-c2-moves.log"
    elif [ -d "$arch" ]; then
      while IFS= read -r f; do
        [ -f "$f" ] || continue
        # Path prefix re-check: only from .remember/
        case "$f" in "$(maude_remember_dir)"/today-*.md) : ;; *) continue ;; esac
        # Age gate is stricter than the shelf: only truly cold files move.
        find "$f" -mtime +"${MAUDE_REROLL_DAYS:-30}" 2>/dev/null | grep -q . || continue
        case "$(basename "$f")" in today-*.md) : ;; *) continue ;; esac   # dailies ONLY
        dest="$arch/$(basename "$f")"
        [ -e "$dest" ] && continue                       # refuse collision
        cp -p "$f" "$dest" 2>/dev/null || { rm -f "$dest"; continue; }  # partial-copy cleanup on failure
        cmp -s "$f" "$dest" || { rm -f "$dest"; continue; }  # verify byte-identity or abort
        # Verify removal before logging success.
        if rm -f "$f" 2>/dev/null && [ ! -e "$f" ]; then
          printf '%s moved %s -> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$f" "$dest" \
            >> "$self/chore-c2-moves.log"
          rolled=$((rolled+1))
        else
          printf '%s RM-FAILED (duplicate kept) %s -> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$f" "$dest" \
            >> "$self/chore-c2-moves.log"
        fi
      done < "$staged"
      [ "$rolled" -gt 0 ] && stagedn="$stagedn (rolled $rolled)"
    fi
  fi

  t1="$(date +%s)"
  chore_stamp c2-shelves --arg n "clipped $clipped, staged $stagedn" --argjson rt "$((t1 - t0))" \
    '.["c2-shelves"] += {status:"done", note:$n, cost:{model:"none", runtime_s:$rt}}'
}

# ── C3: the extension agent (new method into the home) ──────────────────────
c3_current_roster() {
  local cache="${MAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}"
  [ -d "$cache" ] || return 0
  # cache/<marketplace>/<plugin>/<version>/ → "<marketplace>/<plugin>@<version>"
  # Only a dir carrying its manifest is a plugin. Installer transients
  # (temp_git_*/.git/*, temp_subdir_*/…) land in the cache at the same depth
  # and would otherwise walk into the roster as phantom arrivals (issue #34 —
  # a live roster was 191 lines, mostly .git@objects garbage).
  # Portability: {} embedded in a larger -exec arg is implementation-defined
  # per POSIX, but GNU and BSD find (this plugin's install base: Linux/macOS)
  # both document full substitution — verified, not assumed.
  find "$cache" -mindepth 3 -maxdepth 3 -type d \
       -exec test -f '{}/.claude-plugin/plugin.json' ';' -print 2>/dev/null \
    | awk -F/ '{n=NF; print $(n-2)"/"$(n-1)"@"$n}' | sort
}

chore_detect_c3_extension() {
  local roster
  roster="$(maude_self_dir)/roster.txt"
  [ -f "$roster" ] || return 0   # no roster yet → due (run will seed silently)
  ! c3_current_roster | diff -q "$roster" - >/dev/null 2>&1
}

chore_run_c3_extension() {
  local self roster new arrivals
  self="$(maude_self_dir)"; roster="$self/roster.txt"
  new="$(c3_current_roster)"
  if [ ! -f "$roster" ]; then
    [ -n "$new" ] && printf '%s\n' "$new" > "$roster" || : > "$roster"
    chore_stamp c3-extension \
      '.["c3-extension"] += {status:"done", note:"roster seeded", cost:{model:"none", runtime_s:0}}'
    return 0
  fi
  arrivals="$(printf '%s\n' "$new" | comm -13 "$roster" - | head -5 | paste -sd', ' -)"
  [ -n "$new" ] && printf '%s\n' "$new" > "$roster" || : > "$roster"
  chore_stamp c3-extension --arg n "${arrivals:+new: $arrivals}" \
    '.["c3-extension"] += {status:"done", note:(if $n == "" then "roster updated" else $n end), cost:{model:"none", runtime_s:0}}'
}

# ── C4: CLAUDE.md freshness (both age and churn) ──────────────────────────
chore_detect_c4_claudemd() {
  local cm proj tdir n
  proj="$(maude_project_dir)"; cm="$proj/CLAUDE.md"
  [ -f "$cm" ] || return 1
  # find -mtime +N matches files modified ≥N+1 full days ago (rounded to day boundaries)
  find "$cm" -mtime +"${MAUDE_CLAUDEMD_DAYS:-30}" 2>/dev/null | grep -q . || return 1
  tdir="$(maude_self_dir)/trace"
  n="$(find "$tdir" -maxdepth 1 -name 'today-*.jsonl' -newer "$cm" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -ge "${MAUDE_CLAUDEMD_SESSIONS:-10}" ]
}

chore_run_c4_claudemd() {
  local cm days n
  cm="$(maude_project_dir)/CLAUDE.md"
  [ -f "$cm" ] || { chore_fail c4-claudemd "CLAUDE.md missing"; return 1; }
  days="$(( ( $(date +%s) - $(stat -c %Y "$cm" 2>/dev/null || echo 0) ) / 86400 ))"
  n="$(find "$(maude_self_dir)/trace" -maxdepth 1 -name 'today-*.jsonl' -newer "$cm" 2>/dev/null | wc -l | tr -d ' ')"
  chore_stamp c4-claudemd --arg note "CLAUDE.md stale: ${days}d old, ${n} sessions since" \
    '.["c4-claudemd"] += {status:"undone", note:$note, cost:{model:"none", runtime_s:0}}'
}

verb_dispatch() {
  local transcript="${1:-}" self id now
  self="$(maude_self_dir)"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  chores_ledger >/dev/null
  for id in $CHORE_IDS; do
    [ "$(jq -r ".[\"$id\"].due // false" "$(chores_ledger)")" = "true" ] || continue
    local lock="$self/.chore-$id.lock"

    # Synchronous probe: stamp ONLY if lock is free (tiny TOCTOU window, acceptable).
    if (flock -n 9 2>/dev/null) 9>"$lock"; then
      # Lock was free: stamp immediately (synchronous, visible before dispatch returns).
      chore_stamp "$id" --arg t "$now" ".[\"$id\"] += {status:\"dispatched\", last_run:\$t}"

      # Now background the doer with lock held until it completes.
      (
        flock -n 9 || exit 0
        if [ -n "${MAUDE_CHORE_DOER_STUB:-}" ]; then
          nohup bash -c "$MAUDE_CHORE_DOER_STUB" >/dev/null 2>&1 &
        else
          nohup bash "$0" run "$id" "$transcript" >/dev/null 2>&1 &
        fi
        # Hold the lock until the doer exits so a second dispatch can't double-fire.
        wait
      ) 9>"$lock" &
    fi
    # If lock is held by running doer, skip: don't stamp, don't dispatch.
  done
}

# Library seam: `MAUDE_CHORES_LIB=1 . maude-chores.sh` loads functions without
# executing a verb — used by tests to drive helpers directly.
if [ "${MAUDE_CHORES_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

case "${1:-}" in
  detect)   verb_detect ;;
  brief)    verb_brief ;;
  stamp)    shift; chore_stamp "$@" ;;
  dispatch) shift; verb_dispatch "$@" ;;
  run)      shift; verb_run "$@" ;;
  *)        exit 0 ;;
esac
exit 0
