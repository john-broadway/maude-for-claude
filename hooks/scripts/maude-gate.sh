#!/usr/bin/env bash
# Maude gate hook — fires before Bash. HARD-BLOCKS on irreversible patterns.
# Exits 2 to block; the message goes to the user as the block reason.
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
[ -z "$CMD" ] && exit 0

# Hard-block patterns. Each entry: PATTERN ||| KEY ||| MESSAGE
# KEY is what `/maude:conscience <key>` clears.
# Order matters: most-specific first (force-push before git-push).
PATTERNS=(
  'git push.*--force ||| force-push ||| force-push detected. Public, irreversible. Run /maude:conscience force-push if you have verified.'
  'git push.*--force-with-lease ||| force-push ||| force-push-with-lease detected. Still public-rewriting. Run /maude:conscience force-push if verified.'
  'git push.*-f([[:space:]]|$) ||| force-push ||| force-push (-f). Run /maude:conscience force-push if verified.'
  'git push ||| git-push ||| git push detected. Public, irreversible. Run /maude:conscience git-push to override.'
  '--no-verify ||| no-verify ||| --no-verify skips hooks. Run /maude:conscience no-verify if intentional.'
  '--no-gpg-sign ||| no-gpg-sign ||| --no-gpg-sign skips signing. Run /maude:conscience no-gpg-sign if intentional.'
  'git reset --hard ||| reset-hard ||| git reset --hard loses local work. Run /maude:conscience reset-hard once you have stashed.'
  'git filter-repo ||| filter-repo ||| git filter-repo rewrites history. Run /maude:conscience filter-repo to override.'
  'git filter-branch ||| filter-branch ||| git filter-branch rewrites history. Run /maude:conscience filter-branch to override.'
  'git commit --amend ||| commit-amend ||| git commit --amend rewrites the last commit. If pushed, this needs force-push. Run /maude:conscience commit-amend.'
  'rm -rf / ||| rm-rf-root ||| "rm -rf /" wipes the system. STOP. Run /maude:conscience rm-rf-root only if you really mean it.'
  'rm -rf \* ||| rm-rf-glob ||| "rm -rf *" — wide blast. Run /maude:conscience rm-rf-glob if you mean it.'
  'sudo rm -rf ||| sudo-rm-rf ||| sudo rm -rf is destructive at root. Run /maude:conscience sudo-rm-rf if intentional.'
  'DROP TABLE ||| drop-table ||| SQL DROP TABLE detected. Run /maude:conscience drop-table to override.'
)

MATCHED_KEY=""
MATCHED_MSG=""
for entry in "${PATTERNS[@]}"; do
  PAT="${entry%% ||| *}"
  REST="${entry#* ||| }"
  KEY="${REST%% ||| *}"
  MSG="${REST#* ||| }"
  if printf '%s' "$CMD" | grep -qE -- "$PAT"; then
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
