#!/usr/bin/env bash
# Shared helpers for Maude's hook scripts.
# Sourced by every hook. Must be silent on success and fast.

# Eye recursion guard: inside a blink subprocess every maude hook is inert.
# NOTE: `exit` (not `return`) is deliberate — this file is SOURCED, and `exit`
# in a sourced file terminates the sourcing hook script with status 0, which is
# exactly the contract. A `return` would only stop the sourcing of this file and
# let the hook continue half-initialized.
[ -n "${MAUDE_EYE_BLINK:-}" ] && exit 0

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

# Parent pid of the process whose /proc entry is $1. Prints it, or returns 1.
#
# /proc/<pid>/stat CANNOT BE PARSED POSITIONALLY. Its second field is `comm`
# wrapped in parens, and comm may contain spaces AND parens — a `tmux: server`
# ancestor splits into two whitespace fields and shifts every later field by one,
# so the old `awk '{print $4}'` returned the process STATE LETTER ("S") instead of
# the ppid. Measured on the live box 2026-07-31:
#     /proc/943593/stat -> "943593 (tmux: server) S 1 ..."   awk $4 -> "S"
#     /proc/943593/status -> "PPid:\t1"
# The walk then died at that ancestor and fell through to $(pwd) — which is how
# the $HOME phantom got minted. status's PPid: line is unambiguous; the stat
# fallback splits on the LAST ')' so comm's own content cannot corrupt it.
_maude_ppid() {
  local _pp_d="$1" _pp_v=""
  if [ -r "$_pp_d/status" ]; then
    _pp_v="$(awk '/^PPid:/ { print $2; exit }' "$_pp_d/status" 2>/dev/null)"
  fi
  if [ -z "$_pp_v" ] && [ -r "$_pp_d/stat" ]; then
    _pp_v="$(sed 's/.*) //' "$_pp_d/stat" 2>/dev/null | awk '{ print $2 }')"
  fi
  case "$_pp_v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$_pp_v"
}

# May an INFERRED project root be $1? Explicit declarations bypass this entirely.
#
# INFERENCE MAY NEVER LAND ON $HOME. When it did, a caller mkdir'd
# $HOME/.maude/plugin, and from then on the filesystem walk-up STOPPED at that
# phantom for every path outside the real workspace — it broke the mission clear,
# the undo list and the conscience clear on 2026-07-30. Barring $HOME from the
# walk-up is what makes the shadowing impossible rather than merely unlikely.
#
# THE TRADE, stated so it is not rediscovered: a project whose root genuinely IS
# $HOME can no longer be found by inference. It is still found by declaration,
# and hooks always carry CLAUDE_PROJECT_DIR, so only a Bash-tool-invoked script
# in such a project is affected. That is the smaller harm: a store that is merely
# missing beats one that is confidently wrong.
#
# Only $HOME ITSELF is barred, never paths beneath it — ordinary workspaces all
# live under $HOME.
# The user's home, even when the environment does not carry it. A hook run from cron, a systemd
# unit with no `Environment=HOME`, `env -i`, or `docker exec` without `-e HOME` has no $HOME, and
# the first version of this guard returned ALLOW in that case — fail-OPEN, on a guard, in exactly
# the unattended contexts nobody watches.
_maude_home() {
  _mh="${HOME:-}"
  if [ -z "$_mh" ] && command -v getent >/dev/null 2>&1; then
    _mh="$(getent passwd "$(id -u 2>/dev/null)" 2>/dev/null | cut -d: -f6)"   # portability-shim (GNU)
  fi
  if [ -z "$_mh" ] && command -v dscl >/dev/null 2>&1; then
    # portability-shim (BSD/macOS): no getent; Directory Services is the passwd db.
    # sed keeps a home path containing spaces whole where awk-$2 would truncate it.
    _mh="$(dscl . -read "/Users/$(id -un 2>/dev/null)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
  fi
  [ -n "$_mh" ] || return 1
  printf '%s' "$_mh"
}

# Canonical path with symlinks resolved. Prints nothing and returns 1 if it cannot be resolved.
_maude_canon() {
  [ -n "${1:-}" ] || return 1
  ( CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P ) 2>/dev/null
}

# May an INFERRED project root be $1? Explicit declarations bypass this entirely.
#
# INFERENCE MAY NEVER LAND ON $HOME. When it did, a caller mkdir'd $HOME/.maude/plugin, and from
# then on the filesystem walk-up STOPPED at that phantom for every path outside the real workspace
# — it broke the mission clear, the undo list and the conscience clear on 2026-07-30.
#
# COMPARE CANONICALLY, NOT AS STRINGS. Bash's `pwd` is LOGICAL: it preserves the symlinked spelling
# you arrived through, and the walk-up feeds candidates from `pwd`/`dirname`. So with `/link` ->
# $HOME, a walk from `/link/work` offers the candidate `/link`, which is not string-equal to $HOME,
# and the phantom was accepted. `$HOME/.`, `$HOME//` and a $HOME carrying a trailing space all
# defeated the string compare the same way. Every one of those was demonstrated against this guard.
#
# FAIL CLOSED. If home cannot be identified at all, refuse the candidate rather than allow it: the
# walk then falls through to pwd, which is conservative and predictable. A guard whose failure mode
# is "permit" is not a guard.
#
# THE TRADE, stated so it is not rediscovered: a project whose root genuinely IS $HOME can no
# longer be found by inference. It is still found by declaration, and hooks always carry
# CLAUDE_PROJECT_DIR, so only a Bash-tool-invoked script in such a project is affected. A store
# that is merely missing beats one that is confidently wrong.
#
# Only $HOME ITSELF is barred, never paths beneath it — ordinary workspaces all live under $HOME.
_maude_inferred_root_ok() {
  local cand="$1" home hc cc
  [ -n "$cand" ] || return 1
  [ "$cand" != "/" ] || return 1
  [ -d "$cand" ] || return 1
  home="$(_maude_home)" || return 1
  # Trailing slashes and trailing whitespace are spellings of the same directory, and both were
  # used to walk past this.
  while :; do
    case "$home" in
      */)   home="${home%/}" ;;
      *' ') home="${home% }" ;;
      *"	") home="${home%	}" ;;
      *)    break ;;
    esac
    [ -n "$home" ] || return 1
  done
  # A home of "/" cannot be distinguished from the root the candidate check above already refuses.
  [ "$home" != "/" ] || return 0
  hc="$(_maude_canon "$home")" || hc="$home"
  cc="$(_maude_canon "$cand")" || cc="$cand"
  [ "$cc" != "$hc" ]
}

# Is a candidate in a LOCATION that could sanely hold a workspace? Path-shaped
# refusal only, no content test, so it is safe for the filesystem walk-up too.
# /tmp is 1777 and /tmp/.maude/plugin exists on real boxes; a root resolved there
# would put care.json, gate tokens, the vault and the trace log into
# world-writable, reboot-volatile storage.
_maude_root_location_ok() {
  local cand _mco_t
  cand="${1%/}"
  [ -n "$cand" ] || return 1
  case "$cand" in
    /tmp|/var/tmp|/) return 1 ;;
  esac
  # Canonicalise both sides. The process walk hands a canonical candidate
  # (readlink /proc/N/cwd) but the filesystem walk-up hands a logical one (pwd),
  # and $TMPDIR may be spelled through a symlink, so a raw compare would miss.
  # KNOWN GAP (0.30.2): the case above matches the raw spelling, so a symlink TO
  # /tmp, or macOS's /private/tmp, is not refused by it.
  if [ -n "${TMPDIR:-}" ]; then
    _mco_t="${TMPDIR%/}"
    if [ "$(_maude_canon "$cand" 2>/dev/null || printf '%s' "$cand")" \
         = "$(_maude_canon "$_mco_t" 2>/dev/null || printf '%s' "$_mco_t")" ]; then
      return 1
    fi
  fi
  return 0
}

# Is a candidate a PLAUSIBLE closet, used only where the process walk must choose
# BETWEEN candidates? Adds a content test on top of the location test, and
# the content test refuses a closet holding none of care.json, trace/ or vault.db
# (a hand-made empty one, or one only the eye has touched) and nothing more. LIMIT, pinned
# in tests/test-project-dir-resolution.sh (13b): the closet the plugin itself
# leaves (maude_ensure_self_dir makes trace/; maude-clear-gate.sh then writes
# care.json) passes this test, and a wrong answer runs exactly that code, so this
# cannot separate a mis-resolution's closet from a real one.
#
# NOT used by the filesystem walk-up, which climbs a single path and takes the
# first hit — it has no candidates to choose between, and a legitimately fresh
# closet there would be refused for having no content yet.
_maude_closet_ok() {
  local cand
  cand="${1%/}"
  _maude_root_location_ok "$cand" || return 1
  [ -f "$cand/.maude/plugin/care.json" ] \
    || [ -d "$cand/.maude/plugin/trace" ] \
    || [ -f "$cand/.maude/plugin/vault.db" ]
}

# Project root — prefer $CLAUDE_PROJECT_DIR (set by Claude Code), fall back to pwd.
# This matches the remember plugin's anchoring so .maude/ and .remember/ stay siblings.
maude_project_dir() {
  # Claude Code exports CLAUDE_PROJECT_DIR to hook subprocesses but NOT to
  # the Bash tool subprocess. So slash-command-invoked scripts have to find
  # the workspace root themselves. Order:
  #   0. $MAUDE_PROJECT_DIR_OVERRIDE if set (test seam only — lets a test
  #      point a hook at a project dir without touching CLAUDE_PROJECT_DIR.
  #      Unset in normal use, so default behavior is unchanged.)
  #   1. $CLAUDE_PROJECT_DIR if set (always for hooks)
  #   2. Walk up the PROCESS tree. Prefer the nearest `claude`-named ancestor's
  #      cwd; if none qualifies, take the nearest ancestor cwd that already
  #      holds a .maude/plugin closet. On Linux this matches what hooks see,
  #      regardless of how many subshells (or daemon processes) are layered
  #      between the script and Claude Code.
  #   3. Walk up the FILESYSTEM from pwd looking for an existing
  #      .maude/plugin/ closet (non-Linux fallback / edge cases). DANGER: from a
  #      subproject this finds the SUBPROJECT's closet, which is not what the
  #      hooks read. Step 2 exists to make this a genuine last resort.
  #   4. pwd (first-time setup, no closet anywhere).
  #
  # Steps 1.5-3 are INFERENCE and are barred from returning $HOME — see
  # _maude_inferred_root_ok. Step 4 is the last resort and returns pwd AS-IS,
  # $HOME or /tmp included: a first-time setup in an odd place is the operator's
  # call, and refusing would hand the caller nothing (0.30.2 question). Steps
  # 0-1 are DECLARATIONS and are not barred.
  #
  # $MAUDE_PROC_ROOT / $MAUDE_PROC_START_PID are test seams (they let
  # tests/test-project-dir-resolution.sh drive the walk against a fixture
  # process tree — without them the real walk short-circuits on the live
  # `claude` process and no wrong answer is reachable). Unset in normal use.
  if [ -n "${MAUDE_PROJECT_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$MAUDE_PROJECT_DIR_OVERRIDE"
    return
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return
  fi
  # 1.5. $CLAUDE_PID — Claude Code naming its OWN process id. Stronger than the
  # walk below, so it outranks it. It is NOT treated as fully declarative: the
  # $HOME guard and the location test still apply (a lens found this step alone
  # accepting a $TMPDIR root the two steps below it refuse), because a stale or recycled pid landing at $HOME
  # would mint the phantom closet that guard exists to prevent. So a project
  # genuinely rooted at $HOME resolves via step 1 for hooks but is refused here —
  # a known, deliberate asymmetry, not an oversight. Verified live 2026-09-02: it IS exported to the
  # Bash tool subprocess and /proc/$CLAUDE_PID/cwd is the workspace root. In the
  # tree measured that morning its `comm` was the VERSION string ("2.1.258"), which
  # is exactly why matching on the name `claude` found the wrong process there; in
  # another tree the same day `comm` was `claude` at the workspace root. The name
  # is not a stable signal in either direction, so it is not used here.
  #
  # Guarded, never required: under a PID namespace or in a container /proc/<pid>
  # may be unreadable. Then we FALL THROUGH to the walk rather than collapsing —
  # making this the walk's starting pid would strand the resolver on iteration 0.
  if [ -n "${CLAUDE_PID:-}" ]; then
    cc_cwd="$(readlink "${MAUDE_PROC_ROOT:-/proc}/$CLAUDE_PID/cwd" 2>/dev/null)"
    if [ -n "$cc_cwd" ] && _maude_root_location_ok "$cc_cwd" \
       && _maude_inferred_root_ok "$cc_cwd"; then
      printf '%s' "$cc_cwd"
      return
    fi
  fi

  # The walk collects TWO candidates in one pass and never abandons early.
  #
  #   claude_hit — nearest ancestor named `claude` whose cwd passes the guard.
  #                Still the strongest of the signals left once CLAUDE_PID has
  #                produced nothing, and it must outrank the closet
  #                probe: in a classic session an intermediate shell may sit in a
  #                subproject that has its own closet, and `claude`'s cwd is the
  #                right answer there.
  #   closet_hit — nearest ancestor whose cwd passes the guard AND already holds
  #                a .maude/plugin closet. This is what survives the daemon tree
  #                (2026-09-02): Claude Code's worker processes are named by
  #                VERSION ("2.1.258") rather than `claude`, and the process still
  #                named `claude` sits at $HOME, which the guard correctly refuses.
  #                Keying only on the name skipped the one ancestor that knew.
  #
  # A refused candidate must NEVER `break`. It did, and that abandoned a walk
  # which had already passed the correct answer at depth 0 — the resolver then
  # fell to the filesystem walk-up and returned a SUBPROJECT's closet. Live cost:
  # maude-clear-gate.sh wrote its token to <subproject>/.maude/plugin/care.json
  # while the gate hook read <workspace>/.maude/plugin/care.json. The clear
  # printed success; the gate refused anyway. Pinned by tests 7 and 8 in
  # tests/test-project-dir-resolution.sh.
  procroot="${MAUDE_PROC_ROOT:-/proc}"
  pid="${MAUDE_PROC_START_PID:-${PPID:-}}"
  i=0
  local claude_hit closet_hit
  claude_hit=""
  closet_hit=""
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$i" -lt 16 ]; do
    cc_cwd="$(readlink "$procroot/$pid/cwd" 2>/dev/null)"
    if [ -n "$cc_cwd" ] && _maude_inferred_root_ok "$cc_cwd"; then
      # The location test applies here too: this branch outranks the closet
      # probe, so without it a claude-named ancestor at $TMPDIR handed back the
      # very root step 1.5 had just refused (a lens proved it; test 12c pins it).
      if [ -z "$claude_hit" ] && [ -r "$procroot/$pid/comm" ] \
         && [ "$(cat "$procroot/$pid/comm" 2>/dev/null)" = "claude" ] \
         && _maude_root_location_ok "$cc_cwd"; then
        claude_hit="$cc_cwd"
      fi
      # NEAREST, deliberately — not outermost.
      #
      # An earlier draft preferred the outermost closet along the same path, to
      # skip the tool shell's own subproject cwd. That REGRESSED a session
      # legitimately rooted IN a subproject: it climbed past the true root. Proven
      # with a fixture, and it is the mirror image of the bug being fixed.
      #
      # The two shapes are INDISTINGUISHABLE from the process tree — "tool shell
      # standing in a subproject" and "session rooted at that subproject" produce
      # the same ancestors. No walk heuristic can separate them, so trading one
      # silent wrong answer for another is not progress. The walk stays
      # conservative and $CLAUDE_PID (step 1.5) is what actually resolves it. The
      # remaining gap is pinned as a documented residual in
      # tests/test-project-dir-resolution.sh rather than papered over.
      if [ -z "$closet_hit" ] && _maude_closet_ok "$cc_cwd"; then
        closet_hit="$cc_cwd"
      fi
    fi
    pid="$(_maude_ppid "$procroot/$pid")" || break
    i=$((i + 1))
  done
  if [ -n "$claude_hit" ]; then
    printf '%s' "$claude_hit"
    return
  fi
  if [ -n "$closet_hit" ]; then
    printf '%s' "$closet_hit"
    return
  fi
  d="$(pwd)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    # Same LOCATION test as the process walk — not the contents test, see
    # _maude_closet_ok. Without it this step accepts /tmp, which has a real
    # .maude/plugin on some boxes. It matters most
    # where there is NO /proc (macOS): steps 1.5 and 2 produce nothing there, so
    # this is the ONLY resolver, and it is the one that finds a subproject.
    if [ -d "$d/.maude/plugin" ] && _maude_root_location_ok "$d" \
       && _maude_inferred_root_ok "$d"; then
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
# $MAUDE_MEM_DIR_OVERRIDE is a test seam (points a hook at a fixture mem dir
# without needing a real ~/.claude/projects/<slug>/memory tree); unset in
# normal use, so default behavior is unchanged.
maude_mem_dir() {
  if [ -n "${MAUDE_MEM_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$MAUDE_MEM_DIR_OVERRIDE"
    return
  fi
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

# ── Session label — ties commentary to the session that produced it ─────────
# Several concurrent Claude sessions can share one project root (a tmux fleet),
# and they all write the SAME trace file. Every aggregate surface built on the
# trace — the catch-digest, drift-watch, /maude:notice — needs to know WHOSE
# event each entry is, or one session's commentary bleeds into another's brief.
# Precedence: explicit MAUDE_SESSION_LABEL > tmux session name (the name the
# user thinks in: "hub", "pacioli") > harness session id > "solo".
# WRITERS AND READERS OF THE SAME TRACE MUST RESOLVE THE SAME LABEL for the
# same session, or scoped surfaces go blind (a reader filtering on a label no
# writer ever stamped). So every tier is visible to every hook alike: a caller
# holding the hook envelope passes its `session_id` as $1, and the harness's
# exported CLAUDE_CODE_SESSION_ID covers the hooks that never parse stdin —
# both are the SAME id, so the resolved label agrees either way.
# #49: the token ledger — every hook that injects context logs its bill.
# Metadata only: hook class + byte count, NEVER content. Bytes are the honest
# stored unit; approximate tokens are derived at read time (receipts), never
# written. Silence costs nothing, so zero/garbage counts log nothing.
maude_log_spend() {  # maude_log_spend <hook-class> <bytes>
  case "${2:-}" in (''|*[!0-9]*) return 0 ;; esac
  [ "$2" -gt 0 ] || return 0
  maude_log_trace "spend" "hook=$1 bytes=$2"
}

# shellcheck disable=SC2120  # $1 (envelope session_id) is optional by design
maude_session_label() {
  local l="${MAUDE_SESSION_LABEL:-}" sid="${1:-}"
  if [ -z "$l" ] && [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    l="$(tmux display-message -p '#S' 2>/dev/null)"
  fi
  [ -z "$sid" ] && sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -z "$l" ] && [ -n "$sid" ] && l="$(printf '%.8s' "$sid")"
  [ -z "$l" ] && l="solo"
  printf '%s' "$l"
}

maude_log_trace() {
  local kind="$1" payload="$2" trace ts
  trace="$(maude_trace_file)"
  mkdir -p "$(dirname "$trace")" 2>/dev/null
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local slbl
  slbl="$(maude_session_label)"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg ts "$ts" --arg kind "$kind" --arg payload "$payload" --arg s "$slbl" \
      '{ts:$ts, kind:$kind, payload:$payload, session:$s}' >> "$trace" 2>/dev/null
  else
    # Fallback: sed-escape backslashes and quotes for JSON safety
    local esc sesc
    esc="$(printf '%s' "$payload" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')"
    sesc="$(printf '%s' "$slbl" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n')"
    printf '{"ts":"%s","kind":"%s","payload":"%s","session":"%s"}\n' \
      "$ts" "$kind" "$esc" "$sesc" >> "$trace"
  fi
}

# Best-effort redaction for content written to disk (the pre-compact snapshot and
# the .remember/ handoff). Masks a few HIGH-signal secret shapes from stdin → stdout.
# BEST-EFFORT, NOT a guarantee — it cannot catch every secret, so callers must
# still treat the output as sensitive (the snapshot is gitignored + session-wiped).
maude_redact() {
  # The IPv4 pattern below is shape-only: a valid-octet dotted quad that's
  # actually a version/build number (e.g. a 10.20.30.x build) is indistinguishable
  # from an IP without semantics and WILL get redacted — accepted trade-off,
  # fail-closed.
  #
  # Portability (issue #39 wave 2): sed `\b` and the one-line `c\text` form are
  # GNU-only — BSD sed rejected the whole expression and every redact caller
  # emitted EMPTY on macOS. Word edges are now explicit (^|[^0-9.]) groups
  # (slightly MORE aggressive than \b at wordchar-adjacent quads, e.g. a
  # v-prefixed v1.2.3.x quad now redacts — fail-closed, accepted; the example
  # here ends in .x so the pre-push guard never lexes its own documentation
  # as an IP), and the PEM range keeps
  # the BEGIN line and rewrites it to the marker instead of using `c\`.
  # The IP substitution runs twice: `g` can't re-match an adjacent quad whose
  # leading boundary char was consumed by the previous match. A quad ending a
  # sentence ("at 192.0.2.4.") is masked: a trailing dot counts as an edge when no
  # digit follows it (2026-10-30; before, the dot let it through).
  local ip='((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])'
  sed -E \
    -e 's#(https?://)[^/:@[:space:]]+:[^/@[:space:]]+@#\1[redacted-creds]@#g' \
    -e 's#(sk-|ghp_|gho_|ghu_|ghs_|github_pat_|xox[abprs]-|AKIA|AIza)[A-Za-z0-9_-]{8,}#[redacted-secret]#g' \
    -e 's#eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+#[redacted-jwt]#g' \
    -e "s#(^|[^0-9.])${ip}(\$|[^0-9.]|\\.\$|\\.[^0-9])#\\1[redacted-ip]\\5#g" \
    -e "s#(^|[^0-9.])${ip}(\$|[^0-9.]|\\.\$|\\.[^0-9])#\\1[redacted-ip]\\5#g" \
    -e '/-----BEGIN[A-Z ]*PRIVATE KEY-----/,/-----END[A-Z ]*PRIVATE KEY-----/{' \
    -e '/-----BEGIN/!d' \
    -e 's#.*#[redacted-key]#' \
    -e '}'
  # ^ the brace block is split across -e fragments: sed joins them with real
  #   newlines, which is the form BSD sed's grammar requires ("the terminating
  #   '}' must be preceded by a newline") — a ;} one-liner is GNU-tolerated only.
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
#
# LOCKED and READ BACK (2026-09-06, the memory lens): twenty-five callers, one on every
# prompt, four sessions at once, and the read-modify-write had no lock, so a second
# writer's rename erased the first's write; and it returned 0 on a successful mv, never
# on the bytes that landed. The chores ledger one file away had the flock all along.
maude_care_set() {
  local care="$1"; shift
  maude_locked "$care.lock" _maude_care_set_unlocked "$care" "$@"
}
_maude_care_set_unlocked() {
  local care="$1"; shift
  local tmp want got
  tmp="$(mktemp "$(dirname "$care")/.care.XXXXXX" 2>/dev/null)" || return 1
  if jq "$@" "$care" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    want="$(od -An -v -tx1 < "$tmp" 2>/dev/null)"
    if mv "$tmp" "$care" 2>/dev/null; then
      # The file that now sits at $care must be the bytes this call wrote, byte for
      # byte; a rename that "succeeded" delivering other bytes is not a write. `$(cat)`
      # on both sides compared text with every trailing newline stripped (the 23rd
      # lens, MINOR-4), so the compare is each file's hex dump: a trailing newline is
      # a token there, and od is on every box this lib already relies on (cksum is in the
      # test farm since the gate's fingerprint needed it, but od reads a byte at a time
      # in the test farm, and need not be).
      got="$(od -An -v -tx1 < "$care" 2>/dev/null)"
      [ -n "$want" ] && [ "$want" = "$got" ] && return 0
      return 1
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Read-and-consume a one-shot gate token as ONE locked step. The gate read the token on
# one open and consumed it on a second, so a concurrent writer's rename could resurrect
# a spent token and a clear granted once passed twice (the memory lens, 2026-09-06).
# Prints "live" and consumes the token when it is live at NOW; "none" otherwise, and
# "none" when the consume did not land (fail closed).
maude_care_take_token() {  # <care.json> <key> <now-epoch>
  maude_locked "$1.lock" _maude_care_take_token_unlocked "$@"
  # Busy, never none: nothing was read, and "none" would send the person for a clear he
  # may hold. The caller blocks on anything but "live" (fail closed).
  [ $? -eq "$MAUDE_LOCK_BUSY" ] && printf 'busy'
  return 0
}
_maude_care_take_token_unlocked() {
  local care="$1" key="$2" now="$3" until
  _maude_care_drain_spent_unlocked "$care" "$key"
  until="$(jq -r --arg k "$key" '.gate_cleared[$k].until // 0' "$care" 2>/dev/null)"
  # The whole group is quiet: a non-numeric `until` made `[` print "integer expression
  # expected" on the person's channel when only the last test was silenced (MINOR-5).
  if { [ -n "$until" ] && [ "$until" -gt 0 ] && [ "$until" -gt "$now" ]; } 2>/dev/null; then
    if _maude_care_set_unlocked "$care" --arg k "$key" 'del(.gate_cleared[$k])'; then
      printf 'live'; return 0
    fi
  fi
  printf 'none'
}

# Reserve, then consume, a one-shot gate token as two locked steps (2026-09-06). The gate
# read AND consumed at PreToolUse, but PreToolUse hooks run in parallel and any sibling
# can refuse the same command (the version gate did on 09-06, the classifier on 09-05);
# PostToolUse never fires for a refused command, so a clear was spent on a push that
# never ran and cost a second clear every time. Now the gate RESERVES for its session at
# PreToolUse and CONSUMES at PostToolUse of the command that actually ran.
# THE IDENTITY OF A TOOL CALL — two helpers: its head (below) and its fingerprint (after).
#
# The fingerprint of a tool call: a hash of its tool_input, keys SORTED (`jq -S`), so the
# same call fingerprints the same at PreToolUse and PostToolUse whatever order the harness
# emits (the 25th lens, IMPORTANT-2: `jq -c` preserves input order, and a Post in another
# order left the token un-spendable and silent). cksum is POSIX and on macOS; the chain
# below keeps a stripped box from losing the identity entirely. Prints "" when nothing can
# hash — the caller then falls back to the command's first 60 chars, which still tells two
# commands apart (IMPORTANT-3: an empty fp used to refuse the sibling-refusal retry that
# the whole reserve/consume split exists to allow). Collisions do not matter: Claude is not
# attacking its own gate (the honest seam).
# The first 60 CHARACTERS of a command, through jq so both ends sanitise identically.
# `printf %.60s` cuts at 60 BYTES, so a multibyte character straddling the cut left a lone
# byte that jq rewrote to U+FFFD when it stored it — the two ends then compared different
# bytes, the retry was refused and the one-shot never spent (the 26th lens, IMPORTANT-3).
maude_call_head() {  # <command>
  command -v jq >/dev/null 2>&1 || { printf '%.60s' "$1" | tr '\n' ' '; return 0; }
  printf '%s' "$1" | tr '\n' ' ' | jq -Rrs '.[0:60]' 2>/dev/null
}

maude_call_fp() {  # <hook-input-json>
  local canon
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  # The TOOL is part of the call: hashing the arguments alone let a different destructive
  # tool with the same bytes ({"target":"x"} on another server, or no arguments at all) ride
  # the reservation as "the same call retried" and spend John's one RED clear (lens 6,
  # BLOCKING). Formula change → reservation v3; a v2 reservation names no call.
  canon="$(printf '%s' "$1" | jq -Sc '{n: (.tool_name // ""), i: (.tool_input // {})}' 2>/dev/null)"
  [ -n "$canon" ] || { printf ''; return 0; }
  if command -v cksum >/dev/null 2>&1; then printf '%s' "$canon" | cksum 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$canon" | shasum 2>/dev/null | awk '{print $1}'
  elif command -v sum >/dev/null 2>&1; then printf '%s' "$canon" | sum 2>/dev/null | awk '{print $1}'
  elif maude_python3_ok; then printf '%s' "$canon" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])' 2>/dev/null
  else printf ''
  fi
}

# Can THIS call spend anything? A consume can only take a live token that is unreserved,
# reserved by this call, or reserved by a shape that names no call at all. All three are
# answerable from the call alone -- no pattern table, no wrapped-payload recursion -- so
# the PostToolUse path asks this before it spawns the gate (the 25th lens, IMPORTANT-1: a
# text grep for `"reserved"` was defeated for the whole life of an orphaned reservation
# and by the word appearing anywhere in a 34 KB shared file, putting 306 ms back on every
# Bash completion in every session). rc 0 = something might be spendable.
maude_gate_spendable_here() {  # <hook-input-json> <command> <token-file>...
  local input="$1" cmd="$2" now f fp head live=0
  command -v jq >/dev/null 2>&1 || return 1
  now=$(date +%s); shift 2
  # PER FILE. One jq over both aborts on the first unparseable one, and red keys live in
  # one file while yellow live in the other, so a corrupt care.json silently made a live
  # RED clear unspendable — an N-shot force-push (the 26th lens, IMPORTANT-2).
  # `until` must be a NUMBER and `gate_cleared` an object, or the fast path green-lights
  # what the slow path refuses (MINOR-9).
  for f in "$@"; do
    [ -s "$f" ] || continue
    jq -e --argjson now "$now" \
      '(.gate_cleared // {}) | if type == "object" then to_entries else [] end
       | any((.value.until? // 0 | if type == "number" then . else 0 end) > $now)' \
      "$f" >/dev/null 2>&1 && { live=1; break; }
  done
  [ "$live" = 1 ] || return 1
  head="$(maude_call_head "$cmd")"
  fp="$(maude_call_fp "$input")"
  for f in "$@"; do
    [ -s "$f" ] || continue
    jq -e --arg f "$fp" --arg h "$head" --argjson now "$now" \
      '(.gate_cleared // {}) | if type == "object" then to_entries else [] end
       | any(((.value.until? // 0 | if type == "number" then . else 0 end) > $now)
             and (((.value.reserved | type) != "object")
                  or (((.value.reserved.v? // 0) | tostring) != "3")
                  or ((.value.reserved.fp // "") == $f and $f != "")
                  or (((.value.reserved.fp // "") == "") and ((.value.reserved.head // "") == $h))))' \
      "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# The reservation belongs to the exact CALL: the session and <fp>, the fingerprint of the
# call's tool_input (the 24th lens, BLOCKING-2: a reservation of {sid, at} was a
# LEASE, so one clear opened a different command of the same session 4 s later, another
# session's after a 120 s window, red keys included). Where nothing can hash, <head> —
# the command's first 60 chars — is the identity instead.
#   maude_care_reserve_token <care> <key> <sid> <now> <fp> <head>
#     "live"       the token is live and now reserved by this call;
#     "inflight"   this same call reserved it less than MAUDE_TOKEN_RETRY_MIN seconds
#                  ago: a duplicate in the same instant (two tool calls in one batch);
#     "reserved" + <sid> + <seconds-left> + <head>, joined by \037 (a
#                  non-blank separator: `read` collapses empty tab fields): another call holds it, until the clear
#                  expires or is made again. There is no takeover window: an orphaned
#                  reservation is the clear's problem, never another lane's opening;
#     "unwritable" the token is live but the reservation did not land (fail closed, and
#                  say so: the person holds a clear the gate cannot record);
#     "busy"       the store's lock was held past MAUDE_LOCK_WAIT: nothing was read;
#     "none"       absent or expired.
#              The same call again after RETRY_MIN is a pass: its earlier run was refused
#              by a sibling hook and never ran. A reservation carrying neither <fp> nor
#              <head> (one written before this shape existed) names no call: it is
#              re-reserved here and spent by any matching command at Post, because a clear
#              left open is the wrong direction for a one-shot.
#   maude_care_consume_token <care> <key> <fp> <head>
#     "spent"    the token is gone: the call that reserved it ran (or nothing had);
#     "none"     otherwise; a different call's reservation is left alone.
# Residual, named: a reserved command that RAN but whose consume never landed (the trace
# hook killed by its budget, care.json unwritable) leaves its reservation, and the same
# bytes from the same session ride it again until the clear expires.
# Each is ONE locked read-modify-write, like the take_token above it.
MAUDE_TOKEN_RETRY_MIN="${MAUDE_TOKEN_RETRY_MIN:-3}"
maude_care_reserve_token() {  # <care.json> <key> <sid> <now-epoch> <fp> <head>
  maude_locked "$1.lock" _maude_care_reserve_token_unlocked "$@"
  # Busy, never none: the person may hold a clear, and "none" sends him for one he has.
  [ $? -eq "$MAUDE_LOCK_BUSY" ] && printf 'busy'
  return 0
}
_maude_care_reserve_token_unlocked() {
  local care="$1" key="$2" sid="$3" now="$4" fp="$5" head="$6" until rsid rat rfp rhead rv _same
  _maude_care_drain_spent_unlocked "$care" "$key"
  until="$(jq -r --arg k "$key" '.gate_cleared[$k].until // 0' "$care" 2>/dev/null)"
  if ! { [ -n "$until" ] && [ "$until" -gt 0 ] && [ "$until" -gt "$now" ]; } 2>/dev/null; then
    printf 'none'; return 0
  fi
  IFS="$(printf '\037')" read -r rsid rat rfp rhead rv <<EOF
$(jq -r --arg k "$key" '.gate_cleared[$k].reserved // {} | [(.sid // ""), ((.at // 0) | tostring), (.fp // ""), (.head // ""), ((.v // 0) | tostring)] | join("\u001f")' "$care" 2>/dev/null)
EOF
  # Only a reservation THIS build wrote can be matched: the fingerprint formula has already
  # changed once between releases, and comparing across a change refused the person their
  # own command on a clear they held (the 26th lens, IMPORTANT-4). Anything else names no
  # call: re-reserve here, spend at Post.
  if [ "$rv" = 3 ] && { [ -n "$rfp" ] || [ -n "$rhead" ]; }; then
    _same=0
    if [ -n "$fp" ] && [ "$rfp" = "$fp" ] && [ "$rsid" = "$sid" ]; then _same=1
    elif [ -z "$fp" ] && [ -z "$rfp" ] && [ -n "$head" ] && [ "$rhead" = "$head" ] && [ "$rsid" = "$sid" ]; then _same=1
    fi
    if [ "$_same" = 1 ]; then
      if [ $(( now - rat )) -lt "$MAUDE_TOKEN_RETRY_MIN" ] 2>/dev/null; then printf 'inflight'; return 0; fi
    else
      printf 'reserved\037%s\037%s\037%s' "$rsid" "$(( until - now ))" "$rhead"; return 0
    fi
  fi
  # Expired tokens are pruned at every reservation: nothing else ever removed them, so
  # `gate_cleared` was permanently non-empty and the PostToolUse cheap exit could never
  # exit cheaply on a box that had ever been given a clear (the 26th lens, MINOR-4).
  if _maude_care_set_unlocked "$care" --arg k "$key" --arg s "$sid" --argjson t "$now" --arg f "$fp" --arg h "$head" \
       '.gate_cleared = ((.gate_cleared // {}) | if type == "object" then . else {} end
          | with_entries(select((.key == $k) or ((.value.until? // 0 | if type == "number" then . else 0 end) > $t))))
        | .gate_cleared[$k].reserved = {sid: $s, at: $t, fp: $f, head: $h, v: 3}'; then
    printf 'live'; return 0
  fi
  printf 'unwritable'
}
# A consume that finds the store busy must not leave a one-shot spendable: the command
# RAN. Answering "none" left the reservation, and after MAUDE_TOKEN_RETRY_MIN the same
# bytes rode the token again, a RED force-push included (the lens, B2). So a busy consume
# leaves a SPENT MARKER beside the store, written without the lock (a rename is atomic),
# and prints "queued"; every locked token read drains the marker first, spending the token
# only while the same session's same call still holds its reservation (see the drain).
# A marker can only ever SPEND, never grant.
maude_care_consume_token() {  # <care.json> <key> <fp> <head> [sid]
  maude_locked "$1.lock" _maude_care_consume_token_unlocked "$@"
  if [ $? -eq "$MAUDE_LOCK_BUSY" ]; then
    if _maude_care_mark_spent "$@"; then printf 'queued'; else printf 'none'; fi
  fi
  return 0
}
_maude_care_spent_marker() { printf '%s.spent-%s' "$1" "$2"; }  # <care.json> <key>
_maude_care_mark_spent() {  # <care.json> <key> <fp> <head> [sid]
  local m tmp
  maude_is_ascii_token "$2" || return 1
  m="$(_maude_care_spent_marker "$1" "$2")"
  tmp="$m.$$"
  # Only a regular file (or nothing) may stand at the marker path. `mv -f` onto a DIRECTORY
  # moves the marker INTO it and reports success, the drain's -f test then never sees a
  # marker, and the same bytes pass again on the token the person believed spent (lens 5,
  # BLOCKING). The obstacle is moved aside, never removed: nothing here deletes what it
  # did not write.
  _maude_care_marker_path_clear "$m" || return 1
  # The session is part of the call's identity: two lanes running the same bytes share an
  # fp, and a late marker from one ate the other's reservation (lens 3, I-A).
  printf '%s\037%s\037%s\n' "${5:-}" "$3" "${4:-}" > "$tmp" 2>/dev/null && mv -f "$tmp" "$m" 2>/dev/null \
    && [ -f "$m" ] && [ ! -L "$m" ] && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}
# True when nothing or a regular file stands at <path>; anything else (a directory, a
# symlink, a fifo) is renamed aside and the function fails if it could not be.
_maude_care_marker_path_clear() {  # <path>
  [ -L "$1" ] || [ -e "$1" ] || return 0
  [ -f "$1" ] && [ ! -L "$1" ] && return 0
  mv -f "$1" "$1.notafile.$$" 2>/dev/null
  ! { [ -L "$1" ] || [ -e "$1" ]; }
}
# Under the store's lock: spend what a queued consume could not, and ONLY that. The marker
# names one call (its fp, else its head when neither side could hash); it spends the token
# only while that exact call still holds the reservation. Anything else (the token gone,
# expired, unreserved because John cleared again, or reserved by another call) makes the
# marker stale: it is dropped and spends nothing. The first version spent through the
# ordinary consume, which also spends an UNRESERVED token, so a marker left from one push
# ate John's next, unrelated clear (lens 2, I1). A marker that names no call is stale.
# The marker is removed only if it still holds what was read (a newer marker renamed in
# between is kept), and never when the store could not be read (jq failed).
_maude_care_drain_spent_unlocked() {  # <care.json> <key>
  local care="$1" key="$2" m snap msid mfp mhead state
  maude_is_ascii_token "$key" || return 0
  m="$(_maude_care_spent_marker "$care" "$key")"
  [ -f "$m" ] || return 0
  snap="$(cat "$m" 2>/dev/null)"
  IFS="$(printf '\037')" read -r msid mfp mhead <<EOF
$snap
EOF
  state="$(jq -r --arg k "$key" --arg s "$msid" --arg f "$mfp" --arg h "$mhead" '
    (.gate_cleared[$k].reserved // null) as $r
    | if ($r | type) != "object" then "stale"
      elif ($s != "" and $s != "default" and ($r.sid // "") != "default" and ($r.sid // "") != $s) then "stale"
      elif ($f != "" and ($r.fp // "") == $f) then "ours"
      elif ($f == "" and $h != "" and ($r.fp // "") == "" and ($r.head // "") == $h) then "ours"
      else "stale" end' "$care" 2>/dev/null)"
  case "$state" in
    ours)  _maude_care_set_unlocked "$care" --arg k "$key" 'del(.gate_cleared[$k])' || return 0 ;;
    stale) : ;;
    *)     return 0 ;;   # the store could not be read: keep the marker for the next read
  esac
  [ "$(cat "$m" 2>/dev/null)" = "$snap" ] && rm -f "$m" 2>/dev/null
  return 0
}
_maude_care_consume_token_unlocked() {
  _maude_care_drain_spent_unlocked "$1" "$2"
  _maude_care_spend_unlocked "$@"
}
_maude_care_spend_unlocked() {
  local care="$1" key="$2" fp="$3" head="${4:-}" sid="${5:-}" until rfp rhead rv rsid
  until="$(jq -r --arg k "$key" '.gate_cleared[$k].until // 0' "$care" 2>/dev/null)"
  { [ -n "$until" ] && [ "$until" -gt 0 ]; } 2>/dev/null || { printf 'none'; return 0; }
  # An UNRESERVED live token IS spent by the command that ran (the 25th lens, MINOR-6): the
  # gate that should have reserved it may never have run (killed by its budget, the very
  # timer errors of 2026-09-25), and a one-shot left open lets a SECOND command through.
  # Lens 3 (I-A) asked the opposite, because this also spends a re-clear John gives while
  # the command runs; that fails closed (one more clear), the other fails open, so MINOR-6
  # holds and I-A is a named residual. The queued (busy) path stays strict: a marker can
  # sit long after its command, so it spends only the reservation it names.
  rsid="$(jq -r --arg k "$key" '.gate_cleared[$k].reserved.sid // ""' "$care" 2>/dev/null)"
  rfp="$(jq -r --arg k "$key" '.gate_cleared[$k].reserved.fp // ""' "$care" 2>/dev/null)"
  rhead="$(jq -r --arg k "$key" '.gate_cleared[$k].reserved.head // ""' "$care" 2>/dev/null)"
  rv="$(jq -r --arg k "$key" '.gate_cleared[$k].reserved.v // 0' "$care" 2>/dev/null)"
  # A reservation this build did not write names no call it can match; the command ran, so
  # spend it. A clear left open is the wrong direction for a one-shot (IMPORTANT-4).
  if [ "$rv" != 3 ]; then rfp=""; rhead=""; rsid=""; fi
  # Another session's reservation of the same bytes is not this call's. "default" is the
  # gate's name for an envelope with no session_id: it spends on the bytes (MINOR-1).
  if [ -n "$sid" ] && [ "$sid" != default ] && [ -n "$rsid" ] && [ "$rsid" != default ] \
     && [ "$rsid" != "$sid" ]; then printf 'none'; return 0; fi
  if [ -n "$rfp" ] && [ "$rfp" != "$fp" ]; then printf 'none'; return 0; fi
  # Nothing on either side could hash: the head is the identity (IMPORTANT-3).
  if [ -z "$rfp" ] && [ -z "$fp" ] && [ -n "$rhead" ] && [ "$rhead" != "$head" ]; then printf 'none'; return 0; fi
  if _maude_care_set_unlocked "$care" --arg k "$key" 'del(.gate_cleared[$k])'; then
    printf 'spent'; return 0
  fi
  printf 'none'
}

# ONE identifier guard, for every side that judges one. A bracket range like
# [!A-Za-z0-9_-] is COLLATION, not bytes: under en_US.UTF-8 it admits the fullwidth ａ
# (U+FF41), the ligature ﬀ (U+FB00) and the Arabic-Indic ١ (U+0661), all of which C
# rejects — so what such a guard MEANT moved with the box's locale, and this repo pins
# no locale anywhere (not tests/run.sh, not lib.sh, not either CI workflow).
#
# It lives here because two copies of it lived in maude-redteam-watch.sh and drifted the
# instant one was fixed (the 30th lens): the side that MINTS a pending key admitted an id
# the side that CLEARS it refused, so an entry could be created and never cleared — the
# exact failure the kill branch exists to end, reintroduced by fixing the shape instead of
# the class. Two guards answering one question must be one guard.
#
# tr tests BYTE membership and says the same thing on every box; the LC_ALL=C is belt for
# a locale-aware tr, which this box's GNU tr is not, so no test here can see that prefix.
# Returns 0 for a non-empty ASCII token of [A-Za-z0-9_-] only.
maude_is_ascii_token() {
  [ -n "${1:-}" ] || return 1
  [ "$1" = "$(printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9_-')" ]
}

# The eye's per-session file suffix: ".<session_id>" for a safe id, "" otherwise (the
# unkeyed files, the shape before 2026-09-25). One helper for the tick, the whisper and
# the blink: every session shared one eye-state and one whisper file, so a whisper born
# from one lane's transcript reached whichever lane prompted next (a fresh session, zero
# tool calls, was told "the last two bash calls appear identical").
maude_eye_suffix() {  # <session_id>
  # Capped: a 250-char id made every eye filename exceed NAME_MAX, and every eye write
  # failed in silence (the lens, m6). Real ids are 36-char UUIDs.
  [ "${#1}" -le 64 ] && maude_is_ascii_token "${1:-}" && printf '.%s' "$1"
  return 0
}

# Run "$@" while holding LOCK, for every read-modify-write of a shared file. flock(1)
# where it exists, blocking: a writer must never lose its write. Without it (macOS), a
# mkdir spin-lock reclaimed off the DIR'S OWN age, the one signal every waiter agrees
# on (a waiter-side counter had every waiter reclaiming on its own clock). The age key
# does not stop theft: a holder still alive past 30 s loses the lock to the next waiter
# and its later write clobbers the thief's. No live caller holds it that long (a jq
# and a mv), so the 30 s is a dead-holder floor, not a guarantee (the 23rd lens).
# Returns the command's exit status.
#
# BOUNDED (2026-09-25): the wait was blocking, so its only bound was the harness's 5 s
# hook timer. Every session on a box shares one store, and a holder past the budget
# turned each waiter into a "hook timed out" on the person's screen (an eye tick behind
# a held lock died at 5003 ms). Now a waiter gives up after MAUDE_LOCK_WAIT seconds
# (whole seconds, default 2) and returns 75 WITHOUT running the command. Every caller
# turns 75 into its safe direction: a lost tick, a write reported as not landed, a
# token read as none, a reservation read as busy.
# The bound is per HOOK, not per call (the lens, I2): a hook that locks three times behind
# a held lock waited 3 x 2 s past its 5 s budget. After one busy, every later wait in the
# same process is a single try. Base-10 and capped: "08" was an arithmetic error on the
# fallback, and a 20-digit value overflowed it into never timing out (the lens, m2).
MAUDE_LOCK_BUSY=75
_MAUDE_LOCK_BUSY_SEEN=""
# The wait, in seconds, from MAUDE_LOCK_WAIT: digits only (else the default 2), base 10,
# at most 60. Its own function so the parse is testable without waiting it out (lens 5:
# the 60 cap on a three-digit value had no test that could see it go).
maude_lock_wait() {  # [value] → seconds
  local wait="${1-${MAUDE_LOCK_WAIT:-2}}"
  case "$wait" in ''|*[!0-9]*) wait=2 ;; esac
  [ "${#wait}" -gt 3 ] && wait=60
  wait=$((10#$wait)); [ "$wait" -gt 60 ] && wait=60
  printf '%s' "$wait"
}
# The busy latch: once a lock has cost this process a real wait and still come back busy,
# every later lock in it waits 0, so one contended store cannot spend a hook's budget
# twice. A caller that asked for wait 0 spent nothing, so its busy does not latch: the
# prune runs wait 0 at every session start and used to silence the next lock's wait.
maude_locked() {  # <lockfile> <command> [args…]
  local lock="$1" wait rc; shift
  wait="$(maude_lock_wait "${MAUDE_LOCK_WAIT:-2}")"
  [ -n "$_MAUDE_LOCK_BUSY_SEEN" ] && wait=0
  # A lock path that cannot be opened (a DIRECTORY where the file should be, no parent)
  # is "busy" on both branches: the flock branch's redirect failed with rc 1, which no
  # caller names, so reserve/consume/take printed nothing (lens 6, MAJOR).
  # A bare name has no directory part (it is "."), and a symlink at the lock path is not
  # ours to open: -e/-f follow it and a dangling one would be created through (lens 7).
  local lockdir="${lock%/*}"; [ "$lockdir" = "$lock" ] && lockdir=.
  if ! { [ -d "$lockdir" ] && [ ! -L "$lock" ] && { [ ! -e "$lock" ] || [ -f "$lock" ]; }; }; then
    [ "$wait" -gt 0 ] && _MAUDE_LOCK_BUSY_SEEN=1; return "$MAUDE_LOCK_BUSY"
  fi
  if command -v flock >/dev/null 2>&1; then  # portability-shim (util-linux)
    (
      flock -w "$wait" 9 || exit "$MAUDE_LOCK_BUSY"  # portability-shim
      "$@"
    ) 9>"$lock"
    rc=$?
    [ "$rc" -eq "$MAUDE_LOCK_BUSY" ] && [ "$wait" -gt 0 ] && _MAUDE_LOCK_BUSY_SEEN=1
    return "$rc"
  fi
  # The bound is the CLOCK, not a try count. `wait * 20` tries of `sleep 0.05` assumed a try
  # costs 50 ms, but each also forks mkdir, date, stat and sleep: on macOS (the only place
  # this branch runs) a 1 s bound waited 4 s and "08" waited 20 (PR #81). $SECONDS is a
  # builtin (bash 3.2 has it), so reading it costs no fork. It is whole seconds, so the
  # wait ends between `wait` and `wait + 1` s; the try count stays as a second ceiling.
  local d="$lock.d" tries=$((wait * 20)) t0="$SECONDS" gone=0
  while ! mkdir "$d" 2>/dev/null; do
    if [ "$tries" -le 0 ] || [ $((SECONDS - t0)) -gt "$wait" ]; then
      [ "$wait" -gt 0 ] && _MAUDE_LOCK_BUSY_SEEN=1; return "$MAUDE_LOCK_BUSY"
    fi
    tries=$((tries - 1))
    # mkdir fails for two reasons: the dir EXISTS (a holder; wait, reclaim if stale) or it
    # CANNOT be made (no parent, no permission). The second used to spin forever: the age
    # of a dir that is not there reads as zero, so nothing was ever reclaimed and a hook
    # against an unwritable store hung a CI job for six hours (macOS, no flock, PR #69).
    # One retry covers a holder that released between the failure and this look.
    if [ ! -d "$d" ]; then
      mkdir "$d" 2>/dev/null && break
      # Cannot be made (a stray FILE at the lock path, no parent, no permission): the
      # store is not lockable, which to every caller is "busy", the outcome they all
      # handle; a bare 1 fell past their case arms and printed nothing (lens 5).
      # Judge THAT from the path, never from "the dir is gone again": under churn another
      # waiter takes and releases the lock between our retry and this look, and reading
      # that as unlockable dropped 2 of 60 eye ticks with no wait at all (macOS shape).
      # A dir that never appears across five looks is not churn (churn shows a holder's dir
      # at some look, which resets the count): disk full, or a reason the path checks cannot
      # see. Give up then, not at the end of the bound (lens on aad5cda, MINOR 1).
      gone=$((gone + 1))
      if [ -e "$d" ] && [ ! -d "$d" ] || [ ! -d "$lockdir" ] || [ ! -w "$lockdir" ] || [ "$gone" -ge 5 ]; then
        [ "$wait" -gt 0 ] && _MAUDE_LOCK_BUSY_SEEN=1; return "$MAUDE_LOCK_BUSY"
      fi
      sleep 0.05; continue
    fi
    gone=0
    if [ $(( $(date +%s) - $(maude_mtime "$d" "$(date +%s)") )) -gt 30 ]; then
      rmdir "$d" 2>/dev/null
    fi
    sleep 0.05
  done
  "$@"; rc=$?
  rmdir "$d" 2>/dev/null
  return "$rc"
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
  # The session tie (the fleet fix): concurrent sessions share the trace, and a
  # pooled tally credits everyone's catches to whoever wakes next. Render per
  # session-label group; when TWO OR MORE sessions have catches in the window,
  # each group is prefixed with its label — a lone stream keeps the plain
  # single-session format unchanged (solo installs never see labels).
  line="$(cat "${files[@]}" 2>/dev/null | jq -rs --arg since "$since" '
    def render($evs):
      ( [ $evs[] | select(.kind=="gate"
                          and ((.payload // "")|startswith("blocked="))
                          and (((.payload // "")|test("git-push"))|not)) ] ) as $blocks
      | ( [ $blocks[] | select((.payload // "")|test("rm-rf-sole-copy")) ]|length ) as $saves
      | ( ($blocks|length) - $saves ) as $otherblocks
      | ( [ $evs[] | select(.kind=="infra-gate" and ((.payload // "")|test("blocked"))) ]|length ) as $infra
      | ( [ $evs[] | select(.kind=="gate-cleared" and ((.payload // "")|test("git-push"))) ]|length ) as $pushclears
      | ( [ $evs[] | select(.kind=="drift") ]|length ) as $drift
      | ( [ $evs[] | select(.kind=="verify") ]|length ) as $verify
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
        else "" end;
    [ .[] | select((.ts // "") > $since) ] as $new
    | ($new | group_by(.session // ""))
    | [ .[] | {label: (.[0].session // ""), txt: render(.)} | select(.txt != "") ] as $groups
    | if ($groups|length) > 1
      then [ $groups[] | ((if .label == "" then "unlabeled" else .label end) + ": " + .txt) ] | join(" · ")
      else ($groups[0].txt // "")
      end
  ')"

  # Every count carries a path to its receipts (issue #37): a folded tally
  # with no way to see the underlying catches is a claim taken on faith.
  [ -n "$line" ] && printf 'Maude caught since you last looked: %s. Receipts: /maude:notice\n' "$line"
  return 0
}

# ─── Uncaptured-work arithmetic (shared by BOTH ends of the continuity loop) ──
# "Capture anchor" = the freshest mtime among the continuity sources the wake
# path actually reads: the Anthropic buffer ($MEM/now.md), the remember
# plugin's live buffer (.remember/now.md), and the handoff (remember.md —
# NON-EMPTY only: it's drained to empty by design, so an empty one carries
# nothing and must not anchor). "Uncaptured" = user `prompt` events in the
# durable trace newer than that anchor. The SessionStart guard (warn on a
# stale wake) and the SessionEnd auto-note (leave a pointer at quit) both
# read THESE — never their own copy — so the two ends of the loop can't
# disagree on what "uncaptured" means.

# ── Portability shims (issue #39) ───────────────────────────────────────
# macOS/BSD userland speaks different flags than GNU coreutils. All mtime
# reads and date parsing go through these two helpers: GNU branch first,
# BSD fallback. Lines carrying a GNU-only construct are tagged
# `# portability-shim` — tests/test-portability.sh forbids them anywhere else.

# Print FILE's mtime as an epoch, or DEFAULT (0 if omitted) when unreadable.
# Always exits 0 — call sites treat "no mtime" as a value, not an error.
maude_mtime() {
  local f="$1" d="${2:-0}" m
  m="$(stat -c %Y "$f" 2>/dev/null)"                 # portability-shim (GNU)
  [ -n "$m" ] || m="$(stat -f %m "$f" 2>/dev/null)"  # portability-shim (BSD)
  # Numeric guard: GNU stat -f means "filesystem status" and can emit non-epoch
  # text to stdout even on failure — anything but pure digits becomes DEFAULT,
  # so callers' arithmetic never sees garbage.
  case "$m" in (''|*[!0-9]*) m="$d" ;; esac
  printf '%s' "$m"
}

# Print FILE's size in bytes, or empty when unreadable. Same GNU/BSD split as
# maude_mtime — `stat -c` is GNU, `stat -f` is BSD, and macOS has only the latter.
maude_file_size() {
  local f="$1" s
  s="$(stat -c %s "$f" 2>/dev/null)"                 # portability-shim (GNU)
  [ -n "$s" ] || s="$(stat -f %z "$f" 2>/dev/null)"  # portability-shim (BSD)
  # GNU `stat -f` means "filesystem status" and can print non-numeric text on the
  # BSD-shaped call, so anything but digits becomes empty rather than garbage.
  case "$s" in (''|*[!0-9]*) s="" ;; esac
  printf '%s' "$s"
}

# True iff python3 actually RUNS — probe by executing, never by presence.
# `command -v python3` passes on interpreters that then fail at the call site:
# Windows resolves python3 to the Microsoft Store alias stub (present on every
# box, executes nothing, exit 9009), and a macOS without Command Line Tools
# ships a shim that dies the same way. A probe that answers the same whether
# the interpreter works or not is not a check. Cached per-process so repeated
# gates in one hook pay the interpreter start once.
maude_python3_ok() {
  if [ -z "${_MAUDE_PY3_OK:-}" ]; then
    if python3 -I -c 'pass' >/dev/null 2>&1; then _MAUDE_PY3_OK=y; else _MAUDE_PY3_OK=n; fi
  fi
  [ "$_MAUDE_PY3_OK" = "y" ]
}

# Print FILE's sha256, or nothing (exit 1) when unreadable. sha256sum is GNU-only —
# macOS ships `shasum` and BSD `md5` — so this hashes with python3 stdlib, which the
# plugin floor already requires. Never prints a placeholder: a digest both sides could
# vacuously agree on is worse than no digest.
maude_file_digest() {
  python3 -I -c 'import hashlib, sys
try:
    print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
except OSError:
    sys.exit(1)' "$1" 2>/dev/null
}

# Print the epoch for a YYYY-MM-DD date at local midnight; empty output and
# rc 1 on garbage/empty input. Both branches parse the same T00:00:00 form so
# GNU and BSD agree on the answer.
maude_date_epoch() {
  local d="$1" e
  [ -n "$d" ] || return 1
  e="$(date -d "${d}T00:00:00" +%s 2>/dev/null)"                                # portability-shim (GNU)
  [ -n "$e" ] || e="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${d}T00:00:00" +%s 2>/dev/null)"  # portability-shim (BSD)
  [ -n "$e" ] || return 1
  printf '%s' "$e"
}

# Whole calendar days between two YYYY-MM-DD dates in the ambient zone.
#
# Both ends are resolved to LOCAL MIDNIGHT and the division rounds to nearest, which is
# what makes this exact across a daylight-saving transition. A raw seconds count against
# "now" is not: a spring-forward leaves a 23-hour day, so the true interval is 3600s short
# of N*86400, and floor division reports N-1 until enough of today has elapsed to absorb
# the deficit. Measured on this box: a file exactly 14 days old read as 13 days from local
# midnight until 01:05, in the two weeks after the 2026-03-08 transition — a staleness
# warning that stays silent for the hour it is most likely to be read.
#
# A FUTURE date reads negative, not zero: bash truncates toward zero, so the +43200 rounds
# a negative numerator the wrong way and only a date one day ahead lands on 0 (two days
# ahead is -1, a year ahead is -364, one short of the true count). Callers compare upward
# against a positive limit, so every one of those answers is inert; the rounding is exact
# in the past direction, which is the only one that decides anything.
maude_days_between() {  # $1 = older date, $2 = newer date
  local a b
  a="$(maude_date_epoch "$1")" || return 1
  b="$(maude_date_epoch "$2")" || return 1
  printf '%s' $(( (b - a + 43200) / 86400 ))
}

# Print EPOCH as UTC ISO (YYYY-MM-DDTHH:MM:SSZ); empty output + rc 1 on
# garbage. GNU spells epoch input `-d @E`; BSD spells it `-r E`.
maude_epoch_iso() {
  local e="$1" s
  case "$e" in (''|*[!0-9]*) return 1 ;; esac
  s="$(date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"                # portability-shim (GNU)
  [ -n "$s" ] || s="$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"  # portability-shim (BSD)
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}

# Run CMD... bounded to SECS wall-clock. timeout(1) where present; python3
# subprocess elsewhere (macOS ships no timeout). rc 124 on overrun (matching
# GNU timeout), the command's own rc otherwise. Caller's stdin/stdout pass
# straight through to the child on both paths.
maude_timeout() {
  local t="$1"; shift
  # MAUDE_TIMEOUT_FALLBACK=1 takes the bash path even where timeout(1) exists: the tests' stand-in
  # for timeout(1) is this function, and a PATH that holds a planted `timeout` shim calling the
  # stand-in would otherwise find the shim again, without end (2026-11-09).
  if [ -z "${MAUDE_TIMEOUT_FALLBACK:-}" ] && command -v timeout >/dev/null 2>&1; then  # portability-shim (GNU/util-linux)
    timeout "$t" "$@"                          # portability-shim
  else
    # GNU-parity contract: 124 on overrun, 125 on a bad duration, 127 when the command can't
    # start, and the WHOLE process group dies on overrun (a runner that shells out leaves no
    # orphan). Pure bash, no python3: the fallback ran in python3 until v0.36.0's public macOS
    # leg (PR #90) showed the timer cannot be the thing it times; a python3 slow to start, or
    # hung, held the judge's 2 s cut for as long as it hung. In a subshell, so job control
    # (set -m: the child leads its own process group) never reaches the caller.
    case "$t" in ''|.|*[!0-9.]*|*.*.*) return 125 ;; esac
    (
      exec 3>&2 2>/dev/null   # the command keeps the caller's stderr (fd 3); job notices go nowhere
      set -m
      "$@" <&0 2>&3 3>&- &
      pid=$!
      ( exec >/dev/null 2>&1 </dev/null; sleep "$t"; kill -KILL -- -"$pid" 2>/dev/null && exit 9; exit 0 ) &
      wd=$!
      wait "$pid" 2>/dev/null; rc=$?
      if kill -0 "$wd" 2>/dev/null; then
        kill -KILL -- -"$wd" 2>/dev/null; wait "$wd" 2>/dev/null
      else
        wait "$wd" 2>/dev/null; [ $? -eq 9 ] && rc=124
      fi
      exit "$rc"
    )
  fi
}

# Print the capture-anchor epoch (freshest capture mtime), or 0 if nothing
# was ever captured.
maude_capture_anchor_epoch() {
  local proj mem remember f m anchor=0
  proj="$(maude_project_dir)"
  mem="$(maude_mem_dir)"
  remember="$proj/.remember"
  for f in "$mem/now.md" "$remember/now.md" "$remember/remember.md"; do
    [ -s "$f" ] || continue
    m="$(maude_mtime "$f")"
    [ "$m" -gt "$anchor" ] && anchor="$m"
  done
  printf '%s' "$anchor"
}

# Print the count of prompt events newer than the capture anchor (0 without
# jq / without a trace). Only trace files whose filename-date could hold a
# post-anchor event are read (ISO timestamps sort lexically, so string compare
# is correct for both the filename filter and the per-event compare).
maude_uncaptured_prompt_count() {
  command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
  local tdir anchor since_iso since_date d f n
  local -a files=()
  tdir="$(maude_self_dir)/trace"
  [ -d "$tdir" ] || { printf '0'; return 0; }
  anchor="$(maude_capture_anchor_epoch)"
  if [ "$anchor" -gt 0 ]; then
    since_iso="$(maude_epoch_iso "$anchor")" || { printf '0'; return 0; }
  else
    since_iso=""   # nothing captured at all → count ALL prior prompts
  fi
  since_date="${since_iso%%T*}"
  for f in "$tdir"/today-*.jsonl; do
    [ -e "$f" ] || continue
    d="${f##*/today-}"; d="${d%.jsonl}"
    if [ -z "$since_date" ] || [ "$d" = "$since_date" ] || [ "$d" \> "$since_date" ]; then
      files+=("$f")
    fi
  done
  [ "${#files[@]}" -gt 0 ] || { printf '0'; return 0; }
  n="$(cat "${files[@]}" 2>/dev/null | jq -rs --arg since "$since_iso" '
    [ .[] | select(.kind=="prompt" and ((.ts // "") > $since)) ] | length')"
  printf '%s' "${n:-0}"
}

# The continuity guard — the closing loop the continuity chain was missing. The Stop hook
# writes NO handoff (it can't tell a real session-end from a mid-turn pause), so a clean
# quit without /maude:rest could leave the next session under-informed. (The SessionEnd
# auto-note now covers the common real-end case; this guard stays as the wake-side
# backstop — SessionEnd may not fire on a crash, and the note needs an empty slot.)
# This runs at
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
  local remember tdir n anchor
  local threshold=3
  remember="$(maude_project_dir)/.remember"
  tdir="$(maude_self_dir)/trace"
  # The remember plugin is the continuity substrate this guards; no .remember dir → N/A.
  [ -d "$remember" ] && [ -d "$tdir" ] || return 0

  # Anchor + count via the shared uncaptured-work helpers (one definition,
  # shared with the SessionEnd auto-note — see maude_uncaptured_prompt_count).
  anchor="$(maude_capture_anchor_epoch)"
  n="$(maude_uncaptured_prompt_count)"
  [ "${n:-0}" -ge "$threshold" ] || return 0

  if [ "$anchor" -gt 0 ]; then
    printf 'Heads-up: ~%s exchanges ran after the last save — the handoff may be stale. /maude:wake reconstructs from the trace.\n' "$n"
  else
    printf 'Heads-up: no continuity captured, but the trace shows ~%s prior exchanges — /maude:wake reconstructs them.\n' "$n"
  fi
  return 0
}

# Append a user-STATED fact to the cross-project profile (the testable core of
# /maude:teach). Distinct from the observed-only writers (save/rest/notice):
# those record what Maude inferred; this records what the user asserted,
# kept under a dedicated "## Told by the user" section so told stays separate from
# observed and the no-fabrication rule holds. Never touches the persona preamble
# or existing observed blocks. Returns non-zero (no write) on an empty fact.
# Usage: maude_identity_append "<fact>" ["<YYYY-MM-DD>"]
# Locked like the state file: the awk-rewrite-then-rename had the same lost-update race
# (the memory lens, 2026-09-06, N-4), at a lower frequency.
maude_identity_append() {
  maude_ensure_user_dir
  maude_locked "$(maude_user_dir)/.identity.lock" _maude_identity_append_unlocked "$@"
}
_maude_identity_append_unlocked() {
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

# Archive the live user-global letter to a dated copy BEFORE /maude:rest
# rewrites it. The live letter is ONE file shared by every lane, so without
# this step the second lane to rest in a day silently erases the first
# (2026-08-17: two lanes rested, the earlier letter survived only because
# that session still held its own text in context).
# Usage: maude_letter_archive "<slug of the OLD letter's theme>"
# Prints the archive path. rc 0 = archived (or already archived, byte-equal);
# rc 1 = empty slug; rc 2 = nothing to archive (letter missing/empty);
# rc 3 = the copy is NOT VERIFIED to have landed (absent, truncated, or
# differing) — the caller must NOT rewrite the letter.
# Byte-equality: cmp(1) when present, else python3 filecmp (python3 is the
# plugin's stated floor, so "compare tool missing" can never wedge the rest
# ritual into refusing a perfectly good archive).
maude_files_equal() {
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    python3 -I -c 'import sys, filecmp; sys.exit(0 if filecmp.cmp(sys.argv[1], sys.argv[2], shallow=False) else 1)' \
      "$1" "$2" 2>/dev/null
  fi
}
maude_letter_archive() {
  local slug="$1" letter d base a n
  # Nothing to archive beats a bad slug: a first-ever rest with a placeholder
  # slug must hear "no prior letter", not "archive failed".
  letter="$(maude_user_dir)/letter-from-maude.md"
  [ -s "$letter" ] || return 2
  # Newlines first (tr, not sed — sed is line-oriented and never sees them),
  # then case-fold and collapse everything non-alphanumeric to hyphens.
  slug="$(printf '%s' "$slug" | tr '\n\r' '  ' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] || return 1
  # The letter format mandates a dated header on line 1, so ONLY that line's
  # first date names the copy (a date in the body must not); a header-less
  # letter is stamped with the day it was archived. head both sides: a line
  # carrying two dates would otherwise put a newline inside the filename.
  d="$(head -n 1 "$letter" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1)"
  [ -n "$d" ] || d="$(date +%Y-%m-%d)"
  base="$(maude_user_dir)/letter-from-maude-$d-$slug"
  a="$base.md"; n=2
  # A same-named archive holding DIFFERENT bytes is someone else's letter:
  # step past it, never over it.
  while [ -e "$a" ] && ! maude_files_equal "$letter" "$a"; do a="$base-$n.md"; n=$((n+1)); done
  [ -e "$a" ] || cp "$letter" "$a" 2>/dev/null
  # Read the copy back — a cp that half-landed must not report success.
  maude_files_equal "$letter" "$a" || return 3
  printf '%s\n' "$a"
}

# Retention window (days) for the append-only artifacts in her closet: trace
# JSONL and pre-compact snapshots. Default 30 — well past the 7-day window that
# the remember plugin's recent.md reads, so a sweep never strands a recent read.
# Override via the MAUDE_RETENTION_DAYS env var.
maude_retention_sweep() {
  local self days anchor f m
  self="$(maude_self_dir)"
  days="${MAUDE_RETENTION_DAYS:-30}"
  # mtime-based, fail-silent. Only removes files strictly older than the window.
  # The trace is metadata-only by design, so age alone is the whole question.
  [ -d "$self/trace" ] && \
    find "$self/trace" -maxdepth 1 -type f -name 'today-*.jsonl' -mtime +"$days" -delete 2>/dev/null
  # The eye's per-session files (one set per session since 2026-09-25): a week untouched
  # means the session is gone. Named shapes only, never a bare glob of the store.
  [ -d "$self" ] && \
    find "$self" -maxdepth 1 -type f \( -name 'eye-state.*' -o -name '.eye-state.*.lock' \
      -o -name 'eye-whisper.*.txt' -o -name 'eye-whisper.*.born' \) -mtime +7 -delete 2>/dev/null
  # Snapshots are CONTENT — a pre-compact capture from a session that never
  # saved may be the only copy of that context. Value before the dustpan: age
  # qualifies a snapshot for the sweep, but it only goes if a later save covers
  # it (capture anchor strictly newer than the snapshot). Uncovered → kept,
  # however old — it waits for a save, not a calendar.
  if [ -d "$self/snapshots" ]; then
    anchor="$(maude_capture_anchor_epoch)"
    while IFS= read -r f; do
      m="$(maude_mtime "$f")"
      [ "$anchor" -gt "$m" ] && rm -f "$f" 2>/dev/null
    done < <(find "$self/snapshots" -maxdepth 1 -type f -name 'precompact-*.md' -mtime +"$days" 2>/dev/null)
  fi
  # UNDO store. Age-based like the trace: an undo blob is a safety net for the work in
  # front of you, not an archive. Blobs go first, then any ledger line pointing at a
  # blob that is no longer there is rewritten as a skip — so `list` keeps telling the
  # truth about what it can actually put back instead of offering a restore that
  # would fail at the last step.
  if [ -d "$self/undo/blobs" ]; then
    find "$self/undo/blobs" -maxdepth 1 -type f -mtime +"$days" -delete 2>/dev/null
    if [ -s "$self/undo/ledger.jsonl" ] && command -v jq >/dev/null 2>&1; then
      # Under a lock, wait 0: five lanes share this closet and every SessionStart runs the
      # sweep. Unlocked, two prunes wrote ONE temp name; a peer's `>` truncated the file a
      # live jq was still writing, the peer died at its hook budget, and the survivor's mv
      # installed 999,424 NUL bytes where the ledger's head had been (found 2026-09-27; jq
      # then failed on it in silence at every wake). Busy means another lane is pruning.
      MAUDE_LOCK_WAIT=0 maude_locked "$self/undo/.prune.lock" _maude_undo_prune "$self/undo"
      [ "$?" -eq "$MAUDE_LOCK_BUSY" ] && maude_log_trace "undo-prune" "skipped=busy"
    fi
  fi
}

# The ledger prune, run under the prune lock. Temp names carry the pid so no two lanes can
# ever write the same file. A ledger whose head is zero-filled (the race above, already
# landed) is healed first: the damaged bytes are kept beside it, the NULs and the torn line
# they end in are dropped, and the prune goes on over what is left.
_maude_undo_prune() {  # <undo dir>
  local u="$1" L="$1/ledger.jsonl" tmp="$1/.prune.$$" have="$1/.blobs.$$" snap="$1/.snap.$$" out="$1/.out.$$" hole torn n0 rc
  if [ "$(head -c1 "$L" | od -An -tx1 | tr -d ' \n')" = "00" ]; then
    # Each failure names itself in the trace; the caller's row is for the lock alone
    # (lens 1: a cp that died mid-copy was logged "busy" and its partial copy stayed).
    # The copy's name is taken only if nothing holds it, so a second heal in the same
    # second keeps the first one's bytes, and the cleanup below removes only what this
    # call created (lens round 2: a same-second name overwrote, and rm -f'd, evidence).
    hole="$(_maude_undo_free_name "$L.hole")"
    if ! cp -p "$L" "$hole" 2>/dev/null; then
      rm -f "$hole" 2>/dev/null; maude_log_trace "undo-prune" "heal=cp-failed"; return 1
    fi
    n0="$(wc -c < "$L" | tr -d ' ')"
    if ! { case "$n0" in ''|*[!0-9]*) false ;; esac && head -c "$n0" "$L" | tr -d '\000' | awk 'NR == 1 && !/^\{/ { next } { print }' > "$tmp" 2>/dev/null \
           && _maude_undo_install "$tmp" "$L" "$n0"; }; then
      rm -f "$tmp" 2>/dev/null; maude_log_trace "undo-prune" "heal=rewrite-failed"; return 1
    fi
    maude_log_trace "undo-prune" "healed=nul-head"
  fi
  # Bytes with no line in them (a healed-away ledger, a stray newline) are nothing to
  # prune, on every sweep, not only the one after a heal (lens 4, then lens round 2 B).
  grep -q . "$L" 2>/dev/null || return 0
  # ONE jq pass with the blob directory's listing read once, never one fork per
  # line: on the dev box an 8,158-line ledger took 33.5 s through a per-line jq,
  # and the wake hook, budgeted at 10 s by the harness, was killed before its brief
  # at every session start for weeks (found 2026-09-06 under the memory lens's
  # unexplained "the wake was billed once in 31 days"). A line whose blob is not in
  # the listing is rewritten as a skip; every other line passes through untouched;
  # a jq failure leaves the ledger as it was and says so in the trace.
  # jq reads a snapshot of the first n0 bytes; whatever a capture appended after that is
  # carried onto the result before it is installed (residual 2 of the 09-27 fix: an
  # append landing between the read and the mv was lost).
  ls -1A "$u/blobs" 2>/dev/null > "$have"
  n0="$(wc -c < "$L" | tr -d ' ')"
  case "$n0" in ''|*[!0-9]*) maude_log_trace "undo-prune" "size-unread"; rm -f "$have"; return 1 ;; esac
  head -c "$n0" "$L" > "$snap" 2>/dev/null
  # Lines are read RAW: a line that parses to an object is pruned as before; one that does
  # not (a short write on a full disk, a killed writer, a later append glued onto it) is
  # reported by its line NUMBER and copied out of the snapshot by sed, so the quarantine
  # file ledger.jsonl.torn-<utc> holds its exact bytes (jq would have replaced invalid UTF-8
  # with U+FFFD; lens on d73f0cf). One bad line used to stop every prune after it, forever.
  # The snapshot gets a final newline first: jq numbers an unterminated last line the same
  # as the line before it.
  [ -s "$snap" ] && [ "$(tail -c1 "$snap" | od -An -tx1 | tr -d ' \n')" != "0a" ] && printf '\n' >> "$snap"
  jq -cnR --rawfile have "$have" \
    '($have | split("\n") | map(select(length > 0)) | map({key: ., value: true}) | from_entries) as $h
     | inputs | select(length > 0) | (try fromjson catch null)
     | if type != "object" then input_line_number
       elif (.blob | type) == "string" and .blob != "" and ($h[.blob] | not)
       then del(.blob) | .skip = "pruned" else . end' \
    "$snap" > "$out" 2>/dev/null; rc=$?
  if [ "$rc" -ne 0 ]; then
    maude_log_trace "undo-prune" "jq=$rc"; rm -f "$tmp" "$out" "$have" "$snap" 2>/dev/null; return 0
  fi
  # Every count is checked before anything is installed: the kept bytes must be exactly the
  # output minus the torn numbers, or the rewrite is short (a failed write, a full disk) and
  # installing it would silently drop live entries under a trace that reads as success
  # (lens on d73f0cf, BLOCKING). The quarantine copy must hold exactly the torn lines.
  # Bytes, not lines: a write that loses its tail keeps a non-empty last line, so a line
  # count passed a corrupt ledger (lens r2 on dbe6db9). The kept bytes plus the torn-number
  # bytes must add up to the jq output exactly.
  local keep g nums="$u/.nums.$$" b_out b_keep b_nums
  torn="$(grep -c '^[0-9]' "$out" 2>/dev/null)"
  grep -v '^[0-9]' "$out" > "$tmp" 2>/dev/null; g=$?
  keep="$(grep -c . "$tmp" 2>/dev/null)"
  b_out="$(wc -c < "$out" | tr -d ' ')"; b_keep="$(wc -c < "$tmp" | tr -d ' ')"
  b_nums="$(grep '^[0-9]' "$out" 2>/dev/null | wc -c | tr -d ' ')"
  if [ "$g" -gt 1 ] || [ "${b_out:-x}" != "$(( ${b_keep:-0} + ${b_nums:-0} ))" ]; then
    maude_log_trace "undo-prune" "keep-failed"; rm -f "$tmp" "$out" "$have" "$snap" 2>/dev/null; return 1
  fi
  if [ "${torn:-0}" -gt 0 ]; then
    hole="$(_maude_undo_free_name "$L.torn")"
    # One awk pass: the torn numbers into a set, then every snapshot line whose number is in
    # it, bytes untouched (C locale; NUL and invalid UTF-8 verified). The numbers go in a
    # FILE, never argv (a sed script as one argument hit the 128 KiB cap near 21,000 torn
    # lines), and never one sed address each (addresses x lines: 54 s at 100,000).
    grep '^[0-9]' "$out" > "$nums" 2>/dev/null
    # Some awks hold a record as a C string and drop everything after a NUL (busybox,
    # shown; the BSD awk on macOS, documented), and the line count below cannot see a
    # shortened line. So when the snapshot holds a NUL, the copy runs only after the same
    # program has carried a NUL through on a probe; otherwise it refuses, named, and the
    # ledger stays as it was (lens round 4 on 4dbf9fd).
    if [ -n "$(tr -cd '\000' < "$snap" | head -c1 | od -An -tx1)" ]; then
      printf '1\n' > "$nums.p"; printf 'a\000b\n' > "$nums.q"
      if [ "$(LC_ALL=C awk 'NR == FNR { t[$1]; next } (FNR in t)' "$nums.p" "$nums.q" 2>/dev/null | wc -c | tr -d ' ')" != 4 ]; then
        rm -f "$nums" "$nums.p" "$nums.q" "$hole" "$tmp" "$out" "$have" "$snap" 2>/dev/null
        maude_log_trace "undo-prune" "torn=$torn nul-unsafe-awk"; return 1
      fi
      rm -f "$nums.p" "$nums.q" 2>/dev/null
    fi
    LC_ALL=C awk 'NR == FNR { t[$1]; next } (FNR in t)' "$nums" "$snap" > "$hole" 2>/dev/null
    if [ "$(wc -l < "$hole" 2>/dev/null | tr -d ' ')" != "$torn" ]; then
      rm -f "$hole" "$nums" "$tmp" "$out" "$have" "$snap" 2>/dev/null
      maude_log_trace "undo-prune" "torn=$torn copy-failed"; return 1
    fi
    maude_log_trace "undo-prune" "torn=$torn"
  fi
  # All torn is still a rewrite (to empty); all whole and empty output is nothing at all.
  if [ "${keep:-0}" -gt 0 ] || [ "${torn:-0}" -gt 0 ]; then _maude_undo_install "$tmp" "$L" "$n0"; fi
  rm -f "$nums" 2>/dev/null
  rm -f "$tmp" "$out" "$have" "$snap" 2>/dev/null
  return 0
}

# A name for an evidence copy that nothing holds: <base>-<utc>, then -2, -3, … A dangling
# symlink counts as taken (lens round 3), so a copy is never written through one or over
# another heal's bytes inside the same second (lens round 2).
_maude_undo_free_name() {  # <base>
  local base n=2 name
  base="$1-$(date -u +%Y%m%dT%H%M%SZ)"; name="$base"
  while [ -e "$name" ] || [ -L "$name" ]; do name="$base-$n"; n=$((n+1)); done
  printf '%s' "$name"
}

# Install a rewritten ledger: first carry every byte appended past the n0 the rewrite read,
# then rename. Captures append under the same lock, so the carry only has work when one
# fell back to a bare append after its short wait; the window left is the carry itself.
_maude_undo_install() {  # <tmp> <ledger> <bytes the rewrite read>
  tail -c +"$(( $3 + 1 ))" "$2" >> "$1" 2>/dev/null && mv "$1" "$2" 2>/dev/null
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
# CALLED BY A HOOK: maude-probe-tier1.sh runs this at every SessionStart against
# hardcoded 127.0.0.1 ports (loopback only — no DNS, no payload, nothing leaves
# the box). PRIVACY.md discloses this; keep the two in sync. (An earlier version
# of this comment claimed "not by hooks" — that lie let the privacy policy drift.)
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

# The auto-memory index budget, in UTF-16 units (the loader's unit). Claude Code loads
# <slug>/memory/MEMORY.md whole at every session start and cuts it past 25,000 units, so the
# default sits just under that cut; a person who wants a lean index sets
# "memory_index_budget" in gate-config. Anything but a whole number >= 1,000 is ignored.
maude_memory_budget() {
  local cfg v
  cfg="$(maude_gate_config)"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r 'if (.memory_index_budget | type) == "number" and .memory_index_budget == (.memory_index_budget | floor) and .memory_index_budget >= 1000 then (.memory_index_budget | floor | tostring) else empty end' "$cfg" 2>/dev/null)"
  fi
  # jq spells 1e4 as 10000 but 1e16 as 1e+16, and a long literal as up to 20 digits
  # (12345678901234567890 prints as 12345678901234567000, past a shell integer's 19).
  # Digits only, at most 18 of them, or the default: never a number a later [ -gt ]
  # cannot read.
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  [ "${#v}" -le 18 ] || v=""
  printf '%s' "${v:-23500}"
}

# The auto-memory index itself: <anything>/.claude/projects/<slug>/memory/MEMORY.md, where a
# slug holds no slash. One definition for every rail that reads it.
maude_is_memory_index() {
  [[ "$1" =~ /\.claude/projects/[^/]+/memory/MEMORY\.md$ ]]
}

# A file's length in UTF-16 units, the way Claude Code's loader counts (\r\n is two).
maude_utf16_units() {
  python3 -I -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", errors="replace", newline="").read().encode("utf-16-le")) // 2)' "$1" 2>/dev/null
}

# Escape ERE metacharacters in a literal path so it can sit inside a gate pattern.
maude_ere_escape() { printf '%s' "$1" | sed -E 's/[][\*^$()+?{|]/\\&/g'; }

# The three rails that read commits (verify-watch, redteam-watch, rules-watch) must agree on
# what a commit is and what counts as a doc. One definition; copies drift.
# The separator is deliberately the WIDER pattern — `(` and a backtick are real command
# positions too (`(git commit)`, `` `git commit` ``, `$(pytest -q)` all run the thing), so a
# narrower copy misses real commits/runs. That widening is a designed choice, not a
# coincidence — see tests/test-verify-watch.sh's paren/backtick rows.
maude_sep_re()    { printf '%s' '(^|[;&|(`])[[:space:]]*'; }
maude_commit_re() { printf '%s' "$(maude_sep_re)git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)"; }
maude_doc_re()    { printf '%s' '\.(md|markdown|txt|rst|adoc|json|ya?ml|toml|cfg|conf|ini|lock|csv|tsv|svg|png|jpe?g|gif|pdf)$|(^|/)(LICENSE|COPYING|NOTICE|CHANGELOG[^/]*|AUTHORS|\.gitignore|\.gitattributes|\.editorconfig)$'; }

# Sole-copy ERE target fragments — generic defaults (NO deployment literals) +
# any paths from config. One per line. Belt reads these into its pattern table.
maude_sole_copy_targets() {
  local cfg proj
  # The gate matches against a command view with repeated slashes collapsed, so a root that
  # arrives with "//" in it (a project dir or config path built from a TMPDIR that ends in a
  # slash, which macOS exports) must be collapsed the same way or it protects nothing.
  proj="$(maude_project_dir | tr -s '/')"
  [ -n "$proj" ] && printf '%s(/[^/[:space:]]+)?\n' "$(maude_ere_escape "$proj")"
  printf '%s/\\.claude(/[^[:space:]]*)?\n' "$(maude_ere_escape "$HOME")"
  printf '%s\n' '(\.git|[^[:space:]]*/\.git)(/[^[:space:]]*)?'
  cfg="$(maude_gate_config)"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    jq -r '.sole_copy_paths[]?' "$cfg" 2>/dev/null | tr -s '/' | while IFS= read -r p; do
      [ -n "$p" ] && printf '%s(/[^[:space:]]*)?\n' "$(maude_ere_escape "$p")"
    done
  fi
}

# Public-facing publish commands (RED — pre-public-push checklist).
maude_public_publish_re() {
  printf '%s' '(gh[[:space:]]+release[[:space:]]+(create|upload)|twine[[:space:]]+upload|uv[[:space:]]+publish|(hf|huggingface-cli)[[:space:]]+upload)'
}

# The shell parser's verdict on a command (maude_shell/judge.py): one line, "block KEY WORDS",
# "pass" or "unreadable"; nothing at all when python3 is missing or the read outruns its
# 2 s, and the gate then keeps its regex verdict. `python3 -I` with the plugin root put first
# on the path by hand: a hook's working directory is the user's project, and a plain
# `python3 -m` would let a module sitting there (re.py) answer for the gate. -I drops that
# entry, the user site and every PYTHON* variable, back to the 3.8 floor, with no cd; -S
# skips site and a distro's sitecustomize. This runs on every Bash call, so it costs one
# interpreter, not two: a python3 that cannot run prints nothing, which is the same answer.
maude_shell_judge() {  # <command> [<seconds>] → the judge's lines: one per key hit, or "pass" / "unreadable"
  # No presence check: `command -v` finds a python3 that cannot run (test-python-probe.sh),
  # and the call below is the probe. A missing or broken one prints nothing, and nothing
  # leaves the tables' verdict standing.
  local root cfg p
  local -a args=(--proj "$(maude_project_dir | tr -s '/')")
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || return 0
  [ -f "$root/maude_shell/judge.py" ] || return 0
  cfg="$(maude_gate_config)"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r p; do [ -n "$p" ] && args+=(--sole "$p"); done < <(jq -r '.sole_copy_paths[]?' "$cfg" 2>/dev/null)
  fi
  # Only a clean run (0) is a read. A cut (124) prints nothing, and nothing read as "no
  # hits, read whole" let a yellow token open the command (lens 2 on 98a4413); any other
  # failure is the same (lens 3 on 652bbd9, minor 2). Each says unreadable. A python3
  # that cannot start (127) says nothing, and the tables' verdict stands.
  local out rc body
  out="$(printf '%s' "$1" | MAUDE_JUDGE_MARK=1 maude_timeout "${2:-2}" python3 -I -S -c 'import sys
sys.path.insert(0, sys.argv[1])
from maude_shell.judge import main
sys.exit(main(sys.argv[2:]))' "$root" "${args[@]}" 2>/dev/null; printf 'rc=%s' "${PIPESTATUS[1]}")"
  rc="${out##*rc=}"; body="${out%rc=*}"
  # A cut says so by name, and the gate reads a cut on a command with no key as red
  # (parser-budget): the clock's cut (124), and a judge that STARTED (its first line is
  # "read", asked for by MAUDE_JUDGE_MARK) and died, by a crash on crafted text or a kill
  # under load; `env -C <dir> git push` passed rc 0 that way once in a loaded suite
  # (2026-11-04). A python3 that never started leaves no line: 127 says nothing, and the
  # tables' verdict stands; any other start failure says unreadable, as before.
  case "$rc" in
    0) ;;
    124) printf 'cut\nunreadable\n' ;;
    *) case "$body" in read*) printf 'cut\nunreadable\n' ;; *) [ "$rc" = 127 ] || printf 'opaque\n' ;; esac ;;
  esac
  [ "$rc" = 0 ] || maude_log_trace "gate" "parser-rc=$rc"
  printf '%s' "${body#read
}" | head -n 64
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

# Servers whose destructive ops are RECOVERABLE, declared in config as
# `mcp_yellow_tool_prefix` (a string or an array of mcp__name__ prefixes). A destructive
# verb on one of them gates YELLOW (`mcp-destructive`, self-clearable) instead of RED.
# The 07-30 law stands for everything else: an UNLISTED server's destructive verb is RED,
# because a second live hypervisor must not pass unseen (2026-10-08: a mail server's
# delete_draft, a draft recoverable from the mailbox, was refused as a hypervisor op with
# "node=? vmid=?"; the person declares which servers are recoverable, the gate does not
# guess). Unreadable config or no jq → nothing is listed → RED.
# ── The push label: which class of remote a `git push` aims at (2026-11-04) ──────────
# "Public, irreversible." on every push trained clearing without reading: four pushes to the
# internal forge in one night, each cleared on a label that was wrong. The block is the same
# block; the LABEL names the class of the remote's push URL. It fails toward the scary word:
# "internal" only on a positive read, anything else is public.
#
# Hosts the person declared internal: `internal_push_hosts` in gate-config (a string or an
# array of host names, matched whole, case-folded). Unreadable config or no jq → none.
maude_internal_push_hosts() {
  local cfg; cfg="$(maude_gate_config)"
  { [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; } || { printf ''; return; }
  jq -r '(.internal_push_hosts // empty) | if type=="array" then .[] else . end' "$cfg" 2>/dev/null
}
# maude_push_url_host <url> → the host of a git remote URL, never its userinfo (an https URL
# can carry a token before the @, and the host is all the label ever prints). Nothing for a
# URL it cannot read, which the caller reads as "unknown", never as internal.
maude_push_url_host() {
  local u="$1" h a
  # A URL that can be read two ways is read neither way: `https://github.com?@x.lan/r`
  # ends its authority at the `?` for git and curl, and a host read past the `@` would
  # say x.lan (the commit review on c898dca). A `?`, `#`, `%`, a backslash or a second `@`
  # has no place in a remote the label will vouch for.
  case "$u" in *'?'*|*'#'*|*'%'*|*'\'*) printf ''; return ;; esac
  a="${u//[!@]/}"; [ "${#a}" -le 1 ] || { printf ''; return; }
  case "$u" in
    *://*) h="${u#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}" ;;  # scheme://[user[:pw]@]host[:port]/
    *@*:*) h="${u%%:*}"; h="${h##*@}" ;;                               # scp-like user@host:path
    *)     h="" ;;
  esac
  case "$h" in ''|*[!A-Za-z0-9.-]*) printf ''; return ;; esac
  printf '%s' "$h"
}
# maude_push_class <url> → internal | public | unknown. Public: a known public forge, by host.
# Internal: a local path or file://, localhost, a loopback or RFC1918 address, a host under a
# private suffix (.lan .local .internal .home.arpa .localdomain), or a host the person listed.
# Everything else is unknown, and the gate reads unknown as public.
maude_push_class() {
  local u="$1" h lh e
  case "$u" in file://*|/*|./*|../*) printf 'internal'; return ;; esac
  h="$(maude_push_url_host "$u")"
  [ -n "$h" ] || { printf 'unknown'; return; }
  lh="$(printf '%s' "$h" | tr 'A-Z' 'a-z')"
  case "$lh" in
    github.com|*.github.com|gitlab.com|*.gitlab.com|bitbucket.org|*.bitbucket.org|codeberg.org|*.codeberg.org|sr.ht|*.sr.ht|huggingface.co|*.huggingface.co)
      printf 'public'; return ;;
    localhost|*.localhost|*.lan|*.local|*.internal|*.home.arpa|*.localdomain)
      printf 'internal'; return ;;
  esac
  if [[ "$lh" =~ ^(127\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)$ ]]; then
    printf 'internal'; return
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$lh" = "$(printf '%s' "$e" | tr 'A-Z' 'a-z')" ] && { printf 'internal'; return; }
  done < <(maude_internal_push_hosts)
  printf 'unknown'
}

maude_mcp_yellow_tool_prefixes() {
  local cfg; cfg="$(maude_gate_config)"
  { [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; } || { printf ''; return; }
  jq -r '(.mcp_yellow_tool_prefix // empty) | if type=="array" then .[] else . end' "$cfg" 2>/dev/null
}
# 0 (true) if <server> (the tool's `mcp__name__` segment) is a listed recoverable server.
# Exact equality against a prefix of the shape `mcp__<name>__`, never a glob: a listed
# `mcp__mail__` is not `mcp__mailsrv__`, and a bare or malformed entry (`mcp__`, `mcp__x`)
# lists nothing (the security lens on this change: the list downgrades RED to YELLOW, so
# it must not be widenable by a short entry). This file is the person's gate-config, which
# the agent can write like the sandbox lists beside it; the harness deny-rules are the lock.
maude_mcp_yellow_server() {  # <server>
  local p
  for p in $(maude_mcp_yellow_tool_prefixes); do
    # One pattern test, no fork per entry (the lens: 2.4 ms an entry on a 10,000-entry list).
    case "$p" in mcp__*__) ;; *) continue ;; esac
    case "${p#mcp__}" in ''|__|*[!A-Za-z0-9_-]*) continue ;; esac
    [ "$1" = "$p" ] && return 0
  done
  return 1
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
# Order: newlines → ';' → strip single-quoted spans → strip double-quoted
# spans. Single-quoted first because shell single-quotes don't interpret
# backslashes — matching them is unambiguous and removes their content
# (including any stray double-quotes inside) before the double-quote pass.
# Newlines map to ';' (a command separator), NOT a space: a command on its own
# line IS a separate command, so it must read as a boundary the CMD_START anchor
# recognises (^ ; & | ( `). Mapping to a space let `foo\ngit push` flatten to
# `foo git push` — mid-line, unanchored — bypassing every command-position gate
# (git push / force-push / reset --hard / rm -rf …). (2026-06-30)
#
# A double-quoted span is NOT all text: bash runs $(...) and `...` inside it, so those are
# kept, each between ';' (a command boundary), and read through this same scan; the rest
# of the span is erased. Two sed passes erased every "..." whole, and
# `echo "$(git push --force)"` passed (lens 2026-10-07). One left-to-right scan, the way
# bash reads quotes, so an apostrophe inside "it's" no longer opens a single-quoted span.
# Unterminated quotes and unbalanced $( are kept raw from their opener: reading more is
# the safe direction. Linear by construction, measured on a 418 KB command: the string is
# split into a character array once (substr() is O(n) per call in one-true-awk, the awk
# macOS ships, so a char-at-a-time substr scan ran past 60 s there), the recursion walks
# index ranges of that array, and output goes through a small flushed buffer.
# MAUDE_SQ_MARK=1: a quoted span is dropped as always, and one \001 byte marks where it
# stood, so a caller can see that a quote stood INSIDE an unquoted word, or in command
# position, without reading its content (ported from fix/gate-false-pass, 2026-11-03: the
# red-clear rule reads it). A substitution inside double quotes is still walked, marked or
# not: the review on b18802e found echo "$(rm FILE)" read as a read when the marked span
# was opaque, so the mark changes nothing about what is read, only adds the byte.
maude_strip_quotes() {
  printf '%s' "$1" | tr '\n' ';' | LC_ALL=C awk -v mark="${MAUDE_SQ_MARK:-}" '
    function emit(c) { buf = buf c; if (++bl >= 512) { printf "%s", buf; buf = ""; bl = 0 } }
    function raw(lo, hi,   k) { for (k = lo; k <= hi; k++) emit(a[k]) }
    # closer(p, hi, ch, esc): index of the next ch in p..hi, or 0. A backslash escapes
    # when esc is set: always outside single quotes, and inside an ANSI-C dollar-quote,
    # where backslash-quote does not end the span (a plain closer let one hide a later
    # "$(...)"). No apostrophe may appear in this program: it sits in shell single quotes.
    function closer(p, hi, ch, esc) {
      for (; p <= hi; p++) {
        if (esc && a[p] == "\\") { p++; continue }
        if (a[p] == ch) return p
      }
      return 0
    }
    function sq_end(p, hi) { return closer(p + 1, hi, "\047", ansi_c(p)) }
    # ansi_c(p): the quote at p opens an ANSI-C dollar-quote only when the dollar before
    # it is a free one: after the run of dollars (a pair is the PID) less one escaped by
    # an odd run of backslashes, an odd count is left (lens 2: a dollar-dollar or a
    # backslash-dollar before a plain quote let its backslash-quote run on and swallow
    # the command after it).
    function ansi_c(p,   q, k, b) {
      for (q = p - 1; q >= 1 && a[q] == "$"; q--) k++
      for (; q >= 1 && a[q] == "\\"; q--) b++
      if (b % 2) k--
      return k % 2
    }
    # A word boundary before p: where bash can start a word that is a comment or a keyword.
    function at_word(p, lo) { return p == lo || index(" \t;&|(", a[p - 1]) > 0 }
    # dq_end(p, hi): index of the " closing the one at p, skipping what bash skips inside
    # it; 0 when it never closes, -1 when a substitution in it is ambiguous.
    function dq_end(p, hi,   j) {
      for (p++; p <= hi; p++) {
        if (a[p] == "\\") { p++; continue }
        if (a[p] == "\"") return p
        if (a[p] == "$" && p < hi && a[p + 1] == "(") {
          j = close_paren(p + 1, hi); if (j <= 0) return j; p = j; continue
        }
        if (a[p] == "`") { j = closer(p + 1, hi, "`", 1); if (!j) return 0; p = j }
      }
      return 0
    }
    # close_paren(p, hi): index of the ")" matching the "(" at p, found as bash finds it:
    # quoted spans and backticks are skipped. 0 when it never closes. -1 (AMBIGUOUS) on a
    # # comment or a case: newlines are ";" here, so the end of a comment is lost, and a case
    # pattern ")" closes nothing; the caller then reads the rest raw (lens 2026-10-08:
    # each closed the $( early and the push after it passed).
    function close_paren(p, hi,   d, j, lo, c) {
      for (lo = p + 1; p <= hi; p++) {
        c = a[p]
        if (c == "\\") { p++; continue }
        if (c == "\047") { j = sq_end(p, hi); if (!j) return 0; p = j; continue }
        if (c == "\"") { j = dq_end(p, hi); if (j <= 0) return j; p = j; continue }
        if (c == "`") { j = closer(p + 1, hi, "`", 1); if (!j) return 0; p = j; continue }
        if (c == "#" && at_word(p, lo)) return -1
        if (c == "c" && at_word(p, lo) && a[p+1] a[p+2] a[p+3] == "ase" && index(" \t", a[p + 4])) return -1
        if (c == "(") d++
        else if (c == ")" && --d == 0) return p
      }
      return 0
    }
    # strip(lo, hi, depth): a[lo..hi] with quoted spans erased; a $(...) or `...` inside
    # double quotes is emitted between ";" and read through strip again.
    function strip(lo, hi, depth,   i, c, j, q) {
      if (depth > 16) { raw(lo, hi); return }
      for (i = lo; i <= hi; ) {
        c = a[i]
        if (c == "\\") { raw(i, i + 1 <= hi ? i + 1 : hi); i += 2; continue }
        if (c == "\047") {
          j = sq_end(i, hi)
          if (j == 0) { raw(i, hi); return }    # unterminated: the rest stays raw
          if (mark) emit("\001")
          i = j + 1; continue
        }
        if (c != "\"") { emit(c); i++; continue }
        for (q = i++; i <= hi; i++) {
          c = a[i]
          if (c == "\\") { i++; continue }
          if (c == "\"") break
          if (c == "$" && i < hi && a[i + 1] == "(") {
            j = close_paren(i + 1, hi)
            if (j < 0) { raw(i, hi); return }   # ambiguous: the rest is read raw
            if (j == 0) j = hi + 1
            emit(";"); strip(i + 2, j - 1, depth + 1); emit(";"); i = j; continue
          }
          if (c == "`") {
            j = closer(i + 1, hi, "`", 1); if (j == 0) j = hi + 1
            emit(";"); strip(i + 1, j - 1, depth + 1); emit(";"); i = j; continue
          }
        }
        if (i > hi) { raw(q, hi); return }      # unterminated "
        if (mark) emit("\001")
        i++
      }
    }
    { n = split($0, a, ""); strip(1, n, 0); if (bl) printf "%s", buf }'
}

# Remove quote CHARACTERS but KEEP their content (newlines → ';', a command
# separator — see maude_strip_quotes: mapping newline to a space let a path gate
# be bypassed by putting `rm -rf /` on its own line). For matching PATH/argument
# patterns where a quoted path (rm -rf "/srv/data") must still match — unlike
# maude_strip_quotes which ERASES quoted content (right for command-name patterns
# like git push, wrong for path args). Fail-closed: keeping content can only ever
# match MORE, never introduce a new bypass.
maude_unquote() {
  printf '%s' "$1" | tr '\n' ';' | tr -d "\"'"
}

# The gate's content-kept view: maude_unquote, then $HOME and a tilde expanded to the home
# directory so a quoted path still resolves. A tilde is expanded only where bash expands
# one, at the start of a word (after a blank, an operator, `=` or `:`) and followed by `/`
# or the word's end: every `~` used to be replaced, so a line of 4,000 tildes grew by HOME's
# length before every grep, outside the clock, and 240 KB of them killed the hook (lens 7
# on fc838c1, B1). Run twice, because one match's trailing boundary is the next one's
# leading boundary (`~ ~`). HOME is escaped for the replacement (`\`, `&`, the delimiter).
maude_home_view() {  # <command>
  local h b='(^|[[:space:]=:;&|(<>])' e='(/|$|[[:space:];&|)<>])'
  # escaped by sed, not by ${h//…}: bash 5.2 gives `&` a meaning in that replacement
  h="$(printf '%s' "$HOME" | sed 's/[\\&#]/\\&/g')"
  maude_unquote "$1" | sed -E "s#$b~$e#\\1$h\\2#g; s#$b~$e#\\1$h\\2#g; s#\\\$HOME#$h#g"
}

# Canonicalise the PATH-matching view of a command string so obfuscated rm
# targets match the canonical gate patterns: collapse repeated slashes (// → /)
# and (Task 3) lexically resolve /<seg>/../ → /. String-level only — never
# touches the filesystem. Fail-direction: canonicalising only makes a path MORE
# likely to match a protected pattern (closes under-blocks); it never invents a
# reachable path. Leading-`..`-beyond-root residue (/../b) is NOT resolved
# (documented limitation #2 residual).
#
# CONTRACT: This function operates on the WHOLE command string (not just path
# args). It is safe to do so ONLY because UNQUOTED_PATH feeds SOLELY the
# rm-command-position-guarded PATH loop (maude_rm_in_command_position must fire
# first). A `://` or stray `..` in a non-path token (URL, here-doc label, etc.)
# could in theory rewrite to something matching a red pattern — the
# rm-command-position guard is the structural firewall that prevents that from
# causing a false-block.
maude_canon_path_view() {
  local s="$1" i=0 prev
  s="$(printf '%s' "$s" | sed -E 's#/{2,}#/#g')"
  # Resolve /<seg>/../ → / repeatedly until stable (cap 16 — bounds work).
  # <seg> = a non-slash, non-space token that is NOT '..' itself, so a
  # leading /../ beyond root is left as residue (documented #2 residual) and
  # never over-pops into a false /-match.
  while [ "$i" -lt 16 ]; do
    prev="$s"
    # interior:  /seg/../  (seg is not '.' or '..')
    s="$(printf '%s' "$s" | sed -E 's#/([^/.[:space:]][^/[:space:]]*|\.[^/.[:space:]][^/[:space:]]*)/\.\./#/#g')"
    # trailing:  /seg/..   at end-of-token (space, end, or shell separator)
    s="$(printf '%s' "$s" | sed -E 's#/([^/.[:space:]][^/[:space:]]*|\.[^/.[:space:]][^/[:space:]]*)/\.\.([[:space:];&|)]|$)#/\2#g')"
    [ "$s" = "$prev" ] && break
    i=$((i + 1))
  done
  printf '%s' "$s"
}

# Remove HEREDOC bodies from a (possibly multi-line) command. A heredoc body is
# DATA fed to a command (git commit -F -, cat > file), not shell structure — so
# for the rm-command-position guard it must NOT read as executable shell. Without
# this, a shell separator inside heredoc prose ( ; ( | ` ) survived into the
# skeleton and made a commit whose body documents `rm -rf /` false-block.
#
# Used by the rm-guard, the target-verb guard AND (v0.27.0) the shared
# command-name strip (maude_match_gate_pattern) — the git-push gate fired on a
# memory-file heredoc whose BODY contained the words, measured live 2026-08-08.
# The DROP-TABLE / red-self-clear / redclear-write backstops are unaffected:
# they read the content-KEPT $UNQUOTED view directly, never this strip, so
# psql <<EOF DROP TABLE … EOF is still seen (v0.12.1 moved that check there).
#
# Fail-direction is UNDER-block (dropping body lines makes the guards see FEWER
# command-position verbs), with the honest costs — verified, not assumed:
#   - A gated command inside a heredoc fed to a SHELL (bash <<EOF …) is
#     uncaught: the already-documented shell-wrapping limitation
#     (maude-gate.sh #3), which as of v0.27.0 uniformly covers the command-name
#     patterns (git push et al) too.
#   - The old #7 phantom-opener classes are CLOSED (v0.27.0): $((…)) spans
#     and <<< herestrings are blinded before detection, and QUOTED SPANS are
#     blanked first too — after explicitly protecting `<<'EOF'` / `<<"EOF"`
#     delimiter-quoting, which is what made the naive quote-strip unsafe
#     before. `echo "note << EOF"` no longer opens a phantom body — which
#     an adversarial pass measured silently swallowing a REAL force-push on
#     the next line once CMD patterns used this strip. Residual, stated:
#     an UNBALANCED quote (`echo "oops << EOF` with no closer) still leaves
#     the token visible and opens a phantom; pinned in tests.
#   - Two heredocs on ONE line (cat <<A <<B) are handled via a delimiter
#     QUEUE — the old single-slot tracker treated body B as live commands.
# Operates on the raw string BEFORE newline-flattening (heredoc bodies are
# delimited by newlines).
# The characters an unquoted heredoc delimiter may carry. Bash takes any word that is not a
# metacharacter; `[A-Za-z_][A-Za-z0-9_]*` was too narrow — `<<END-OF-FILE` was keyed on
# `END`, the closing line never matched, and every line after it was stripped as body (lens on
# merged main, 2026-10-02: a real `eval '… --force'` on the next line passed).
MAUDE_HEREDOC_DELIM='[A-Za-z0-9_.:/+@%,=!~*#?-]+'
# The blanker keeps a quoted or escaped delimiter standing (`<<'EOF'` reads `<<` + this byte +
# `EOF`) so the quoted-span rule after it cannot erase the opener: `cat <<'EOF' | bash` must
# still read as a heredoc fed to a shell.
MAUDE_HEREDOC_QMARK=$'\001'
# … and a `<<` word it cannot read with certainty becomes this byte, `<<` included, so the
# shell-fed scan counts no opener there. (The stripper does not read the blanker any more: it
# fails closed on such a line through its own allowlist, maude_heredoc_line_ok, which also
# tells a quoted delimiter from an unquoted one for the close.)
MAUDE_HEREDOC_UNSURE=$'\002'

# One line of a command, with everything that is NOT shell structure blanked, so that a
# `<<` left standing is a heredoc opener and a word left standing is a word in command
# position. Its one reader is maude_heredoc_shell_fed (maude-gate.sh). It began as the shared
# reader of the stripper and that scan (the 2026-10-02 lens found their two copies drifting:
# an escaped quote inside double quotes, `$'…'`, a nested paren in `$(( ))`); since the
# allowlist (2026-10-04) the stripper reads lines with maude_heredoc_line_ok instead. In order:
#   `<<<` herestrings are not openers;
#   a delimiter the gate can read with certainty is a plain word, optionally quoted or
#     escaped WHOLE (`<<EOF`, `<<'EOF'`, `<<"EOF"`, `<<\EOF`); any other `<<` word — a quote
#     or a backslash inside it (`<<\#\#`, `<<E'O'F`, `<<"E\OF"`, `<<\-\-`) — is NOT an opener:
#     no body is stripped and the lines after it are read as commands, fail-closed; so is a
#     word with any character outside the class before its end (`<<EOF{`, `<<EOF[a]`,
#     `<<EOF$X`: bash's delimiter is the whole word, and read as `EOF` the body closed past
#     bash's close and hid the lines between — lens round 7, merged too, oracle RAN). The
#     word ends where BASH ends it: a space, a tab, or `; | & < > )` — never `[[:space:]]`,
#     which also ends it at `\r` `\v` `\f` and, in a UTF-8 locale, at Unicode spaces bash
#     reads as word characters; and not at `(`, which extglob reads into the word (`<<@(x)`);
#     each of those is a stray character, so the word opens no body (lens round 8). Lens
#     rounds 3, 4 and 5 each found a new way to read such a word differently from bash, and
#     every misread opened a body that never closed and swallowed a real force-push;
#   an escaped metacharacter is INERT (`\<\<`, `<\<`, `\#`, `\$`, `\"` become `_`): the
#     first cut unescaped it to the character, which MANUFACTURED a `<<` from `\<\<` and a
#     comment from `\#` (lens round 2); an escaped letter is the letter (`b\ash` is bash);
#   arithmetic is blanked to two levels of inner parens — `$((…))`, the `((…))` command,
#     `$[…]` — and an array subscript `a[…]` is its name: bash reads `<<` there as a shift,
#     and a delimiter class that admits digits would otherwise open a body on `<< 2`;
#   an array literal `x=(…)` (also `declare -a x=(…)`, `x+=(…)`) is `x=()`: bash reads its
#     words, not redirections, so `x=(1<<2)` opens nothing (lens round 3, oracle RAN);
#   `${NAME}` becomes `$NAME` so `${0}` / `${SHELL}` stay readable as shell words, then any
#     other `${…}` expansion becomes `$X` — still a variable in command position, so
#     `${SH:-bash} <<EOF` is read as a shell held in a variable, and `${x:-<<EOF}` is not
#     an opener;
#   real quoted delimiters are protected (`<<'EOF'` → `<<` MAUDE_HEREDOC_QMARK `EOF`) before
#     the span blanking;
#   quoted spans go in ONE left-to-right pass — `$'…'`, `'…'`, `"…"` — a span that is a single
#     word is that word (`exec -i c 'bash'` runs bash), any other span becomes ONE SPACE: a
#     space, not nothing, so `<''<` cannot close up into `<<`; ONE pass, because a separate
#     single-word rule run first paired the closing quote of `'s <<EOF '` with the opening
#     quote of `'x'` in `echo it's <<EOF 'x'` and left the `<<` standing (lens round 2), the
#     same way two span passes once paired the apostrophe in "it's" with a later `'`;
#   a `#` comment is not shell, after whitespace OR a separator (`echo |#…`).
# Residual, named: `$((` nested three deep, an UNBALANCED quote, and an escaped `$` before
# `{` (`\${x:-<<EOF}` reads a delimiter `EOF` where bash reads `EOF}`) still leave or move
# the token (pinned).
maude_blank_opener_line() {
  local scan="${1//<<</ }" dc="${MAUDE_HEREDOC_DELIM#[}" bl=$' \t'
  dc="${dc%-]+}"
  printf '%s' "$scan" | sed -E \
    -e "s/<<(-?)[$bl]*'($MAUDE_HEREDOC_DELIM)'/<<\1$MAUDE_HEREDOC_QMARK\2/g" \
    -e "s/<<(-?)[$bl]*\"($MAUDE_HEREDOC_DELIM)\"/<<\1$MAUDE_HEREDOC_QMARK\2/g" \
    -e "s/<<(-?)[$bl]*\\\\($MAUDE_HEREDOC_DELIM)([$bl]|$|[;|&<>)])/<<\1$MAUDE_HEREDOC_QMARK\2\3/g" \
    -e "s/<<-?[$bl]*[^$bl]*[\\\\'\"][^$bl]*/ $MAUDE_HEREDOC_UNSURE /g" \
    -e "s}<<-?[$bl]*$MAUDE_HEREDOC_QMARK?[$dc-]*[^$dc$MAUDE_HEREDOC_QMARK$bl;|&<>)-][^$bl;|&<>()]*} $MAUDE_HEREDOC_UNSURE }g" \
    -e 's/\\([^A-Za-z0-9_])/_/g' \
    -e 's/\$?\(\(([^()]|\([^()]*\)|\(([^()]|\([^()]*\))*\))*\)\)/ /g' \
    -e 's/\+?=\(([^()]|\([^()]*\))*\)/=()/g' \
    -e 's/\$\[[^]]*\]/ /g' \
    -e 's/([A-Za-z_][A-Za-z0-9_]*)\[[^]]*\]/\1/g' \
    -e 's/\$\{([A-Za-z_0-9]+)\}/$\1/g' \
    -e 's/\$\{[^}]*\}/$X/g' \
    -e "s/\\\$'[^']*'|'([A-Za-z_\$][A-Za-z0-9_]*)'|'[^']*'|\"([A-Za-z_\$][A-Za-z0-9_]*)\"|\"[^\"]*\"/\1\2 /g" \
    -e 's/\\(.)/\1/g' \
    -e 's/(^|[[:space:];|&(){}])#.*$/\1/'
}

# A quote can run across lines: `echo "a <<2` ⏎ `b"` is one string, and bash reads no heredoc
# in it, while the next line after the close is a command again (lens round 3: the digit `2`
# made the standing `<<2` a delimiter where `<<EOF` never was). The shell-fed scan reads lines
# through this (the stripper did until the allowlist, 2026-10-04): it carries the open quote in MAUDE_INQ (reset it to ""
# before a walk), leaves in MAUDE_SCAN only the blanked text that is OUTSIDE a quote still
# open from an earlier line, and on the line where a quote closes the rest of that line. It
# writes variables, not stdout, because a `$( )` call would lose the carried state. A quote
# char left standing after blanking (balanced spans are gone by then) is one that opens and
# does not close on its line — except the `"` of `"$(`: a command substitution starts a new
# parse inside the quotes, so `git commit -m "$(cat <<'EOF'` IS an opener line and the `)"`
# that closes it lines later is that quote's close, not a new open (MAUDE_DQSUB carries it).
# The close is the first UNESCAPED quote of the open kind (`"`, `'`, or `$'`). Known short: a
# `"$(` nested in another.
MAUDE_INQ=""
MAUDE_DQSUB=""
MAUDE_SCAN=""
maude_blank_outside_quotes() {
  local line="$1" q probe rest
  MAUDE_SCAN=""
  if [ -n "$MAUDE_INQ" ]; then
    # The close is the first quote char that is not escaped: inside `"…"` and `$'…'` a `\"` /
    # `\'` is a character, not the close (lens round 4: `echo "a` ⏎ `\" x <<2` ⏎ `"` closed
    # early and a bare force-push after the real close ran). Escapes are neutralised in a
    # same-length probe so the cut lands on the original line. A plain `'…'` has no escapes.
    q="${MAUDE_INQ#\$}"; probe="$line"
    case "$MAUDE_INQ" in '"'|"\$'") probe="${probe//\\\\/__}"; probe="${probe//\\$q/__}" ;; esac
    case "$probe" in
      *"$q"*) rest="${probe#*"$q"}"; line="${line:$(( ${#probe} - ${#rest} ))}"; MAUDE_INQ="" ;;
      *) return 0 ;;
    esac
  fi
  # `"$(` … `)` … `"`: the substitution's commands are shell, the text between its closing
  # paren and the closing quote is quoted (`echo "$(echo a)<<EOF"` opens nothing — lens round 3
  # differential, oracle RAN). Matched on this line by paren depth; unmatched, it closes on a
  # later line and MAUDE_DQSUB carries that.
  local pre rest inner after j depth
  while [[ "$line" == *'"$('* ]]; do
    pre="${line%%\"\$(*}"; rest="${line#*\"\$(}"
    depth=1; j=0
    while [ "$j" -lt "${#rest}" ] && [ "$depth" -gt 0 ]; do
      case "${rest:$j:1}" in '(') depth=$((depth+1)) ;; ')') depth=$((depth-1)) ;; esac
      j=$((j+1))
    done
    if [ "$depth" -gt 0 ]; then line="$pre \$($rest"; MAUDE_DQSUB=1; break; fi
    inner="${rest:0:$j}"; after="${rest:$j}"
    case "$after" in *\"*) after=" ${after#*\"}" ;; esac
    line="$pre \$($inner$after"
  done
  MAUDE_SCAN="$(maude_blank_opener_line "$line")"
  while [[ "$MAUDE_SCAN" =~ [\'\"] ]]; do
    q="${BASH_REMATCH[0]}"
    if [ "$q" = '"' ] && [ -n "$MAUDE_DQSUB" ]; then
      # The close of a `"$(` from an earlier line: what stands between the substitution's
      # last `)` and this quote is quoted text.
      pre="${MAUDE_SCAN%%\"*}"; after="${MAUDE_SCAN#*\"}"
      case "$pre" in *\)*) pre="${pre%\)*})" ;; esac
      MAUDE_DQSUB=""; MAUDE_SCAN="$pre $after"; continue
    fi
    # `$'` opens an ANSI-C string, whose `\'` is a character; remember which kind is open.
    MAUDE_SCAN="${MAUDE_SCAN%%"$q"*}"
    if [ "$q" = "'" ] && [[ "$MAUDE_SCAN" == *'$' ]]; then MAUDE_INQ="\$'"; else MAUDE_INQ="$q"; fi
    break
  done
}

# An opener line the gate strips after is one it can prove bash reads the same way (2026-10-04,
# John's ruling after lens rounds 5-9 each found one more divergence in a parser that tried to
# read every shape). EVERY command line, from the first, is read by ONE left-to-right pass that
# accepts only these tokens, each structurally the same to bash (same line boundary, same quote
# state at the end of the line, same openers):
#   blanks       space, tab: bash's own word separators (not \r \v \f, not Unicode spaces);
#   words        [A-Za-z0-9_./:=@%+,~*?-]: no quote, expansion, escape, group or comment char;
#                a glob or `~` expands, but expansion never changes where a line or a quote ends;
#   $NAME ${NAME} $1 $@ $? and the other special parameters, in a word or inside "...": bash
#                parses the line BEFORE it expands, and an expanded value is never parsed again,
#                so it cannot open a quote, a heredoc or a line; `$(` `$((` `${x:-...}` `$'...'`
#                are not this (their insides can hold quotes and heredocs) and are rejected
#                (the one widening the real-command corpus asked for: 7 of 5,122 heredoc
#                commands run here blocked on a path in a variable, 2026-10-04);
#   '...'        any bytes but `'`, closed on the same line: bash reads nothing inside;
#   "..."        no `"` `\` or backtick inside, and a `$` only as a parameter above, closed on
#                the same line;
#   operators    | || & && ; > >> >| < >& <& : metacharacters, they end a word in bash too;
#   # at a token start, to the end of the line: bash's comment (a `#` inside a word is not one,
#                and is rejected as a non-word character);
#   an opener    << or <<-, blanks, then WORD, 'WORD', "WORD" or \WORD, WORD being
#                [A-Za-z_][A-Za-z0-9_.-]*, ended by a blank, an operator or the end of the line:
#                bash's delimiter is the same word; quoted or escaped, the body does not join;
#   `"$(cat <<OPENER` ending the line: the commit-message shape; its `)"` comes after the body.
# Anything else ends the stripping: that line and every later line are read as commands (a
# `$`, `\`, `(`, `{`, a backtick, `<<<`, an unclosed quote, a byte bash reads into a word). Cost,
# named: a heredoc after such a line keeps its body in the scan.
#
# A body ends on the line bash ends it on, exactly: no trimming (`EOF `, `  EOF`, `EOF\r` close
# nothing in bash), leading TABS stripped under `<<-`, and in an UNQUOTED body a line ending in
# an odd run of `\` joins the next before the compare (`EO\` ⏎ `F` closes `<<EOF`). Closing
# early is not safe: body text after a too-early close is read as commands, and a `cat <<Z` in
# it would open a phantom over the lines bash runs after its real close (round 6). A body that
# never closes is not stripped: its lines are handed back.
MAUDE_HEREDOC_WORDCH='A-Za-z0-9_./:=@%+,~*?-'
maude_heredoc_line_ok() {
  # Sets MAUDE_HD_Q / MAUDE_HD_DASH / MAUDE_HD_QUOT (space-separated, one per opener) and
  # returns 0 when every token of $1 is one the header above accepts.
  # LC_ALL=C for this function only: in a UTF-8 locale a range like `A-Za-z0-9` also matches
  # accented letters and non-ASCII digits, and the accepted set must not move with the locale.
  # ${#1} and every offset below count BYTES under it, so the slicing agrees with the regexes.
  local LC_ALL=C
  local s="$1" i=0 n c rest w d qt tab=$'\t'
  n="${#s}"
  local param='\$([A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}|[0-9@*#?$!-])'
  local word="^([$MAUDE_HEREDOC_WORDCH]|$param)+" delim='^[A-Za-z_][A-Za-z0-9_.-]*'
  MAUDE_HD_Q="" MAUDE_HD_DASH="" MAUDE_HD_QUOT=""
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"; rest="${s:$i}"
    case "$c" in
      ' '|"$tab") i=$((i + 1)); continue ;;
      '#') return 0 ;;
    esac
    if [[ "$rest" =~ ^\"\$\(cat[\ $'\t']+\<\<(-?)[\ $'\t']*(\'[A-Za-z_][A-Za-z0-9_.-]*\'|\"[A-Za-z_][A-Za-z0-9_.-]*\"|\\[A-Za-z_][A-Za-z0-9_.-]*|[A-Za-z_][A-Za-z0-9_.-]*)[\ $'\t']*$ ]]; then
      d="${BASH_REMATCH[1]}"; w="${BASH_REMATCH[2]}"; qt=""
      case "$w" in \'*|\"*) w="${w:1:${#w}-2}"; qt=1 ;; \\*) w="${w:1}"; qt=1 ;; esac
      MAUDE_HD_Q="$MAUDE_HD_Q $w" MAUDE_HD_DASH="$MAUDE_HD_DASH ${d:-_}" MAUDE_HD_QUOT="$MAUDE_HD_QUOT ${qt:-_}"
      return 0
    fi
    case "$rest" in
      '<<<'*) return 1 ;;   # also refused by the delimiter rule below today (`<` starts no word); explicit so a wider delimiter cannot open one
      '<<'*)
        i=$((i + 2)); d="_"
        [ "${s:$i:1}" = "-" ] && { d="-"; i=$((i + 1)); }
        while [ "$i" -lt "$n" ] && { [ "${s:$i:1}" = " " ] || [ "${s:$i:1}" = "$tab" ]; }; do i=$((i + 1)); done
        rest="${s:$i}"; qt="_"
        case "$rest" in
          \'*) rest="${rest:1}"; qt=1; [[ "$rest" =~ $delim ]] || return 1; w="${BASH_REMATCH[0]}"
               [ "${rest:${#w}:1}" = "'" ] || return 1; i=$((i + ${#w} + 2)) ;;
          \"*) rest="${rest:1}"; qt=1; [[ "$rest" =~ $delim ]] || return 1; w="${BASH_REMATCH[0]}"
               [ "${rest:${#w}:1}" = '"' ] || return 1; i=$((i + ${#w} + 2)) ;;
          \\*) rest="${rest:1}"; qt=1; [[ "$rest" =~ $delim ]] || return 1; w="${BASH_REMATCH[0]}"
               i=$((i + ${#w} + 1)) ;;
          *) [[ "$rest" =~ $delim ]] || return 1; w="${BASH_REMATCH[0]}"; i=$((i + ${#w})) ;;
        esac
        # The word ends where bash ends it: a blank, an operator, the end of the line.
        case "${s:$i:1}" in ''|' '|"$tab"|';'|'|'|'&'|'<'|'>') ;; *) return 1 ;; esac
        MAUDE_HD_Q="$MAUDE_HD_Q $w" MAUDE_HD_DASH="$MAUDE_HD_DASH $d" MAUDE_HD_QUOT="$MAUDE_HD_QUOT $qt"
        continue ;;
      '||'*|'&&'*|'>>'*|'>|'*|'>&'*|'<&'*) i=$((i + 2)); continue ;;
      ';;'*) return 1 ;;
      '|'*|'&'*|';'*|'>'*|'<'*) i=$((i + 1)); continue ;;
    esac
    # A word: runs of word characters and closed quotes, glued (`a'b'"c"`).
    local took=""
    while [ "$i" -lt "$n" ]; do
      rest="${s:$i}"
      if [[ "$rest" =~ $word ]]; then i=$((i + ${#BASH_REMATCH[0]})); took=1; continue; fi
      case "$rest" in
        \'*) rest="${rest:1}"; case "$rest" in *\'*) ;; *) return 1 ;; esac
             w="${rest%%\'*}"; i=$((i + ${#w} + 2)); took=1; continue ;;
        \"*) rest="${rest:1}"; case "$rest" in *\"*) ;; *) return 1 ;; esac
             w="${rest%%\"*}"
             local inner="$w"
             while [[ "$inner" =~ $param ]]; do inner="${inner/"${BASH_REMATCH[0]}"/}"; done
             case "$inner" in *\\*|*\$*|*\`*) return 1 ;; esac
             i=$((i + ${#w} + 2)); took=1; continue ;;
      esac
      break
    done
    [ -n "$took" ] || return 1
    # After a word: a blank, an operator, or the end; anything else is not ours.
    case "${s:$i:1}" in ''|' '|"$tab"|';'|'|'|'&'|'<'|'>') ;; *) return 1 ;; esac
  done
  return 0
}

# Besides printing the stripped text it leaves, for an in-process caller: MAUDE_HD_STRIPPED
# (the same text) and the bodies it took out, MAUDE_HD_BODIES[i] recorded under
# MAUDE_HD_BODY_IDX[i] = the index of its opener line IN THE STRIPPED TEXT (several openers on
# one line share it). A body cut short by a stop is recorded as far as it went; a body that
# never closes is handed back in the text and recorded nowhere.
MAUDE_HD_STRIPPED=""
MAUDE_HD_BODIES=()
MAUDE_HD_BODY_IDX=()
# The walks below are bash, per character, and worse than linear in a line's quotes: one
# 20 KB line of `"a" "a" …` cost the stripper 6.9 s, and the hook budget is 5 s, after
# which a killed hook blocks nothing (lens 6 on 8a0de19). No count of lines bounds that,
# so the bound is the clock: a caller that has a budget marks its start in MAUDE_WALK_T0
# (whole seconds since its shell began, `$SECONDS`, which bash 3.2 has) and the seconds it
# can spend in MAUDE_WALK_BUDGET; every walk asks per line and, overdue, stops CLOSED
# (the rest of the command handed back whole). Unset, there is no deadline: a test or a
# hook that has already run for seconds would otherwise find every walk overdue at once.
# `$SECONDS` ticks on the wall clock's second, so a budget of N fires after N-1 to N
# seconds of real time; the gate's 3 leaves room for one more line and the greps.
# Both values are read only when they are plain digits (base 10: `08` is octal to bash
# arithmetic): an inherited `1;rm` made the arithmetic fail and the stripper print nothing
# but the error, a fail-open read, and a negative T0 made every walk overdue at once
# (lens 7 on fc838c1, M3). Anything else means no deadline.
# Microseconds since the walks' start by the real clock, or 1 (and a nonzero status) when
# the clock cannot be read: EPOCHREALTIME is written with the locale's decimal separator,
# so only its digits are read (a comma locale made the arithmetic fail and the clock read
# "not overdue"; the commit review on c898dca), and a clock that went backwards reads as
# overdue rather than as time to spare. The whole-second clock stands in on an older bash.
maude_walk_elapsed_us() {
  local now t0
  if [ -n "${EPOCHREALTIME:-}" ] && [ -n "${MAUDE_WALK_T0_US:-}" ]; then
    now="${EPOCHREALTIME//[!0-9]/}"; t0="${MAUDE_WALK_T0_US//[!0-9]/}"
    if [ -z "$now" ] || [ -z "$t0" ] || [ "${#now}" -gt 18 ] || [ "${#t0}" -gt 18 ] || [ $(( 10#$now - 10#$t0 )) -lt 0 ]; then
      printf '%s' 999999999; return 1
    fi
    printf '%s' $(( 10#$now - 10#$t0 ))
    return 0
  fi
  printf '%s' $(( (SECONDS - ${MAUDE_WALK_T0:-$SECONDS}) * 1000000 ))
}
maude_walk_overdue() {
  case "${MAUDE_WALK_BUDGET:-3}" in ''|*[!0-9]*) return 1 ;; esac
  # By the real clock when the gate set one (MAUDE_WALK_T0_US): SECONDS turns on the
  # shell's own second boundary, so the whole-second read was overdue anywhere from 2.0 to
  # 3.0 s real, and a walk of 3.7 s was not refused (2026-11-04). The whole-second clock
  # stands in for an older bash.
  if [ -n "${EPOCHREALTIME:-}" ] && [ -n "${MAUDE_WALK_T0_US:-}" ]; then
    # In-process, no fork: this is asked between every pattern of the walk. The same read
    # as maude_walk_elapsed_us: digits only, and a clock it cannot read, or one that went
    # backwards, is overdue.
    local now="${EPOCHREALTIME//[!0-9]/}" t0="${MAUDE_WALK_T0_US//[!0-9]/}"
    { [ -n "$now" ] && [ -n "$t0" ] && [ "${#now}" -le 18 ] && [ "${#t0}" -le 18 ]; } || return 0
    [ $(( 10#$now - 10#$t0 )) -lt 0 ] && return 0
    [ $(( 10#$now - 10#$t0 )) -ge $(( 10#${MAUDE_WALK_BUDGET:-3} * 1000000 )) ]
    return
  fi
  case "${MAUDE_WALK_T0:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ $((SECONDS - 10#$MAUDE_WALK_T0)) -ge $((10#${MAUDE_WALK_BUDGET:-3})) ]
}
maude_strip_heredocs() {
  local input="$1" out="" line logical join="" bs pend="" tab=$'\t' stop="" j nout=0
  local -a q=() qdash=() qquot=() qidx=() nq nd nt
  local h=0
  MAUDE_HD_BODIES=(); MAUDE_HD_BODY_IDX=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$stop" ]; then out+="$line"$'\n'; continue; fi
    # Overdue (see maude_walk_overdue): this line and every later one are handed back,
    # the body in progress with them, unread.
    if maude_walk_overdue; then stop=1; out+="$pend$line"$'\n'; pend=""; continue; fi
    if [ "$h" -lt "${#q[@]}" ]; then
      pend+="$line"$'\n'
      logical="$join$line"; join=""
      if [ "${qquot[$h]}" = "_" ]; then
        bs="${line##*[!\\]}"
        if [ $(( ${#bs} % 2 )) -eq 1 ]; then join="${logical%\\}"; continue; fi
        # An unquoted delimiter's body is EXPANDED: bash runs $(...) and `...` in it, so it
        # is not text (lens 2026-10-06: `cat <<EOF` / `$(git push --force)` / `EOF` passed).
        # A body line that holds either ends the stripping and is emitted for the matcher.
        # It is tested and emitted as the LOGICAL line, after bash's backslash-newline join:
        # `$(git pu\` then `sh --force)` is one push, and neither piece reads as one.
        # (${ and $[ run nothing without a $( or ` inside, so they are not reasons to read.)
        case "$logical" in *'$('*|*'`'*)
          stop=1; out+="$logical"$'\n'
          MAUDE_HD_BODIES+=("${pend%"$line"$'\n'}"); MAUDE_HD_BODY_IDX+=("${qidx[$h]}"); pend=""; continue ;;
        esac
      fi
      [ "${qdash[$h]}" = "-" ] && logical="${logical#"${logical%%[!$tab]*}"}"
      if [ "$logical" = "${q[$h]}" ]; then
        MAUDE_HD_BODIES+=("${pend%"$line"$'\n'}"); MAUDE_HD_BODY_IDX+=("${qidx[$h]}")
        h=$((h + 1)); pend=""
      fi
      continue   # drop body lines AND the closing delimiter line
    fi
    join=""
    # A command line past 4 KB is handed back unread, as an opener line past 4 KB is in
    # the gate: the per-character walk below is what the budget cannot afford on it.
    if [ "${#line}" -gt 4096 ] || ! maude_heredoc_line_ok "$line"; then stop=1; out+="$line"$'\n'; continue; fi
    read -r -a nq <<< "$MAUDE_HD_Q"; read -r -a nd <<< "$MAUDE_HD_DASH"; read -r -a nt <<< "$MAUDE_HD_QUOT"
    for j in "${!nq[@]}"; do q+=("${nq[$j]}"); qdash+=("${nd[$j]}"); qquot+=("${nt[$j]}"); qidx+=("$nout"); done
    out+="$line"$'\n'; nout=$((nout + 1))
  done <<< "$input"
  [ "$h" -lt "${#q[@]}" ] && out+="$pend"
  # shellcheck disable=SC2034   # read by maude-gate.sh after an in-process call
  MAUDE_HD_STRIPPED="$out"
  printf '%s' "$out"
}

# Match a gate pattern against a command. Excises heredoc BODIES first
# (v0.27.0 — a memory-file heredoc containing the words "git push" fired the
# push gate, measured live 2026-08-08; a heredoc body is data, not a command),
# then strips paired quotes to dodge the in-string false positive that bit
# v0.1.5 (commit messages describing the gate self-blocked the commit). The
# heredoc-fed-shell residual (bash <<EOF git push EOF) joins limitation #3,
# same as the rm guards. The pattern is responsible for its own anchoring —
# see maude-gate.sh for the CMD_START / FLAG constants used to build
# cmd-start and flag-position anchored patterns.
#
# Usage: maude_match_gate_pattern "<command>" "<pattern-regex>"
# Returns: 0 if matches, 1 otherwise.
maude_match_gate_pattern() {
  local cmd="$1" pat="$2" stripped
  stripped="$(maude_strip_quotes "$(maude_strip_heredocs "$cmd")")"
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
maude_rm_in_command_position() {  # <command> [<its body-stripped, quote-stripped view>]
  local skeleton
  # Excise heredoc bodies (data, not shell) BEFORE quote-stripping/flattening so
  # documentation prose in a `git commit -F -` body cannot read as a subshell rm.
  # A caller that holds that view already passes it: the stripper walks every line.
  skeleton="${2:-$(maude_strip_quotes "$(maude_strip_heredocs "$1")")}"
  printf '%s' "$skeleton" | grep -qE -- \
    '(^|[;&|(`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|command[[:space:]]+|sudo[[:space:]]+|(\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]|\{[^}[:space:];&|]*\}|\(\([^();&|]*\)\)|\([^();&|]*\))|`[^`;&|]*`)+[[:space:]]+)*(/[^[:space:]]*/|(\$\{[^}[:space:];&|]*\}|\$\([^();&|]*\)|`[^`;&|]*`)+(/[^[:space:]]*/)?)?rm([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)'
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
  printf '%s' 'git-push commit-amend no-verify no-gpg-sign reset-hard run-governor mcp-destructive'
}
maude_red_keys() {
  printf '%s' 'rm-rf-root rm-rf-glob sudo-rm-rf rm-rf-sole-copy sole-copy-target public-publish force-push filter-repo filter-branch infra-destructive drop-table'
}
# The sentence every RED refusal ends with, in ONE place (the UX lens, 2026-09-06: six
# of nine refusals told the person to run the yellow self-clear for a red key, and only
# a file path in a parenthetical told a red refusal from a yellow one). A red key is the
# human's hand, never Claude's; /maude:conscience <key> shows the line to paste.
maude_red_refusal_line() {  # <key>
  printf '"%s" is a RED key: the human'"'"'s hand only, by a ! line pasted in their own shell. Claude cannot clear it; /maude:conscience %s shows the line to paste.' "$1" "$1"
}
# 0 (true) if $1 is a red key.
maude_is_red_key() {
  case " $(maude_red_keys) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
# 0 (true) if $1 ranks red in the gate: a red key, one of the two backstop keys about red
# keys (red-self-clear, redclear-write), parser-depth (a command too deep to read) or
# parser-budget (a table walk cut by the gate's clock). None is in the red list and no
# clear script mints them; their tokens are read from the red file only, so a yellow key
# never stands in for one and care.json never opens one.
maude_gate_key_red() {
  case "$1" in red-self-clear|redclear-write|parser-depth|parser-budget|parser-unread) return 0 ;; esac
  [ -n "$1" ] && maude_is_red_key "$1"
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

# ─── Wrapper-payload extraction primitives (v0.13.2) ──────────────────────────
#
# maude_wrapped_payloads "<cmd>"
#   Prints each INSPECTABLE literal payload found in the command string, one per
#   line. Inspectable = single-quoted ('...'), or double-quoted ("...") with no
#   $ or backtick.  Wrappers recognised: bash|sh|dash|zsh -c, and eval.
#   Flags before -c (e.g. -l, -lc) and trailing args after the quoted payload
#   are handled correctly.
#
#   UNDER-EXTRACT BIAS: when a payload's boundaries are ambiguous the function
#   outputs NOTHING rather than a wrong/partial string.  A mis-extraction in
#   Task 8's recursive re-match could produce a FALSE-BLOCK; an under-extraction
#   merely under-blocks (same class as the documented variable-indirection limit).
#
# maude_has_opaque_wrap "<cmd>"
#   Returns 0 (true) iff a wrapper carries an UNINSPECTABLE payload:
#     • double-quoted body containing $ or backtick, OR
#     • unquoted / bare-word token right after -c or eval.
#   Drives a whisper in Task 8.
#
# Caller note: each grep sub-pipeline exits 1 on no-match; safe under set +e /
# the test harness, but callers using set -e pipefail should account for that.

# shellcheck disable=SC2016  # $/$` inside single-quoted pattern strings are
#                            # intentionally literal (grep/sed ERE), not expansions.
maude_wrapped_payloads() {
  local cmd="$1"
  local _q _pfx _eval_pfx _bash_c_sq _bash_c_dq _eval_sq _eval_dq
  _q="'"
  # Prefix patterns (stored in variables to keep the grep calls readable and to
  # allow _q substitution without breaking single-quote strings).
  _pfx='(bash|sh|dash|zsh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+'
  _eval_pfx='(^|[;&|(`[:space:]])eval[[:space:]]+'
  # Single-quoted body: '...' — always a literal, safe to extract.
  _bash_c_sq="${_pfx}${_q}[^${_q}]*${_q}"
  _eval_sq="${_eval_pfx}${_q}[^${_q}]*${_q}"
  # Double-quoted body with no $ or backtick: "..." — literal, safe to extract.
  _bash_c_dq='(bash|sh|dash|zsh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+"[^"$`]*"'
  _eval_dq='(^|[;&|(`[:space:]])eval[[:space:]]+"[^"$`]*"'

  # bash/sh/dash/zsh -c 'payload'
  # Strip: ^[^']*' removes everything up to and including the opening quote;
  # .$ removes the closing quote (grep guarantees the last char is ').
  printf '%s\n' "$cmd" | grep -oE "$_bash_c_sq" \
    | sed -E "s/^[^${_q}]*${_q}//" | sed 's/.$//'
  # bash/sh/dash/zsh -c "payload"  (no $ or backtick)
  printf '%s\n' "$cmd" | grep -oE "$_bash_c_dq" \
    | sed -E 's/^[^"]*"//; s/.$//'
  # eval 'payload'
  printf '%s\n' "$cmd" | grep -oE "$_eval_sq" \
    | sed -E "s/^[^${_q}]*${_q}//" | sed 's/.$//'
  # eval "payload"  (no $ or backtick)
  printf '%s\n' "$cmd" | grep -oE "$_eval_dq" \
    | sed -E 's/^[^"]*"//; s/.$//'
}

maude_has_opaque_wrap() {
  local cmd="$1"
  local _bash_c_opaque_dq _eval_opaque_dq _bash_c_bare _eval_bare
  # Double-quoted body containing $ or backtick → uninspectable interpolation.
  _bash_c_opaque_dq='(bash|sh|dash|zsh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+"[^"]*[$`]'
  _eval_opaque_dq='(^|[;&|(`[:space:]])eval[[:space:]]+"[^"]*[$`]'
  # Unquoted / bare-word token after -c or eval → uninspectable indirection.
  # INTENTIONAL: a bareword (not just $VAR) is treated as opaque because an
  # unquoted wrapped command (e.g. `eval rm -rf /`, `bash -c rm`) is NOT
  # extracted or inspected by maude_wrapped_payloads and must still be surfaced
  # via this whisper. The cost is a benign whisper on harmless `eval ls`.
  # [^[:space:]'"] = first char is not space, not single-quote, not double-quote.
  _bash_c_bare='(bash|sh|dash|zsh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+[^[:space:]'"'"'"]'
  _eval_bare='(^|[;&|(`[:space:]])eval[[:space:]]+[^[:space:]'"'"'"]'
  printf '%s' "$cmd" | grep -qE "$_bash_c_opaque_dq" && return 0
  printf '%s' "$cmd" | grep -qE "$_eval_opaque_dq"   && return 0
  printf '%s' "$cmd" | grep -qE "$_bash_c_bare"       && return 0
  printf '%s' "$cmd" | grep -qE "$_eval_bare"         && return 0
  return 1
}

# maude_redclear_fold <content view>: the view with simple NAME=LITERAL assignments folded
# into the words that use $NAME or ${NAME}, in assignment order, each value folded against
# the assignments before it, and a `cd DIR` folded onto the relative words after it. For the
# name check only, and only ever to ADD a match: the caller checks the raw view too (lens 4,
# 2026-11-03: p=DIR/care-red; cat /tmp/f > ${p}clear.json spelled no stem in any view, and
# neither did d=/x/.maude/plug; … ${d}in/${p}clear.json). Only a value that is a pure
# literal once folded (no $, no backtick) registers: a value holding an expansion stays
# unfolded, so the $ it leaves in a word is the built-name net's to read, and a value can
# never re-enter its own fold (p=${p}x). Each replacement removes one $, so the loops end.
# A name assigned twice, or mentioned bare anywhere (for p, read p, printf -v p, unset p),
# is never folded: its run-time value is not the literal, and a use of it where .maude
# is spelled is OVER (the second review on adf94aa). Where .maude is spelled, a builtin
# that binds a name anywhere in the command turns the fold off for every name and makes
# any $ use OVER, and the names the shell itself binds (REPLY, PWD, _, BASH_*, …) are
# OVER on use (the review on 4274bdc), and so is any expansion that is not a folded
# literal, a special parameter included (the review on dd75ced). The cost, owned: a read
# of the token file beside a read builtin, a for, a $PWD or a $? is refused; split it, or
# read with a tool, not the shell.
# Bounded (the review on e69db43): a value past 4 KB, a word past 64 KB, or more than 64
# assignments prints OVER and the caller refuses; so does a fold that prints nothing, and
# so does a relative shell-built word after ANY cd, pushd or popd, in a command that
# spells .maude anywhere (the reviews on adf94aa and dd75ced: cd -P DIR bound the option,
# pushd was not cd, cd a; cd b never chained, and pushd +1, popd, a bare cd and CDPATH move
# where no fold can follow). The literal cd tracking only adds a stem match.
# maude_redclear_join: a backslash-newline continuation, which the views carry as
# backslash+newline or backslash+; (unquote maps a newline to ;), is joined the way bash
# joins it before any view is read (the review on dd75ced: care-red\<newline>clear.json
# spelled no stem in any view). Only an odd run of backslashes continues: an even run is an
# escaped backslash and the separator after it is real (the review on dbd9120: a blanket
# join read echo \\; rm FILE as one echo).
# Linear in the bytes: the text is split at its backslashes (a run of k yields k-1 empty
# fields) and only the runs are walked, never each character. The per-character loop this
# replaces was 1.5 s at the byte cap, three calls a command, with the hook killed at 5 s
# (the padding bypass).
maude_redclear_join() {  # <text>: only an odd run of backslashes before a newline or ; continues
  # One record at a time, each piece printed as it is made: a run of backslashes never
  # spans a newline, so a run that ends a line is held until the next line says whether a
  # newline follows it. Growing one string by appending is quadratic in BSD awk (macOS),
  # which copies the string on every append: the whole text, then every run, was that
  # (the macOS-shaped suite on the v0.36.0 release; GNU awk appends in place).
  printf '%s' "$1" | LC_ALL=C awk '
    function bs(k,  r) { if (k <= 0) return ""; r = "\\"; while (length(r) < k) r = r r; return substr(r, 1, k) }
    {   # every byte kept: a marker is never a separator (the review on 17bdbdd)
      if (NR > 1) { if (tail % 2 == 1) printf "%s", bs(tail - 1); else printf "%s\n", bs(tail) }
      tail = 0
      m = split($0, f, /\\/); printf "%s", f[1]; p = 2
      while (p <= m) {
        run = 1
        while (p < m && f[p] == "") { run++; p++ }
        if (p == m && f[p] == "") { tail = run; break }   # the run ends the line
        nxt = substr(f[p], 1, 1)
        if (run % 2 == 1 && nxt == ";") printf "%s%s", bs(run - 1), substr(f[p], 2)
        else printf "%s%s", bs(run), f[p]
        p++
      }
    }
    END { if (tail > 0) printf "%s", bs(tail) }'
}

maude_redclear_fold() {  # <content view, JOINED by the caller (maude_redclear_touch joins both views first)>
  # No join here: the touch has joined this view already, and a second pass over a joined
  # view changes only a trailing newline, which the tr below erases (the padding bypass:
  # three joins of a 129 KB view were a third of the hook's time).
  printf '%s' "$1" | tr '\n' ' ' | tr -d '\\' | LC_ALL=C awk '
    # Output is built in a small buffer flushed to a table every 4 KB, never one string
    # grown per word (BSD awk, as on macOS, copies a string on every append) and never a
    # table of one entry per word (its table growth made 60,000 entries cost 1.2 s where
    # 64,000 cost 0.3 s): the macOS-shaped suite on the v0.36.0 release.
    function app(x) { buf = buf " " x; blen += 1 + length(x); olen += 1 + length(x); if (blen > 4096) { o[++no] = buf; buf = ""; blen = 0 } }
    function fold(t,   k, p) {
      for (k = 1; k <= nv; k++) {   # in assignment order: $p$q folds $p first, never gluing $q to it
        while ((p = index(t, "${" names[k] "}")) > 0) {
          t = substr(t, 1, p - 1) vals[k] substr(t, p + length(names[k]) + 3)
          if (length(t) > 65536) { print "OVER cap"; exit }
        }
        while (match(t, "\\$" names[k] "([^A-Za-z0-9_]|$)")) {
          t = substr(t, 1, RSTART - 1) vals[k] substr(t, RSTART + 1 + length(names[k]))
          if (length(t) > 65536) { print "OVER cap"; exit }
        }
      }
      return t
    }
    { n = split($0, tok, /[[:space:];&|()`]+/); cd = ""; no = 0; olen = 0; buf = ""; blen = 0; want = 0; unknown = 0
      maude = ($0 ~ /\.maude/)
      # pass 1: a name folds only when its ONE mention is its plain NAME=LITERAL. A mention
      # is any word holding the name as an identifier (p, p+=, p[0]=, -vp, p>f): for p, read
      # p, printf -v p, unset p, local p, getopts … p, mapfile -t p, p+=x rebind it at run
      # time (the second review on adf94aa, the review on b865c4d). Where .maude is spelled,
      # declare/typeset/local -n, let, (( and ${NAME=/${NAME:= end the fold outright.
      # where .maude is spelled, a builtin that binds a name anywhere in the command (by any
      # spelling, a nameref, a built operand, a printf -v) means no literal can be trusted:
      # the fold is off for every name and any $ use is OVER (the review on 4274bdc)
      bind = (maude && $0 ~ /declare|typeset|local|export|readonly|readarray|mapfile|getopts|unset|printf[[:space:]]+-[A-Za-z]*v|(^|[^A-Za-z0-9_])(read|let|eval|for|select|set)([^A-Za-z0-9_]|$)|\(\(|\$\{[A-Za-z_][A-Za-z0-9_]*:?=/)   # portability-name-only: builtins matched by name, never run here
      # The mentions are read only for names the command assigns (every read of bare is
      # keyed by a name in cnt), so cnt is collected first and only those names are
      # counted; with no assignment the count is skipped. The same verdict, by construction;
      # the work it saves was most of the fold under BSD awk (macOS), where a table of
      # 60,000 mention keys went superlinear and the fold took 1.8 s of a 3.5 s hook.
      nasg = 0
      for (i = 1; i <= n; i++) if (tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { cnt[substr(tok[i], 1, index(tok[i], "=") - 1)]++; nasg++ }
      for (i = 1; i <= n && nasg; i++) {
        t = tok[i]; if (t == "") continue
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) w = substr(t, index(t, "=") + 1); else w = t
        # every identifier in the rest of the word (its value, or the word itself) that is not
        # a $use is a mention: split on everything but identifier characters, drop $-prefixed
        gsub(/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/, " ", w)
        # the pieces are read by a match loop, not split(): a split into a fresh array per
        # word went superlinear in BSD awk beside the large word array (60,000 words with an
        # assignment and .maude: 3.3 s, the fifth lens on the release). Same pieces: the
        # maximal runs of identifier characters; one that starts with a digit is no name.
        while (match(w, /[A-Za-z0-9_]+/)) { kw = substr(w, RSTART, RLENGTH); w = substr(w, RSTART + RLENGTH); if (kw in cnt) bare[kw]++ }
        # an option word with a name glued on (printf -vp, read -rp): every suffix is a mention
        if (t ~ /^-[A-Za-z_][A-Za-z0-9_]*$/) for (j = 2; j <= length(t); j++) if (substr(t, j) in cnt) bare[substr(t, j)]++
      }
      for (i = 1; i <= n; i++) {
        t = tok[i]; if (t == "") continue
        # the folded view is bounded as a whole, not only per word: a 4 KB value used 25,000
        # times folded to 100 MB under the per-word cap and the touch outran the hook (the
        # advisor on fix/gate-time-budget). Past twice the byte cap the fold is OVER.
        # (a running length and an array of pieces, not one growing string: BSD awk copies
        # the string on every append and measures it on every length(), so 60,000 words
        # took 7.4 s under the macOS-shaped suite, past the 5 s kill of the hook)
        if (olen > 262144) { print "OVER cap"; exit }
        # a use of a name the fold may not read (assigned twice, or mentioned anywhere else)
        # in a command that spells .maude anywhere: refused outright; the check reads every
        # word, the value of an assignment included (the review on b865c4d). No apostrophe
        # may appear in this program: it sits in shell single quotes.
        if (maude && t ~ /\$/) {
          if (bind) { print "OVER"; exit }
          if (t ~ /\$\{?(_|REPLY|PWD|OLDPWD|OPTARG|OPTIND|MAPFILE|DIRSTACK|BASH_[A-Z_]*|RANDOM|SECONDS|LINENO|IFS|PIPESTATUS|FUNCNAME)([^A-Za-z0-9_]|$)/) { print "OVER"; exit }
          for (nm in cnt) if ((cnt[nm] > 1 || (nm in bare)) && (index(t, "$" nm) || index(t, "${" nm))) { print "OVER"; exit }
          # any expansion that is not a folded literal: a name never assigned here, a special
          # parameter ($1 $@ $? $$ $! $# $* $-): OVER (the review on dd75ced). $( and $" are
          # left to the built-name net: a substitution in the token directory is a built word.
          # No apostrophe may appear in this program: it sits in shell single quotes.
          u = t
          while (match(u, /\$(\{[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*|\{?[0-9@*#?$!-])/)) {
            e = substr(u, RSTART + 1, RLENGTH - 1); sub(/^\{/, "", e); ok = 0
            for (k = 1; k <= nv; k++) if (names[k] == e) ok = 1
            if (!ok) { print "OVER"; exit }
            u = substr(u, RSTART + RLENGTH)
          }
        }
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          e = index(t, "="); nm = substr(t, 1, e - 1); vl = substr(t, e + 1); if (nv && index(vl, "$")) vl = fold(vl)
          if (length(vl) > 4096) { print "OVER cap"; exit }
          app(nm "=" vl)
          if (!bind && vl !~ /[$`]/ && cnt[nm] == 1 && !(nm in bare)) { if (++nv > 64) { print "OVER cap"; exit }; names[nv] = nm; vals[nv] = vl }
          continue
        }
        if (nv && index(t, "$")) t = fold(t)   # fold only replaces a $ use: a word without one, or no name to fold, is itself
        # the directory: cd and pushd take the next operand, options skipped (cd -P DIR); a
        # relative operand resolves against the current one; an operand that is no literal
        # (cd -, cd $d, cd `…`) or a popd makes it UNKNOWN (the review on adf94aa)
        # any change of directory at all (a bare cd, pushd +N, popd, CDPATH) can move to a
        # directory the fold cannot model: from here a relative shell-built word is OVER
        # where .maude is spelled; the literal tracking below only ADDS a stem match
        if (t == "cd" || t == "pushd") { want = 1; unknown = 1; app(t); continue }
        if (t == "popd" || t ~ /^CDPATH=/) { unknown = 1; cd = ""; app(t); continue }
        if (want) {
          if (t ~ /^-./ && t != "--") { app(t); continue }   # an option: the operand is still to come
          want = 0
          if (t == "--") { want = 1; continue }
          if (t == "-" || t ~ /^[+~]/ || t ~ /[$`]/) cd = ""; else cd = (t ~ /^\// || cd == "") ? t : cd "/" t
          app(t); continue
        }
        if (cd != "" && t !~ /^\//) t = cd "/" t
        # after an unknown directory, a relative word the shell builds, in a command that
        # spells .maude anywhere, could be the token: refused outright
        if (unknown && maude && t !~ /^\// && t ~ /[$`{}?*[]/) { print "OVER"; exit }
        app(t)
      }
      if (no == 0 && buf == "") print " "
      else { for (q = 1; q <= no; q++) printf "%s", o[q]; printf "%s\n", buf } }'
}

# ── The red-clear token file: a command that names it may only read it ──────────────────
# maude_redclear_touch <content view> [<skeleton>]: 0 when the command names the token file
# and is not a plain read of it; 1 otherwise. The CONTENT view (quotes dropped, their text
# kept, ~ and $HOME expanded, literal assignments and a cd folded in by maude_redclear_fold)
# decides whether the file is named: by its STEM, "care-redclear",
# case-folded and with backslashes dropped, so care-redclear.js\on, CARE-REDCLEAR.JSON,
# $'…\x6fn', jso${e}n, .js?n and a=care-redclear; … $a.json all count as naming it (lens 2,
# 2026-11-03: the full name let every one of those through). The SKELETON (quoted spans
# erased whole, maude_strip_quotes) is what the redirect check and the command-word walk
# read, so a `|` in a jq filter or a `>` in a grep pattern is not a pipe or a redirect
# (they were, and jq -r '.a | keys[]' FILE was refused). On the skeleton a redirect into
# the file reads as `> …care-redclear…`; into a quoted target as a bare `>` with nothing
# after it; into a target the shell builds ($a, {x,y}, a glob, ~) or quoted in part
# (DIR/"care-redclear.json" is DIR/ and a marker) as an odd character after the `>`: all
# four refuse. Then every command word must be a plain reader, and in a pipe every
# segment's first word is one (cat FILE | cut is read; cat FILE | python3 is not). A reader
# is a tool that cannot write a file or run one from its arguments or environment: sort
# (-o), uniq and xxd (a second operand), less and more (LESSOPEN, -o) are not readers,
# the review on ae87414 found each writes the token when its operand is the file. Without a
# skeleton (the gate reads a raw command whole) the content view stands in for it. The
# skeleton the gate passes is MARKED (MAUDE_SQ_MARK=1): an erased quoted span leaves one
# \001 byte, which is an odd character in a redirect target (`> /x/.maude/plugin/"…"`) and a
# non-reader in command position (`"rm" FILE`, `""cat x; "rm" FILE`), so a quote can hide
# neither (the commit security review on fd6851e found both seams in the unmarked skeleton).
# What this view cannot see, and the harness deny on the path is for: a glob that never
# spells the stem and sits outside its directory's spelling (care-red* is still read: a
# built word inside .maude/plugin names the token), a move or rm of the directory above
# the file, an interpreter heredoc (python3 - <<PY … open(path, "w")), text decoded or
# evaluated at run time (base64 -d | bash, eval "$(…)", sh < file, xargs -a file).
# Collateral, by design: any file whose name holds the stem (care-redclear-notes.json) is
# read as the token; a read inside a shell-fed heredoc (bash <<EOF cat FILE EOF) refuses,
# bash is no reader; a text heredoc into an extensionless path beside a read refuses, its
# body's words walk as commands; (( a > b )) beside a read refuses, the `>` is a redirect
# to the walk.
# Why it refused, for the label (2026-11-05; the lens on 1e4618d reshaped it): MAUDE_REDCLEAR_WHY is
#   unread          the fold could not read something beside `.maude` (a $(…), a ${X:-…}, a
#                   name it did not see assigned, a binding builtin, a cd) and no write stood
#                   before that point; the write checks read the clean prefix of the skeleton
#                   first, so `rm <token> $1` says "write", and a write past the first
#                   expansion is not read (the label says so)
#   redirect:<how>  a redirect into the token, or into a quoted or shell-built target
#   word:<how>:<w>  a command word beside the token that is not a plain reader
# where <how> is "stem" (the token's name is spelled) or "built" (a word inside
# .maude/plugin the shell builds at run time, read as the token by the rule), and <w> is
# what maude_redclear_word allows on stderr. One label said "names the token file" for all
# of these, and most of a day's refusals named no token at all: a refusal that states the
# wrong reason is a lying refusal.
MAUDE_REDCLEAR_WHY=""
maude_redclear_touch() {  # <content view> [<skeleton>]
  local v s f named over bad
  MAUDE_REDCLEAR_WHY=""
  set -- "$(maude_redclear_join "$1")" "$(maude_redclear_join "${2-}")"
  # named by its stem, or by a word inside its directory that the shell builds at run time
  # (an expansion, a brace, a glob, a backtick, a quoted span the skeleton marks): a name the
  # view cannot read whole inside .maude/plugin is read as the token (review on fd6851e).
  # Read on the raw view AND on the folded view (literal assignments and a cd folded in):
  # the fold only ever adds a match (review on e69db43). A fold past its bound, or one
  # that prints nothing, is OVER: refused outright, after the write checks on the raw view
  # have had their say (a write beside an unread expansion is a write).
  over=""
  f="$(maude_redclear_fold "$1")" || f="OVER"
  [ -n "$f" ] || f="OVER"
  # the fold's own caps (64 names, a 4 KB value, 64 KB of text) are OVER too, and the
  # label says so: an "unread" that tells the person to move an expansion out of a
  # command that holds none cannot be followed (lens 5 on 238e1c9, finding 4)
  case "$f" in "OVER cap"*) over=cap; f="" ;; OVER*) over=1; f="" ;; esac
  named=""
  for v in "$1" ${f:+"$f"}; do
    v="$(printf '%s' "$v" | tr -d '\\' | tr '[:upper:]' '[:lower:]')"
    case "$v" in
      *care-redclear*) named="stem" ;;
      *.maude/plugin*) printf '%s' "$v" | tr ';&|()' '\n' | tr -s '[:space:]' '\n' \
        | grep -qE -- '\.maude/plugin[^[:space:]]*[$`{}?*[]|[$`{}?*[][^[:space:]]*\.maude/plugin' && { [ "$named" = stem ] || named="built"; } ;;
    esac
  done
  if [ -n "$named" ]; then
    s="${2-}"; [ -n "$s" ] || s="$1"
    s="$(printf '%s' "$s" | tr -d '\\' | tr '[:upper:]' '[:lower:]' | sed -E 's/[0-9]*[<>]&([0-9]+|-)([[:space:];&|()]|$)/\2/g')"
    # On a command the fold could not read, the write checks read the CLEAN PREFIX of the
    # skeleton alone: the text before its first `$`, backtick, `{`, `(`, `#` or `}`. There
    # every `;` `&` `|` is a real boundary and every word is one bash runs; past that point
    # a `;` may sit inside `${x:-a;rm b}` or a comment, a word may be a fragment the seams
    # cut from an expansion, and a loop that re-read the skeleton per refused word went
    # quadratic and outran the hook (lens 3 on 601ff37, BLOCKING: 620 fragments, 6 s; the
    # hook is killed at 5 s and a killed hook blocks nothing). One pass, bounded by the
    # command's bytes. Cost, named: a write after the first expansion on an unread command
    # (`cat ${MAP:-x} <token>; rm <token>`) is refused unread, and the label says a write
    # past that point was not read, which is true; it does not say "not caught writing".
    if [ -n "$over" ]; then
      s="${s%%[\$\`{(#]*}"   # a `}` cannot sit in the bracket (bash would close the expansion there):
      s="${s%%\}*}"            # it is cut in a second step
    fi
    printf '%s' "$s" | grep -qE -- '>[|]?[[:space:]]*[^[:space:];&|()<>`]*care-redclear|>[|]?[[:space:]]*([;&|()]|$)|>[|]?[[:space:]]*[a-z0-9_./+:@%,=-]*[^a-z0-9_./+:@%,=[:space:];&|()<>-]' && { MAUDE_REDCLEAR_WHY="redirect:$named"; return 0; }
    # ${NAME} is one word to bash: read as $NAME before the split on braces (a brace group
    # is a seam); ${x:-rm} is not an identifier and still splits, fail closed. The first
    # word refused is printed, for the label; a marker word prints as "a quoted word".
    bad="$(printf '%s' "$s" | sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/$\1/g' | tr ';&|(){}`' '[\n*]' | awk -v M="$(printf '\001')" '
      { n = split($0, f, /[[:space:]]+/); i = (f[1] == "") ? 2 : 1
        while (i <= n && (f[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || f[i] ~ /^(if|then|else|elif|do|while|until|!|time)$/)) i++
        w = (i <= n) ? f[i] : ""
        # a word that is only markers: the residue of an erased span after a seam when it is
        # the LAST word (echo "$(cat FILE)" -> echo ;cat FILE;\001); followed by words it is a
        # command word bash would run from the quote ("rm" cat FILE runs rm): a non-reader
        if (w ~ ("^" M "+$")) { if (i < n && !bad) { bad = 1; first = M }; w = "" } }
      w != "" && w !~ /^(cat|head|tail|wc|grep|egrep|fgrep|jq|ls|stat|file|shasum|sha1sum|sha256sum|sha512sum|md5sum|b2sum|cksum|test|\[|\[\[|\]\]|diff|cmp|echo|printf|readlink|realpath|basename|dirname|du|cd|true|false|:|for|case|fi|done|esac|cut|tr|column|nl|rev|fold|paste|comm|od|strings|read)$/ { if (!bad) first = w; bad = 1 }   # portability-name-only: readers matched by name, never run here
      END { if (bad) print first; exit bad ? 0 : 1 }')"
    if [ -n "$bad" ]; then
      # shellcheck disable=SC2034   # read by maude-gate.sh after an in-process call
      MAUDE_REDCLEAR_WHY="word:$named:$(maude_redclear_word "$bad")"
      return 0
    fi
  fi
  [ -n "$over" ] || return 1
  # shellcheck disable=SC2034   # read by maude-gate.sh after an in-process call
  MAUDE_REDCLEAR_WHY="unread"
  # shellcheck disable=SC2034   # read by maude-gate.sh after an in-process call
  [ "$over" = cap ] && MAUDE_REDCLEAR_WHY="unread:cap"
  return 0
}

# maude_redclear_word <word as the walk read it> → what the label may print of it. The walk's
# view is lowercased with quotes erased to one marker byte, so a word holding a marker was
# quoted in part or whole (`"r"m`, `""cat`) and prints as "a quoted word": the gate cannot
# tell what the quote held. Anything outside [a-z0-9_./+-] or past 40 characters is not
# printed either: a URL-shaped word carried a credential to stderr, an ESC byte carried a
# terminal escape (the lens on 1e4618d). Cost, named: the word prints lowercased (Rscript
# as rscript), since that is the view the rule read.
maude_redclear_word() {
  local m
  m="$(printf '\001')"
  case "$1" in
    *"$m"*) printf 'a quoted word' ;;
    # LC_ALL=C: under a UTF-8 locale [a-z] takes accented and fullwidth letters too, and a
    # lookalike of `rm` printed as the command run (lens 2 on f03f02e, finding 3); in C
    # the class is the 26 letters and a byte past them is refused
    *) if printf '%s' "$1" | LC_ALL=C grep -qE -- '^[a-z0-9_./+-]{1,40}$' && [ "$(printf '%s' "$1" | wc -l)" -eq 0 ]; then printf '%s' "$1"
       else printf 'a word the label does not print (outside [a-z0-9_./+-], or past 40 characters)'; fi ;;
  esac
}

