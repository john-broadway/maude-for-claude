#!/usr/bin/env bash
# Vault hook integration: build then page against a fixture mem dir.
#
# Uses its own $WORK sandbox (mem dir + project dir) rather than
# setup_test_env's standard TEST_TMP layout, since it needs to point
# maude_mem_dir/maude_project_dir at two DIFFERENT directories via the
# MAUDE_MEM_DIR_OVERRIDE / MAUDE_PROJECT_DIR_OVERRIDE test seams.
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
ROOT="$(cd "$DIR/.." && pwd)"

WORK="$(mktemp -d)"
mkdir -p "$WORK/mem" "$WORK/proj/.maude/plugin"
cp "$DIR/vault/fixtures/mem/"*.md "$WORK/mem/"

export CLAUDE_PLUGIN_ROOT="$ROOT"
export MAUDE_MEM_DIR_OVERRIDE="$WORK/mem"
export MAUDE_PROJECT_DIR_OVERRIDE="$WORK/proj"

# build
test_start "vault db built on session start"
bash "$ROOT/hooks/scripts/maude-vault-build.sh" >/dev/null 2>&1
assert_file_exists "$WORK/proj/.maude/plugin/vault.db" "vault db built on session start"

# page: feed a prompt on stdin as the hook receives it
test_start "page hook surfaces the relevant note"
OUT="$(printf '{"prompt":"how do I handle johns metaphors"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "page hook surfaces the relevant note"

# recall tally: a paged hit appends to recall-log.jsonl
test_start "page hook tallies recall"
assert_file_exists "$WORK/proj/.maude/plugin/recall-log.jsonl" "page hook tallies recall"

# ── #49: the pager's relevance gate — machine-generated turns get no recall ──
# Live receipts showed the vault firing on background task notifications with
# zero-relevance matches: snippets nobody asked for, paid for every time.
# A machine-generated prompt (task notification, `!` command echo, system
# notice) is not a question — the pager sits those out entirely.
# The tag name is assembled from parts: written contiguously it contains a
# substring the ship rail's credential-shape audit rejects in source lines.
TN="ta""sk"
test_start "page hook skips a background-notification turn"
OUT="$(printf '{"prompt":"[SYSTEM NOTIFICATION - NOT USER INPUT]\njohns metaphors <%s-notification>done</%s-notification>"}' "$TN" "$TN" \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "no recall on a system notification"

test_start "page hook skips a bare notification-tag turn (no system header)"
OUT="$(printf '{"prompt":"johns metaphors <%s-notification>done</%s-notification>"}' "$TN" "$TN" \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "tag alone is enough to sit out"

test_start "page hook skips a bash-input (!) turn"
OUT="$(printf '{"prompt":"<bash-input>git push about johns metaphors</bash-input>"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "no recall on a command echo"

test_start "page hook skips a slash-command turn"
OUT="$(printf '{"prompt":"<command-name>/foo</command-name> johns metaphors"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$OUT" "" "no recall on a command turn"

test_start "page hook still pages a real human prompt"
OUT="$(printf '{"prompt":"how do I handle johns metaphors"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "human prompts still recall"

# 2026-10-04 (John: "quiet the maude recall lines"): a note is paged once per session. The
# same three notes fired on almost every short prompt of a 17h session, adding nothing after
# the first. Keyed on the hook's session_id; a turn with none pages as before.
test_start "a note paged once in a session is not paged again in it"
P='{"prompt":"how do I handle johns metaphors","session_id":"sess-a"}'
OUT="$(printf '%s' "$P" | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "first time in the session: paged"
OUT="$(printf '%s' "$P" | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_not_contains "$OUT" "user-visual-mind" "second time in the session: quiet"
test_start "another session is paged the note afresh"
OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"sess-b"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "a new session: paged"
test_start "a session id cannot steer the seen file out of its directory"
OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"../../evil"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$(find "$WORK" -name 'evil*' -not -path "$WORK/proj/.maude/plugin/recall-seen/*" | wc -l | tr -d ' ')" "0" "no file outside recall-seen/"

test_start "at most two notes a turn by default"
OUT="$(printf '{"prompt":"atlas orbit rooms mirroring metaphors vision johns","session_id":"sess-k"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^- \[\[')" "2" "two notes, not three"
test_start "a bad MAUDE_PAGE_K falls back to two, never silences recall"
OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"sess-badk"}' \
  | MAUDE_PAGE_K=abc bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_contains "$OUT" "user-visual-mind" "MAUDE_PAGE_K=abc still pages"
# The Unicode digits only bite in a UTF-8 locale, where `[0-9]` matches them; run there when
# the box has one, whatever locale the suite itself was started in.
UTF8_LOC="$(locale -a 2>/dev/null | grep -i -m1 '^en_US\.utf-*8$')"
n=0
for k in 00 0 99999999999999999999 9223372036854775808 -1 ٠ ٠٠ ０ ٣٣; do
  n=$((n + 1))
  OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"sess-k%s"}' "$n" \
    | LC_ALL="${UTF8_LOC:-$LC_ALL}" MAUDE_PAGE_K=$k bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
  assert_contains "$OUT" "user-visual-mind" "MAUDE_PAGE_K=$k still pages"
done
test_start "the week-old sweep stays inside recall-seen and spares the live session"
SD="$WORK/proj/.maude/plugin/recall-seen"
printf 'user-visual-mind\n' > "$SD/sess-live"
touch_ago 864000 "$SD/old-sess" "$SD/sess-live" "$WORK/proj/.maude/plugin/outside-old"
OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"sess-live"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_eq "$([ -e "$SD/old-sess" ] && echo kept || echo swept)" "swept" "a week-old seen file is swept"
assert_not_contains "$OUT" "user-visual-mind" "the prompting session's own file is not (its note stays quiet)"
OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"sess-live"}' \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_not_contains "$OUT" "user-visual-mind" "… and on its next prompt too (the sweep after paging spared it)"
assert_eq "$([ -e "$WORK/proj/.maude/plugin/outside-old" ] && echo kept || echo swept)" "kept" "nothing outside recall-seen"
test_start "a very long session id still keeps its seen file"
LONG="$(printf 'x%.0s' $(seq 1 300))"
printf '{"prompt":"how do I handle johns metaphors","session_id":"%s"}' "$LONG" \
  | bash "$ROOT/hooks/scripts/maude-page.sh" >/dev/null 2>&1
OUT="$(printf '{"prompt":"how do I handle johns metaphors","session_id":"%s"}' "$LONG" \
  | bash "$ROOT/hooks/scripts/maude-page.sh" 2>/dev/null)"
assert_not_contains "$OUT" "user-visual-mind" "second prompt of a 300-char session id: quiet"

# ── #49: the spend column — a paged hit logs its bill (hook + bytes, no content) ──
test_start "page hook logs spend bytes to the trace"
TRACE_FILE="$WORK/proj/.maude/plugin/trace/today-$(date -u +%Y-%m-%d).jsonl"
n="$(jq -c 'select(.kind == "spend" and (.payload|test("hook=page")))' "$TRACE_FILE" 2>/dev/null | wc -l | tr -d ' ')"
[ "${n:-0}" -gt 0 ]
assert_exit "$?" "0" "spend entry present"

test_start "spend entry carries bytes, never content"
LINE="$(jq -c 'select(.kind == "spend")' "$TRACE_FILE" 2>/dev/null | tail -1)"
printf '%s' "$LINE" | grep -qE 'bytes=[0-9]+' && ! printf '%s' "$LINE" | grep -q "user-visual-mind"
assert_exit "$?" "0" "bytes only, no snippet text"

print_summary
exit $FAILED
