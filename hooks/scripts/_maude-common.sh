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
# /maude:weekly and recent.md read, so a sweep never strands a recent read.
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
  local now=$(date +%s)
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
