#!/usr/bin/env bash
# tests/test-self-check.sh — maude-self-check.sh: the wake-time installed-vs-source
# drift whisper (born of the 10-day stale-install trap, 2026-08-08).
#
# Fixture: two fake plugin dirs (an "installed" ROOT and a "source" SRC), driven
# via CLAUDE_PLUGIN_ROOT + MAUDE_SOURCE_DIR so discovery never touches the real
# marketplace record. Every case asserts BOTH the exit code (always 0 — a
# whisper must never block a session start) and the message (or its absence —
# a probe that prints the same thing either way is not a check).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
setup_test_env
# The hook reads the harness's own switches and config dir; a caller exporting any of them
# changed three rows' verdicts (lens 6). lib.sh strips MAUDE_*/SHIP_* only, so these go here.
unset CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER DISABLE_UPDATES CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC FORCE_AUTOUPDATE_PLUGINS

CHECK="$HOOKS_DIR/maude-self-check.sh"

mkplugin() {  # dir version
  mkdir -p "$1/.claude-plugin" "$1/hooks/scripts"
  printf '{"name":"maude","version":"%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\n' > "$1/hooks/scripts/stub.sh"
}

ROOTD="$TEST_TMP/installed"
SRCD="$TEST_TMP/source"

run_check() {  # rootdir srcdir [extra env assignments via caller export]
  OUT="$(CLAUDE_PLUGIN_ROOT="$1" MAUDE_SOURCE_DIR="$2" bash "$CHECK" 2>&1)"
  RC=$?
}

# ── versions differ → "update is waiting" ───────────────────────────────
mkplugin "$ROOTD" "0.26.0"
mkplugin "$SRCD"  "0.27.0"
test_start "self-check whispers when source version is ahead"
run_check "$ROOTD" "$SRCD"
assert_exit "$RC" "0" "whisper never blocks"
assert_contains "$OUT" "update is waiting" "version-diff message"

# ── versions EQUAL but files differ → the 10-day trap message ────────────
rm -rf "$ROOTD" "$SRCD"
mkplugin "$ROOTD" "0.27.0"
mkplugin "$SRCD"  "0.27.0"
printf 'new organ\n' > "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check names version-keyed drift (same version, files differ)"
run_check "$ROOTD" "$SRCD"
assert_exit "$RC" "0" "whisper never blocks"
assert_contains "$OUT" "NEVER auto-deliver" "unbumped-drift message"

# ── identical → silent ───────────────────────────────────────────────────
rm -f "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check is SILENT when installed matches source"
run_check "$ROOTD" "$SRCD"
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── dev checkout (ROOT == SRC) → silent ──────────────────────────────────
test_start "self-check is SILENT running from the source checkout itself"
run_check "$SRCD" "$SRCD"
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── no source discoverable → silent (a guess is worse than nothing) ──────
test_start "self-check is SILENT with no source dir on this machine"
OUT="$(CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$TEST_TMP/nope" HOME="$TEST_TMP/nohome" bash "$CHECK" 2>&1)"
RC=$?
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── eye recursion guard: inert inside a blink ────────────────────────────
# Drift is planted FIRST so the un-guarded script WOULD whisper — silence on
# a clean diff proves nothing (measured: the working tree masked exactly this
# behind the dev-checkout short-circuit while the archive failed).
printf 'drift\n' > "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check is SILENT under an eye blink (recursion guard)"
OUT="$(CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$SRCD" MAUDE_EYE_BLINK=1 bash "$CHECK" 2>&1)"
RC=$?
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence under blink, got: $OUT"; fi

# ── kill switch ──────────────────────────────────────────────────────────
printf 'drift\n' > "$SRCD/hooks/scripts/new-organ.sh"
test_start "self-check honors MAUDE_SELF_CHECK=off"
OUT="$(CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$SRCD" MAUDE_SELF_CHECK=off bash "$CHECK" 2>&1)"
RC=$?
assert_exit "$RC" "0" "silent exit 0"
if [ -z "$OUT" ]; then _pass; else _fail "expected silence, got: $OUT"; fi

# ── the auto-update whisper: a remote marketplace nobody switched on ────────
# Claude Code's own "Plugin updated: maude · Run /reload-plugins to apply" line
# is the only update notice a plugin ever gets, and it fires only for a
# marketplace with auto-update on; that is off by default for every marketplace
# that is not Anthropic's. Fixture: a fake $HOME with the harness's two records.
# The harness takes autoUpdate from the settings scopes merged (project-local
# over project over user: a scope's `maude` entry replaces the lower one WHOLE),
# else from the known_marketplaces.json record. A boolean there, true or false,
# is a choice somebody made and she says nothing; the whisper is for the switch
# nobody has touched. Records live under CLAUDE_CONFIG_DIR when it is set.
# Hostile names on purpose: a space and an apostrophe in both, so an unquoted expansion in
# the hook goes red here instead of on an adopter's box (lens 7: no fixture had either).
HOMED="$TEST_TMP/ho me's"; PROJD="$TEST_TMP/pro j'ect"
km() {  # <source-json> [autoUpdate-json]
  mkdir -p "$HOMED/.claude/plugins"
  if [ -n "${2:-}" ]; then
    printf '{"maude":{"source":%s,"installLocation":"/x","autoUpdate":%s}}\n' "$1" "$2"
  else
    printf '{"maude":{"source":%s,"installLocation":"/x"}}\n' "$1"
  fi > "$HOMED/.claude/plugins/known_marketplaces.json"
}
settings() {  # <file> [autoUpdate-json]  (no second arg: an entry with no key)
  mkdir -p "$(dirname "$1")"
  if [ -n "${2:-}" ]; then
    printf '{"extraKnownMarketplaces":{"maude":{"source":{"source":"github","repo":"o/r"},"autoUpdate":%s}}}\n' "$2"
  else
    printf '{"extraKnownMarketplaces":{"maude":{"source":{"source":"github","repo":"o/r"}}}}\n'
  fi > "$1"
}
GH='{"source":"github","repo":"john-broadway/maude-for-claude"}'
reset_home() { rm -rf "$HOMED" "$PROJD"; mkdir -p "$HOMED" "$PROJD"; }
# Every run pins HOME and the project to the fixture and strips the harness's own
# switches from the caller's shell (lens 1: a box exporting DISABLE_AUTOUPDATER went
# 8 red). stdout and stderr are kept APART: the whisper is the brief Claude reads on
# stdout, and a copy sent to stderr passed a `2>&1` capture (lens 1, BLOCKING).
run_au() {  # [VAR=val …]
  ERR="$TEST_TMP/au.err"
  OUT="$(env -u DISABLE_AUTOUPDATER -u DISABLE_UPDATES -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC \
             -u FORCE_AUTOUPDATE_PLUGINS -u CLAUDE_CONFIG_DIR "$@" \
             HOME="$HOMED" CLAUDE_PROJECT_DIR="$PROJD" CLAUDE_PLUGIN_ROOT="$ROOTD" MAUDE_SOURCE_DIR="$TEST_TMP/nope" \
             bash "$CHECK" 2>"$ERR")"
  RC=$?
}
assert_whisper() {
  assert_exit "$RC" "0" "whisper never blocks"; assert_contains "$OUT" "auto-update is off" "$1"
  if [ ! -s "$ERR" ]; then _pass; else _fail "stderr must stay empty, got: $(cat "$ERR")"; fi
}
assert_quiet() {
  assert_exit "$RC" "0" "silent exit 0"
  if [ -z "$OUT" ] && [ ! -s "$ERR" ]; then _pass; else _fail "expected silence, got: $OUT $(cat "$ERR")"; fi
}

reset_home; km "$GH"
test_start "github marketplace, auto-update never chosen → whispers, names the switch"
run_au; assert_whisper "names the off switch"
assert_contains "$OUT" "Enable auto-update" "hands the user the menu label"
assert_contains "$OUT" "Plugin updated: maude" "says what they will see afterwards"

test_start "git and url sources whisper the same"
km '{"source":"git","url":"https://example.invalid/maude.git"}'; run_au; assert_whisper "git source"
km '{"source":"url","url":"https://example.invalid/marketplace.json"}'; run_au; assert_whisper "url source"

test_start "known_marketplaces autoUpdate true → silent"
km "$GH" true; run_au; assert_quiet

test_start "known_marketplaces autoUpdate false → silent (the user chose)"
km "$GH" false; run_au; assert_quiet

test_start "user settings true beats a missing km key → silent"
km "$GH"; settings "$HOMED/.claude/settings.json" true; run_au; assert_quiet

test_start "an explicit false in user settings is a choice → silent"
km "$GH"; settings "$HOMED/.claude/settings.json" false; run_au; assert_quiet

test_start "project and project-local settings count too"
reset_home; km "$GH"; settings "$PROJD/.claude/settings.json" true; run_au; assert_quiet
reset_home; km "$GH"; settings "$PROJD/.claude/settings.local.json" false; run_au; assert_quiet

test_start "a higher scope's entry replaces the lower one whole (the harness's merge)"
reset_home; km "$GH"; settings "$HOMED/.claude/settings.json" true; settings "$PROJD/.claude/settings.json"
run_au; assert_whisper "project entry without the key hides the user's true"
settings "$PROJD/.claude/settings.local.json" true; run_au; assert_quiet
reset_home; km "$GH" true; settings "$PROJD/.claude/settings.json"; run_au; assert_quiet

test_start "CLAUDE_CONFIG_DIR relocates both records"
reset_home; CFGD="$TEST_TMP/cfg"; mkdir -p "$CFGD/plugins" "$HOMED/.claude/plugins"
printf '{"maude":{"source":%s,"installLocation":"/x"}}\n' "$GH" > "$CFGD/plugins/known_marketplaces.json"
printf '{"maude":{"source":%s,"installLocation":"/x","autoUpdate":true}}\n' "$GH" > "$HOMED/.claude/plugins/known_marketplaces.json"
run_au CLAUDE_CONFIG_DIR="$CFGD"; assert_whisper "the relocated record has no key; the stale HOME one is not read"
settings "$CFGD/settings.json" true; run_au CLAUDE_CONFIG_DIR="$CFGD"; assert_quiet

test_start "a non-boolean autoUpdate is no vote"
reset_home; km "$GH" '"yes"'; run_au; assert_whisper "string autoUpdate in km"
km "$GH"; settings "$HOMED/.claude/settings.json" '"true"'; run_au; assert_whisper "string autoUpdate in settings"

test_start "an entry the harness rejects is no entry (lens 2): no source object, or a non-boolean key"
reset_home; km "$GH"; mkdir -p "$HOMED/.claude"
printf '{"extraKnownMarketplaces":{"maude":{"autoUpdate":true}}}\n' > "$HOMED/.claude/settings.json"
run_au; assert_whisper "a hand-edited entry without source is dropped by the harness"
settings "$HOMED/.claude/settings.json" true
mkdir -p "$PROJD/.claude"; printf '{"extraKnownMarketplaces":{"maude":{}}}\n' > "$PROJD/.claude/settings.json"
run_au; assert_quiet
settings "$PROJD/.claude/settings.json" '"yes"'; run_au; assert_quiet
printf '{"extraKnownMarketplaces":{"maude":{"source":"github"}}}\n' > "$PROJD/.claude/settings.json"; run_au; assert_quiet

# The harness's entry schema, one level down (lens 3, checked against `claude doctor`'s
# "Invalid marketplace entry was ignored"): source.source a string, the field its kind
# requires a string (github: repo; git/url: url; file/directory: path), installLocation
# absent or a string, autoUpdate absent or a boolean (an explicit null is rejected).
user_entry() { mkdir -p "$HOMED/.claude"; printf '{"extraKnownMarketplaces":{"maude":%s}}\n' "$1" > "$HOMED/.claude/settings.json"; }
proj_entry() { mkdir -p "$PROJD/.claude"; printf '{"extraKnownMarketplaces":{"maude":%s}}\n' "$1" > "$PROJD/.claude/settings.json"; }
test_start "a malformed entry carrying true is dropped by the harness → whisper (missed-whisper shapes)"
reset_home; km "$GH"
user_entry '{"source":{"source":"github"},"autoUpdate":true}'; run_au; assert_whisper "github without repo"
user_entry '{"source":{"type":"github","repo":"a/b"},"autoUpdate":true}'; run_au; assert_whisper "no source.source"
user_entry '{"source":{"source":"github","repo":"a/b"},"installLocation":5,"autoUpdate":true}'; run_au; assert_whisper "installLocation not a string"
user_entry '{"source":{"source":"git"},"autoUpdate":true}'; run_au; assert_whisper "git without url"
user_entry '{"source":{"source":"directory"},"autoUpdate":true}'; run_au; assert_whisper "directory without path"
test_start "a malformed higher entry is dropped, the lower true stands → silent (false-whisper shapes)"
reset_home; km "$GH"; settings "$HOMED/.claude/settings.json" true
proj_entry '{"source":{}}'; run_au; assert_quiet
proj_entry '{"source":{"source":"github"}}'; run_au; assert_quiet
proj_entry '{"source":{"source":"github","repo":"a/b"},"installLocation":5}'; run_au; assert_quiet
proj_entry '{"source":{"source":"github","repo":"a/b"},"installLocation":null}'; run_au; assert_quiet
proj_entry '{"source":{"source":"github","repo":"a/b"},"autoUpdate":null}'; run_au; assert_quiet
test_start "a well-formed higher entry with no key still hides the lower true (unchanged)"
proj_entry '{"source":{"source":"github","repo":"a/b"},"installLocation":"/x"}'; run_au; assert_whisper "valid entry, key absent"
proj_entry '{"source":{"source":"bogus-kind"}}'; run_au; assert_whisper "an unknown kind is left unvalidated by the harness: kept"

test_start "directory and file sources → silent (in-place loads, nothing to auto-update)"
reset_home; km '{"source":"directory","path":"/nowhere"}'; run_au; assert_quiet
km '{"source":"file","path":"/nowhere/marketplace.json"}'; run_au; assert_quiet

test_start "an unrecognized source kind → silent (a whisper it cannot compute says nothing)"
km '{"source":"claudeai","id":"x"}'; run_au; assert_quiet

test_start "no maude entry, no record, malformed record → silent"
mkdir -p "$HOMED/.claude/plugins"; printf '{"other":{}}\n' > "$HOMED/.claude/plugins/known_marketplaces.json"; run_au; assert_quiet
rm -f "$HOMED/.claude/plugins/known_marketplaces.json"; run_au; assert_quiet
printf '{not json\n' > "$HOMED/.claude/plugins/known_marketplaces.json"; run_au; assert_quiet
km "$GH"; printf '{not json\n' > "$HOMED/.claude/settings.json"; run_au; assert_whisper "a malformed settings file is no vote"

test_start "the harness kill switches silence it: the pass they stop would not run"
reset_home; km "$GH"
run_au DISABLE_AUTOUPDATER=1; assert_quiet
run_au DISABLE_UPDATES=1; assert_quiet
run_au CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; assert_quiet
run_au DISABLE_AUTOUPDATER=1 FORCE_AUTOUPDATE_PLUGINS=1; assert_whisper "FORCE_AUTOUPDATE_PLUGINS overrides the switch"

test_start "the switches read as the harness reads them (2.1.296: 1/true/yes/on, trimmed, any case)"
run_au DISABLE_AUTOUPDATER=" TRUE "; assert_quiet
run_au DISABLE_UPDATES=Yes; assert_quiet
run_au DISABLE_AUTOUPDATER=ON; assert_quiet
run_au DISABLE_UPDATES=on; assert_quiet
run_au DISABLE_AUTOUPDATER=1 FORCE_AUTOUPDATE_PLUGINS=on; assert_whisper "on forces too"
run_au DISABLE_AUTOUPDATER=FALSE; assert_whisper "FALSE is off"
run_au DISABLE_AUTOUPDATER=0; assert_whisper "0 is off"
run_au DISABLE_UPDATES=2; assert_whisper "2 is off: not in the harness's list"
run_au DISABLE_AUTOUPDATER=" "; assert_whisper "blank is off"
run_au DISABLE_AUTOUPDATER=1 FORCE_AUTOUPDATE_PLUGINS=0; assert_quiet
run_au DISABLE_AUTOUPDATER=1 FORCE_AUTOUPDATE_PLUGINS=enabled; assert_quiet
run_au CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0; assert_quiet
run_au CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=false; assert_quiet

# The fourth switch is in the global config (lens 4, read from 2.1.296): autoUpdates false
# kills the pass unless the install is native AND protected; then the Marketplaces menu does
# not even show Enable auto-update. The file is .claude.json under CLAUDE_CONFIG_DIR when
# set, else under HOME.
gc() { printf '%s\n' "$2" > "$1/.claude.json"; }
test_start "autoUpdates false in the global config kills the pass → silent, with the native exemption"
reset_home; km "$GH"
gc "$HOMED" '{"autoUpdates":false,"installMethod":"npm"}'; run_au; assert_quiet
gc "$HOMED" '{"autoUpdates":false}'; run_au; assert_quiet
gc "$HOMED" '{"autoUpdates":false,"installMethod":"native"}'; run_au; assert_quiet
gc "$HOMED" '{"autoUpdates":false,"installMethod":"native","autoUpdatesProtectedForNative":true}'; run_au; assert_whisper "native and protected: the switch does not apply"
gc "$HOMED" '{"autoUpdates":true,"installMethod":"npm"}'; run_au; assert_whisper "autoUpdates true"
gc "$HOMED" '{"installMethod":"npm"}'; run_au; assert_whisper "the common adopter config: no autoUpdates key (lens 5)"
gc "$HOMED" '{"autoUpdates":null,"installMethod":"npm"}'; run_au; assert_whisper "null is not false"
gc "$HOMED" '{"autoUpdates":0,"installMethod":"npm"}'; run_au; assert_whisper "0 is not false"
gc "$HOMED" '{"autoUpdates":false,"installMethod":"Native","autoUpdatesProtectedForNative":true}'; run_au; assert_quiet
gc "$HOMED" '{"autoUpdates":false,"installMethod":"native","autoUpdatesProtectedForNative":"true"}'; run_au; assert_quiet
gc "$HOMED" '{"autoUpdates":"false","installMethod":"npm"}'; run_au; assert_whisper "a string is not false"
gc "$HOMED" '{not json'; run_au; assert_whisper "a broken config casts no vote"
gc "$HOMED" '{"autoUpdates":false,"installMethod":"npm"}'; run_au DISABLE_AUTOUPDATER=1 FORCE_AUTOUPDATE_PLUGINS=1; assert_whisper "FORCE overrides the config switch too"
rm -f "$HOMED/.claude.json"; CFGD="$TEST_TMP/cfg2"; mkdir -p "$CFGD/plugins"; cp "$HOMED/.claude/plugins/known_marketplaces.json" "$CFGD/plugins/"
gc "$CFGD" '{"autoUpdates":false,"installMethod":"npm"}'; run_au CLAUDE_CONFIG_DIR="$CFGD"; assert_quiet
gc "$HOMED" '{"autoUpdates":false,"installMethod":"npm"}'; rm -f "$CFGD/.claude.json"; run_au CLAUDE_CONFIG_DIR="$CFGD"; assert_whisper "with CLAUDE_CONFIG_DIR set, HOME's config is not read"
rm -f "$HOMED/.claude.json"

# The drift whispers through the REAL discovery path: a directory or file record's
# source.path, MAUDE_SOURCE_DIR unset. Every row above reached them through the seam, so a
# hook that exited on a directory record passed the suite (lens 6). The github arm must
# also leave the drift path intact when a seam names a source.
run_disc() {  # [VAR=val …]
  ERR="$TEST_TMP/disc.err"
  OUT="$(env "$@" HOME="$HOMED" CLAUDE_PROJECT_DIR="$PROJD" CLAUDE_PLUGIN_ROOT="$ROOTD" bash "$CHECK" 2>"$ERR")"
  RC=$?
}
test_start "a directory record's source.path reaches the drift whispers"
reset_home; rm -rf "$ROOTD" "$SRCD"; mkplugin "$ROOTD" "0.9.0"; mkplugin "$SRCD" "1.0.0"
km "{\"source\":\"directory\",\"path\":\"$SRCD\"}"
run_disc; assert_exit "$RC" "0" "rc 0"; assert_contains "$OUT" "update is waiting" "version drift through the record"
assert_not_contains "$OUT" "auto-update is off" "no whisper on a directory record"
mkplugin "$SRCD" "0.9.0"; printf 'drift\n' > "$SRCD/hooks/scripts/new-organ.sh"
run_disc; assert_contains "$OUT" "NEVER auto-deliver" "file drift through the record"
test_start "a file record's source.path reaches the drift whispers too"
km "{\"source\":\"file\",\"path\":\"$SRCD\"}"
run_disc; assert_contains "$OUT" "NEVER auto-deliver" "file source"
assert_not_contains "$OUT" "auto-update is off" "no whisper on a file record"
test_start "a github record with a seam-named source prints the whisper AND the drift line"
km "$GH"; run_disc MAUDE_SOURCE_DIR="$SRCD"
assert_contains "$OUT" "auto-update is off" "whisper"; assert_contains "$OUT" "NEVER auto-deliver" "drift still reported"
if [ ! -s "$ERR" ]; then _pass; else _fail "stderr must stay empty, got: $(cat "$ERR")"; fi
rm -f "$SRCD/hooks/scripts/new-organ.sh"

test_start "the whisper sits under the kill switch and the blink guard too"
run_au MAUDE_SELF_CHECK=off; assert_quiet
run_au MAUDE_EYE_BLINK=1; assert_quiet

teardown_test_env
print_summary
exit "$FAILED"
