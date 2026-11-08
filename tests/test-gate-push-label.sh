#!/usr/bin/env bash
# The push label: a `git push` block names the class of remote it aims at, read from the
# remote's push URL on the block path. "Public, irreversible." on every push trained clearing
# without reading (four pushes to the internal forge in one night, each cleared on a label
# that was wrong). The block itself never changes; the label fails toward the scary word.

set +e
. "$(dirname "$0")/lib.sh"
setup_test_env

HOOKS_DIR="$(dirname "$0")/../hooks/scripts"
GATE="$HOOKS_DIR/maude-gate.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# run_gate <cmd> [cwd] — the hook input carries the session's cwd, as the harness sends it.
run_gate() {
  ERR="$(make_bash_tool_input "$1" "${2:-}" | bash "$GATE" 2>&1 >/dev/null)"
  RC=$?
}

mkrepo() { # mkrepo <dir> <remote-name> <url> [pushurl]
  git init -q "$1" && git -C "$1" remote add "$2" "$3" || return 1
  [ -z "${4:-}" ] || git -C "$1" remote set-url --push "$2" "$4"
}

R="$TEST_TMP/repos"
_ip1='192.168.'; _ip1="${_ip1}7.7"; _ip2='10.0.'; _ip2="${_ip2}0.9"   # assembled: the RFC1918 shapes are the subject
mkrepo "$R/internal-lan"  origin 'git@forge.example.lan:john/x.git'
mkrepo "$R/internal-file" origin "file://$TEST_TMP/bare.git"
mkrepo "$R/internal-ip"   origin "ssh://git@${_ip1}:2222/john/x.git"
mkrepo "$R/public"        origin 'https://github.com/john/x.git'
mkrepo "$R/public-secret" origin 'https://john:hunter2hunter2@github.com/john/x.git'
mkrepo "$R/pushurl"       origin "file://$TEST_TMP/bare.git" 'https://github.com/john/x.git'
mkrepo "$R/two-internal"  origin "file://$TEST_TMP/bare.git"
git -C "$R/two-internal" remote add mirror "ssh://git@${_ip2}/john/x.git"
mkrepo "$R/mixed"         origin "file://$TEST_TMP/bare.git"
git -C "$R/mixed" remote add gh 'git@github.com:john/x.git'
mkrepo "$R/listed"        origin 'ssh://git@forge.example.net/john/x.git'
mkrepo "$R/unknown"       origin 'ssh://git@forge.example.net/john/x.git'
mkrepo "$R/two-ways"      origin 'https://github.com?@forge.example.lan/john/x.git'
mkrepo "$R/submodules"    origin "file://$TEST_TMP/bare.git"
git -C "$R/submodules" config push.recurseSubmodules on-demand
mkrepo "$R/pushremote"    origin "file://$TEST_TMP/bare.git"
git -C "$R/pushremote" commit -q --allow-empty -m init && git -C "$R/pushremote" config branch.master.pushRemote 'https://github.com/john/x.git'
mkrepo "$R/pushdefault"   origin 'https://github.com/john/x.git'
git -C "$R/pushdefault" remote add forge "file://$TEST_TMP/bare.git" && git -C "$R/pushdefault" config remote.pushDefault forge
mkrepo "$R/detached"      origin "file://$TEST_TMP/bare.git"
git -C "$R/detached" commit -q --allow-empty -m init && git -C "$R/detached" checkout -q --detach
mkrepo "$R/many"          r1 "file://$TEST_TMP/bare.git"
for i in 2 3 4 5 6 7 8 9 10; do git -C "$R/many" remote add "r$i" "file://$TEST_TMP/bare.git"; done
mkdir -p "$R/not-a-repo"

LEAD="git push detected"
PUB="Public, irreversible"

# ── Internal classes ────────────────────────────────────────────────────────
test_start "a push to a host under .lan is labelled internal, and still blocked"
run_gate 'git push origin main' "$R/internal-lan"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "$LEAD" "keyed git-push"
assert_contains "$ERR" "internal remote (forge.example.lan)" "internal, the host named"
assert_not_contains "$ERR" "$PUB" "not called public"
assert_contains "$ERR" "/maude:conscience git-push" "the yellow clear named"

test_start "a file:// remote is internal"
run_gate 'git push origin main' "$R/internal-file"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "internal remote" "internal"

test_start "an RFC1918 address is internal"
run_gate 'git push -q origin HEAD' "$R/internal-ip"
assert_contains "$ERR" "internal remote (${_ip1})" "internal, the address named"

test_start "no remote named: every remote internal reads internal"
run_gate 'git push' "$R/two-internal"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "internal remote" "internal"

test_start "a host the person listed in gate-config is internal"
printf '{"internal_push_hosts":["Forge.Example.Net"]}\n' > "$MAUDE_GATE_CONFIG"
run_gate 'git push origin main' "$R/listed"
assert_contains "$ERR" "internal remote (forge.example.net)" "listed host, case-folded"
rm -f "$MAUDE_GATE_CONFIG"

# ── Public, and everything that fails toward it ─────────────────────────────
test_start "a push to github is labelled PUBLIC"
run_gate 'git push origin main' "$R/public"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "PUBLIC remote (github.com)" "public, the host named"
assert_contains "$ERR" "$PUB" "the public sentence kept"

test_start "a secret in the remote URL never reaches stderr"
run_gate 'git push origin main' "$R/public-secret"
assert_contains "$ERR" "PUBLIC remote (github.com)" "the host, not the URL"
assert_not_contains "$ERR" "hunter2" "no credential echoed"

test_start "the push URL decides, not the fetch URL"
run_gate 'git push origin main' "$R/pushurl"
assert_contains "$ERR" "PUBLIC remote (github.com)" "pushurl is github"

test_start "no remote named: origin is where git sends it, whatever else is configured"
# Until M1 the label read every remote and called the push public if any was: a guess.
# git's rule is branch.<b>.pushRemote, remote.pushDefault, branch.<b>.remote, else origin.
run_gate 'git push' "$R/mixed"
assert_contains "$ERR" "internal remote (a local path)" "origin is the file remote"
run_gate 'git push gh main' "$R/mixed"
assert_contains "$ERR" "PUBLIC remote (github.com)" "named, the github one"

test_start "a host of no known class reads as public, and says why"
run_gate 'git push origin main' "$R/unknown"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "could not class" "the gate says it could not class the remote"
assert_contains "$ERR" "$PUB" "read as public"
assert_not_contains "$ERR" "internal remote" "never internal"

test_start "a remote name the repo does not have reads as public"
run_gate 'git push nosuch main' "$R/internal-lan"
assert_contains "$ERR" "could not class" "unresolved"
assert_contains "$ERR" "$PUB" "read as public"

test_start "an argless push follows branch.<b>.pushRemote, a URL where a name goes (the lens on c898dca, M1)"
run_gate 'git push' "$R/pushremote"
assert_contains "$ERR" "PUBLIC remote (github.com)" "the push goes to github, whatever origin is"
assert_not_contains "$ERR" "internal remote" "never internal"

test_start "an argless push follows remote.pushDefault"
run_gate 'git push' "$R/pushdefault"
assert_contains "$ERR" "internal remote" "forge is internal, though origin is github"

test_start "an argless push on a detached HEAD with nothing configured reads as public"
run_gate 'git push' "$R/detached"
assert_contains "$ERR" "could not class" "unknown"
assert_contains "$ERR" "$PUB" "read as public"

test_start "ten remotes and no origin: more than the gate reads, public (M3)"
run_gate 'git push' "$R/many"
assert_contains "$ERR" "more remotes than the gate reads" "says why"
assert_contains "$ERR" "$PUB" "read as public"

test_start "the label prints a host and nothing else (M2)"
run_gate 'git push https://john:hunter2@[::1]/x.git main' "$R/internal-lan"
assert_contains "$ERR" "no host the gate reads" "no host"
assert_not_contains "$ERR" "hunter2" "no secret"
assert_not_contains "$ERR" "::1" "no address it could not read"
run_gate "git push $TEST_TMP/bare.git main" "$R/internal-lan"
assert_contains "$ERR" "internal remote (a local path)" "a path reads as a local path"
assert_not_contains "${ERR%%$'\n'*}" "$TEST_TMP" "the path itself is not on the label line"
run_gate 'git push 2>err origin main' "$R/internal-lan"
assert_contains "$ERR" "no remote named 2" "the name, as read"
assert_not_contains "${ERR%%$'\n'*}" "$R" "the directory is not on the label line"
run_gate 'git -C nosuch push origin main' "$R"
assert_contains "$ERR" "push directory does not exist" "says so"
assert_not_contains "${ERR%%$'\n'*}" "nosuch" "without the path"

test_start "a URL git reads one way and a host reader another reads as public (the commit review on c898dca)"
run_gate 'git push origin main' "$R/two-ways"
assert_contains "$ERR" "could not class" "neither way"
assert_not_contains "$ERR" "internal remote" "never internal"
assert_not_contains "$ERR" "forge.example.lan" "the host past the @ is not named"

test_start "a push that recurses into submodules by config reads as public"
run_gate 'git push origin main' "$R/submodules"
assert_contains "$ERR" "recurses into submodules" "says why"
assert_contains "$ERR" "$PUB" "read as public"

test_start "a cwd that is not a repo reads as public"
run_gate 'git push origin main' "$R/not-a-repo"
assert_contains "$ERR" "$PUB" "read as public"
assert_not_contains "$ERR" "internal remote" "never internal"

test_start "no cwd in the hook input reads as public"
run_gate 'git push origin main'
assert_contains "$ERR" "$PUB" "read as public"
assert_not_contains "$ERR" "internal remote" "never internal"

test_start "a URL in command position is classed from the command itself"
run_gate 'git push https://github.com/john/x.git main' "$R/internal-lan"
assert_contains "$ERR" "PUBLIC remote (github.com)" "the positional URL, not origin"

# ── Anything that could move the push behind the gate's read keeps the public label ──
for shape in \
  'git -c url.https://github.com/.pushInsteadOf=file:// push origin main' \
  'GIT_CONFIG_GLOBAL=/tmp/x git push origin main' \
  'HOME=/tmp/x git push origin main' \
  'cd /tmp && git push origin main' \
  'git push origin main; git push gh main' \
  'git --git-dir=/tmp/x/.git push origin main' \
  'git push --receive-pack=/tmp/x origin main' \
  'git push --recurse-submodules=on-demand origin main' \
  'git push --repo=https://github.com/john/x.git origin main' \
  'git push `echo origin` main' \
  'git --config-env=user.name=X push origin main' \
  'git --work-tree=/tmp/x push origin main' \
  'git push --exec=/tmp/x origin main' \
  'git push -o x origin main' \
  'git push --push-option=x origin main' \
  'pushd /tmp && git push origin main' \
  'exec git push origin main' \
  'git push ~/x main' \
  'git -c=x push origin main' \
  'env -C /tmp git push origin main'
do
  test_start "redirectable shape keeps the public label: $shape"
  run_gate "$shape" "$R/internal-file"
  assert_eq "2" "$RC" "blocked"
  assert_not_contains "$ERR" "internal remote" "never internal"
  assert_contains "$ERR" "$PUB" "read as public"
done

test_start "a -C the gate can resolve is followed"
run_gate "git -C $R/internal-lan push origin main" "$TEST_TMP"
assert_contains "$ERR" "internal remote (forge.example.lan)" "resolved through -C"

test_start "a -C holding an expansion is not resolved"
run_gate 'git -C $D push origin main' "$R/internal-lan"
assert_not_contains "$ERR" "internal remote" "never internal"
assert_contains "$ERR" "$PUB" "read as public"

# ── The block is the same block ─────────────────────────────────────────────
test_start "force-push keeps its red row, whatever the remote"
run_gate 'git push --force origin main' "$R/internal-file"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "[RED]" "red"
assert_contains "$ERR" "force-push detected" "the force-push row"

test_start "a yellow token still opens an internal push"
bash "$HOOKS_DIR/maude-clear-gate.sh" git-push >/dev/null 2>&1
run_gate 'git push origin main' "$R/internal-file"
assert_eq "0" "$RC" "passes on the token"

test_start "the label is read only on the block path: a command that passes runs no git"
PATH_SAVE="$PATH"
mkdir -p "$TEST_TMP/bin"
printf '#!/bin/sh\necho GIT_RAN >> "%s/git-ran"\nexec /usr/bin/git "$@"\n' "$TEST_TMP" > "$TEST_TMP/bin/git"
chmod +x "$TEST_TMP/bin/git"
PATH="$TEST_TMP/bin:$PATH" run_gate 'ls -la' "$R/internal-file"
PATH="$PATH_SAVE"
assert_eq "0" "$RC" "ls passes"
[ ! -f "$TEST_TMP/git-ran" ] && _pass || _fail "git ran on a command the gate passed"

teardown_test_env
# ── the label reaches the partial-read refusal too (lens 4 on dd9d405, finding 5) ──────
test_start "a push behind a run-time command word is refused unread, with its remote classed"
run_gate '$x git push origin main' "$R/internal-file"
assert_eq "2" "$RC" "blocked"
assert_contains "$ERR" "could not read all of this command" "refused unread"
assert_contains "$ERR" "could not class its remote" "an expansion disqualifies the class"
assert_not_contains "$ERR" "git push detected. Public, irreversible." "not the flat lead"

print_summary
exit "$FAILED"
