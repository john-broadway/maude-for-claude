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

# Quote-content-kept normalisation — used by the backstop checks below
# (red-self-clear, redclear-write, drop-table). PATH patterns are matched
# inside maude_gate_eval, which builds its own canonicalised view.
# Strips quote CHARACTERS but keeps their content, so rm -rf "/srv/app"
# becomes rm -rf /srv/app for backstop matching. Also expands ~ and $HOME
# to the real home directory so quoted-path arguments in those checks still
# resolve correctly.
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
# PREFIX = a chain of transparent command-position prefixes that don't change
# WHAT runs: env-assignments (FOO=1 BAR=2) and the `command` builtin. Inserted
# between CMD_START and the command keyword so a gated command behind such a
# prefix is still seen at a boundary. Matches empty (so unprefixed commands are
# unaffected). Closes #7 (command) and #8 (env-assign, for ALL patterns).
PREFIX='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|command[[:space:]]+)*'
# ARGS = other arguments of the SAME simple command, so a dangerous target is
# caught in any argument position (`rm -rf /tmp/ok /srv/app`).
# The token class MUST exclude the shell separators ; & | (and only those — see
# the note below). It once was a
# bare [^[:space:]]+, and because maude_canon_path_view joins a multi-line
# command into ONE line with `;` separators (verified: a 3-line script becomes
# `rm -rf /tmp/safe;echo filler;cat /srv/app/x.sh`), a separator was absorbed as
# an ordinary argument and the walk ran to the end of the whole script. Any
# harmless `rm -rf` then paired with any protected path appearing ANYWHERE
# later. Measured 2026-07-30 on a real 14-line probe: `rm -rf "$S"` on line 1
# blocked because line 14 mentioned a <workspace> path, and the refusal said
# "rm -rf of a protected sole-copy path" — naming an rm that never existed.
# Over-blocking is the safe direction, but a refusal that states the wrong
# reason is a lying refusal, and a gate that blocks ordinary multi-command
# scripts is a gate that gets switched off.
# NOTE the separator half is [[:space:]] and stays that way on purpose: there
# are no newlines left to exclude by this point, so narrowing it to [[:blank:]]
# would be an inert edit dressed up as a fix.
# The excluded set is DELIBERATELY the minimum that does the job — ; & | only.
# ( ) and backtick are command starts to CMD_START, but mid-argument they are
# command SUBSTITUTION, and excluding them would stop the walk in
# `rm -rf $(echo x) /srv/app` — a genuinely destructive command that is blocked
# today. Narrowing a block rule can only ever cause UNDER-blocking, so it gets
# the smallest cut that fixes the measured fault, not the tidiest-looking one.
# Regression: tests/test-gate.sh "the arg-walk must stop at the end of ITS OWN command".
ARGS='([^[:space:];&|]+[[:space:]]+)*'
# ABS = optional absolute/relative path prefix on a command NAME (/bin/rm,
# /usr/bin/git). Ends in a slash so it can't eat into the command word. Closes #6.
ABS='(/[^[:space:]]*/)?'
# GIT = "git" + any global options (-C <dir>, -c <cfg>, --git-dir=<dir>) + the
# whitespace before the subcommand. Lets `git -C /repo push` / `git  push` (extra
# whitespace) match the same as `git push` — closing the v0.3.0 interior-space and
# `-C` bypasses. Interior token gaps use [[:space:]]+ everywhere for the same reason.
GIT="${ABS}"'git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--git-dir[=[:space:]][^[:space:]]+))*[[:space:]]+'
# RMRF = "rm" + a flag bearing both r and f in either order (-rf, -fr, -Rf, -rfv…).
# (Kept for backward compat / other callers; sole-copy patterns use RMR below.)
# shellcheck disable=SC2034  # RMRF intentionally retained for external callers; unused in this file
RMRF='rm[[:space:]]+(-[[:alnum:]]*r[[:alnum:]]*f[[:alnum:]]*|-[[:alnum:]]*f[[:alnum:]]*r[[:alnum:]]*)'
# RMR = "rm" + any leading flags (including --recursive, --force, -r, -f in any
# order and any combination) followed by whitespace before the path argument.
# Force is OPTIONAL — a bare `rm -r` without -f still deletes recursively (RED).
# Matches: rm -rf, rm -fr, rm -r -f, rm -r, rm --recursive, rm --recursive --force,
# rm -rfv, rm -r --force, etc.
RMR="${ABS}"'rm([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*[[:space:]]+'

# ── Known limitations (honest about what this regex belt does NOT catch) ──
#
# These gaps are acknowledged, not buried. They rely on the fail-closed bias
# plus (for MCP) the harness-deny backstop:
#
# 1. (Closed in v0.13.2) Interior double-slash: PATH patterns now match the
#    canonicalised path view (maude_canon_path_view, now computed inside
#    maude_gate_eval) which collapses repeated slashes before matching.
# 2. (Partial residual) Leading `..` beyond root (e.g. `rm -rf /../b`) is
#    left as unresolvable residue — the seg pattern cannot consume `..` (or a
#    lone `.`) as a segment, so `/../` and `/./../` are never reduced. All
#    other `/seg/../` forms (seg ≠ `.` or `..`) are now resolved (v0.13.2).
# 3. (v0.13.2 PARTIALLY CLOSED) `bash|sh|dash|zsh -c` and `eval` LITERAL
#    payloads (single-quoted, or double-quoted without `$`/backtick) ARE now
#    inspected. Still uncaught: heredoc-fed-shell (`bash <<EOF … rm -rf /
#    … EOF`) and variable/interpolated payloads (`bash -c "$CMD"`,
#    `eval "$X"`) — the latter now emit a non-blocking whisper.
#    v0.27.0: heredoc excision now also covers the COMMAND patterns (git
#    push et al) — a heredoc body naming a gated command no longer
#    false-blocks, and a gated command inside a heredoc-fed SHELL is
#    uniformly this limitation, for every pattern family.
#    Unquoted bareword payloads (e.g. `eval ls`, `bash -c rm -rf /`) are
#    also not inspected but DO whisper via the opaque-wrap check.
#    Under-extraction is the deliberate bias. Top-level-only opaque check:
#    a nested opaque wrap inside an inspectable outer payload is residual.
# 4. Variable-indirected paths: `P=/srv/app; rm -rf $P` — the gate sees
#    the literal `$P`, not the expanded value.
# 5. `cd` + relative delete: `cd /srv && rm -rf app` or
#    `cd /srv/app && rm -rf .` — the gate only sees the relative target
#    and cannot infer the effective path from a prior `cd`.
# 6. Adjacent transparent prefixes/alias-escapes NOT closed: `exec rm`,
#    `env rm`, `nohup`/`timeout`/`xargs rm`, and `\rm` (backslash
#    alias-escape). Same class as the now-closed /bin/, command, and FOO=1
#    prefixes; extend on real need.
# 7. Heredoc mis-detection (CLOSED for the known classes, v0.27.0): the
#    guards excise heredoc bodies via a `<<WORD` scan (maude_strip_heredocs)
#    that now blinds `$((a << b))` arithmetic, `<<<` herestrings AND quoted
#    prose (`echo "x << EOF"`) before detection — delimiter-quoting
#    (`<<'EOF'`) is protected first, which is what made quote-blanking
#    unsafe before. This matters doubly since the strip now also feeds the
#    COMMAND patterns: an adversarial pass measured the quoted-opener
#    phantom silently swallowing a real `git push --force` on the next
#    line. Residual, pinned in tests: an UNBALANCED quote before `<<WORD`
#    still opens a phantom body and can under-block a later command.
# ──────────────────────────────────────────────────────────────────────────

# Sole-copy targets come from the config-aware list (generic defaults + local
# gate-config) — no hardcoded paths in this source.
SC_TARGETS=()
while IFS= read -r _t; do [ -n "$_t" ] && SC_TARGETS+=("$_t"); done < <(maude_sole_copy_targets)

# ── PATH patterns — matched (inside maude_gate_eval) against the canonicalised
# unquoted view (uq). Quoting still works — rm -rf "/srv/app" is still caught
# even though the path was quoted.
# These are checked FIRST, before command patterns.
PATH_PATTERNS=(
  # rm (recursive, force optional) targeting / directly — system wipe
  # ${ARGS} allows a dangerous target in any argument position OF THIS COMMAND
  # (e.g. `rm -rf /tmp/ok /` — the / is caught even as the second argument).
  "${CMD_START}${PREFIX}${RMR}${ARGS}/${FLAG_AFTER} ||| rm-rf-root ||| \"rm -rf /\" wipes the system. STOP. Run /maude:conscience rm-rf-root only if you really mean it."
  # rm (recursive) targeting glob * — wide blast
  "${CMD_START}${PREFIX}${RMR}${ARGS}\\*${FLAG_AFTER} ||| rm-rf-glob ||| \"rm -rf *\" — wide blast. Run /maude:conscience rm-rf-glob if you mean it."
  # sudo rm (recursive) — any target is RED at root
  "${CMD_START}${PREFIX}sudo[[:space:]]+${RMR} ||| sudo-rm-rf ||| sudo rm -rf is destructive at root. Run /maude:conscience sudo-rm-rf if intentional."
)
# Sole-copy entries — one per target, built from the config-aware list.
# `/*` absorbs zero or more trailing slashes (including //).
# `${ARGS}` allows the sole-copy path in any argument position of the same command.
for _t in "${SC_TARGETS[@]}"; do
  PATH_PATTERNS+=("${CMD_START}${PREFIX}${RMR}${ARGS}(${_t})/*${FLAG_AFTER} ||| rm-rf-sole-copy ||| rm -rf of a protected sole-copy path (workspace / repo root / .git / configured path). Sole copy, no fallback. Run /maude:conscience rm-rf-sole-copy only if you truly mean it.")
done

# ── TARGET-keyed table (added 2026-07-30, unreleased) ────────────────────────
# The tables above are keyed on the VERB. A verb denylist can only ever block the
# verbs someone thought of, and on 2026-07-23 that cost John three irreplaceable
# PNGs to `rm -f ~/projects/*.png` — a command the verb table let straight
# through, along with mv / find -delete / shred / truncate / dd / rmtree of the
# workspace root (all re-proven exit 0 against 0.24.0 on 2026-07-30).
#
# This table asks the other question: is the THING being destroyed a sole copy?
# If so the verb does not matter. The rule it encodes is John's own:
#   "NEVER glob-delete in workspace root — exact names only, only files I created."
# so a glob whose parent IS the protected root blocks, while an exact deep path
# and a deep glob (build/*.o) stay free. A gate that blocked ordinary deep
# deletes would be switched off inside a day, and a gate that is off protects
# nothing — the false-positive rows in tests/test-gate-targets.sh are load-bearing.

# Roots WITHOUT the optional one-segment tail that maude_sole_copy_targets appends.
# Needed because glob-depth matters here: with the tail, `_t` would swallow
# `<root>/build` and then `/*.o` would read as a root glob.
SC_ROOTS=()
_pd="$(maude_project_dir)"
[ -n "$_pd" ] && SC_ROOTS+=("$(maude_ere_escape "$_pd")")
SC_ROOTS+=("$(maude_ere_escape "$HOME")/\\.claude")
_cfg="$(maude_gate_config)"
if [ -f "$_cfg" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r _p; do
    [ -n "$_p" ] && SC_ROOTS+=("$(maude_ere_escape "$_p")")
  done < <(jq -r '.sole_copy_paths[]?' "$_cfg" 2>/dev/null)
fi

# DEPTH-BOUNDED targets. maude_sole_copy_targets() appends `(/[^[:space:]]*)?` for
# CONFIG-sourced paths (_maude-common.sh:855) and for ~/.claude and .git — a tail
# that excludes whitespace but NOT `/`, so it matches at ANY depth. The project-dir
# entry at :849 correctly bounds it to one segment. Consuming the unbounded list
# here made this table block every non-recursive rm/mv anywhere under the workspace
# root on the deployed config, while the suite stayed green because lib.sh points
# MAUDE_GATE_CONFIG at a file it never creates. A redteam pass measured 25 such
# false positives, three of them contradicting this table's own ALLOW rows.
# So build the list here, bounded to ONE optional segment, exactly like :849.
SC_BOUNDED=()
for _r in "${SC_ROOTS[@]}"; do
  [ -n "$_r" ] && SC_BOUNDED+=("${_r}(/[^/[:space:]]+)?")
done
# The .git protection is depth-bounded the same way, so `rm <repo>/.git/index.lock`
# stays allowed while `rm -rf <repo>/.git` is still caught by the rm -rf table above.

# Transparent prefixes, wider than PREFIX: hats a destructive command can wear
# without changing what it does. The redteam broke the first version by naming
# wrappers that were not listed (xargs, nice, time, ionice, setsid, stdbuf, uv,
# busybox) — the same denylist failure this table exists to correct, one level up.
TPREFIX='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|command[[:space:]]+|exec[[:space:]]+|env[[:space:]]+|nohup[[:space:]]+|sudo([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+|timeout[[:space:]]+[0-9]+[smhd]?[[:space:]]+|nice([[:space:]]+-n[[:space:]]*[0-9]+)?[[:space:]]+|ionice([[:space:]]+-[^[:space:]]+)*[[:space:]]+|time[[:space:]]+|setsid[[:space:]]+|stdbuf([[:space:]]+-[^[:space:]]+)*[[:space:]]+|xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+|busybox[[:space:]]+|uv[[:space:]]+run[[:space:]]+)*'
# Verbs that destroy or relocate content with no -r required.
# `install` was here and is removed: `install -d <dir>` CREATES a directory and
# destroys nothing, which the redteam measured as a false positive.
TVERB='(rm|unlink|mv|shred|truncate)'
# Any flags/other args between the verb and the target — of the SAME command.
# The intervening-args half carries the same bound as ${ARGS} above and for the
# same measured reason: `;` survives canonicalisation as a non-space character,
# so a bare [^[:space:]]+ walked out of this command and into the next one.
TARGS='([[:space:]]+(-[^[:space:]]+|--[a-z-]+))*([[:space:]]+[^[:space:];&|]+)*[[:space:]]+'
TMSG='Run /maude:conscience sole-copy-target only if you truly mean it.'

# TSTART: CMD_START plus the shell keyword/brace boundaries a command can follow.
# The redteam defeated even the pre-existing `rm -rf <root>` control with `{ ...; }`,
# `until false; do ...; done`, `if ...; then ...; fi`, `! rm ...` and `case`.
TSTART='(^|[;&|(`{]|[[:space:]](do|then|else|in)[[:space:]]|[[:space:]]!)[[:space:]]*'
TARGET_PATTERNS=()
for _t in "${SC_BOUNDED[@]}"; do
  # Bare protected path (root, or one segment in: a repo/project dir) as the
  # target of a non-recursive destroy/relocate verb.
  TARGET_PATTERNS+=("${TSTART}${TPREFIX}${ABS}${TVERB}${TARGS}(${_t})/*${FLAG_AFTER} ||| sole-copy-target ||| destroying or relocating a protected sole-copy path without rm -rf. The verb changes, the loss does not. ${TMSG}")
  # find <protected> … -delete / -exec rm
  TARGET_PATTERNS+=("${TSTART}${TPREFIX}${ABS}find[[:space:]]+${ARGS}(${_t})(/[^[:space:]]*)?([[:space:]].*)?(-delete([[:space:]]|;|\+|$)|-exec(dir)?[[:space:]]+${ABS}(rm|shred|truncate|unlink)) ||| sole-copy-target ||| find with -delete/-exec rm under a protected sole-copy path. ${TMSG}")
  # dd of=<protected>  — intervening args bounded to this command (see ${ARGS}).
  TARGET_PATTERNS+=("${TSTART}${TPREFIX}${ABS}dd([[:space:]]+[^[:space:];&|]+)*[[:space:]]+of=(${_t})/* ||| sole-copy-target ||| dd writing over a protected sole-copy path. ${TMSG}")
  # rsync --delete into <protected> — both arg walks bounded to this command.
  TARGET_PATTERNS+=("${TSTART}${TPREFIX}${ABS}rsync([[:space:]]+[^[:space:];&|]+)*[[:space:]]+--del(ete[a-z-]*)?([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(${_t})/*[[:space:]]*\$ ||| sole-copy-target ||| rsync --delete INTO a protected sole-copy path removes whatever the source lacks. (Workspace as SOURCE is a backup and is allowed.) ${TMSG}")
  # Interpreter one-liner doing the deletion in-process.
  # ASYMMETRIC on purpose. The gap BEFORE the destructive call keeps `.*`: a real
  # one-liner's own payload contains `;` (python3 -c "import shutil;shutil.rmtree(…)")
  # and quotes are already stripped by this point, so the gate cannot tell that `;`
  # from a shell separator — excluding it would kill the true positive.
  # The gap AFTER the call is bounded, which is where the measured false positives
  # lived: `python3 train.py; echo os.remove; cat <root>/README.md` blocked because
  # a delete-word in one command paired with a protected path two commands later.
  # In a genuine one-liner the path follows the call immediately, with no separator.
  TARGET_PATTERNS+=("${TSTART}${TPREFIX}${ABS}(python3?|perl|ruby|node)[[:space:]].*(rmtree|unlink|os\\.remove|fs\\.rm|File\\.delete|shutil\\.move)[^;&|]*(${_t}) ||| sole-copy-target ||| an interpreter one-liner deleting a protected sole-copy path. The gate cannot see inside a script, so this is the last place to catch it. ${TMSG}")
done
# Glob whose PARENT is the protected root itself — the 2026-07-23 disaster shape.
# Root-anchored on purpose: `<root>/*.png` blocks, `<root>/build/*.o` does not.
for _r in "${SC_ROOTS[@]}"; do
  TARGET_PATTERNS+=("${TSTART}${TPREFIX}${ABS}${TVERB}${TARGS}(${_r})/[^/[:space:]]*[*?[][^/[:space:]]*${FLAG_AFTER} ||| sole-copy-target ||| a GLOB delete at the root of a protected sole-copy path. This is the shape that destroyed files on 2026-07-23: exact names only at the root. ${TMSG}")
done

# Command-position guard for the target table, mirroring
# maude_rm_in_command_position but for the wider verb set: heredoc bodies are
# excised first so a doc or commit message describing a destructive command
# cannot self-block.
maude_target_verb_in_command_position() {
  local skeleton
  skeleton="$(maude_strip_quotes "$(maude_strip_heredocs "$1")")"
  printf '%s' "$skeleton" | grep -qE -- \
    "${TSTART}${TPREFIX}${ABS}(${TVERB}|find|dd|rsync|python3?|perl|ruby|node)([[:space:]]|$)"
}

# ── COMMAND patterns — matched against $CMD via maude_match_gate_pattern
# (strip_quotes: content ERASED). This preserves all canaries — a commit message
# containing "git push" as literal text must not self-block the commit.
CMD_PATTERNS=(
  "${CMD_START}${PREFIX}${GIT}push[[:space:]].*--force-with-lease ||| force-push ||| force-push-with-lease detected. Still public-rewriting. Run /maude:conscience force-push if verified."
  "${CMD_START}${PREFIX}${GIT}push[[:space:]].*--force ||| force-push ||| force-push detected. Public, irreversible. Run /maude:conscience force-push if you have verified."
  "${CMD_START}${PREFIX}${GIT}push[[:space:]].*-f${FLAG_AFTER} ||| force-push ||| force-push (-f). Run /maude:conscience force-push if verified."
  "${CMD_START}${PREFIX}${GIT}push${FLAG_AFTER} ||| git-push ||| git push detected. Public, irreversible. Run /maude:conscience git-push to override."
  "${FLAG_BEFORE}--no-verify${FLAG_AFTER} ||| no-verify ||| --no-verify skips hooks. Run /maude:conscience no-verify if intentional."
  "${FLAG_BEFORE}--no-gpg-sign${FLAG_AFTER} ||| no-gpg-sign ||| --no-gpg-sign skips signing. Run /maude:conscience no-gpg-sign if intentional."
  "${CMD_START}${PREFIX}${GIT}reset[[:space:]].*--hard ||| reset-hard ||| git reset --hard loses local work. Run /maude:conscience reset-hard once you have stashed."
  "${CMD_START}${PREFIX}${GIT}filter-repo${FLAG_AFTER} ||| filter-repo ||| git filter-repo rewrites history. Run /maude:conscience filter-repo to override."
  "${CMD_START}${PREFIX}${GIT}filter-branch${FLAG_AFTER} ||| filter-branch ||| git filter-branch rewrites history. Run /maude:conscience filter-branch to override."
  "${CMD_START}${PREFIX}${GIT}commit[[:space:]].*--amend ||| commit-amend ||| git commit --amend rewrites the last commit. If pushed, this needs force-push. Run /maude:conscience commit-amend."
  "${CMD_START}${PREFIX}$(maude_public_publish_re) ||| public-publish ||| public-facing publish (gh release / twine / uv publish / hf upload). Run /maude:conscience public-publish after the pre-public-push checklist + John's go."
  # NOTE: DROP TABLE is NOT a CMD_PATTERN — matching the quote-ERASED skeleton
  # made it exactly backwards (missed quoted real SQL, fired on prose). It is
  # handled by the context-aware block below (content-kept view + SQL client).
)

# Evaluate the PATH + COMMAND pattern tables against ONE command string.
# Echoes "KEY ||| MSG" on the first match; returns 1 with no output otherwise.
# Used for the live command and (Task 8) recursively for wrapped payloads.
# Does NOT run the red-self-clear / redclear-write / drop-table backstops —
# those guard the literal live command only.
maude_gate_eval() {
  local cmd="$1" uq entry pat rest key msg
  uq="$(maude_canon_path_view "$(maude_unquote "$cmd" | sed "s|~|${HOME}|g; s|\\\$HOME|${HOME}|g")")"
  if maude_rm_in_command_position "$cmd"; then
    for entry in "${PATH_PATTERNS[@]}"; do
      pat="${entry%% ||| *}"; rest="${entry#* ||| }"; key="${rest%% ||| *}"; msg="${rest#* ||| }"
      if printf '%s' "$uq" | grep -qE -- "$pat"; then printf '%s ||| %s' "$key" "$msg"; return 0; fi
    done
  fi
  if maude_target_verb_in_command_position "$cmd"; then
    for entry in "${TARGET_PATTERNS[@]}"; do
      pat="${entry%% ||| *}"; rest="${entry#* ||| }"; key="${rest%% ||| *}"; msg="${rest#* ||| }"
      if printf '%s' "$uq" | grep -qE -- "$pat"; then printf '%s ||| %s' "$key" "$msg"; return 0; fi
    done
  fi
  for entry in "${CMD_PATTERNS[@]}"; do
    pat="${entry%% ||| *}"; rest="${entry#* ||| }"; key="${rest%% ||| *}"; msg="${rest#* ||| }"
    if maude_match_gate_pattern "$cmd" "$pat"; then printf '%s ||| %s' "$key" "$msg"; return 0; fi
  done
  return 1
}

# Recursively inspect inspectable wrapped payloads up to a depth cap. Echoes
# "KEY ||| MSG" if any inspectable inner command is itself gated; else returns 1.
maude_wrapped_match() {
  local cmd="$1" depth="${2:-3}" payload m
  [ "$depth" -le 0 ] && return 1
  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    if m="$(maude_gate_eval "$payload")"; then printf '%s' "$m"; return 0; fi
    if m="$(maude_wrapped_match "$payload" "$((depth - 1))")"; then printf '%s' "$m"; return 0; fi
  done <<< "$(maude_wrapped_payloads "$cmd")"
  return 1
}

MATCHED_KEY=""
MATCHED_MSG=""

MATCHED="$(maude_gate_eval "$CMD")"
if [ -n "$MATCHED" ]; then
  MATCHED_KEY="${MATCHED%% ||| *}"
  MATCHED_MSG="${MATCHED#* ||| }"
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
# WIDENED 2026-07-30: the arg run was `-[^space]+`, i.e. only FLAGS, so a flag VALUE
# before the key slipped past — `maude-clear-gate.sh --marker abc sole-copy-target`
# was measured ALLOWED by a redteam while the same command with the key first was
# blocked. Now any token run precedes the key. Still bypassable by wrapping the call
# in a script file; that residual is the harness deny-rules' job, not this grep's.
if [ -z "$MATCHED_KEY" ]; then
  for _rk in $(maude_red_keys); do
    if printf '%s' "$UNQUOTED" | grep -qE -- "maude-clear-(gate|red)\.sh([[:space:]]+[^[:space:]]+)*[[:space:]]+${_rk}([[:space:]]|$)"; then
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

# ── #3 shell wrapping ────────────────────────────────────────────────────────
# Nothing matched the live command directly: inspect literal wrapped payloads
# (bash -c 'rm -rf /', eval 'git push --force', nested). Block with the inner
# key. A wrapper whose payload we CAN'T read (variable / interpolated) → whisper
# and pass (consistent with #4 var-indirection: noticed, not gated).
if [ -z "$MATCHED_KEY" ]; then
  if WM="$(maude_wrapped_match "$CMD" 3)"; then
    MATCHED_KEY="${WM%% ||| *}"
    MATCHED_MSG="${WM#* ||| }"
  elif maude_has_opaque_wrap "$CMD"; then
    maude_log_trace "gate" "wrap-opaque-whisper"
    printf "Maude: a wrapped command (bash -c / eval) carries a payload I can't inspect — the gate is blind to it here. Eyeball it yourself.\n" >&2
    exit 0
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

# No live token — block.
# NAME THE FILE WE LOOKED IN. The clear-script names the file it WROTE; without
# this the reader stayed silent, so a resolver split showed up only as "cleared"
# followed by a refusal, with nothing on either side to compare. That is exactly
# how the 2026-09-02 bug hid. One line closes the loop from the reader's side.
maude_log_trace "gate" "blocked=$MATCHED_KEY"
printf 'Maude: %s\n' "$MATCHED_MSG" >&2
# Deliberately does NOT repeat the matched key. An earlier draft did, and that
# put the key into stderr from a second source — which let nine assertions in
# test-gate.sh ("...block names its conscience key") pass even with the primary
# message suppressed. A diagnostic must not become an alternative supply of the
# thing other tests are checking for.
printf '       (looked in: %s)\n' "$CARE" >&2
exit 2
