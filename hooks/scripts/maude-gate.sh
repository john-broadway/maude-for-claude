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
RMRF='rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*f[[:alnum:]]*|-[[:alnum:]]*f[[:alnum:]]*r[[:alnum:]]*)'

# Hard-block patterns. Each entry: PATTERN ||| KEY ||| MESSAGE
# KEY is what `/maude:conscience <key>` clears.
# Order matters: most-specific first (force-push variants before plain git push).
PATTERNS=(
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
  "${CMD_START}${RMRF}[[:space:]]+/${FLAG_AFTER} ||| rm-rf-root ||| \"rm -rf /\" wipes the system. STOP. Run /maude:conscience rm-rf-root only if you really mean it."
  "${CMD_START}${RMRF}[[:space:]]+\\*${FLAG_AFTER} ||| rm-rf-glob ||| \"rm -rf *\" — wide blast. Run /maude:conscience rm-rf-glob if you mean it."
  "${CMD_START}sudo[[:space:]]+${RMRF} ||| sudo-rm-rf ||| sudo rm -rf is destructive at root. Run /maude:conscience sudo-rm-rf if intentional."
  "DROP TABLE ||| drop-table ||| SQL DROP TABLE detected. Run /maude:conscience drop-table to override."
)

MATCHED_KEY=""
MATCHED_MSG=""
for entry in "${PATTERNS[@]}"; do
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

[ -z "$MATCHED_KEY" ] && exit 0

# Check for a live conscience token for this key
NOW=$(date +%s)
CARE="$(maude_self_dir)/care.json"
if [ -f "$CARE" ] && command -v jq >/dev/null 2>&1; then
  CLEARED_UNTIL="$(jq -r --arg k "$MATCHED_KEY" '.gate_cleared[$k].until // 0' "$CARE" 2>/dev/null)"
  if [ -n "$CLEARED_UNTIL" ] && [ "$CLEARED_UNTIL" -gt 0 ] && [ "$CLEARED_UNTIL" -gt "$NOW" ] 2>/dev/null; then
    # Token is live — allow this one through, then clear it
    TMP="$(mktemp 2>/dev/null)" && jq --arg k "$MATCHED_KEY" 'del(.gate_cleared[$k])' "$CARE" > "$TMP" 2>/dev/null && mv "$TMP" "$CARE"
    maude_log_trace "gate" "passed=$MATCHED_KEY"
    exit 0
  fi
fi

# No live token — block
maude_log_trace "gate" "blocked=$MATCHED_KEY"
printf 'Maude: %s\n' "$MATCHED_MSG" >&2
exit 2
