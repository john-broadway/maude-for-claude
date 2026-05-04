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
  printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}"
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

# Append a line to today's daily log in Anthropic memory if the memory dir
# already exists. Silent if it doesn't — never auto-creates Anthropic structure.
maude_log_to_today() {
  local line="$1" mem today
  mem="$(maude_mem_dir)"
  [ -d "$mem" ] || return 0
  today="$mem/today-$(date +%Y-%m-%d).md"
  [ -f "$today" ] || printf '# %s\n\n' "$(date +%Y-%m-%d)" > "$today"
  printf -- '%s\n' "$line" >> "$today"
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
