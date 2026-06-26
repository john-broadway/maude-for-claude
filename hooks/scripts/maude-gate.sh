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
# shellcheck disable=SC2034  # RMRF intentionally retained for external callers; unused in this file
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
#    is not recursively expanded; the inner command is not inspected. This now
#    also covers an rm inside a heredoc fed to a shell (`bash <<EOF … EOF`):
#    the rm-command-position guard excises ALL heredoc bodies (they are data,
#    so a `git commit -F -` body documenting rm -rf / no longer false-blocks),
#    which means a shell-fed heredoc rm falls here, uniformly uncaught.
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
# 9. Heredoc mis-detection: the rm-command-position guard excises heredoc bodies
#    via a HEURISTIC `<<WORD` scan of the raw line (see maude_strip_heredocs).
#    A `<<WORD` that is actually quoted text (`echo "x << EOF"`) or a letter-led
#    arithmetic shift (`$((a << b))`) is mis-read as a heredoc start, so a real
#    `rm -rf …` on a LATER line of the same command can be wrongly skipped and
#    under-blocked. Accepted to keep doc/commit heredocs from false-blocking;
#    not narrowed because the obvious fix reopens the `<<'EOF'` false-block.
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
  # NOTE: DROP TABLE is NOT a CMD_PATTERN — matching the quote-ERASED skeleton
  # made it exactly backwards (missed quoted real SQL, fired on prose). It is
  # handled by the context-aware block below (content-kept view + SQL client).
)

MATCHED_KEY=""
MATCHED_MSG=""

# Check PATH patterns first (against UNQUOTED) — but ONLY when the quote-ERASED
# skeleton proves a recursive rm is actually executing in command position.
# Without this guard, quoted prose like  echo "(rm -rf /)"  or  echo "x; rm -rf /"
# false-blocks: UNQUOTED keeps quoted content, so a separator inside the quoted
# argument reads as a real subshell rm. The skeleton tells the truth about shell
# structure; the unquoted string is only trusted to resolve WHICH path once
# execution is proven. (All current PATH_PATTERNS are rm-family; a future non-rm
# path pattern would need its own command-position guard.)
if maude_rm_in_command_position "$CMD"; then
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
fi

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

# ── Red-key self-clear backstop (v0.10.0) ────────────────────────────────────
# Claude must not self-authorize a RED gate key by running the clear-script via
# the Bash TOOL (which fires this hook). John's ! line runs in his shell and
# skips PreToolUse, so it is unaffected — that channel asymmetry is the whole
# discriminator. Matched against UNQUOTED so a quoted script path still resolves.
# SOFT: a direct care.json Write bypasses this (the gate is Bash-only, the token
# carries no provenance); the harness deny-rules in .scratch/maude-spine-deny.json
# are the real, unbypassable layer. The 'red-self-clear' block key is itself not
# clearable here (maude-clear-gate.sh refuses unknown keys).
if [ -z "$MATCHED_KEY" ]; then
  for _rk in $(maude_red_keys); do
    if printf '%s' "$UNQUOTED" | grep -qE -- "maude-clear-gate\.sh([[:space:]]+-[^[:space:]]+)*[[:space:]]+${_rk}([[:space:]]|$)"; then
      MATCHED_KEY="red-self-clear"
      MATCHED_MSG="\"$_rk\" is a RED key — Claude cannot self-clear it. This is John's hand: he authorizes by pasting a ! line. See /maude:conscience $_rk for the exact line."
      break
    fi
  done
fi

# ── Red-clear-file write backstop (v0.10.1, net widened v0.13.0) ─────────────
# The dedicated care-redclear.json holds RED clear tokens. Block any Claude Bash
# that writes/relocates it: a REDIRECT or tee (echo/jq/printf > …, >>, | tee),
# OR a mutating/relocating verb naming the file (chattr/chmod/chown/mv/cp/dd/
# install/truncate/ln — the cp/mv/dd "pre-staged token" shapes the v0.10.1 net
# missed). With the harness Write/Edit deny on that path + the red-self-clear
# backstop above, the !-run clear-script (John's shell, no tool-gate) is left the
# clean writer of a red token. Reads (cat/grep) are left alone. Matched against
# UNQUOTED so a quoted path still resolves.
#
# HONEST RESIDUAL — verified, not hand-waved: this is a Bash-pattern net, and the
# gate is the ONLY enforcement here. A determined programmatic write still slips
# it — an interpreter (`python3 -c "open('…/care-redclear.json','w')…"`, perl,
# `sed -i`), or a verb the net doesn't list. There is NO OS lock behind it: on a
# single-uid box the agent process and John's ! line run as the SAME user, so
# file ownership/perms cannot tell them apart — you cannot cage a same-uid peer
# with OS perms, and a fake lock would be theatre. The real discriminator is the
# CHANNEL asymmetry (! skips the tool-gate; the Bash tool does not) plus this
# net + the harness deny + the audit trail. Where the authorizer and the agent
# run as DIFFERENT OS users, standard ownership/perms close this further; on a
# single-uid box they cannot. (See CHANGELOG honest seam.)
if [ -z "$MATCHED_KEY" ]; then
  if printf '%s' "$UNQUOTED" | grep -qE -- '(>>?[[:space:]]*|tee[[:space:]]+)[^[:space:];&|]*care-redclear\.json' ||
     printf '%s' "$UNQUOTED" | grep -qE -- '(^|[[:space:];&|(`])(chattr|chmod|chown|mv|cp|dd|install|truncate|ln)[[:space:]][^;&|]*care-redclear\.json'; then
    MATCHED_KEY="redclear-write"
    MATCHED_MSG="writes to the red-clear token file are blocked. Only John's ! line may authorize a red key (see /maude:conscience)."
  fi
fi

# ── DROP TABLE — only in a SQL-execution context (v0.12.1) ───────────────────
# A real DROP TABLE is passed to a SQL client and lives INSIDE quotes
# (psql -c "DROP TABLE x") or a heredoc — so the quote-ERASED skeleton the
# CMD_PATTERNS use never saw it (it slipped through), while an unquoted prose
# mention (echo DROP TABLE, a commit body) false-blocked. Match the content-KEPT
# view ($UNQUOTED) for "drop table" AND require a known SQL-client token, so
# quoted real SQL is caught and prose / .sql file-authoring is left alone.
# Case-insensitive — `drop table` lowercase is the common script form.
# Known limitation: a heredoc/commit body that mentions BOTH a client name and
# "drop table" fails closed (drop-table is a RED key, conscience-clearable) —
# rare, not chased. Client list intentionally small; extend on real need.
if [ -z "$MATCHED_KEY" ]; then
  if printf '%s' "$UNQUOTED" | grep -qiE -- 'drop[[:space:]]+table' &&
     printf '%s' "$UNQUOTED" | grep -qiE -- '(^|[[:space:];&|(`])(psql|mysql|mariadb|sqlite3|sqlplus)([[:space:]]|$)'; then
    MATCHED_KEY="drop-table"
    MATCHED_MSG="SQL DROP TABLE in an execution context. Run /maude:conscience drop-table to override."
  fi
fi

[ -z "$MATCHED_KEY" ] && exit 0

# Check for a live conscience token for this key. RED keys read from the locked
# care-redclear.json; yellow keys (and synthetic block keys) from care.json.
NOW=$(date +%s)
if maude_is_red_key "$MATCHED_KEY"; then
  CARE="$(maude_redclear_file)"
else
  CARE="$(maude_self_dir)/care.json"
fi
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
