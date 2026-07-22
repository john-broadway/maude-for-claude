#!/usr/bin/env bash
# Tests for hooks/scripts/_maude-common.sh helpers.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env
source_common

# ── maude_project_dir ─────────────────────────────────────────────────
test_start "project_dir respects CLAUDE_PROJECT_DIR"
assert_eq "$(maude_project_dir)" "$TEST_TMP" "project_dir"

test_start "project_dir returns non-empty existing dir when env unset"
# When run from inside Claude Code, the proc-tree walk (step 2) typically finds
# the claude process's cwd before the filesystem walk-up (step 3) runs. So we
# can't cleanly test step 3 from inside a CC session. Instead verify the
# function returns SOMETHING reasonable: a non-empty existing directory.
saved="$CLAUDE_PROJECT_DIR"
unset CLAUDE_PROJECT_DIR
got="$(maude_project_dir)"
export CLAUDE_PROJECT_DIR="$saved"
[ -n "$got" ] && [ -d "$got" ]
assert_exit "$?" "0" "returns existing dir"

# ── maude_slug ────────────────────────────────────────────────────────
test_start "slug replaces non-alphanumerics with dashes"
slug="$(maude_slug)"
assert_not_contains "$slug" "/" "slug has no slashes"

# ── maude_self_dir ────────────────────────────────────────────────────
test_start "self_dir is project_dir/.maude/plugin"
assert_eq "$(maude_self_dir)" "$TEST_TMP/.maude/plugin" "self_dir"

# ── maude_user_dir ────────────────────────────────────────────────────
test_start "user_dir is HOME/.claude/maude"
assert_eq "$(maude_user_dir)" "$HOME/.claude/maude" "user_dir"

# ── maude_log_trace ───────────────────────────────────────────────────
test_start "log_trace writes a JSONL line"
maude_log_trace "test-kind" "test-payload"
assert_file_exists "$(trace_path)" "trace file created"

test_start "trace line has expected fields"
last="$(tail -1 "$(trace_path)")"
assert_contains "$last" '"kind":"test-kind"' "kind field"

test_start "trace payload preserved"
assert_contains "$last" '"payload":"test-payload"' "payload field"

# ── single-clock invariant (characterization — NOT a deterministic regression
# guard) ── maude_trace_file() and `ts` both use UTC, so a record's ts-day always
# equals its filename day. This documents the contract that fixed the v0.1.8
# local-vs-UTC midnight split; it holds BY CONSTRUCTION (one UTC helper). It does
# NOT catch a local-date regression on a normal run — local==UTC except in the
# brief near-midnight window of a non-UTC zone, and CI boxes are UTC — so the
# failing branch is unreachable without an injected clock. The real safety is the
# single source (maude_trace_file), not this assertion's ability to fail.
test_start "trace filename date == the record's UTC ts date"
file_day="$(basename "$(maude_trace_file)" .jsonl)"; file_day="${file_day#today-}"
ts_day="$(printf '%s' "$last" | sed -E 's/.*"ts":"([0-9]{4}-[0-9]{2}-[0-9]{2})T.*/\1/')"
assert_eq "$ts_day" "$file_day" "ts-day matches filename-day"

test_start "maude_trace_file uses the UTC date"
assert_contains "$(maude_trace_file)" "today-$(date -u +%Y-%m-%d).jsonl" "UTC-dated filename"

# ── maude_strip_quotes ───────────────────────────────────────────────
test_start "strip_quotes removes single-quoted span"
got="$(maude_strip_quotes "echo 'git push' done")"
assert_eq "$got" "echo  done" "single-quote strip"

test_start "strip_quotes removes double-quoted span"
got="$(maude_strip_quotes 'echo "hi there" done')"
assert_eq "$got" "echo  done" "double-quote strip"

test_start "strip_quotes removes mixed quotes"
got="$(maude_strip_quotes "echo 'a' \"b\" c")"
assert_eq "$got" "echo   c" "mixed quote strip"

test_start "strip_quotes flattens newlines (heredoc inside double-quotes)"
input='git commit -m "$(cat <<'"'"'EOF'"'"'
mentions git push in body
EOF
)"'
got="$(maude_strip_quotes "$input")"
# After flatten + strip single-quotes, then double-quotes: only `git commit -m ` remains.
assert_not_contains "$got" "git push" "literal scrubbed from heredoc"

test_start "strip_quotes preserves unquoted content"
got="$(maude_strip_quotes "git push origin main")"
assert_eq "$got" "git push origin main" "unquoted preserved"

test_start "strip_quotes handles backslash-escaped double-quote"
got="$(maude_strip_quotes 'echo "say \"hi\""')"
assert_eq "$got" "echo " "escaped quote handled"

# ── maude_match_gate_pattern ─────────────────────────────────────────
test_start "match_gate_pattern matches bare git push"
maude_match_gate_pattern "git push origin" '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "0" "should match git push"

test_start "match_gate_pattern does NOT match git push inside double-quotes"
maude_match_gate_pattern 'git commit -m "do not git push"' '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "1" "should NOT match git push in quotes"

test_start "match_gate_pattern matches after && separator"
maude_match_gate_pattern "cd foo && git push" '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "0" "should match after &&"

test_start "match_gate_pattern does NOT match git pull"
maude_match_gate_pattern "git pull origin" '(^|[;&|(])[[:space:]]*git push([[:space:]]|$)'
assert_exit "$?" "1" "should NOT match git pull"

# ── maude_rm_in_command_position ─────────────────────────────────────
# True iff a recursive rm is actually EXECUTED (command position on the
# quote-erased skeleton), not merely present inside a quoted argument.
test_start "rm_in_command_position true for a bare recursive rm"
maude_rm_in_command_position "rm -rf /srv/app"
assert_exit "$?" "0" "real rm executes"

test_start "rm_in_command_position true even when only the path is quoted"
maude_rm_in_command_position 'rm -rf "/srv/app"'
assert_exit "$?" "0" "rm bare, path quoted, still executes"

test_start "rm_in_command_position true for sudo rm in command position"
maude_rm_in_command_position "sudo rm -R /var/log/x"
assert_exit "$?" "0" "sudo rm executes"

test_start "rm_in_command_position FALSE for rm-rf inside a quoted echo arg"
maude_rm_in_command_position 'echo "danger (rm -rf /) prose"'
assert_exit "$?" "1" "quoted prose is not execution"

test_start "rm_in_command_position FALSE for ; rm -rf inside a quoted commit msg"
maude_rm_in_command_position 'git commit -m "; rm -rf /srv/app"'
assert_exit "$?" "1" "quoted commit msg is not execution"

test_start "rm_in_command_position FALSE for a plain non-rm command"
maude_rm_in_command_position "ls -la /srv/app"
assert_exit "$?" "1" "no rm at all"

# heredoc bodies are DATA — a separator in heredoc prose must not read as a
# real subshell rm (this is the doc/commit-body false-positive the guard fixes).
test_start "rm_in_command_position FALSE for ; rm -rf / in a heredoc body"
maude_rm_in_command_position "git commit -F - <<EOF
fixed bug; rm -rf / no longer fires
EOF"
assert_exit "$?" "1" "heredoc prose is not execution"

test_start "rm_in_command_position FALSE for (rm -rf /) in a heredoc body"
maude_rm_in_command_position "cat > note.txt <<EOF
a destructive (rm -rf /) is fatal
EOF"
assert_exit "$?" "1" "heredoc paren-prose is not execution"

# A real one-line rm has no heredoc — excision is a no-op, it STILL executes.
test_start "rm_in_command_position still TRUE for a real rm with no heredoc"
maude_rm_in_command_position "rm -rf /"
assert_exit "$?" "0" "no heredoc, real rm still executes"

# ── maude_strip_heredocs ─────────────────────────────────────────────
test_start "strip_heredocs removes a quoted-delimiter heredoc body"
got="$(maude_strip_heredocs "cat <<'EOF'
secret rm -rf / body
EOF")"
printf '%s' "$got" | grep -q 'rm -rf'; assert_exit "$?" "1" "body removed"

test_start "strip_heredocs keeps the command line itself"
got="$(maude_strip_heredocs "git commit -F - <<EOF
body line
EOF")"
printf '%s' "$got" | grep -q 'git commit -F -'; assert_exit "$?" "0" "command line kept"

test_start "strip_heredocs is a no-op on a single-line command (no <<)"
# $(...) strips the function's trailing newline — assert the content is intact.
got="$(maude_strip_heredocs "rm -rf /")"
assert_eq "$got" "rm -rf /" "single line preserved"

test_start "strip_heredocs does not treat arithmetic << as a heredoc"
got="$(maude_strip_heredocs "x=\$((1 << 2)); echo done")"
printf '%s' "$got" | grep -q 'echo done'; assert_exit "$?" "0" "arithmetic shift kept"

# ── maude_have_remember / maude_have_map ─────────────────────────────
test_start "have_remember is false in fresh test env"
maude_have_remember
assert_exit "$?" "1" "no .remember dir"

test_start "have_map is false in fresh test env"
maude_have_map
assert_exit "$?" "1" "no house-map"

mkdir -p "$TEST_TMP/.remember"
test_start "have_remember is true after creating .remember/"
maude_have_remember
assert_exit "$?" "0" "remember exists"

# ── maude_tier1_up ───────────────────────────────────────────────────
test_start "tier1_up false when no care.json"
maude_tier1_up
assert_exit "$?" "1" "no care.json"

test_start "tier1_up false when care.json says down"
printf '{"tier1_up":false,"tier1_last_probe":%d}\n' "$(date +%s)" > "$TEST_TMP/.maude/plugin/care.json"
maude_tier1_up
assert_exit "$?" "1" "tier1 marked down"

test_start "tier1_up true when care.json says up and probe fresh"
printf '{"tier1_up":true,"tier1_last_probe":%d}\n' "$(date +%s)" > "$TEST_TMP/.maude/plugin/care.json"
maude_tier1_up
assert_exit "$?" "0" "tier1 marked up + fresh"

test_start "tier1_up false when probe stale"
printf '{"tier1_up":true,"tier1_last_probe":1}\n' > "$TEST_TMP/.maude/plugin/care.json"
maude_tier1_up
assert_exit "$?" "1" "tier1 stale"

# ── maude_care_ensure (R2: a corrupt care.json reseed must be RECORDED, not a ──
# silent wipe of the shared-state file — tier1 cache, gate_cleared, cooldowns) ──
CARE_E="$TEST_TMP/.maude/plugin/care.json"

test_start "care_ensure seeds {} when care.json is missing"
rm -f "$CARE_E"
maude_care_ensure "$CARE_E"
assert_eq "$(jq -rc . "$CARE_E" 2>/dev/null)" "{}" "missing → {}"

test_start "care_ensure seeds {} when care.json is empty"
: > "$CARE_E"
maude_care_ensure "$CARE_E"
assert_eq "$(jq -rc . "$CARE_E" 2>/dev/null)" "{}" "empty → {}"

test_start "care_ensure PRESERVES a valid care.json (foreign keys survive)"
printf '{"gate_cleared":{"git-push":{"until":999}},"tier1_up":true}\n' > "$CARE_E"
maude_care_ensure "$CARE_E"
assert_eq "$(jq -r '.gate_cleared["git-push"].until' "$CARE_E" 2>/dev/null)" "999" "valid untouched"

test_start "care_ensure reseeds a CORRUPT care.json to {}"
printf 'this is not json {{{\n' > "$CARE_E"
maude_care_ensure "$CARE_E"
assert_eq "$(jq -rc . "$CARE_E" 2>/dev/null)" "{}" "corrupt → {}"

test_start "care_ensure RECORDS the corrupt reseed in the trace (not silent)"
: > "$(trace_path)"
printf 'still not json {{{\n' > "$CARE_E"
maude_care_ensure "$CARE_E"
assert_contains "$(cat "$(trace_path)" 2>/dev/null)" '"kind":"care"' "loss traced"

test_start "care_ensure stays silent on stderr when it cannot write (no redirect leak)"
rm -rf "$CARE_E"; mkdir -p "$CARE_E"   # an unwritable path (a directory) — reseed can't write
err="$(maude_care_ensure "$CARE_E" 2>&1 >/dev/null)"
rm -rf "$CARE_E"
assert_eq "$err" "" "no stderr leak on write failure"

# ── maude_care_set (shared atomic care.json write; returns status) ──
test_start "care_set writes a key and returns success"
printf '{}\n' > "$CARE_E"
maude_care_set "$CARE_E" --arg v "hi" '.foo = $v'; rc=$?
assert_eq "$rc" "0" "returns 0 on success"

test_start "care_set persisted the value"
assert_eq "$(jq -r '.foo' "$CARE_E" 2>/dev/null)" "hi" "value written"

test_start "care_set merges — preserves existing keys"
printf '{"keep":1}\n' > "$CARE_E"
maude_care_set "$CARE_E" --arg v "x" '.foo = $v'
assert_eq "$(jq -r '.keep' "$CARE_E" 2>/dev/null)" "1" "existing key kept"

test_start "care_set returns failure when the write can't happen"
rm -rf "$CARE_E"; mkdir -p "$CARE_E"   # care.json is a directory → jq can't read/write it
maude_care_set "$CARE_E" '.foo = 1'; rc=$?
rm -rf "$CARE_E"
assert_eq "$rc" "1" "returns 1 on write failure"

# ── maude_bucket_for_hour (pure: hour int → time-of-day bucket) ───────
test_start "bucket_for_hour 4 is night (pre-dawn)"
assert_eq "$(maude_bucket_for_hour 4)" "night" "h=4"

test_start "bucket_for_hour 5 is morning (lower morning boundary)"
assert_eq "$(maude_bucket_for_hour 5)" "morning" "h=5"

test_start "bucket_for_hour 08 (leading zero) is morning"
assert_eq "$(maude_bucket_for_hour 08)" "morning" "h=08 base-10"

test_start "bucket_for_hour 11 is morning (upper morning boundary)"
assert_eq "$(maude_bucket_for_hour 11)" "morning" "h=11"

test_start "bucket_for_hour 12 is afternoon (lower afternoon boundary)"
assert_eq "$(maude_bucket_for_hour 12)" "afternoon" "h=12"

test_start "bucket_for_hour 16 is afternoon (upper afternoon boundary)"
assert_eq "$(maude_bucket_for_hour 16)" "afternoon" "h=16"

test_start "bucket_for_hour 17 is evening (lower evening boundary)"
assert_eq "$(maude_bucket_for_hour 17)" "evening" "h=17"

test_start "bucket_for_hour 20 is evening (upper evening boundary)"
assert_eq "$(maude_bucket_for_hour 20)" "evening" "h=20"

test_start "bucket_for_hour 21 is night (lower night boundary)"
assert_eq "$(maude_bucket_for_hour 21)" "night" "h=21"

test_start "bucket_for_hour 23 is night"
assert_eq "$(maude_bucket_for_hour 23)" "night" "h=23"

test_start "bucket_for_hour 00 (midnight, leading zero) is night"
assert_eq "$(maude_bucket_for_hour 00)" "night" "h=00 base-10"

# ── maude_greeting_for_bucket (pure: bucket → greeting word) ──────────
test_start "greeting_for_bucket morning"
assert_eq "$(maude_greeting_for_bucket morning)" "Morning." "morning greeting"

test_start "greeting_for_bucket afternoon"
assert_eq "$(maude_greeting_for_bucket afternoon)" "Afternoon." "afternoon greeting"

test_start "greeting_for_bucket evening"
assert_eq "$(maude_greeting_for_bucket evening)" "Evening." "evening greeting"

test_start "greeting_for_bucket night is non-empty and warm"
assert_contains "$(maude_greeting_for_bucket night)" "here" "night greeting present"

test_start "greeting_for_bucket unknown is empty (no false time word)"
assert_eq "$(maude_greeting_for_bucket unknown)" "" "unknown → no greeting"

# ── maude_user_tz (reads house-map timezone; empty when unverified) ───
test_start "user_tz empty when no house-map exists"
assert_eq "$(maude_user_tz)" "" "no map → no tz"

mkdir -p "$TEST_TMP/.maude/plugin"
test_start "user_tz reads timezone from house-map"
printf '## Clock\ntimezone: America/Chicago\n' > "$(maude_map_path)"
assert_eq "$(maude_user_tz)" "America/Chicago" "map tz read"

test_start "user_tz reads 'system' sentinel"
printf '## Clock\ntimezone: system\n' > "$(maude_map_path)"
assert_eq "$(maude_user_tz)" "system" "system sentinel"

test_start "user_tz treats placeholder as unset"
printf '## Clock\ntimezone: <none>\n' > "$(maude_map_path)"
assert_eq "$(maude_user_tz)" "" "placeholder → empty"

# ── maude_time_of_day (composes; 'unknown' when tz unverified) ────────
test_start "time_of_day is 'unknown' when no tz configured"
rm -f "$(maude_map_path)"
assert_eq "$(maude_time_of_day)" "unknown" "no tz → unknown"

test_start "time_of_day returns a real bucket when tz=system"
printf '## Clock\ntimezone: system\n' > "$(maude_map_path)"
tod="$(maude_time_of_day)"
assert_ne "$tod" "unknown" "system tz → not unknown"

test_start "time_of_day bucket matches box clock under tz=system"
assert_eq "$tod" "$(maude_bucket_for_hour "$(date +%H)")" "system bucket matches date"

# ── maude_local_time_str (empty when unverified) ─────────────────────
test_start "local_time_str empty when no tz configured"
rm -f "$(maude_map_path)"
assert_eq "$(maude_local_time_str)" "" "no tz → empty"

test_start "local_time_str non-empty when tz=system"
printf '## Clock\ntimezone: system\n' > "$(maude_map_path)"
assert_contains "$(maude_local_time_str)" ":" "has HH:MM"

# ── maude_greeting (THE anti-bug: silent when clock unverified) ───────
test_start "greeting is EMPTY when timezone unknown (never guess time)"
rm -f "$(maude_map_path)"
assert_eq "$(maude_greeting)" "" "unverified clock → no time word"

test_start "greeting is non-empty when tz is configured"
printf '## Clock\ntimezone: system\n' > "$(maude_map_path)"
assert_ne "$(maude_greeting)" "" "configured clock → greeting"

# ── redteam v0.1.8 hardening ──────────────────────────────────────────
test_start "user_tz strips a trailing inline comment (else TZ falls back to UTC)"
printf '## Clock\ntimezone: America/Chicago  # my real tz\n' > "$(maude_map_path)"
assert_eq "$(maude_user_tz)" "America/Chicago" "inline comment stripped"

test_start "user_tz strips inline comment after the system sentinel"
printf '## Clock\ntimezone: system   # box clock is right\n' > "$(maude_map_path)"
assert_eq "$(maude_user_tz)" "system" "system + comment"

test_start "bucket_for_hour tolerates non-numeric input without stderr noise"
err="$(maude_bucket_for_hour "abc" 2>&1 >/dev/null)"
assert_eq "$err" "" "no arithmetic error on garbage"

test_start "bucket_for_hour returns a valid bucket for non-numeric input"
assert_contains "morning afternoon evening night" "$(maude_bucket_for_hour abc)" "garbage → some bucket"

# ── tz typo guard (a mistyped IANA zone must NOT silently become UTC) ──
# date accepts a bogus TZ and falls back to UTC → a confident wrong greeting,
# the exact failure v0.1.8 exists to prevent. The guard rejects a value ONLY
# when the zoneinfo DB is present AND has no such zone (provably bad). On a box
# without the DB it can't prove bad, so a valid zone is passed through.
test_start "user_tz rejects a typo zone when zoneinfo proves it bad"
printf '## Clock\ntimezone: America/Chigago\n' > "$(maude_map_path)"
if [ -d /usr/share/zoneinfo ]; then
  assert_eq "$(maude_user_tz)" "" "typo zone → empty (never UTC fallback)"
else
  assert_eq "$(maude_user_tz)" "America/Chigago" "no zoneinfo DB → can't prove bad, pass through"
fi

test_start "user_tz still returns a valid zone the DB confirms"
printf '## Clock\ntimezone: America/Chicago\n' > "$(maude_map_path)"
assert_eq "$(maude_user_tz)" "America/Chicago" "valid zone survives the guard"

# ── TZ-conversion branch (was untested — only `system` was exercised) ──
test_start "non-system tz actually converts vs UTC (not a silent UTC fallback)"
if [ -f /usr/share/zoneinfo/Etc/GMT-5 ]; then
  printf '## Clock\ntimezone: Etc/GMT-5\n' > "$(maude_map_path)"
  loc_h="$(maude_local_time_str)"; loc_h="${loc_h%%:*}"
  utc_h="$(date -u +%H)"
  exp_h="$(printf '%02d' $(( (10#$utc_h + 5) % 24 )))"   # Etc/GMT-5 is UTC+5
  assert_eq "$loc_h" "$exp_h" "Etc/GMT-5 = UTC+5 applied by maude_local_time_str"
else
  assert_eq "skip" "skip" "Etc/GMT-5 unavailable — conversion test skipped"
fi

# ── maude_redact: every secret-shape branch masks (regression guard) ──
# Each sed alternative breaks independently; pin them all. Secret prefixes are
# split in source ("sk" "-") so no scanner-matchable token literal is committed.
redact_one() { printf '%s\n' "$1" | maude_redact; }

test_start "redact masks sk- API keys"
SK="sk""-abcdefgh12345678ABCDEF"
assert_contains "$(redact_one "key $SK end")" "[redacted-secret]" "sk- masked"
test_start "redact removes the raw sk- token"
assert_not_contains "$(redact_one "key $SK end")" "$SK" "raw sk- gone"

test_start "redact masks github_pat_ tokens"
GP="github_pat_""abcdefgh12345678ABCDEF"
assert_contains "$(redact_one "t $GP end")" "[redacted-secret]" "github_pat_ masked"

test_start "redact masks xoxb- slack tokens"
XO="xoxb""-abcdefgh12345678ABCDEF"
assert_contains "$(redact_one "t $XO end")" "[redacted-secret]" "xoxb- masked"

test_start "redact masks AWS AKIA access-key ids"
AK="AKIA""ABCDEFGH12345678IJKL"
assert_contains "$(redact_one "id $AK end")" "[redacted-secret]" "AKIA masked"

test_start "redact masks Google AIza keys"
AZ="AIza""abcdefgh12345678ABCDEF"
assert_contains "$(redact_one "k $AZ end")" "[redacted-secret]" "AIza masked"

test_start "redact masks JWTs"
JWT="eyJ""abcDEF123.eyJpayload456.sigGHI789"
assert_contains "$(redact_one "tok $JWT end")" "[redacted-jwt]" "JWT masked"
test_start "redact removes the raw JWT"
assert_not_contains "$(redact_one "tok $JWT end")" "$JWT" "raw JWT gone"

test_start "redact leaves ordinary prose untouched"
assert_eq "$(redact_one "just a normal sentence about keys and tokens")" "just a normal sentence about keys and tokens" "no over-redaction"

test_start "redact masks bounded-octet IPv4 addresses"
assert_contains "$(redact_one "built ledger at 192.0.2.71")" "[redacted-ip]" "IPv4 masked"
test_start "redact removes the raw IPv4 address"
assert_not_contains "$(redact_one "built ledger at 192.0.2.71")" "192.0.2.71" "raw IPv4 gone"

test_start "redact leaves Chrome version strings untouched"
assert_eq "$(redact_one "Chrome version 120.0.6099.109")" "Chrome version 120.0.6099.109" "over-255 octets survive"

test_start "redact leaves Windows version strings untouched"
assert_eq "$(redact_one "Windows 10.0.19045.3803")" "Windows 10.0.19045.3803" "over-255 octets survive"

# ── Slug consistency: the memory-dir slug is INLINED into ~13 command .md files
# rather than calling maude_slug(). The root cause of the v0.3.0 "computed two ways"
# bug (dotted paths reading nothing) is that duplication — the fix synced the copies
# but left them as copies. This guard fails if any command's inline transform drifts
# from the canonical one in _maude-common.sh, so a future edit can't desync silently.
test_start "the canonical slug transform is found in _maude-common.sh"
CANON="$(sed -n "s/.*| sed '\([^']*\)'.*/\1/p" "$HOOKS_DIR/_maude-common.sh" | grep 'a-zA-Z0-9' | head -1)"
[ -n "$CANON" ]
assert_exit "$?" "0" "canonical transform present"

bad=""
for f in "$MAUDE_ROOT"/commands/*.md; do
  while IFS= read -r line; do
    case "$line" in
      *SLUG=*sed*)
        expr="$(printf '%s' "$line" | sed -n "s/.*sed '\([^']*\)'.*/\1/p")"
        if [ -n "$expr" ] && [ "$expr" != "$CANON" ]; then
          bad="$bad $(basename "$f")[$expr]"
        fi
        ;;
    esac
  done < "$f"
done
test_start "no command inlines a non-canonical slug transform"
[ -z "$bad" ]
assert_exit "$?" "0" "all command slugs canonical${bad:+ — DRIFT:$bad}"

# ── Public-facing publish commands (present regardless of config) ─────────────
test_start "public-publish regex matches gh release create"
printf 'gh release create v1' | grep -qE -- "$(maude_public_publish_re)"
assert_exit "$?" "0" "gh release"

test_start "public-publish regex matches uv publish"
printf 'uv publish' | grep -qE -- "$(maude_public_publish_re)"; assert_exit "$?" "0" "uv publish"

test_start "public-publish regex matches twine upload"
printf 'twine upload dist/*' | grep -qE -- "$(maude_public_publish_re)"; assert_exit "$?" "0" "twine"

test_start "public-publish regex matches hf upload"
printf 'hf upload repo file' | grep -qE -- "$(maude_public_publish_re)"; assert_exit "$?" "0" "hf"

test_start "public-publish regex does NOT match a plain git commit"
printf 'git commit -m hi' | grep -qE -- "$(maude_public_publish_re)"; assert_exit "$?" "1" "commit safe"

test_start "public-publish regex matches huggingface-cli upload"
printf 'huggingface-cli upload repo file' | grep -qE -- "$(maude_public_publish_re)"
assert_exit "$?" "0" "huggingface-cli upload"

test_start "public-publish regex does NOT match gh pr create"
printf 'gh pr create' | grep -qE -- "$(maude_public_publish_re)"
assert_exit "$?" "1" "gh pr create safe"

# ── Config-driven gate palette ───────────────────────────────────────────
GCFG="$TEST_TMP/gate-config.json"
printf '{"sole_copy_paths":["/srv/data"],"infra_destructive_tools":["delete_thing","wipe_store"],"infra_tool_prefix":"mcp__testsrv__","infra_sandbox_nodes":["test-node-a"],"infra_sandbox_vmids":["9001"]}\n' > "$GCFG"

test_start "sole-copy includes generic default ~/.claude"
maude_sole_copy_targets | grep -qF '.claude'; assert_exit "$?" "0" "default .claude"
test_start "sole-copy includes a config path"
maude_sole_copy_targets | grep -qF '/srv/data'; assert_exit "$?" "0" "config path present"
test_start "destructive tools come from config"
assert_eq "$(maude_infra_destructive_tools)" "delete_thing wipe_store" "tools from config"
test_start "tool prefix from config"
assert_eq "$(maude_infra_tool_prefix)" "mcp__testsrv__" "prefix from config"
test_start "comanage true for config sandbox node"
maude_is_comanage_target "test-node-a" ""; assert_exit "$?" "0" "sandbox node"
test_start "comanage true for config sandbox vmid"
maude_is_comanage_target "" "9001"; assert_exit "$?" "0" "sandbox vmid"
test_start "comanage false for unlisted target"
maude_is_comanage_target "prod-x" "1"; assert_exit "$?" "1" "not sandbox"

rm -f "$GCFG"   # now exercise no-config (generic defaults / inert)
test_start "no config → infra tools EMPTY (gate inert)"
assert_eq "$(maude_infra_destructive_tools)" "" "empty without config"
test_start "no config → comanage fails closed"
maude_is_comanage_target "anything" "1"; assert_exit "$?" "1" "fail-closed no config"
test_start "no config → sole-copy still has generic defaults"
maude_sole_copy_targets | grep -qF '.claude'; assert_exit "$?" "0" "defaults survive"

test_start "canon_path_view collapses repeated slashes"
assert_eq "$(maude_canon_path_view 'rm -rf /srv//app')" "rm -rf /srv/app" "//-collapse"

test_start "canon_path_view collapses triple slashes"
assert_eq "$(maude_canon_path_view 'rm -rf /srv///app')" "rm -rf /srv/app" "///-collapse"

# ── maude_canon_path_view: .. resolution (Task 3) ────────────────────────────
test_start "canon resolves middle .. (keeps the safe segment)"
assert_eq "$(maude_canon_path_view 'rm -rf /tmp/x/../safe')" "rm -rf /tmp/safe" "mid-dotdot"

test_start "canon resolves trailing .. to parent (/tmp/.. -> /)"
assert_eq "$(maude_canon_path_view 'rm -rf /tmp/..')" "rm -rf /" "trailing-dotdot-root"

test_start "canon resolves chained .. correctly"
assert_eq "$(maude_canon_path_view 'rm -rf /a/b/../../etc')" "rm -rf /etc" "chain-dotdot"

test_start "canon leaves a non-dotdot path untouched"
assert_eq "$(maude_canon_path_view 'rm -rf /srv/app/project')" "rm -rf /srv/app/project" "no-op"

test_start "canon leaves leading /../b as residue (no over-pop into false /-match)"
assert_eq "$(maude_canon_path_view 'rm -rf /../b')" "rm -rf /../b" "beyond-root-residue"

# ── maude_wrapped_payloads / maude_has_opaque_wrap (Task 7) ──────────────────
test_start "wrapped_payloads extracts single-quoted bash -c body"
assert_eq "$(maude_wrapped_payloads "bash -c 'rm -rf /'")" "rm -rf /" "sq-payload"

test_start "wrapped_payloads extracts double-quoted literal (no \$)"
assert_eq "$(maude_wrapped_payloads 'sh -c "git push --force"')" "git push --force" "dq-literal"

test_start "wrapped_payloads handles -lc and trailing args"
assert_eq "$(maude_wrapped_payloads "bash -lc 'rm -rf /' arg0")" "rm -rf /" "lc-trailing"

test_start "wrapped_payloads extracts eval single-quoted body"
assert_eq "$(maude_wrapped_payloads "eval 'rm -rf /'")" "rm -rf /" "eval-sq"

test_start "wrapped_payloads SKIPS interpolated double-quote (under-extract)"
assert_eq "$(maude_wrapped_payloads 'bash -c "rm -rf $VAR"')" "" "interp-skipped"

test_start "has_opaque_wrap true for interpolated payload"
maude_has_opaque_wrap 'bash -c "rm -rf $VAR"'; assert_exit "$?" "0" "opaque-interp"

test_start "has_opaque_wrap true for eval \$X"
maude_has_opaque_wrap 'eval "$DYNAMIC"'; assert_exit "$?" "0" "opaque-eval-var"

test_start "has_opaque_wrap false for single-quoted literal"
maude_has_opaque_wrap "bash -c 'ls'"; assert_exit "$?" "1" "literal-not-opaque"

# Task 8 carry-forward: bare-word (unquoted) token after -c / eval is also opaque
test_start "has_opaque_wrap true for bare bash -c \$CMD"
maude_has_opaque_wrap 'bash -c $CMD'; assert_exit "$?" "0" "opaque-bare-cmd"

test_start "has_opaque_wrap true for bare eval \$CMD"
maude_has_opaque_wrap 'eval $CMD'; assert_exit "$?" "0" "opaque-eval-bare"

# Pin intentional bareword whisper: an unquoted bareword after eval/-c is opaque
# (it is not inspected by maude_wrapped_payloads) and must surface via the whisper.
# Cost: benign whisper on harmless `eval ls`. This test owns that behavior.
test_start "has_opaque_wrap true for bare eval ls (bareword is opaque; benign whisper cost)"
maude_has_opaque_wrap 'eval ls'; assert_exit "$?" "0" "opaque-eval-bareword"

# ── maude_session_label — ties commentary to the session that produced it ──
# Under a concurrent fleet (several Claude sessions sharing one project root),
# every aggregate surface needs to know WHICH session an event came from.
test_start "session label: explicit MAUDE_SESSION_LABEL wins"
LBL="$(MAUDE_SESSION_LABEL=pacioli maude_session_label)"
assert_eq "$LBL" "pacioli" "env override"

test_start "session label: an explicitly passed envelope session_id wins over env"
LBL="$(CLAUDE_CODE_SESSION_ID=99999999-x maude_session_label d8671962-81c6-4b86)"
assert_eq "$LBL" "d8671962" "envelope sid prefix"

test_start "session label: falls back to the harness CLAUDE_CODE_SESSION_ID env"
LBL="$(CLAUDE_CODE_SESSION_ID=d8671962-81c6-4b86 maude_session_label)"
assert_eq "$LBL" "d8671962" "env sid prefix"

test_start "session label: solo when nothing identifies the session"
LBL="$(maude_session_label)"
assert_eq "$LBL" "solo" "solo fallback"

test_start "log_trace records the session label"
: > "$(trace_path)"
( export MAUDE_SESSION_LABEL="hub"; maude_log_trace "verify" "stop" )
assert_contains "$(tail -1 "$(trace_path)")" '"session":"hub"' "session on trace entry"

# ── #49: the token ledger — spend entries: hook + bytes, metadata only ──
test_start "log_spend writes a spend entry with hook and bytes"
: > "$(trace_path)"
maude_log_spend "page" 512
assert_contains "$(tail -1 "$(trace_path)")" '"payload":"hook=page bytes=512"' "spend recorded"

test_start "log_spend refuses zero bytes (no bill for silence)"
: > "$(trace_path)"
maude_log_spend "page" 0
[ ! -s "$(trace_path)" ]
assert_exit "$?" "0" "no entry for zero"

test_start "log_spend refuses garbage byte counts"
: > "$(trace_path)"
maude_log_spend "page" "abc"
[ ! -s "$(trace_path)" ]
assert_exit "$?" "0" "no entry for non-numeric"

print_summary
teardown_test_env
exit $FAILED
