#!/usr/bin/env bash
# Maude gate hook — fires before Bash. HARD-BLOCKS on irreversible patterns.
# Exits 2 to block; the message goes to the user as the block reason.
#
# v0.1.6: matches via maude_match_gate_pattern (in _maude-common.sh) which
# strips paired quotes from the command before grep-matching. Patterns embed
# their own anchoring via the CMD_START / FLAG_BEFORE / FLAG_AFTER constants
# below. This closes the v0.1.5 self-block bug (commit messages containing
# the literal substring "git push" no longer fire the gate).
#
# Override mechanism: /maude:conscience writes a 5-minute token to care.json
# scoped to a specific key. If the gate matches a pattern AND a live token
# exists for that key, the gate allows the command through and clears the
# token (one-shot pass).
#
# Reads tool input JSON from stdin.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/_maude-common.sh"

CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
fi
# Fail-OPEN by design: without jq there's no trustworthy way to parse the command
# out of the tool-input JSON (a hand-rolled parse reintroduces the v0.1.6
# quote-stripping self-block risk), so the gate provides NO protection here. The
# user is warned once at SessionStart ("the gate is OFF this session"). This is a
# deliberate limitation of an intentionally-soft dependency, not an oversight.
[ -z "$CMD" ] && exit 0

# Quote-content-kept normalisation — used by PATH patterns (see below).
# Strips quote CHARACTERS but keeps their content, so rm -rf "/srv/app"
# becomes rm -rf /srv/app and can be matched by the path patterns.
# Also expands ~ and $HOME to the real home directory so path patterns
# that embed $HOME can match tilde-prefixed or $HOME-prefixed arguments.
UNQUOTED="$(maude_unquote "$CMD" | sed "s|~|${HOME}|g; s|\\\$HOME|${HOME}|g")"

# Anchors used in the patterns table.
# CMD_START   = start of input or after a shell separator (;, &, |, ()
# FLAG_BEFORE = preceded by start-of-input or whitespace
# FLAG_AFTER  = followed by whitespace or end-of-input
# Separators a gated command can sit right after: line start, shell separators
# (;&|), an opening paren — incl. $( — and a backtick (command substitution). The
# backtick closes the `result=`git push`` bypass. Residual: a commit message that
# literally contains a backtick-wrapped gated command (e.g. -m "...`git push`...")
# can false-block after quote-stripping — fail-CLOSED is the right bias for an
# irreversible-command gate, and /maude:conscience clears it one-shot.
CMD_START='(^|[;&|(`])[[:space:]]*'
FLAG_BEFORE='(^|[[:space:]])'
# Followed by whitespace, end-of-input, or a CLOSING separator (so `rm -rf /` still
# matches when wrapped: `…/` then a backtick / ) / ; etc.). Mirrors CMD_START.
FLAG_AFTER='([[:space:]]|[;&|)`]|$)'
# GIT = "git" + any global options (-C <dir>, -c <cfg>, --git-dir=<dir>) + the
# whitespace before the subcommand. Lets `git -C /repo push` / `git  push` (extra
# whitespace) match the same as `git push` — closing the v0.3.0 interior-space and
# `-C` bypasses. Interior token gaps use [[:space:]]+ everywhere for the same reason.
GIT='git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--git-dir[=[:space:]][^[:space:]]+))*[[:space:]]+'
# RMRF = "rm" + a flag bearing both r and f in either order (-rf, -fr, -Rf, -rfv…).
# (Kept for backward compat / other callers; sole-copy patterns use RMR below.)
RMRF='rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*f[[:alnum:]]*|-[[:alnum:]]*f[[:alnum:]]*r[[:alnum:]]*)'
# RMR = "rm" + any leading flags (including --recursive, --force, -r, -f in any
# order and any combination) followed by whitespace before the path argument.
# Force is OPTIONAL — a bare `rm -r` without -f still deletes recursively (RED).
# Matches: rm -rf, rm -fr, rm -r -f, rm -r, rm --recursive, rm --recursive --force,
# rm -rfv, rm -r --force, etc.
RMR='rm([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*[[:space:]]+'

# ── Known limitations (honest about what this regex belt does NOT catch) ──
#
# These gaps are acknowledged, not buried. They rely on the fail-closed bias
# plus (for MCP) the harness-deny backstop:
#
# 1. Interior double-slash: `rm -rf /srv//app` — the literal `/app`
#    segment breaks the pattern; interior slashes are not normalised.
# 2. Path traversal: `rm -rf /srv/app/../app` — not normalised;
#    the `..` component defeats the pattern.
# 3. Shell wrapping: `bash -c "rm -rf /srv/app"` — the outer bash command
#    is not recursively expanded; the inner command is not inspected.
# 4. Variable-indirected paths: `P=/srv/app; rm -rf $P` — the gate sees
#    the literal `$P`, not the expanded value.
# 5. `cd` + relative delete: `cd /srv && rm -rf app` or
#    `cd /srv/app && rm -rf .` — the gate only sees the relative target
#    and cannot infer the effective path from a prior `cd`.
# 6. Absolute-path invocation: `/bin/rm -rf <path>` — the matcher anchors on
#    the bareword `rm`; the leading `/bin/` prefix defeats the match.
# 7. `command` builtin: `command rm -rf <path>` — the `command` builtin
#    prefix bypasses the gate for the same reason as #6.
# 8. Environment-variable assignment prefix: `FOO=1 rm -rf /srv/app` —
#    the command-start anchor treats an assignment prefix as not-a-separator,
#    so `rm` isn't seen at a command boundary.
# ──────────────────────────────────────────────────────────────────────────

# Sole-copy targets come from the config-aware list (generic defaults + local
# gate-config) — no hardcoded paths in this source.
SC_TARGETS=()
while IFS= read -r _t; do [ -n "$_t" ] && SC_TARGETS+=("$_t"); done < <(maude_sole_copy_targets)

# ── PATH patterns — matched against $UNQUOTED (quote chars removed, content kept)
# This ensures rm -rf "/srv/app" is caught even though the path was quoted.
# These are checked FIRST, before command patterns.
PATH_PATTERNS=(
  # rm (recursive, force optional) targeting / directly — system wipe
  # ([^[:space:]]+[[:space:]]+)* allows a dangerous target in any argument position
  # (e.g. `rm -rf /tmp/ok /` — the / is caught even as the second argument).
  "${CMD_START}${RMR}([^[:space:]]+[[:space:]]+)*/${FLAG_AFTER} ||| rm-rf-root ||| \"rm -rf /\" wipes the system. STOP. Run /maude:conscience rm-rf-root only if you really mean it."
  # rm (recursive) targeting glob * — wide blast
  "${CMD_START}${RMR}([^[:space:]]+[[:space:]]+)*\\*${FLAG_AFTER} ||| rm-rf-glob ||| \"rm -rf *\" — wide blast. Run /maude:conscience rm-rf-glob if you mean it."
  # sudo rm (recursive) — any target is RED at root
  "${CMD_START}sudo[[:space:]]+${RMR} ||| sudo-rm-rf ||| sudo rm -rf is destructive at root. Run /maude:conscience sudo-rm-rf if intentional."
)
# Sole-copy entries — one per target, built from the config-aware list.
# `/*` absorbs zero or more trailing slashes (including //).
# `([^[:space:]]+[[:space:]]+)*` allows the sole-copy path in any argument position.
for _t in "${SC_TARGETS[@]}"; do
  PATH_PATTERNS+=("${CMD_START}${RMR}([^[:space:]]+[[:space:]]+)*(${_t})/*${FLAG_AFTER} ||| rm-rf-sole-copy ||| rm -rf of a protected sole-copy path (workspace / repo root / .git / configured path). Sole copy, no fallback. Run /maude:conscience rm-rf-sole-copy only if you truly mean it.")
done

# ── COMMAND patterns — matched against $CMD via maude_match_gate_pattern
# (strip_quotes: content ERASED). This preserves all canaries — a commit message
# containing "git push" as literal text must not self-block the commit.
CMD_PATTERNS=(
  "${CMD_START}${GIT}push[[:space:]].*--force-with-lease ||| force-push ||| force-push-with-lease detected. Still public-rewriting. Run /maude:conscience force-push if verified."
  "${CMD_START}${GIT}push[[:space:]].*--force ||| force-push ||| force-push detected. Public, irreversible. Run /maude:conscience force-push if you have verified."
  "${CMD_START}${GIT}push[[:space:]].*-f${FLAG_AFTER} ||| force-push ||| force-push (-f). Run /maude:conscience force-push if verified."
  "${CMD_START}${GIT}push${FLAG_AFTER} ||| git-push ||| git push detected. Public, irreversible. Run /maude:conscience git-push to override."
  "${FLAG_BEFORE}--no-verify${FLAG_AFTER} ||| no-verify ||| --no-verify skips hooks. Run /maude:conscience no-verify if intentional."
  "${FLAG_BEFORE}--no-gpg-sign${FLAG_AFTER} ||| no-gpg-sign ||| --no-gpg-sign skips signing. Run /maude:conscience no-gpg-sign if intentional."
  "${CMD_START}${GIT}reset[[:space:]].*--hard ||| reset-hard ||| git reset --hard loses local work. Run /maude:conscience reset-hard once you have stashed."
  "${CMD_START}${GIT}filter-repo${FLAG_AFTER} ||| filter-repo ||| git filter-repo rewrites history. Run /maude:conscience filter-repo to override."
  "${CMD_START}${GIT}filter-branch${FLAG_AFTER} ||| filter-branch ||| git filter-branch rewrites history. Run /maude:conscience filter-branch to override."
  "${CMD_START}${GIT}commit[[:space:]].*--amend ||| commit-amend ||| git commit --amend rewrites the last commit. If pushed, this needs force-push. Run /maude:conscience commit-amend."
  "${CMD_START}$(maude_public_publish_re) ||| public-publish ||| public-facing publish (gh release / twine / uv publish / hf upload). Run /maude:conscience public-publish after the pre-public-push checklist + John's go."
  "DROP TABLE ||| drop-table ||| SQL DROP TABLE detected. Run /maude:conscience drop-table to override."
)

MATCHED_KEY=""
MATCHED_MSG=""

# Check PATH patterns first (against UNQUOTED)
for entry in "${PATH_PATTERNS[@]}"; do
  PAT="${entry%% ||| *}"
  REST="${entry#* ||| }"
  KEY="${REST%% ||| *}"
  MSG="${REST#* ||| }"
  if printf '%s' "$UNQUOTED" | grep -qE -- "$PAT"; then
    MATCHED_KEY="$KEY"
    MATCHED_MSG="$MSG"
    break
  fi
done

# Then check COMMAND patterns (against CMD via strip_quotes, unchanged)
if [ -z "$MATCHED_KEY" ]; then
  for entry in "${CMD_PATTERNS[@]}"; do
    PAT="${entry%% ||| *}"
    REST="${entry#* ||| }"
    KEY="${REST%% ||| *}"
    MSG="${REST#* ||| }"
    if maude_match_gate_pattern "$CMD" "$PAT"; then
      MATCHED_KEY="$KEY"
      MATCHED_MSG="$MSG"
      break
    fi
  done
fi

[ -z "$MATCHED_KEY" ] && exit 0

# Check for a live conscience token for this key
NOW=$(date +%s)
CARE="$(maude_self_dir)/care.json"
if [ -f "$CARE" ] && command -v jq >/dev/null 2>&1; then
  CLEARED_UNTIL="$(jq -r --arg k "$MATCHED_KEY" '.gate_cleared[$k].until // 0' "$CARE" 2>/dev/null)"
  if [ -n "$CLEARED_UNTIL" ] && [ "$CLEARED_UNTIL" -gt 0 ] && [ "$CLEARED_UNTIL" -gt "$NOW" ] 2>/dev/null; then
    # Token is live — allow this one through, then consume it (atomic, shared helper)
    maude_care_set "$CARE" --arg k "$MATCHED_KEY" 'del(.gate_cleared[$k])'
    maude_log_trace "gate" "passed=$MATCHED_KEY"
    exit 0
  fi
fi

# No live token — block
maude_log_trace "gate" "blocked=$MATCHED_KEY"
printf 'Maude: %s\n' "$MATCHED_MSG" >&2
exit 2
