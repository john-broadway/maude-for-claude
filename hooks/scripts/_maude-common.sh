#!/usr/bin/env bash
# Shared helpers for Maude's hook scripts.
# Sourced by every hook. Must be silent on success and fast.
#
# Layout convention:
#
#   <project>/.maude/plugin/                    = HER project state (the closet inside the project)
#                                                 house-map.md, care.json, trace/, plus anything she
#                                                 organizes for herself per-project. Sub-scoped under
#                                                 .maude/ to coexist with anything else the user might
#                                                 keep at .maude/ (other tools they install).
#                                                 Auto-gitignored: .maude/plugin/.gitignore = '*'
#
#   ~/.claude/maude/                            = HER cross-project state (her own home base)
#                                                 patterns.md (cross-project observations),
#                                                 identity.md (about the user, shaped over time),
#                                                 projects.json (index of every project walked).
#
#   ~/.claude/projects/<slug>/memory/           = Anthropic auto-memory (the shared kitchen)
#                                                 She writes Anthropic-shaped digests here so
#                                                 next-session Claude inherits them. Doesn't put
#                                                 her own working files here.
#
#   <project>/.remember/                        = remember plugin's dir (if installed)
#                                                 She READS all *.md as context.
#                                                 She WRITES only remember.md (the agent-handoff
#                                                 file that remember explicitly leaves for agents).
#                                                 She does NOT touch now.md/today-*.md/recent.md/
#                                                 archive.md/core-memories.md — those are remember's
#                                                 pipeline output.
#
#   Vaults the user maintains (custom journals, decisions logs)
#                                                = Stay where they are. She writes through.
#
# Slug for both Anthropic memory AND user-global index = pwd, with non-alphanumerics replaced by '-'
# (matches the remember plugin's slug computation for compatibility).

# Project root — prefer $CLAUDE_PROJECT_DIR (set by Claude Code), fall back to pwd.
# This matches the remember plugin's anchoring so .maude/ and .remember/ stay siblings.
maude_project_dir() {
  # Claude Code exports CLAUDE_PROJECT_DIR to hook subprocesses but NOT to
  # the Bash tool subprocess. So slash-command-invoked scripts have to find
  # the workspace root themselves. Order:
  #   1. $CLAUDE_PROJECT_DIR if set (always for hooks)
  #   2. Walk up the process tree looking for the `claude` process; read its
  #      cwd. On Linux this matches what hooks see, regardless of how many
  #      bash subshells are layered between the script and Claude Code.
  #   3. Walk up the FILESYSTEM from pwd looking for an existing
  #      .maude/plugin/ closet (non-Linux fallback / edge cases).
  #   4. pwd (first-time setup, no closet anywhere).
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return
  fi
  pid="${PPID:-}"
  i=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$i" -lt 16 ]; do
    if [ -r "/proc/$pid/comm" ]; then
      cmd="$(cat /proc/$pid/comm 2>/dev/null)"
      if [ "$cmd" = "claude" ]; then
        cc_cwd="$(readlink /proc/$pid/cwd 2>/dev/null)"
        if [ -n "$cc_cwd" ] && [ "$cc_cwd" != "/" ] && [ -d "$cc_cwd" ]; then
          printf '%s' "$cc_cwd"
          return
        fi
        break
      fi
    fi
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
    i=$((i + 1))
  done
  d="$(pwd)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -d "$d/.maude/plugin" ]; then
      printf '%s' "$d"
      return
    fi
    d="$(dirname "$d")"
  done
  printf '%s' "$(pwd)"
}

maude_slug() {
  printf '%s' "$(maude_project_dir)" | sed 's/[^a-zA-Z0-9]/-/g'
}

# Anthropic auto-memory dir (the shared kitchen). Read-only when absent — never auto-create.
maude_mem_dir() {
  printf '%s' "$HOME/.claude/projects/$(maude_slug)/memory"
}

# Maude's project-local closet (under the project's .maude/, sub-scoped to plugin/)
maude_self_dir() {
  printf '%s/.maude/plugin' "$(maude_project_dir)"
}

# Maude's cross-project home base (user-global). Auto-creates freely.
maude_user_dir() {
  printf '%s/.claude/maude' "$HOME"
}

# remember plugin's dir, if it exists in this project
maude_remember_dir() {
  printf '%s/.remember' "$(maude_project_dir)"
}

maude_have_remember() {
  [ -d "$(maude_remember_dir)" ]
}

# House-map lives in her project closet
maude_map_path() {
  printf '%s/house-map.md' "$(maude_self_dir)"
}

maude_have_map() {
  [ -f "$(maude_map_path)" ]
}

# Returns 0 if a path appears in the house-map's "watch list".
maude_is_watched() {
  local target="$1" map
  map="$(maude_map_path)"
  [ -f "$map" ] || return 1
  grep -qF -- "$target" "$map"
}

# Append a JSONL event to the project-local trace.
# Trace lives in HER closet at <project>/.maude/plugin/trace/, NEVER in Anthropic
# auto-memory. Auto-creates the trace dir.
#
# Payload is written as-is (no redaction filter). Callers must pass short
# metadata strings (flag names, tool names, paths). Do NOT pass file content,
# bash output, or anything else that could carry user content — that's a leak
# vector. Trace is for event audit, not content capture.
# Current trace file path. The filename date is UTC — the SAME clock as each
# record's `ts` (date -u) — so a record always lands in the file matching its ts
# day, and a session crossing local midnight doesn't split across two files.
# Writers AND readers go through this single source so they can't disagree on
# the name. (Previously each of ~6 sites rebuilt it with local `date`, which
# split the trace at the UTC/local boundary.)
maude_trace_file() {
  printf '%s/trace/today-%s.jsonl' "$(maude_self_dir)" "$(date -u +%Y-%m-%d)"
}

maude_log_trace() {
  local kind="$1" payload="$2" trace ts
  trace="$(maude_trace_file)"
  mkdir -p "$(dirname "$trace")" 2>/dev/null
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg ts "$ts" --arg kind "$kind" --arg payload "$payload" \
      '{ts:$ts, kind:$kind, payload:$payload}' >> "$trace" 2>/dev/null
  else
    # Fallback: sed-escape backslashes and quotes for JSON safety
    local esc
    esc="$(printf '%s' "$payload" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')"
    printf '{"ts":"%s","kind":"%s","payload":"%s"}\n' \
      "$ts" "$kind" "$esc" >> "$trace"
  fi
}

# Best-effort redaction for content written to disk (the pre-compact snapshot and
# the .remember/ handoff). Masks a few HIGH-signal secret shapes from stdin → stdout.
# BEST-EFFORT, NOT a guarantee — it cannot catch every secret, so callers must
# still treat the output as sensitive (the snapshot is gitignored + session-wiped).
maude_redact() {
  sed -E \
    -e 's#(https?://)[^/:@[:space:]]+:[^/@[:space:]]+@#\1[redacted-creds]@#g' \
    -e 's#(sk-|ghp_|gho_|ghu_|ghs_|github_pat_|xox[abprs]-|AKIA|AIza)[A-Za-z0-9_-]{8,}#[redacted-secret]#g' \
    -e 's#eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+#[redacted-jwt]#g' \
    -e '/-----BEGIN[A-Z ]*PRIVATE KEY-----/,/-----END[A-Z ]*PRIVATE KEY-----/c\[redacted-key]'
}

# Ensure her project closet exists, including the auto-gitignore.
# Safe to call from any hook — only creates her own sub-scope under .maude/plugin/.
# If the user has anything else under .maude/ for unrelated reasons, leave it alone.
maude_ensure_self_dir() {
  local self
  self="$(maude_self_dir)"
  mkdir -p "$self/trace" 2>/dev/null
  # Self-ignore: only the plugin sub-dir gitignores itself; the parent .maude/ is left untouched.
  if [ ! -f "$self/.gitignore" ]; then
    printf '*\n' > "$self/.gitignore" 2>/dev/null
  fi
}

# Ensure her user-global home base exists.
maude_ensure_user_dir() {
  mkdir -p "$(maude_user_dir)" 2>/dev/null
}

# Ensure care.json is present and a valid JSON object, RECORDING any loss.
# care.json is the plugin's SHARED state (tier1 cache, gate_cleared, cooldowns,
# session counters); every hook jq-MERGES its own keys into it, which needs a valid
# base object. So:
#   * missing or empty        → seed {}.
#   * present but invalid JSON → TRACE the loss, then reseed {}.
# All keys here are transient/regenerable (gate_cleared is a minutes-lived, fail-safe
# token), so a corrupt file is reseeded rather than salvaged — but the reset is now
# RECORDED in the trace instead of silent. (Hooks used to open-code
# `jq -e . || printf '{}'`, which wiped the whole shared-state file with no record —
# the R2 finding. Route care.json init/reset through here so the pattern can't be
# silently re-copied.) jq is required to DETECT corruption; without it we only handle
# missing/empty and leave a present file untouched (callers are inert without jq).
# Usage: maude_care_ensure "<care.json path>"
maude_care_ensure() {
  local care="$1"
  [ -n "$care" ] || return 0
  # Group-redirect the seed so a FAILED redirection (e.g. unwritable path) is
  # suppressed too — `printf > x 2>/dev/null` still leaks bash's redirect error
  # because `>` is set up before `2>` applies; `{ …; } 2>/dev/null` covers it.
  if [ ! -s "$care" ]; then
    { printf '{}\n' > "$care"; } 2>/dev/null
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0
  jq -e . "$care" >/dev/null 2>&1 && return 0
  maude_log_trace "care" "care.json was invalid JSON — reseeded {} (transient shared state reset)"
  { printf '{}\n' > "$care"; } 2>/dev/null
}

# Atomic, status-returning merge into care.json — the single write path every hook
# shares (was open-coded as `jq … > tmp && mv` in ~6 hooks, each an SC2015 footgun
# that couldn't report failure). mktemp in care.json's OWN dir so the rename is a
# true same-filesystem atomic mv, never a cross-fs copy; the temp is removed on any
# failure. Returns 0 only if the new content was persisted, 1 otherwise — so callers
# can avoid claiming a write that didn't land (see clear-gate / verify-watch).
# Usage: maude_care_set "<care.json path>" <jq args…> '<filter>'
maude_care_set() {
  local care="$1"; shift
  local tmp
  tmp="$(mktemp "$(dirname "$care")/.care.XXXXXX" 2>/dev/null)" || return 1
  if jq "$@" "$care" > "$tmp" 2>/dev/null && mv "$tmp" "$care" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# The session-start catch-digest — Maude's one JOHN-FACING line. Everything else she
# does aims at Claude (gate blocks, drift nudges, verify whispers); this is the one
# channel that surfaces TO John what she caught. Summarizes catches since the last
# digest, then advances a watermark (last_digest_iso in care.json) so SessionStart's
# resume/clear/compact re-fires never re-print the same catch. Value-first: real saves
# lead; the git-push gate is the toll booth, shown as "push-clears" (friction), never
# as protection; a window with nothing caught stays silent. Reads only trace files
# whose day could hold a newer-than-watermark event, so it stays cheap. jq-absent →
# no-op, like every other counting hook. Prints the line (if any) to stdout.
maude_digest_line() {
  command -v jq >/dev/null 2>&1 || return 0
  local self care tdir since now since_date d f line
  local -a files=()
  self="$(maude_self_dir)"
  tdir="$self/trace"
  care="$self/care.json"
  [ -d "$tdir" ] || return 0
  maude_care_ensure "$care"
  since="$(jq -r '.last_digest_iso // ""' "$care" 2>/dev/null)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # First run ever: seed the watermark and announce — never retro-dump weeks of history.
  if [ -z "$since" ]; then
    maude_care_set "$care" --arg ts "$now" '.last_digest_iso = $ts'
    printf "Maude's catch-digest is on — from here I'll show what I caught while you were away.\n"
    return 0
  fi

  # Only trace files whose filename-date is on/after the watermark's day can hold an
  # event newer than the watermark. ISO timestamps sort lexically, so string compare is
  # correct for both the filename filter and the per-event `.ts > since` below.
  since_date="${since%%T*}"
  for f in "$tdir"/today-*.jsonl; do
    [ -e "$f" ] || continue
    d="${f##*/today-}"; d="${d%.jsonl}"
    if [ "$d" = "$since_date" ] || [ "$d" \> "$since_date" ]; then
      files+=("$f")
    fi
  done

  # Advance the watermark now — we've captured `since`, so a crash mid-compose skips one
  # digest rather than re-printing the same window every session forever.
  maude_care_set "$care" --arg ts "$now" '.last_digest_iso = $ts'

  [ "${#files[@]}" -gt 0 ] || return 0

  # Aggregate the new catches into a terse, value-first token list (empty string if the
  # window holds nothing worth surfacing). `(.payload // "")` guards the kinds whose
  # payload could be absent; `and` short-circuits so non-matching kinds are never probed.
  line="$(cat "${files[@]}" 2>/dev/null | jq -rs --arg since "$since" '
    [ .[] | select((.ts // "") > $since) ] as $new
    | ( [ $new[] | select(.kind=="gate"
                          and ((.payload // "")|startswith("blocked="))
                          and (((.payload // "")|test("git-push"))|not)) ] ) as $blocks
    | ( [ $blocks[] | select((.payload // "")|test("rm-rf-sole-copy")) ]|length ) as $saves
    | ( ($blocks|length) - $saves ) as $otherblocks
    | ( [ $new[] | select(.kind=="infra-gate" and ((.payload // "")|test("blocked"))) ]|length ) as $infra
    | ( [ $new[] | select(.kind=="gate-cleared" and ((.payload // "")|test("git-push"))) ]|length ) as $pushclears
    | ( [ $new[] | select(.kind=="drift") ]|length ) as $drift
    | ( [ $new[] | select(.kind=="verify") ]|length ) as $verify
    | [ (if $saves>0       then "\($saves) sole-copy save\(if $saves==1 then "" else "s" end)" else empty end),
        (if $infra>0       then "\($infra) infra-block\(if $infra==1 then "" else "s" end)" else empty end),
        (if $otherblocks>0 then "\($otherblocks) block\(if $otherblocks==1 then "" else "s" end)" else empty end),
        (if $drift>0       then "\($drift) drift-catch\(if $drift==1 then "" else "es" end)" else empty end)
      ] as $value
    | [ (if $pushclears>0  then "\($pushclears) push-clear\(if $pushclears==1 then "" else "s" end)" else empty end),
        (if $verify>0      then "\($verify) verify-flag\(if $verify==1 then "" else "s" end)" else empty end)
      ] as $volume
    # Value catches lead; high-volume noise (push-clears, verify-flags) folds into a
    # parenthetical tail so the gold pops. Volume-only windows show the volume plainly.
    | if ($value|length)>0
      then ($value|join(", ")) + (if ($volume|length)>0 then " (+\($volume|join(", ")))" else "" end)
      elif ($volume|length)>0 then ($volume|join(", "))
      else "" end
  ')"

  [ -n "$line" ] && printf 'Maude caught since you last looked: %s.\n' "$line"
  return 0
}

# The continuity guard — the closing loop the continuity chain was missing. The Stop hook
# writes NO handoff (it can't tell a real session-end from a mid-turn pause), so a clean
# quit without /maude:rest could leave the next session under-informed. This runs at
# SessionStart and reconciles the last CAPTURE against real ACTIVITY. "Last capture" is
# the freshest mtime among the continuity sources the wake path actually reads: the
# Anthropic buffer ($MEM/now.md), the remember plugin's live buffer ($REMEMBER/now.md),
# and the handoff (remember.md — NON-EMPTY only: it's drained to empty by design, so an
# empty one carries nothing and must not anchor). Activity is user `prompt` events in the
# durable trace — the right unit, because SessionStart fires before this session's first
# prompt, so every counted prompt is genuinely prior work. If the freshest capture is
# stale relative to that activity (or nothing was captured at all), it warns — continuity
# degrades LOUDLY, not silently. On a healthy system the live buffer keeps the anchor
# current and the guard stays quiet. jq-absent → no-op. Prints the warning (if any).
maude_continuity_guard() {
  command -v jq >/dev/null 2>&1 || return 0
  local proj mem remember handoff tdir since_iso since_date n f d m anchor
  local -a files=()
  local threshold=3
  proj="$(maude_project_dir)"
  mem="$(maude_mem_dir)"
  remember="$proj/.remember"
  handoff="$remember/remember.md"
  tdir="$(maude_self_dir)/trace"
  # The remember plugin is the continuity substrate this guards; no .remember dir → N/A.
  [ -d "$remember" ] && [ -d "$tdir" ] || return 0

  # Anchor = freshest mtime among the sources the wake path reads (non-empty only).
  anchor=0
  for f in "$mem/now.md" "$remember/now.md" "$handoff"; do
    [ -s "$f" ] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "$m" -gt "$anchor" ] && anchor="$m"
  done
  if [ "$anchor" -gt 0 ]; then
    since_iso="$(date -u -d "@$anchor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 0
  else
    since_iso=""   # nothing captured at all → count ALL prior prompts
  fi
  since_date="${since_iso%%T*}"

  # Only trace files whose day could hold a prompt after the anchor (ISO sorts lexically).
  for f in "$tdir"/today-*.jsonl; do
    [ -e "$f" ] || continue
    d="${f##*/today-}"; d="${d%.jsonl}"
    if [ -z "$since_date" ] || [ "$d" = "$since_date" ] || [ "$d" \> "$since_date" ]; then
      files+=("$f")
    fi
  done
  [ "${#files[@]}" -gt 0 ] || return 0

  n="$(cat "${files[@]}" 2>/dev/null | jq -rs --arg since "$since_iso" '
    [ .[] | select(.kind=="prompt" and ((.ts // "") > $since)) ] | length')"
  [ "${n:-0}" -ge "$threshold" ] || return 0

  if [ "$anchor" -gt 0 ]; then
    printf 'Heads-up: ~%s exchanges ran after the last save — the handoff may be stale. /maude:wake reconstructs from the trace.\n' "$n"
  else
    printf 'Heads-up: no continuity captured, but the trace shows ~%s prior exchanges — /maude:wake reconstructs them.\n' "$n"
  fi
  return 0
}

# Append a user-STATED fact to the cross-project profile (the testable core of
# /maude:teach). Distinct from the observed-only writers (save/rest/check-on-me/
# notice): those record what Maude inferred; this records what the user asserted,
# kept under a dedicated "## Told by the user" section so told stays separate from
# observed and the no-fabrication rule holds. Never touches the persona preamble
# or existing observed blocks. Returns non-zero (no write) on an empty fact.
# Usage: maude_identity_append "<fact>" ["<YYYY-MM-DD>"]
maude_identity_append() {
  local fact="$1" date_str entry id tmp
  # Collapse newlines/whitespace runs to single spaces (one fact = one line, so a
  # multi-line fact can't inject a second '## Told by the user' header or split the
  # list), then trim; reject empty OR whitespace-only.
  fact="$(printf '%s' "$fact" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -n "$fact" ] || return 1
  date_str="${2:-$(date +%Y-%m-%d)}"
  maude_ensure_user_dir
  id="$(maude_user_dir)/identity.md"
  entry="- ${date_str}: ${fact}"

  # Fresh profile: write a minimal skeleton (a stranger's file is empty/absent).
  if [ ! -f "$id" ]; then
    {
      printf "# Who the user is (Maude's living profile)\n\n"
      printf 'Shaped over time, observed-only and never fabricated. Facts the user states\n'
      printf 'directly are recorded below, kept distinct from what Maude infers.\n\n'
      printf '## Told by the user\n\n'
      printf '%s\n' "$entry"
    } > "$id" 2>/dev/null
    return $?
  fi

  # Section missing: append it (with the entry) at end of file. Anchor the test
  # to EXACTLY match the awk insertion pattern below — a prefix-only grep could
  # match a variant heading the awk then never inserts into (silent drop).
  if ! grep -qE '^## Told by the user[[:space:]]*$' "$id" 2>/dev/null; then
    printf '\n## Told by the user\n\n%s\n' "$entry" >> "$id" 2>/dev/null
    return $?
  fi

  # Section present: APPEND the entry at the END of the Told section (after the
  # last existing bullet, before the next '## ' header or EOF) — one contiguous,
  # oldest-first list, never prepended after the header (which orphaned the
  # header's spacer blank and split the list). Robust to whatever sections follow.
  # mktemp in the destination dir so the final mv is a true atomic rename.
  tmp="$(mktemp "$(maude_user_dir)/.identity.XXXXXX")" || return 1
  # Pass the entry via the ENVIRONMENT, not `awk -v`: awk applies C-style escape
  # processing to -v/command-line assignments (a fact containing "C:\notes" or
  # "\t" would be mangled into a newline/tab), but does NOT escape-process
  # ENVIRON[] values — so the fact round-trips literally.
  entry="$entry" awk '
    BEGIN { e = ENVIRON["entry"] }
    { lines[NR] = $0 }
    /^## Told by the user[[:space:]]*$/ { start = NR }
    END {
      endline = NR
      for (i = start + 1; i <= NR; i++) if (lines[i] ~ /^## /) { endline = i - 1; break }
      ins_after = start
      if (start + 1 <= endline && lines[start + 1] ~ /^[[:space:]]*$/) ins_after = start + 1
      for (i = start + 1; i <= endline; i++) if (lines[i] !~ /^[[:space:]]*$/) ins_after = i
      for (i = 1; i <= NR; i++) { print lines[i]; if (i == ins_after) print e }
    }
  ' "$id" > "$tmp" 2>/dev/null && mv "$tmp" "$id" || { rm -f "$tmp"; return 1; }
}

# Retention window (days) for the append-only artifacts in her closet: trace
# JSONL and pre-compact snapshots. Default 30 — well past the 7-day window that
# the remember plugin's recent.md reads, so a sweep never strands a recent read.
# Override via the MAUDE_RETENTION_DAYS env var.
maude_retention_sweep() {
  local self days
  self="$(maude_self_dir)"
  days="${MAUDE_RETENTION_DAYS:-30}"
  # mtime-based, fail-silent. Only removes files strictly older than the window.
  [ -d "$self/trace" ] && \
    find "$self/trace" -maxdepth 1 -type f -name 'today-*.jsonl' -mtime +"$days" -delete 2>/dev/null
  [ -d "$self/snapshots" ] && \
    find "$self/snapshots" -maxdepth 1 -type f -name 'precompact-*.md' -mtime +"$days" -delete 2>/dev/null
}

# ─── Tier model ───────────────────────────────────────────────────────────
# Memory sources are classified by (locality, shape):
#   tier 0 = local on-disk          (markdown, sqlite, local vector index)
#   tier 1 = local service          (stdio MCP, localhost daemon: redis/qdrant/etc)
#   tier 2 = network service        (HTTP MCP, remote API)
#   tier 3 = ephemeral session ctx  (LLM's loaded context — refer only)
#
# Hooks must stay strictly tier 0 — they fire every turn and need to be fast.
# Commands can use tier 1 if cached-up, tier 2 selectively for rich queries.
# ──────────────────────────────────────────────────────────────────────────

# Returns 0 if the cached tier-1 liveness probe says "up" within TTL (default 300s).
# Reads from care.json which is updated by the SessionStart probe.
maude_tier1_up() {
  local care self ttl
  self="$(maude_self_dir)"
  care="$self/care.json"
  ttl="${1:-300}"
  [ -f "$care" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local last_probe up
  last_probe="$(jq -r '.tier1_last_probe // 0' "$care" 2>/dev/null)"
  up="$(jq -r '.tier1_up // false' "$care" 2>/dev/null)"
  [ "$up" = "true" ] || return 1
  local now; now=$(date +%s)
  [ $((now - last_probe)) -lt "$ttl" ] && return 0
  return 1
}

# Returns 0 if a network endpoint at $1 (URL or host:port) is reachable within $2 seconds (default 2).
# Used by /maude:found probes only — not by hooks.
maude_tier2_reachable() {
  local target="$1" timeout="${2:-2}"
  case "$target" in
    http://*|https://*)
      command -v curl >/dev/null 2>&1 || return 1
      curl -fsS --max-time "$timeout" -o /dev/null "$target" 2>/dev/null
      ;;
    *:*)
      local host="${target%:*}" port="${target##*:}"
      command -v nc >/dev/null 2>&1 || return 1
      nc -z -w "$timeout" "$host" "$port" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# ─── Local time / clock ───────────────────────────────────────────────────
# Maude greets by the USER's local time, never the box clock — a server or
# container box defaults to UTC, so a confident "afternoon" from `date` is how
# she said the wrong time-of-day before. The contract: only assert a time-of-day
# when the timezone is KNOWN; otherwise stay silent and let the caller hedge.
#
# Source of truth: a `timezone:` line in the house-map, captured (and confirmed)
# by /maude:found. Value is an IANA tz (e.g. America/Chicago), or the literal
# `system` meaning "trust this box's clock — the user confirmed it's right".
# Pure date/grep/sed — no jq dependency.
# ──────────────────────────────────────────────────────────────────────────

# Echo the user's configured timezone, or nothing if unverified.
maude_user_tz() {
  local map val
  map="$(maude_map_path)"
  [ -f "$map" ] || return 0
  val="$(grep -E '^[[:space:]]*timezone:[[:space:]]*' "$map" 2>/dev/null | head -1)"
  [ -n "$val" ] || return 0
  val="${val#*:}"
  # Strip any trailing inline `# comment`, then surrounding whitespace. An
  # unstripped comment would be passed to `TZ=...` and silently fall back to
  # UTC — a confident wrong greeting, the exact bug this release prevents.
  val="$(printf '%s' "$val" | sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$val" in
    ""|"<none>"|none|unknown|unset) return 0 ;;
  esac
  # Reject a value ONLY when it is provably bad: the zoneinfo DB exists but has
  # no such zone (a typo like America/Chigago, which `date` would silently turn
  # into UTC — a confident wrong greeting). On a box without the DB we can't
  # prove anything, so pass the value through rather than regress a valid zone
  # to time-neutral. `system` is a sentinel, never a zone file — never checked.
  if [ "$val" != "system" ] && [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$val" ]; then
    return 0
  fi
  printf '%s' "$val"
}

# Pure: map an hour (0-23, leading zeros ok) to a time-of-day bucket.
# Non-numeric input defaults to night rather than erroring (10# would emit a
# base error to stderr); the live path only ever passes `date +%H`, so this is
# defensive hardening for the helper as a unit.
maude_bucket_for_hour() {
  local h
  case "${1:-}" in
    ""|*[!0-9]*) h=0 ;;
    *) h=$((10#$1)) ;;
  esac
  if   [ "$h" -ge 5 ]  && [ "$h" -le 11 ]; then printf 'morning'
  elif [ "$h" -ge 12 ] && [ "$h" -le 16 ]; then printf 'afternoon'
  elif [ "$h" -ge 17 ] && [ "$h" -le 20 ]; then printf 'evening'
  else printf 'night'
  fi
}

# Pure: map a bucket to a greeting word. Unknown/empty → empty (no time word).
maude_greeting_for_bucket() {
  case "$1" in
    morning)   printf 'Morning.' ;;
    afternoon) printf 'Afternoon.' ;;
    evening)   printf 'Evening.' ;;
    night)     printf "Late, but I'm here." ;;
    *)         printf '' ;;
  esac
}

# Current time-of-day bucket in the user's tz, or 'unknown' if unverified.
maude_time_of_day() {
  local tz hour
  tz="$(maude_user_tz)"
  [ -n "$tz" ] || { printf 'unknown'; return; }
  if [ "$tz" = "system" ]; then
    hour="$(date +%H)"
  else
    hour="$(TZ="$tz" date +%H)"
  fi
  maude_bucket_for_hour "$hour"
}

# Formatted local time (HH:MM ZONE) in the user's tz, or empty if unverified.
maude_local_time_str() {
  local tz
  tz="$(maude_user_tz)"
  [ -n "$tz" ] || return 0
  if [ "$tz" = "system" ]; then
    date '+%H:%M %Z'
  else
    TZ="$tz" date '+%H:%M %Z'
  fi
}

# Time-aware greeting word, or empty when the clock is unverified.
maude_greeting() {
  maude_greeting_for_bucket "$(maude_time_of_day)"
}

# ─── Shared danger-palette (the RoE zones, expressed ONCE) ────────────────
# Belt (maude-gate), shoes (maude-bash-watch) and suspenders (maude-infra-gate)
# all read THESE — never their own copy — so the outfit "matches": one
# definition of what is RED, drawn from the Rules of Engagement.

# ─── Gate config (deployment-specific; NEVER in shipped source) ──────────────
# The plugin ships the gate MECHANISM. Deployment specifics live in a LOCAL config
# at $HOME/.claude/maude/gate-config.json (override $MAUDE_GATE_CONFIG), tracked by
# NO repo. Absent config → generic defaults: belt protects the workspace + ~/.claude
# + any .git; the infra-gate is INERT (no tools declared → nothing gated).
maude_gate_config() { printf '%s' "${MAUDE_GATE_CONFIG:-$(maude_user_dir)/gate-config.json}"; }

# Escape ERE metacharacters in a literal path so it can sit inside a gate pattern.
maude_ere_escape() { printf '%s' "$1" | sed -E 's/[][\*^$()+?{|]/\\&/g'; }

# Sole-copy ERE target fragments — generic defaults (NO deployment literals) +
# any paths from config. One per line. Belt reads these into its pattern table.
maude_sole_copy_targets() {
  local cfg proj
  proj="$(maude_project_dir)"
  [ -n "$proj" ] && printf '%s(/[^/[:space:]]+)?\n' "$(maude_ere_escape "$proj")"
  printf '%s/\\.claude(/[^[:space:]]*)?\n' "$(maude_ere_escape "$HOME")"
  printf '%s\n' '(\.git|[^[:space:]]*/\.git)(/[^[:space:]]*)?'
  cfg="$(maude_gate_config)"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    jq -r '.sole_copy_paths[]?' "$cfg" 2>/dev/null | while IFS= read -r p; do
      [ -n "$p" ] && printf '%s(/[^[:space:]]*)?\n' "$(maude_ere_escape "$p")"
    done
  fi
}

# Public-facing publish commands (RED — pre-public-push checklist).
maude_public_publish_re() {
  printf '%s' '(gh[[:space:]]+release[[:space:]]+(create|upload)|twine[[:space:]]+upload|uv[[:space:]]+publish|(hf|huggingface-cli)[[:space:]]+upload)'
}

# Destructive MCP tool BARE names (space-delimited) from config; empty if none.
maude_infra_destructive_tools() {
  local cfg; cfg="$(maude_gate_config)"
  { [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; } || { printf ''; return; }
  jq -r '(.infra_destructive_tools // []) | join(" ")' "$cfg" 2>/dev/null
}

# The MCP server prefix to gate (e.g. mcp__myserver__); empty if unconfigured.
maude_infra_tool_prefix() {
  local cfg; cfg="$(maude_gate_config)"
  { [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; } || { printf ''; return; }
  jq -r '.infra_tool_prefix // ""' "$cfg" 2>/dev/null
}

# Co-manage sandbox membership from config. Returns 0 ONLY on a positive match;
# empty/unknown/no-config → 1 (NOT sandbox) so callers fail CLOSED.
maude_is_comanage_target() {
  local node="$1" vmid="$2" cfg; cfg="$(maude_gate_config)"
  { [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; } || return 1
  if [ -n "$node" ] && jq -e --arg n "$node" '(.infra_sandbox_nodes // []) | index($n)' "$cfg" >/dev/null 2>&1; then return 0; fi
  if [ -n "$vmid" ] && jq -e --arg v "$vmid" '(.infra_sandbox_vmids // []) | map(tostring) | index($v)' "$cfg" >/dev/null 2>&1; then return 0; fi
  return 1
}

# ─── Gate matching helpers (used by maude-gate.sh) ────────────────────────
# Strip paired quotes from a shell command string so gate patterns don't
# match user-supplied literal text inside quoted args (e.g. commit messages
# containing the substring "git push"). Newlines are flattened first so a
# multi-line HEREDOC inside `"$(cat <<EOF ... EOF)"` collapses correctly.
#
# Order: flatten newlines → strip single-quoted spans → strip double-quoted
# spans. Single-quoted first because shell single-quotes don't interpret
# backslashes — matching them is unambiguous and removes their content
# (including any stray double-quotes inside) before the double-quote pass.
maude_strip_quotes() {
  local cmd="$1"
  cmd="$(printf '%s' "$cmd" | tr '\n' ' ')"
  cmd="$(printf '%s' "$cmd" | sed -E "s/'[^']*'//g")"
  cmd="$(printf '%s' "$cmd" | sed -E 's/"([^"\\]|\\.)*"//g')"
  printf '%s' "$cmd"
}

# Remove quote CHARACTERS but KEEP their content (newlines flattened). For
# matching PATH/argument patterns where a quoted path (rm -rf "/srv/data")
# must still match — unlike maude_strip_quotes which ERASES quoted content
# (right for command-name patterns like git push, wrong for path args).
# Fail-closed: keeping content can only ever match MORE, never introduce a
# new bypass.
maude_unquote() {
  printf '%s' "$1" | tr '\n' ' ' | tr -d "\"'"
}

# Remove HEREDOC bodies from a (possibly multi-line) command. A heredoc body is
# DATA fed to a command (git commit -F -, cat > file), not shell structure — so
# for the rm-command-position guard it must NOT read as executable shell. Without
# this, a shell separator inside heredoc prose ( ; ( | ` ) survived into the
# skeleton and made a commit whose body documents `rm -rf /` false-block.
#
# Scoped to the rm-guard (see maude_rm_in_command_position) — NOT applied to the
# shared strip used by command-name patterns, so a heredoc fed to a SQL client
# (psql <<EOF DROP TABLE … EOF) is still seen by the DROP-TABLE check.
#
# Fail-direction is UNDER-block (dropping body lines makes the guard see FEWER
# command-position rms), with two honest costs — verified, not assumed:
#   - An rm inside a heredoc fed to a SHELL (bash <<EOF …) is uncaught: the
#     already-documented shell-wrapping limitation (maude-gate.sh #3).
#   - This is a HEURISTIC `<<WORD` detector on the raw line — it cannot tell a
#     real heredoc from a `<<WORD` sitting inside quotes ("note << EOF") or a
#     letter-led arithmetic shift ($((a << b))). When such a token precedes a
#     real rm on a later line, that rm line is wrongly eaten and the guard
#     under-blocks (the old strip_quotes-only guard caught that case). This is a
#     NEW, narrow gap, accepted per the gate's fail-closed-where-it-matters
#     posture (maude-gate.sh #9). NOT chased closed: the obvious narrowing
#     (strip quoted spans before detecting <<) erases the `<<'EOF'` delimiter
#     and reopens the doc-body false-block this function exists to fix.
# Operates on the raw string BEFORE newline-flattening (heredoc bodies are
# delimited by newlines).
maude_strip_heredocs() {
  local input="$1" out="" line trimmed delim="" inh=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inh" = 1 ]; then
      # ltrim+rtrim whitespace (covers <<- tab-indented close)
      trimmed="${line#"${line%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [ "$trimmed" = "$delim" ] && inh=0
      continue   # drop body lines AND the closing delimiter line
    fi
    # heredoc start: << [-] [spaces] [quote] WORD [quote]. A digit-led token
    # (arithmetic  $((a << 2)) ) is not a valid delimiter and won't match.
    if [[ "$line" =~ \<\<-?[[:space:]]*[\"\']?([A-Za-z_][A-Za-z0-9_]*)[\"\']? ]]; then
      delim="${BASH_REMATCH[1]}"
      inh=1
    fi
    out+="$line"$'\n'
  done <<< "$input"
  printf '%s' "$out"
}

# Match a gate pattern against a command. Strips paired quotes first to
# dodge the in-string false positive that bit v0.1.5 (commit messages
# describing the gate self-blocked the commit). The pattern is responsible
# for its own anchoring — see maude-gate.sh for the CMD_START / FLAG
# constants used to build cmd-start and flag-position anchored patterns.
#
# Usage: maude_match_gate_pattern "<command>" "<pattern-regex>"
# Returns: 0 if matches, 1 otherwise.
maude_match_gate_pattern() {
  local cmd="$1" pat="$2" stripped
  stripped="$(maude_strip_quotes "$cmd")"
  printf '%s' "$stripped" | grep -qE -- "$pat"
}

# Returns 0 (true) if a recursive rm (optionally sudo-prefixed) appears in
# COMMAND POSITION on the quote-ERASED skeleton of $1 — i.e. an rm that is
# actually being EXECUTED, not one sitting inside a quoted argument
# (echo "rm -rf /"). The rm-family PATH patterns in maude-gate.sh match against
# the UNQUOTED command (quote chars stripped, CONTENT kept — so a quoted path
# like rm -rf "/srv" still resolves). That content-kept view means quoted PROSE
# containing a shell separator + rm-rf would otherwise false-block (the quoted
# '(' / ';' / backtick reads as a real subshell). The skeleton (quoted content
# ERASED, via maude_strip_quotes) tells the truth about shell structure; only
# once execution is proven here does the gate trust the unquoted string for
# WHICH path. Mirrors maude-gate.sh's CMD_START + RMR recursive-flag anchors;
# the trailing path argument is intentionally NOT required (path resolution is a
# separate step). Fail-direction: if this wrongly returned false on a real rm the
# gate would under-block — but the skeleton always retains a command-position
# rm whenever the rm itself is unquoted (only the path may be quoted away), which
# is the only shape that reaches a destructive delete.
maude_rm_in_command_position() {
  local skeleton
  # Excise heredoc bodies (data, not shell) BEFORE quote-stripping/flattening so
  # documentation prose in a `git commit -F -` body cannot read as a subshell rm.
  skeleton="$(maude_strip_quotes "$(maude_strip_heredocs "$1")")"
  printf '%s' "$skeleton" | grep -qE -- \
    '(^|[;&|(`])[[:space:]]*(sudo[[:space:]]+)?rm([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'
}

# ─── Gate-key severity tiers (v0.10.0) ────────────────────────────────────
# Single source of truth, consumed by maude-gate.sh and maude-clear-gate.sh.
#
# YELLOW: Claude MAY self-clear via /maude:conscience — routine, reversible-
#   enough that the agent clearing its own block is acceptable.
# RED: John's hand ONLY — the irreversible / public / sole-copy class. A red
#   clear needs the --john flag, which John supplies by pasting a ! line (which
#   runs in his shell and skips the Bash tool-gate). Listed EXPLICITLY rather
#   than "anything not yellow", so any future key is recognised by the clear
#   script (unknown keys are refused) but only an enumerated red key gets the
#   John's-hand path.
maude_yellow_keys() {
  printf '%s' 'git-push commit-amend no-verify no-gpg-sign reset-hard run-governor'
}
maude_red_keys() {
  printf '%s' 'rm-rf-root rm-rf-glob sudo-rm-rf rm-rf-sole-copy public-publish force-push filter-repo filter-branch infra-destructive drop-table'
}
# 0 (true) if $1 is a red key.
maude_is_red_key() {
  case " $(maude_red_keys) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
# 0 (true) if $1 is a known gate key (yellow OR red).
maude_is_known_key() {
  case " $(maude_yellow_keys) $(maude_red_keys) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Path to the dedicated RED-clear token file (v0.10.1). RED clears (John's hand)
# live HERE, separate from care.json, so two enforcement points outside the
# plugin's reflex can lock it: (1) the harness can deny the Write/Edit tools on
# this exact path, and (2) maude-gate.sh blocks Bash redirects/tees to it. Yellow
# tokens stay in care.json (Claude may self-clear those). The only writer left for
# a red token is John's ! line running maude-clear-gate.sh — which skips both the
# Bash tool-gate and the harness tool-perms because it is his shell, not a tool.
maude_redclear_file() {
  printf '%s/care-redclear.json' "$(maude_self_dir)"
}
