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

# MODE: "" = the PreToolUse gate; "consume" = PostToolUse, spend the token this
# session reserved (called from maude-trace.sh; never blocks). Stdin is read ONCE.
MODE="${1:-}"
INPUT="$(cat 2>/dev/null)"
CMD=""
SID=""
HOOK_CWD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)"
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"
  HOOK_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)"
fi
# The whole id, as the eye keys by it: an 8-character prefix narrowed the session half of a
# call's identity to 32 bits for no reason (lens 5). Unsafe or over-long ids are "default".
{ maude_is_ascii_token "$SID" && [ "${#SID}" -le 64 ]; } 2>/dev/null || SID="default"
# Fail-OPEN by design: without jq there's no trustworthy way to parse the command
# out of the tool-input JSON (a hand-rolled parse reintroduces the v0.1.6
# quote-stripping self-block risk), so the gate provides NO protection here. The
# user is warned once at SessionStart ("the gate is OFF this session"). This is a
# deliberate limitation of an intentionally-soft dependency, not an oversight.
[ -z "$CMD" ] && exit 0

# CONSUME: leave before the pattern table. A consume can only spend a live token that is
# unreserved or reserved by THIS call, and both are answerable from the call alone — no
# pattern walk, no wrapped-payload recursion. The caller's text guard could not do this:
# an orphaned reservation (the residual 898dab7 names) or the word "reserved" anywhere in
# a 34 KB shared file put 306 ms back on every Bash completion in every session, for the
# whole life of a clear (the 25th lens, IMPORTANT-1).
if [ "$MODE" = "consume" ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  maude_gate_spendable_here "$INPUT" "$CMD" "$(maude_self_dir)/care.json" "$(maude_redclear_file)" || exit 0
fi

# A command past 128 KB is refused whole, before anything reads it. The clock bounds the
# walks, but after it fires the whole-command reads (the table, the views, the backstop
# greps) still cost per byte, and ~1.5 MB of plain lines outran the 5 s budget, after
# which a killed hook blocks nothing (lens 7 on fc838c1, B2). No key clears this: the
# remedy is a smaller command. The cap was set by the worst shape measured under it: every
# word a `$HOME` (bash expands each one, so the views grow by HOME's length) took 4.2 s
# at 256 KB here, too near the budget; at 128 KB it was about half that. The cap bounds
# the bytes, not the cost per byte: under it, 100,000 spaces before `git push` still ran
# the hook to 7.4 s here (lens 2 on the redclear port), one bash substitution over a
# 100 KB segment being 5.7 s of it. So the cost is bounded three ways below: a blank run
# is squeezed before any view, every walk over the command is linear in its bytes, and
# the table walk stops closed on the clock (parser-budget).
MAUDE_GATE_BYTES_CAP=131072
_cmd_bytes="$(printf '%s' "$CMD" | LC_ALL=C wc -c | tr -d ' ')"
if [ "$_cmd_bytes" -gt "$MAUDE_GATE_BYTES_CAP" ]; then
  maude_log_trace "gate" "oversize=$_cmd_bytes"
  printf 'Maude: this command is %s bytes, past the %s the gate can read inside its 5 s budget, so it is refused whole: split it, or write a large file with the Write tool.\n' "$_cmd_bytes" "$MAUDE_GATE_BYTES_CAP" >&2
  exit 2
fi
# A run of blanks reads as one. Every view of the command (the stripped text, the quote
# skeleton, the path views, the backstop views, the redclear fold, the judge's input) walks
# its bytes, and a run of 64 or more spaces, or of 64 or more tabs, is squeezed to one
# before any of them is made. One class at a time, never a mixed run to its first blank:
# `<<-` strips leading TABS only, so a tab then 64 spaces before a delimiter word is body
# text to bash, and squeezed to a lone tab it would close the body for the gate (the
# security review on this branch); squeezed within its class it stays a tab then a space,
# body text to both. Bash reads a run and its squeeze the same outside quotes; inside
# quotes and heredoc bodies the gate never needs the count. Only the gate's view changes:
# the command runs as sent, and the reservation hashes the tool input, not this view. A
# squeeze that fails keeps the bytes as they came; the clock below still bounds the walks.
_tab="$(printf '\t')"
_sq="$(printf '%s' "$CMD" | LC_ALL=C sed -E "s/ {64,}/ /g;s/${_tab}{64,}/${_tab}/g")" && [ -n "$_sq" ] && CMD="$_sq"
unset _sq _tab

# Quote-content-kept normalisation — used by the drop-table backstop below (the two
# red backstops read BACKSTOP_VIEW, the same normalisation over a body-stripped
# command). PATH patterns are matched inside maude_gate_eval, which builds its own
# canonicalised view.
# Strips quote CHARACTERS but keeps their content, so rm -rf "/srv/app"
# becomes rm -rf /srv/app for backstop matching. Also expands ~ and $HOME
# to the real home directory so quoted-path arguments in those checks still
# resolve correctly.
UNQUOTED="$(maude_home_view "$CMD")"
# The cap bounds what the gate READS, the expanded view included: `~` is one byte in the
# command and the home directory's length in every view that expands it (this one, the
# path view in the table walk, the backstop view the red-clear touch and the drop-table
# greps read), so 62,000 tildes under the byte cap made 600 KB of views and the stages
# past the clock outran the kill (the lens on 177319d, BLOCKING). A command whose
# home-expanded view passes the cap is refused whole, like one whose bytes do; the views
# built later expand text no longer than this one. Cost, named: a command spelling some
# 20,000 home paths is refused; split it.
_uq_bytes="$(printf '%s' "$UNQUOTED" | LC_ALL=C wc -c | tr -d ' ')"
if [ "$_uq_bytes" -gt "$MAUDE_GATE_BYTES_CAP" ]; then
  maude_log_trace "gate" "oversize-expanded=$_uq_bytes"
  printf 'Maude: this command expands to %s bytes once ~ and $HOME are spelled out, past the %s the gate can read inside its 5 s budget, so it is refused whole: split it, or spell fewer home paths.\n' "$_uq_bytes" "$MAUDE_GATE_BYTES_CAP" >&2
  exit 2
fi
unset _uq_bytes

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
# No run in a row may cross a separator. A run like `[^[:space:]]*` scanned to the next
# space from every place a match may start, and one 80 KB line of `a=1;` with a space at
# its end cost the git-push row's grep 45 s (quadratic: 5,000 segments 3 s, 20,000 48 s;
# the lens on c898dca, BLOCKING), one grep the clock between patterns cannot cut. With
# `;&|` out of the run a start at a `;` scans its own segment and no further, and the same
# grep is 10 ms. (An interval bound, `{0,255}`, made it slower: grep expands intervals.)
# maude_gate_eval applies the same exclusion to every row's runs (maude_nosep_pat). What
# it costs: an unquoted assignment value holding `;&|`, which bash reads as a separator
# too, is not a prefix; a quoted one is read by the judge, which keeps the quotes.
# A word known only at run time (`$x`, `${x:-}`, `$1`, `$(true)`, a backtick) in command
# position is a prefix too: with x unset bash runs the words after it, and `$x git push
# --force` passed every table rc 0 (2026-11-05). The judge reads the same shape and refuses
# a yellow token on it; this row keeps the plain form blocked on a box with no python3.
PREFIX='([A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*[[:space:]]+|command[[:space:]]+|(\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]|\{[^}[:space:];&|]*\}|\(\([^();&|]*\)\)|\([^();&|]*\))|`[^`;&|]*`)+[[:space:]]+)*'
# The rest of ONE simple command: a flag belongs to the verb only if no separator stands
# between them. `.*` ran past `&&`, so `git push … && git worktree remove --force x` was
# blocked RED as a force-push (2026-09-28). Newlines already split the match (grep is
# line-wise); `;` `&` `|` end a command.
SAME_CMD='[^;&|]*'
# The only characters a command may hold for SAME_CMD to apply (see maude_gate_eval).
PLAIN_CMD_RE='^[A-Za-z0-9 ./:=@+,%_~-]*([;&|]+[A-Za-z0-9 ./:=@+,%_~-]*)*$'
# A segment whose command word is `git` or an inert tool. CMD_START/PREFIX know
# env-assignments and `command `, nothing else, so `sudo git push -f` is invisible on its
# own; on a plain command the old greedy `.*` carried an EARLIER `git push` across the
# separator into it, and that accident was the only cover. The narrow match must not
# take it away (lens round 3 on 1da5501: `git push a; sudo git push -f` fell RED→YELLOW).
# A LIST OF WRAPPERS was the first answer, and lens round 4 ran 95 wrapper words through
# it: 48 were not on the list (`pct exec`, `docker exec`, `eval`, `.`, `FOO=1 sudo`, …)
# and every one lost the cover again. So, as with PLAIN_CMD_RE, an allowlist: the narrow
# match runs only when EVERY segment's command word is one of these. Anything else, a
# wrapper, an env-assignment, a tool this list does not know, keeps the greedy match.
# `git` counts only with a listed subcommand right after it: a global option GIT does not
# know (`git --no-pager push -f`, `git -c alias.x=push x -f`) hides the verb from the
# gate, and the earlier greedy carry was its only cover too (lens round 5); and some
# subcommands RUN their arguments (`git submodule foreach git push -f`, `git bisect run`,
# `git rebase -x`, `git for-each-repo`, difftool, mergetool, filter-branch), so "any
# plain subcommand" was a wrapper again (lens round 6). A user-config alias (`git p -f`)
# is not on this list and keeps the greedy match.
INERT_CMD_RE='^[[:space:]]*(git[[:space:]]+(add|am|apply|archive|blame|branch|checkout|cherry-pick|clean|clone|commit|describe|diff|fetch|grep|init|log|ls-files|ls-remote|merge|mv|notes|pull|push|reflog|remote|reset|restore|rev-list|rev-parse|revert|rm|shortlog|show|stash|status|switch|tag|worktree)([[:space:]]|$)|(echo|ls|rm|cd|true|false|tee|cat|grep|head|tail|sleep|test|mkdir|cp|mv|touch|wc|sort|date|pwd|printf)([[:space:]]|$))'
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
# …or a run-time expansion glued to the front of it: `${x}git push` is `git push` with x
# unset (2026-11-05, with the `$x git push` class). `$xgit` is one name and is not this.
ABS='(/[^[:space:];&|]*/|(\$\{[^}[:space:];&|]*\}|\$\([^();&|]*\)|`[^`;&|]*`)+(/[^[:space:];&|]*/)?)?'
# GIT = "git" + any global options (-C <dir>, -c <cfg>, --git-dir=<dir>) + the
# whitespace before the subcommand. Lets `git -C /repo push` / `git  push` (extra
# whitespace) match the same as `git push` — closing the v0.3.0 interior-space and
# `-C` bypasses. Interior token gaps use [[:space:]]+ everywhere for the same reason.
# …and a word known only at run time among them (`git $x push`): skipped, as bash does
# when it is empty (2026-11-05, the lens on 4b3cd91)
GIT="${ABS}"'git([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--git-dir[=[:space:]][^[:space:];&|]+|\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]|\{[^}[:space:];&|]*\}|\([^();&|]*\))|`[^`;&|]*`))*[[:space:]]+'
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
# What the gate promises, and which of these limits count, is docs/gate-threat-model.md:
# a limit below is a finding only in the tier that page puts it in.
#
# These gaps are acknowledged, not buried. They rely on the fail-closed bias
# plus (for MCP) the harness-deny backstop:
#
# Since the shell parser's read (below the backstops), the command keys (git push and
# its kin, the publishes, the rm -rf family) are also judged from the words bash would
# run. That closes, for those keys only, the heredoc-fed shell of #3, the prefixes and
# `\rm` of #6, and the dressed forms of tier B. The limits below still hold for the
# tables themselves, the red backstops and the sole-copy TARGET table.
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
#    line. The old residual (an UNBALANCED quote before `<<WORD` opened a
#    phantom body) closed 2026-10-03: the open quote is carried across lines
#    (maude_blank_outside_quotes), so a `<<` inside it is text.
#    2026-10-02: the blanking moved into ONE function (maude_blank_opener_line)
#    read by both the stripper and maude_heredoc_shell_fed, after a lens on the
#    merged main found the two copies had drifted (`\"` inside double quotes,
#    `$'…'`, a nested paren in `$(( ))`, `${x:-<<EOF}`) and the delimiter class
#    was narrower than bash's (`<<END-OF-FILE` keyed on `END`). Still open: a
#    `$((` nested two deep, and a delimiter outside MAUDE_HEREDOC_DELIM.
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
TPREFIX='((\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-]|\{[^}[:space:];&|]*\}|\(\([^();&|]*\)\)|\([^();&|]*\))|`[^`;&|]*`)+[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|command[[:space:]]+|exec[[:space:]]+|env[[:space:]]+|nohup[[:space:]]+|sudo([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+|timeout[[:space:]]+[0-9]+[smhd]?[[:space:]]+|nice([[:space:]]+-n[[:space:]]*[0-9]+)?[[:space:]]+|ionice([[:space:]]+-[^[:space:]]+)*[[:space:]]+|time[[:space:]]+|setsid[[:space:]]+|stdbuf([[:space:]]+-[^[:space:]]+)*[[:space:]]+|xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+|busybox[[:space:]]+|uv[[:space:]]+run[[:space:]]+)*'
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
maude_target_verb_in_command_position() {  # <command> [<its body-stripped, quote-stripped view>]
  local skeleton
  skeleton="${2:-$(maude_strip_quotes "$(maude_strip_heredocs "$1")")}"
  printf '%s' "$skeleton" | grep -qE -- \
    "${TSTART}${TPREFIX}${ABS}(${TVERB}|find|dd|rsync|python3?|perl|ruby|node)([[:space:]]|$)"
}

# ── COMMAND patterns — matched against $CMD via maude_match_gate_pattern
# (strip_quotes: content ERASED). This preserves all canaries — a commit message
# containing "git push" as literal text must not self-block the commit.
CMD_PATTERNS=(
  "${CMD_START}${PREFIX}${GIT}push[[:space:]]${SAME_CMD}--force-with-lease ||| force-push ||| force-push-with-lease detected. Still public-rewriting. Run /maude:conscience force-push if verified."
  "${CMD_START}${PREFIX}${GIT}push[[:space:]]${SAME_CMD}--force ||| force-push ||| force-push detected. Public, irreversible. Run /maude:conscience force-push if you have verified."
  "${CMD_START}${PREFIX}${GIT}push[[:space:]]${SAME_CMD}-f${FLAG_AFTER} ||| force-push ||| force-push (-f). Run /maude:conscience force-push if verified."
  "${CMD_START}${PREFIX}${GIT}push${FLAG_AFTER} ||| git-push ||| git push detected. Public, irreversible. Run /maude:conscience git-push to override."
  "${FLAG_BEFORE}--no-verify${FLAG_AFTER} ||| no-verify ||| --no-verify skips hooks. Run /maude:conscience no-verify if intentional."
  "${FLAG_BEFORE}--no-gpg-sign${FLAG_AFTER} ||| no-gpg-sign ||| --no-gpg-sign skips signing. Run /maude:conscience no-gpg-sign if intentional."
  "${CMD_START}${PREFIX}${GIT}reset[[:space:]]${SAME_CMD}--hard ||| reset-hard ||| git reset --hard loses local work. Run /maude:conscience reset-hard once you have stashed."
  "${CMD_START}${PREFIX}${GIT}filter-repo${FLAG_AFTER} ||| filter-repo ||| git filter-repo rewrites history. Run /maude:conscience filter-repo to override."
  "${CMD_START}${PREFIX}${GIT}filter-branch${FLAG_AFTER} ||| filter-branch ||| git filter-branch rewrites history. Run /maude:conscience filter-branch to override."
  "${CMD_START}${PREFIX}${GIT}commit[[:space:]]${SAME_CMD}--amend ||| commit-amend ||| git commit --amend rewrites the last commit. If pushed, this needs force-push. Run /maude:conscience commit-amend."
  "${CMD_START}${PREFIX}${ABS}$(maude_public_publish_re) ||| public-publish ||| public-facing publish (gh release / twine / uv publish / hf upload), only after the pre-public-push checklist and the account owner's go. Run /maude:conscience public-publish."
  # NOTE: DROP TABLE is NOT a CMD_PATTERN — matching the quote-ERASED skeleton
  # made it exactly backwards (missed quoted real SQL, fired on prose). It is
  # handled by the context-aware block below (content-kept view + SQL client).
)

# Evaluate the PATH + COMMAND pattern tables against ONE command string.
# Echoes "KEY ||| MSG" on the first red match, else the first match; returns 1 with no
# output otherwise.
# Used for the live command and (Task 8) recursively for wrapped payloads.
# Does NOT run the red-self-clear / redclear-write / drop-table backstops —
# those guard the literal live command only.
# The body-stripped, quote-stripped view is made ONCE and handed down (lens 5 on 8bfd395):
# every pattern of the table re-ran the stripper on the whole command, and the two
# command-position guards ran it twice more, ~0.7 ms per command line each, so 300 plain
# lines cost 4.5 s and 700 outran the 5 s budget, which blocks nothing. A payload (the
# wrapped-command walk) arrives without one and makes its own.
# A red hit wins over a yellow one that matched first: a token is per key, so the key a
# command is judged by must be its most severe (the commit security review on 965d025).
# Echoes "KEY ||| MSG" and returns 0 on a red key; a yellow one waits in _MAUDE_FIRST.
maude_gate_take() {  # <key> <msg>
  if maude_gate_key_red "$1"; then printf '%s ||| %s' "$1" "$2"; return 0; fi
  [ -n "$_MAUDE_FIRST" ] || _MAUDE_FIRST="$1 ||| $2"
  return 1
}
# The table walk of the LIVE command is on the walks' clock (maude_walk_overdue): a
# pattern tried past it means the tables were not read whole, and the walk stops CLOSED
# as parser-budget, red, which nothing clears (the padding bypass: under the byte cap, a
# killed hook blocks nothing, so a cut read refuses rather than runs out). Only the live
# command's walk is cut here (MAUDE_EVAL_CUT, set by its caller alone): a payload walk
# keeps its own rule, the clock between payloads in maude_wrapped_match, where a walk
# stopped on the clock is a partial read that refuses the yellow token.
maude_gate_cut() { [ -n "${MAUDE_EVAL_CUT:-}" ] && maude_walk_overdue; }
# maude_nosep_pat <ere> → the same row with `;&|` out of every `[^[:space:]]` run (see
# PREFIX). In-process, no fork (it runs once per row per command): the result is in _BP.
# Every [^[:space:]] in a pattern becomes [^[:space:];&|]: a run of non-space must not walk
# across a separator into the next command. By a walk, not a // substitution with a quoted
# replacement: bash 3.2 (macOS)
# keeps the quotes of a substitution's replacement as literal characters, so every target
# pattern carried stray quotes and matched nothing, and `FOO=1 mv <workspace> /tmp` passed
# (PR #90's macOS leg, 2026-11-09); unquoted, bash 5.2 reads the `&` as the matched text.
maude_nosep_pat() {
  local s="$1" out="" f='[^[:space:]]' r='[^[:space:];&|]'
  while [[ "$s" == *"$f"* ]]; do out="$out${s%%"$f"*}$r"; s="${s#*"$f"}"; done
  _BP="$out$s"
}
maude_budget_msg() { printf '%s' "the gate ran out of time before it had read this command's tables, so what it runs is unknown; nothing clears this key. Split the command."; }
maude_budget_hit() { printf 'parser-budget ||| %s' "$(maude_budget_msg)"; }
maude_gate_eval() {  # <command> [<its body-stripped, quote-stripped view>]
  local cmd="$1" sq="${2:-}" uq entry pat rest key msg _MAUDE_FIRST="" _nseg=0
  [ -n "$sq" ] || sq="$(maude_strip_quotes "$(maude_strip_heredocs "$cmd")")"
  uq="$(maude_canon_path_view "$(maude_home_view "$cmd")")"
  if maude_rm_in_command_position "$cmd" "$sq"; then
    for entry in "${PATH_PATTERNS[@]}"; do
      if maude_gate_cut; then maude_budget_hit; return 0; fi
      maude_nosep_pat "${entry%% ||| *}"; pat="$_BP"; rest="${entry#* ||| }"; key="${rest%% ||| *}"; msg="${rest#* ||| }"
      if printf '%s' "$uq" | grep -qE -- "$pat"; then maude_gate_take "$key" "$msg" && return 0; fi
    done
  fi
  if maude_target_verb_in_command_position "$cmd" "$sq"; then
    for entry in "${TARGET_PATTERNS[@]}"; do
      if maude_gate_cut; then maude_budget_hit; return 0; fi
      maude_nosep_pat "${entry%% ||| *}"; pat="$_BP"; rest="${entry#* ||| }"; key="${rest%% ||| *}"; msg="${rest#* ||| }"
      if printf '%s' "$uq" | grep -qE -- "$pat"; then maude_gate_take "$key" "$msg" && return 0; fi
    done
  fi
  # The narrow SAME_CMD match is sound only where every `;` `&` `|` is a real command
  # boundary. A list of constructs that hide one (`$( )`, backticks, escapes) missed
  # `${x//|/z}`, bracket globs, `2>&1` / `&>` / `>|` and a backslash line continuation
  # (lens round 2 on bf22c9d: 61 commands the old gate blocked, passed or fell to YELLOW).
  # So it is an ALLOWLIST, twice: the narrow match runs only on a command made of the
  # plain class (`A-Za-z0-9`, space, `./:=@+,%_~-`) and the separators themselves, and
  # only when every segment's command word is on INERT_CMD_RE; anything else keeps the
  # old greedy match, so the gate never blocks less than it did.
  # Linear in the bytes, each step: the blank test is a regex match, not a substitution
  # (`${seg//[[:space:]]/}` over a 100 KB segment was 5.7 s of bash, the padding bypass);
  # a run of separators is one line, not one empty line per separator; and the segment
  # loop asks the clock every 64 segments (130,000 `;` were 4 s of empty reads).
  local subst=1 seg
  if [[ "$cmd" =~ $PLAIN_CMD_RE ]]; then
    subst=""
    while IFS= read -r seg; do
      if [ $(( ++_nseg % 64 )) -eq 0 ] && maude_gate_cut; then maude_budget_hit; return 0; fi
      [[ "$seg" =~ [^[:space:]] ]] || continue
      [[ "$seg" =~ $INERT_CMD_RE ]] || { subst=1; break; }
    done < <(printf '%s\n' "$cmd" | tr -s ';&|' '\n\n\n')
  fi
  for entry in "${CMD_PATTERNS[@]}"; do
    if maude_gate_cut; then maude_budget_hit; return 0; fi
    pat="${entry%% ||| *}"; rest="${entry#* ||| }"; key="${rest%% ||| *}"; msg="${rest#* ||| }"
    [ -n "$subst" ] && pat="${pat//"$SAME_CMD"/.*}"
    maude_nosep_pat "$pat"; pat="$_BP"
    if printf '%s' "$sq" | grep -qE -- "$pat"; then maude_gate_take "$key" "$msg" && return 0; fi
  done
  [ -n "$_MAUDE_FIRST" ] || return 1
  printf '%s' "$_MAUDE_FIRST"
}

# Recursively inspect inspectable wrapped payloads up to a depth cap. Echoes
# "KEY ||| MSG" if any inspectable inner command is itself gated; else returns 1.
maude_wrapped_match() {
  local cmd="$1" depth="${2:-3}" payload m _MAUDE_FIRST=""
  [ "$depth" -le 0 ] && return 1
  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    # On the walks' clock: a hundred small payloads behind a yellow key ran the hook past
    # its 5 s (lens 4 on 13c95f8, BLOCKING). The gate counts an overdue walk as not read whole.
    maude_walk_overdue && break
    if m="$(maude_gate_eval "$payload")"; then maude_gate_take "${m%% ||| *}" "${m#* ||| }" && return 0; fi
    if m="$(maude_wrapped_match "$payload" "$((depth - 1))")"; then maude_gate_take "${m%% ||| *}" "${m#* ||| }" && return 0; fi
  done <<< "$(maude_wrapped_payloads "$cmd")"
  [ -n "$_MAUDE_FIRST" ] || return 1
  printf '%s' "$_MAUDE_FIRST"
}

MATCHED_KEY=""
MATCHED_RED_KEY=""
MATCHED_TIER=""
MATCHED_MSG=""
JUDGE_PARTIAL=""

# ── The body-stripped view, once, under two line caps ─────────────────────────
# The per-line walks are bash: the stripper costs ~0.7 ms per COMMAND line here, the
# shell-fed scan ~4 ms per line the stripper hands back (a heredoc that never closes, or
# a line it refuses, hands back everything after it). A 700-line plain command and a
# 5,000-line unclosed heredoc each outran the 5 s hook budget, which blocks nothing
# (lens 5 on 8bfd395). Past a cap the walk is skipped and the command is read WHOLE,
# bodies and all: closed, like the 4 KB opener line. Cost, named: a command over the
# cap that carries the red line in a note is blocked; split it.
MAUDE_GATE_CMD_LINES_CAP=2048
MAUDE_GATE_SCAN_LINES_CAP=256
# And the clock (maude_walk_overdue, _maude-common.sh): the line caps bound a count, the
# per-character walks cost by bytes and quotes, so each walk also stops closed once this
# many seconds of the hook's 5 have gone (lens 6 on 8a0de19).
# shellcheck disable=SC2034   # read by maude_walk_overdue in _maude-common.sh
MAUDE_WALK_T0="$SECONDS"
# The same start by the real clock, in microseconds, for the judge's budget below: SECONDS
# counts whole seconds from the shell's start, so a walk of 2.97 s could read as 2 and the
# judge be handed time the hook did not have, or read as 3 and the judge be skipped on a
# command the walk had read in time (2026-11-04). An older bash has no EPOCHREALTIME; the
# whole-second clock stands in.
# shellcheck disable=SC2034   # read by maude_walk_elapsed_us in _maude-common.sh
MAUDE_WALK_T0_US="${EPOCHREALTIME//[!0-9]/}"
# shellcheck disable=SC2034
MAUDE_WALK_BUDGET=3
# Called in-process, not in a `$( )`: the stripped text comes back in MAUDE_HD_STRIPPED
# and the bodies it took out in MAUDE_HD_BODIES, which a subshell could not hand back.
if [ "$(printf '%s\n' "$CMD" | wc -l)" -gt "$MAUDE_GATE_CMD_LINES_CAP" ]; then
  STRIPPED="$CMD"; MAUDE_HD_BODIES=(); MAUDE_HD_BODY_IDX=()
else
  maude_strip_heredocs "$CMD" >/dev/null
  STRIPPED="$MAUDE_HD_STRIPPED"
  while [[ "$STRIPPED" == *$'\n' ]]; do STRIPPED="${STRIPPED%$'\n'}"; done
fi
# The cut is the BLOCKING run's alone: the PostToolUse spend run re-reads the command to
# find the key it reserved under, and a walk cut there would key parser-budget, look in
# the red file, and leave the yellow reservation unspent for its 5 minutes (the commit
# security review on 177319d). A spend run that outruns the kill leaves it unspent too,
# as before this branch; the reservation is bound to the exact call and expires.
_cut=1; [ "$MODE" = "consume" ] && _cut=""
MATCHED="$(MAUDE_EVAL_CUT="$_cut" maude_gate_eval "$CMD" "$(maude_strip_quotes "$STRIPPED")")"
unset _cut
if [ -n "$MATCHED" ]; then
  MATCHED_KEY="${MATCHED%% ||| *}"
  MATCHED_MSG="${MATCHED#* ||| }"
fi

# Is any heredoc in this (body-stripped) command fed to something that RUNS the body?
# From the first opener line to the end of the command, blank what strip_heredocs blanks
# (herestrings, $((…)), quoted spans), split on `;` `|` `&`, and look for: a shell word
# standing alone (`bash`, `/bin/sh`, `sudo bash`, `docker exec -i c sh`, `pct exec 1 --
# bash`, `ssh host` whose remote shell reads stdin, `su`, `chroot`, `eval`, `screen`),
# `source` or `.` in command position, or `sudo` with a login/shell option. `x.sh`,
# `bash-tips.md` and `bash"` are not shell words; `bash<<EOF` is. Everything AFTER the
# opener counts, not one segment: `cat <<EOF > x.sh; chmod +x x.sh; bash x.sh`, `cat
# <<EOF | tee x | bash`, and a `bash x.sh` on a later line all run the body (lens round
# 2). The price is a text heredoc followed later by an unrelated shell word, which keeps
# the old reading; the commit-message shape `git add . && git commit -m "$(cat <<'EOF'`
# has nothing after it and `.` is not in command position. An interpreter (`python3 -`,
# `perl -`, `node -`, `make -f -`) is not on the list: a python body that quotes
# "bash -c '…'" is the incident this exists to pass, and one that runs it is
# indistinguishable from it; the plain patterns never read those bodies either.
# The opener line is not always where the command word is (lens on merged main, 2026-10-02):
# `bash \` ⏎ `<<EOF` joins by continuation, and `(` ⏎ `bash` ⏎ `) <<EOF` feeds a group, so the
# lines joined to the opener by a trailing `\`, and — when only a group closer stands before
# the `<<` — the group's lines back to its opener, are scanned with it. A shell held in a
# variable (`$SH <<EOF`, `"$SH"`) cannot be read, so a `$NAME` in command position counts as a
# shell: fail-closed, at the named cost that `$PYTHON - <<EOF` keeps its body in the scan.
maude_heredoc_shell_fed() {
  local stripped="$1" line scan tail="" seen="" target="" rest head="" before i
  local -a prior=()
  # Every line is read through maude_blank_opener_line — the SAME blanking the stripper
  # uses, so the two cannot disagree on what an opener is (`${0}` arrives as `$0`,
  # `${SHELL}` as `$SHELL`, `b\ash` as `bash`, `'bash'` as `bash`).
  local shellw='(^|[[:space:]/({`])(bash|sh|dash|zsh|ksh|fish|ash|csh|tcsh|rbash|mksh|pwsh|ssh|su|chroot|eval|screen|\$0|\$SHELL|\$BASH|proc/self/exe)([[:space:]);}<>`]|$)'
  # What may stand before the command word and leave it the command word: an assignment
  # (`FOO=1`, `FOO=$X`), a redirect (`</dev/null`, `<<EOF`, `2>&1`), or a wrapper with its
  # options. Each wrapper has its own option grammar, because an option that TAKES an argument
  # (`sudo -u root`, `nice -n 5`) must take it, attached or detached, and may not take nothing:
  # the first cut let `-u` take nothing, so `sudo -u $U tee <<EOF` read `$U` as the command
  # (lens round 2, false block); and `-n` is an argument-taker for nice but not for sudo, so
  # one shared letter set made `sudo -n -u $U` swallow `-u`. A detached argument never starts
  # with `-`. `--user root` (a long option with a detached argument) is not a prefix; open.
  local arg='([[:space:]]+[^-[:space:]][^[:space:]]*|[^[:space:]]+)'
  local sudo_o="[[:space:]]+(-[ugCDhpRTUrt]$arg|-[^-ugCDhpRTUrt[:space:]][^[:space:]]*|--[^[:space:]]*)"
  local nice_o="[[:space:]]+(-n$arg|-[^-n[:space:]][^[:space:]]*|--[^[:space:]]*)"
  # env -u NAME / -C dir / -S string; timeout -s SIG / -k DUR; exec -a NAME take an argument
  # (lens round 3: `env -u X $SH`, `timeout -s KILL 5 $SH`, `exec -a name $SH` ran the body).
  local env_o="[[:space:]]+(-[uCS]$arg|-[^-uCS[:space:]][^[:space:]]*|--[^[:space:]]*)"
  local tmo_o="[[:space:]]+(-[sk]$arg|-[^-sk[:space:]][^[:space:]]*|--[^[:space:]]*)"
  local exec_o="[[:space:]]+(-a$arg|-[^-a[:space:]][^[:space:]]*)"
  local ion_o="[[:space:]]+(-[cn]$arg|-[^-cn[:space:]][^[:space:]]*|--[^[:space:]]*)"
  local sb_o="[[:space:]]+(-[ioe]$arg|-[^-ioe[:space:]][^[:space:]]*|--[^[:space:]]*)"
  local gen_o='[[:space:]]+-[^[:space:]]*'
  local wrap="(sudo($sudo_o)*|nice($nice_o)*|env($env_o)*|exec($exec_o)*|ionice($ion_o)*|stdbuf($sb_o)*|timeout($tmo_o)*[[:space:]]+[0-9][^[:space:]]*|(nohup|time|command|builtin|setsid|chrt|unbuffer|doas)($gen_o)*)"
  # A keyword or `!` before the command word is not the command word either (`if $SH <<EOF`,
  # `! $SH <<EOF`, `while $SH`).
  local pfx="([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[0-9]*[<>][<>&|]?[^[:space:]]*|$wrap|if|then|else|elif|do|while|until|!)[[:space:]]+"
  local cmdw="^[[:space:]({]*($pfx)*(source|\.)[[:space:]]"
  # A shell held in a variable cannot be read; a `$NAME` (or a `${…}` expansion, which the
  # blanker hands over as `$X`) in command position counts as one, fail-closed. `{` and `(`
  # before it are group openers, not words.
  local varw="^[[:space:]({]*($pfx)*\\\$[A-Za-z_][A-Za-z0-9_]*([[:space:]<>)]|$)"
  local sudow='(^|[[:space:]])sudo[[:space:]].*(-[A-Za-z]*[is]|--login|--shell)([[:space:]]|$)'
  # Read and written by maude_blank_outside_quotes (_maude-common.sh): the quote and `$(` it
  # carries across lines. Reset per command so one call's open quote never leaks into the next.
  # shellcheck disable=SC2034
  MAUDE_INQ=""
  # shellcheck disable=SC2034
  MAUDE_DQSUB=""
  while IFS= read -r line || [ -n "$line" ]; do
    # A line past 4 KB, or a walk past its budget (maude_walk_overdue), is not read: the
    # body counts as shell-fed, which is closed (lens 6 on 8a0de19).
    if [ "${#line}" -gt 4096 ] || maude_walk_overdue; then return 0; fi
    # Through the same quote-carrying blanker as the stripper: a line inside a quote that
    # opened earlier is text, not an opener and not a shell word.
    maude_blank_outside_quotes "$line"; scan="$MAUDE_SCAN"
    if [ -z "$seen" ]; then
      case "$scan" in *'<<'*) ;; *) prior+=("$scan"); continue ;; esac
      seen=1
      # The head: lines joined to the opener by `\`⏎ …
      i=${#prior[@]}
      while [ "$i" -gt 0 ] && [[ "${prior[$((i-1))]}" == *\\ ]]; do
        i=$((i-1)); head="${prior[$i]%\\} $head"
      done
      # … and, when nothing but `)` / `}` stands before the `<<`, the group above it, back to
      # the line that opened it — counting nesting, so an inner `( cat )` on the way up does
      # not end the walk early (lens round 3) — or every prior line, if none does: fail-closed.
      before="${scan%%<<*}"
      local closer='^[[:space:])}]*$' depth=0 o c
      if [[ "$before" =~ $closer ]]; then
        depth="$(printf '%s' "$before" | tr -cd ')}' | wc -c)"; [ "$depth" -gt 0 ] || depth=1
        while [ "$i" -gt 0 ]; do
          i=$((i-1)); head="${prior[$i]}"$'\n'"$head"
          o="$(printf '%s' "${prior[$i]}" | tr -cd '({' | wc -c)"
          c="$(printf '%s' "${prior[$i]}" | tr -cd ')}' | wc -c)"
          depth=$((depth + c - o)); [ "$depth" -le 0 ] && break
        done
      fi
      scan="$head$scan"
      # The body written to a FILE that something later runs by path: `cat <<EOF > r.sh;
      # chmod +x r.sh; ./r.sh`, or `/tmp/r` on a later line, or `at -f r now`. Remember the
      # redirect target; if its name recurs as a word after the opener, the body runs.
      # The fd digits go with the redirect (`2>/dev/null $SH`): removing only `>/dev/null` left
      # a `2` standing as the command word (lens round 3).
      if [[ "$scan" =~ [0-9]*\>\>?[[:space:]]*([^[:space:]\;\|\&\<\>]+) ]]; then
        target="${BASH_REMATCH[1]}"
        rest="${scan#*"${BASH_REMATCH[0]}"}"
        scan="${scan%%"${BASH_REMATCH[0]}"*} $rest"
      fi
    fi
    tail+="$scan"$'\n'
  done <<< "$stripped"
  [ -n "$seen" ] || return 1
  if [ -n "$target" ]; then
    local t b
    t="$(printf '%s' "$target" | sed 's/[][\.*^$/+?(){}|]/\\&/g')"
    b="$(printf '%s' "${target##*/}" | sed 's/[][\.*^$/+?(){}|]/\\&/g')"
    # Recurs as a word: `./r.sh;echo`, `(./r.sh)`, `./r.sh>/dev/null` count (lens round 4);
    # `r.sh.bak` and `r.sh-old` do not.
    printf '%s' "$tail" | grep -qE "(^|[[:space:]/(])($t|$b)([^[:alnum:]_.-]|$)" && return 0
  fi
  printf '%s' "$tail" | tr ';|&' '\n\n\n' | grep -qE "$shellw|$cmdw|$varw|$sudow"
}

# ── The backstops' view of the command ───────────────────────────────────────
# A heredoc body is text unless a shell reads it. Every pattern in the table has read
# a body as data since v0.27.0 and the wrap scan since v0.34.0, but the two RED backstops
# below still grepped UNQUOTED with the bodies in it, so a vault note written through
# `cat >> note.md <<'EOF'` that QUOTED the red clear line was blocked as a self-clear
# (2026-10-08, live: documenting the trap sprang it). Same rule as the wrap scan, decided
# once here and reused there: bodies out, unless a shell is fed the heredoc (that body
# runs) or, for the two red backstops only, the body is written into a runnable file
# (see maude_heredoc_to_runnable_file below); then the whole command is read. Quote
# characters are stripped with
# their content kept and ~/$HOME expanded, exactly as UNQUOTED is, so a quoted path still
# resolves. The drop-table backstop keeps the whole-command view: a body that names both
# a SQL client and DROP TABLE fails closed by design (see its own note).
#
# One more thing the red backstops keep that the table does not (the lens on this change):
# a body written INTO A RUNNABLE FILE. `cat > f.sh <<'EOF'` carrying the clear line, a
# Makefile then `make` in the same command, `> ~/.bashrc`: main blocked those at authoring
# time by accident, and the second step (`bash f.sh`) carries no clear line, so for the
# reflex rail the write is the moment. A heredoc whose opener redirects (or tees) into a
# file that is not doc-shaped (maude_doc_re: .md .txt .json …, LICENSE, CHANGELOG…), or
# whose target cannot be read (`> "$F"`), keeps its body for the backstops; the 10-08 note
# (`>> note.md`) stays text. An allowlist of doc shapes, not a blocklist of script ones.
# Named residual: a doc-shaped file another tool runs (package.json then `npm run`, a CI
# yaml) is text here; that two-step is the harness deny-rules' job, as the script-file
# residual always was.
# Every stdout target on the opener line is read, not the last (the security lens: `> f.sh 2> err.md`
# hid the script behind a doc-shaped stderr); `/dev/null` is a sink, not a file. A doc-shaped
# target that the SAME command then names again as a word (`> notes.md; bash notes.md`,
# `make -f Makefile.txt`) is run, not read: its body stays too.
# ── Where does a heredoc body go? (the red backstops' second question) ───────
# Read on the OPENER LINES ONLY (the body-stripped command: a body line that documents
# `cat <<X > run.sh` is text, lens round 2 B4), by a quote-aware walk of each opener
# line, not a greedy sed (round 2 B1/B5: `>> "note.md"` read as the file `note.md"`,
# `--title "a -> b"` read as a redirect to `b"`). It prints one token per line:
#   S<TAB>words     the opener's own command segment (words up to `<<`, a pipe or a redirect)
#   P<TAB>words     a pipe segment
#   R<fd><TAB>name  a redirect: <fd> is "" for stdout, a digit string, "&" for &>/>&,
#                   or ends in "d" for a dup (>&N / >& name): the name follows.
# Quotes are removed from names and words with their content kept; a `\` escapes one char.
maude_opener_tokens() {  # <line>
  local s="$1" n=${#1} i=0 c q out="" fd j t seg kind
  _word() {  # reads a (possibly quoted) word at $i into $t; advances $i
    t=""
    while [ "$i" -lt "$n" ]; do
      c="${s:$i:1}"
      case "$c" in
        "'"|'"') q="$c"; i=$((i + 1))
          while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != "$q" ]; do t="$t${s:$i:1}"; i=$((i + 1)); done
          i=$((i + 1)) ;;
        '\') t="$t${s:$((i + 1)):1}"; i=$((i + 2)) ;;
        ' '|$'\t'|';'|'&'|'|'|'<'|'>') break ;;
        *) t="$t$c"; i=$((i + 1)) ;;
      esac
    done
  }
  _seg() {  # reads words at $i up to an unquoted ; & | < > into $seg
    seg=""
    while [ "$i" -lt "$n" ]; do
      c="${s:$i:1}"
      case "$c" in
        ' '|$'\t') seg="$seg "; i=$((i + 1)) ;;
        ';'|'&'|'|'|'<'|'>') break ;;
        *) _word; seg="$seg$t" ;;
      esac
    done
  }
  _seg; out+="S"$'\t'"$seg"$'\n'
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case "$c" in
      '>')
        fd=""; j=$((i - 1))
        while [ "$j" -ge 0 ]; do case "${s:$j:1}" in [0-9]) fd="${s:$j:1}$fd"; j=$((j - 1)) ;; *) break ;; esac; done
        [ -z "$fd" ] && [ "$j" -ge 0 ] && [ "${s:$j:1}" = '&' ] && fd='&'
        i=$((i + 1))
        [ "${s:$i:1}" = '>' ] && i=$((i + 1))
        [ "${s:$i:1}" = '|' ] && i=$((i + 1))
        if [ "${s:$i:1}" = '&' ]; then fd="${fd}d"; i=$((i + 1)); fi
        while [ "${s:$i:1}" = ' ' ] || [ "${s:$i:1}" = $'\t' ]; do i=$((i + 1)); done
        _word; out+="R$fd"$'\t'"$t"$'\n' ;;
      '|')
        if [ "${s:$((i + 1)):1}" = '|' ]; then i=$((i + 2)); _seg; out+="S"$'\t'"$seg"$'\n'; continue; fi
        i=$((i + 1)); _seg; out+="P"$'\t'"$seg"$'\n' ;;
      ';'|'&') i=$((i + 1)); _seg; out+="S"$'\t'"$seg"$'\n' ;;
      '<') i=$((i + 1)); case "${s:$i:1}" in '<') i=$((i + 1)); [ "${s:$i:1}" = '<' ] && i=$((i + 1)); [ "${s:$i:1}" = '-' ] && i=$((i + 1)) ;; esac
        while [ "${s:$i:1}" = ' ' ] || [ "${s:$i:1}" = $'\t' ]; do i=$((i + 1)); done
        _word ;;   # the delimiter, a file, or a herestring: never a body target
      *) i=$((i + 1)) ;;
    esac
  done
  printf '%s' "$out"
}
# Does a body written to <name> make it runnable? 0 = yes. Matched case-insensitively
# (LICENSE and NOTE.MD alike; round 3: lower-casing the name against the upper-case
# names in maude_doc_re lost LICENSE/CHANGELOG/AUTHORS) against the doc shapes plus the
# plain text names a note takes (README, NOTES, .log, .html…); the dev sinks are not files.
# A doc-shaped name the COMMAND names again as a word outside its own body (`> notes.md;
# bash notes.md`, `make -f Makefile.txt` on a later line) is run, not read; a body that names
# its own file ("see now_maude.md") is the 10-08 note and stays text (round 3, M2). The
# opener's own mention may follow `>` with no space, so the prefix class counts it.
# The OTHER bodies count too (the security review on c7cfaa6, 3): an interpreter body
# (`python3 - <<PY` ⏎ `os.system("bash notes.md")`) is never read by this scan, so a mention
# there is the one place a run of the note could hide. The own body is the one the stripper
# recorded under this line's index (MAUDE_HD_CUR_IDX; a closer line owns none, so the bodies
# inside its loop count). Cost, named: a second note that links the first (`[x](notes.md)`
# in a MEMORY.md append, a commit message naming it) reads the first's body, and blocks
# only when that body carries the red line.
maude_runnable_name() {  # <name> <stripped-command>
  local t b
  t="$1"; [ -n "$t" ] || return 0
  # A name bash would rewrite before opening (ANSI-C `$'f.sh\x00.md'`, a `$"…"`, a
  # substitution, a backtick, a backslash) is not the name this scan read: closed. A
  # plain `$VAR/notes.md` keeps its literal extension and stays a doc (round 2, B1).
  case "$t" in *'$'"'"*|*'$"'*|*'$('*|*'`'*|*'\'*) return 0 ;; esac
  case "$t" in /dev/null|/dev/stdout) return 1 ;; esac
  if ! printf '%s' "$t" | grep -qiE "$(maude_doc_re)" \
     && ! printf '%s' "$t" | grep -qiE '(^|/)(readme|notes?|todo|changes|history|news)$|\.(log|html?|xml|css|tex|org|rtf|diff|patch|out|err)$'; then
    return 0
  fi
  b="$(printf '%s' "${t##*/}" | sed 's/[][\.*^$/+?(){}|]/\\&/g')"
  # `<` is in the prefix class: `bash<notes.md` runs it (lens 4, M1).
  local re="(^|[[:space:]/(<>&|=\"'])$b([^[:alnum:]_.-]|$)" n i own=0
  n=""
  # The other bodies, gathered ONCE per opener line and grepped once per target: a grep per
  # body per target was quadratic, and past ~40 heredocs it outran the 5 s hook budget,
  # which blocks nothing (lens 4, B2). Quote characters out with their content kept, as the
  # stripped text is (`n''otes.md`), and grepped in BOTH views: unquoting deletes the quote
  # that was the only prefix of `["bash","notes.md"]` (lens 5, B1). A line that opens two
  # heredocs owns both, and which of them its redirect takes is not traced here: both count
  # (lens 4, B1: the python body on the note's own line was dropped as "own").
  if [ "${MAUDE_HD_OTHERS_IDX:-unset}" != "${MAUDE_HD_CUR_IDX:-}" ]; then
    MAUDE_HD_OTHERS="" MAUDE_HD_OTHERS_UQ="" MAUDE_HD_OTHERS_IDX="${MAUDE_HD_CUR_IDX:-}"
    for i in "${!MAUDE_HD_BODY_IDX[@]}"; do
      [ "${MAUDE_HD_BODY_IDX[$i]}" = "${MAUDE_HD_CUR_IDX:-}" ] && own=$((own + 1))
    done
    for i in "${!MAUDE_HD_BODIES[@]}"; do
      [ "$own" -eq 1 ] && [ "${MAUDE_HD_BODY_IDX[$i]}" = "${MAUDE_HD_CUR_IDX:-}" ] && continue
      MAUDE_HD_OTHERS+="${MAUDE_HD_BODIES[$i]}"$'\n'
    done
    [ -n "$MAUDE_HD_OTHERS" ] && MAUDE_HD_OTHERS_UQ="$(maude_unquote "$MAUDE_HD_OTHERS")"
  fi
  # One count over the three texts (the stripped command, the other bodies raw and
  # unquoted): one pipeline per target, not three.
  n="$(printf '%s\n%s\n%s\n' "$2" "$MAUDE_HD_OTHERS" "$MAUDE_HD_OTHERS_UQ" | grep -oiE "$re" | wc -l)"
  [ "$n" -ge 2 ]
}
# tee's operands, every one (lens: `| tee notes.md f.sh`); only its own flags are options,
# `--` ends them, any other dash word is a file it would write (`tee -- -f.sh`).
maude_tee_writes_runnable() {  # <words after tee...> <stripped-command>
  local eoo=0 t cmd="${*: -1}"
  set -- "${@:1:$(($# - 1))}"
  for t in "$@"; do
    if [ "$eoo" = 0 ]; then
      case "$t" in --) eoo=1; continue ;; -a|-i|-p|--append|--ignore-interrupts|--output-error*) continue ;; -*) return 0 ;; esac
    fi
    maude_runnable_name "$t" "$cmd" && return 0
  done
  return 1
}
# A pipe segment that stays text: a pure reader, or an interpreter reading its program
# from stdin and nothing else (`python3 -`). sed/awk/sort/uniq/xxd and an interpreter
# with -c/-e or a script operand can write files: closed.
maude_pipe_segment_is_text() {  # <words...>
  local w
  case "${1##*/}" in
    cat|grep|egrep|fgrep|head|tail|wc|less|more|tr|cut|nl|rev|base64|shasum|cksum|cmp|diff|column|fold|fmt|jq) return 0 ;;
    python3|python|perl|ruby|node|php|lua)
      shift
      for w in "$@"; do [ "$w" = "-" ] || return 1; done
      return 0 ;;
  esac
  return 1
}
# 0 = some heredoc body in <stripped> (the body-stripped command) is written into a file
# a shell, make or an interpreter would run; the "named again" check reads the same
# stripped text, so a body naming its own file is text. Three readers, in order, on every
# opener line, and the redirects and pipes of a closer line after it (`done > f.sh`,
# `fi | tee f.sh`; round 3, B3). An opener line past 4 KB is closed unread: the walk is
# per character and a 32 KB line took the hook past its 5 s budget (round 3, M5):
#   the opener's own command word: a known WRITER takes the body (`tee f.sh <<EOF`,
#     `dd of=`, `sponge`, `cp /dev/stdin f.sh`, `install /dev/stdin f.sh`; round 2 M1);
#     any other word is the commit/gh/psql/python class and is read by its redirects alone
#     (named residual: a writer not on this list);
#   every redirect that carries STDOUT (fd "", 1, `&>`; a `2>` carries no body, round 2
#     B2/M2): an fd dup (`>&1`, `>&-`) is a sink, `>& name` is the csh spelling of a file;
#   every pipe segment by its command word: tee by its operands, a reader or `python3 -`
#     is text, anything else is closed.
# An empty name after `>` or an empty pipe segment is an operator this scan cannot read:
# closed.
maude_heredoc_to_runnable_file() {  # <stripped>
  local line tok kind name dup dupfd others opened peeled closer
  local -a w
  # An fd opened by `exec` on another line (`exec 3>f.sh`, then `>&3`) is state this
  # line-at-a-time scan does not carry: a command that does both is closed outright.
  # Read on the quote-stripped view: `ex""ec` is exec to bash (the security lens).
  name="$(maude_unquote "$1")"
  if printf '%s' "$name" | grep -qE '(^|[^[:alnum:]_])exec([[:space:]]|$)' && printf '%s' "$name" | grep -q '>'; then return 0; fi
  # More than 32 stripped bodies is closed unread, like the 4 KB opener line: the walk and
  # the named-again count grow with the number of openers, and the count of heredocs is a
  # path to the hook budget an opener-line cap does not bound (lens 4, B2). The cap sits
  # where the walk AT the cap fits the clock (maude_walk_overdue): 32 notes each quoting
  # the red line take ~1.2 s here, 64 took 3 s and were closed by the clock instead.
  [ "${#MAUDE_HD_BODIES[@]}" -gt 32 ] && return 0
  MAUDE_HD_OTHERS="" MAUDE_HD_OTHERS_UQ="" MAUDE_HD_OTHERS_IDX="unset"
  # Lines are walked as the stripper emitted them, never joined on a trailing `\`: the
  # stripper admits no backslash outside a delimiter, so a continued command line ends the
  # stripping and its body reaches the backstops raw; the one admitted line that can end in
  # `\` is a COMMENT, which bash does not join, and joining it swallowed the next opener's
  # writer (`echo # \` ⏎ `tee f.sh <<EOF`; the security review on c7cfaa6, 2).
  # `idx` is the line's index in the stripped text: the key the stripper recorded each body
  # under (MAUDE_HD_BODY_IDX), so the named-again count can leave out THIS line's own body.
  local idx=-1
  while IFS= read -r line; do
    idx=$((idx + 1))
    # Past the walk's budget (maude_walk_overdue): closed, like the 4 KB opener line below.
    maude_walk_overdue && return 0
    # Opener lines, and closer lines (`done`, `fi`, `esac`, `}`, `)`) that carry an
    # operator: a redirect on a loop or if closer takes every body inside (round 3, B3).
    # (A `{ … }` group's heredoc is never stripped by maude_strip_heredocs, so the backstops
    # read it whole already; the closer arm covers the loop and if shapes, which are.)
    closer=0
    case "$line" in
      *'<<'*) ;;
      *) case "$line" in *'>'*|*'|'*) ;; *) continue ;; esac
         # a closer word at the start of ANY segment of the line (`break; done > f.sh`;
         # the security lens), read with the operators blanked by quotes ignored
         # (`done>f.sh`: the word ends at `<` or `>` too — the security review on c7cfaa6, 1.)
         if printf '%s' "$line" | tr ';&|' '\n\n\n' | grep -qE '^[[:space:]]*(done|fi|esac|\}|\))([[:space:]<>]|$)'; then closer=1; else continue; fi ;;
    esac
    [ "${#line}" -gt 4096 ] && return 0
    MAUDE_HD_CUR_IDX="$idx"
    # A dup of stdout onto a numeric fd (`>&2`, `>&3`), or onto a /dev or /proc alias of
    # one (`>/dev/stderr`, `>/dev/fd/3`), sends the body wherever that fd points, and
    # `2>f.sh` may stand before or after it (the security lens, twice): when the line dups
    # stdout, every file target of every fd on it is read. Closed, not traced.
    dup=0; dupfd=""; others=""; opened=" "
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      kind="${tok%%$'\t'*}"; name="${tok#*$'\t'}"
      case "$kind" in
        S)
          [ "$closer" = 1 ] && continue   # `done`, `fi`: not a command word
          read -r -a w <<< "$name"
          # An opener inside a compound command (`do cat <<EOF`, `then …`, `if …`) has a
          # closer this scan does not trace: closed (the security lens).
          case "${w[0]}" in do|then|else|elif|if|while|until|for|case|select|'{'|'(') return 0 ;; esac
          # A writer may stand behind an assignment or a wrapper (`FOO=1 sudo -u x tee f.sh`,
          # the security lens): peel those, with the options that take an argument, before
          # reading the command word. A wrapper whose argument grammar is not known here
          # is read no further: closed.
          peeled=0
          while [ "${#w[@]}" -gt 0 ]; do
            case "${w[0]##*/}" in
              [A-Za-z_]*=*) w=("${w[@]:1}"); peeled=1 ;;
              sudo|doas|env|nice|ionice|nohup|command|builtin|exec|time|setsid|chrt|unbuffer|stdbuf|t[i]meout)
                name="${w[0]##*/}"; w=("${w[@]:1}"); peeled=1
                while [ "${#w[@]}" -gt 0 ]; do
                  case "$name:${w[0]}" in
                    sudo:-[ugCDhpRTUrt]|doas:-[uCa]|env:-[uCS]|nice:-n|ionice:-[cn]|stdbuf:-[ioe]|t[i]meout:-[sk]|chrt:-p|time:-[of]) w=("${w[@]:2}") ;;
                    *:--user|*:--group|*:--signal|*:--kill-after|*:--class|*:--classdata|*:--adjustment|*:--chdir|*:--unset|*:--split-string|*:--input|*:--output|*:--error|*:--host|*:--role|*:--prompt|*:--other-user|*:--format) w=("${w[@]:2}") ;;
                    *:--*=*) w=("${w[@]:1}") ;;
                    *:-*) return 0 ;;   # an option whose arity this scan does not know: closed
                    *) break ;;
                  esac
                done
                # the duration / the priority (spelled so the portability lint sees no call)
                case "$name" in t[i]meout|chrt) w=("${w[@]:1}") ;; esac ;;
              *) break ;;
            esac
          done
          [ "${#w[@]}" -gt 0 ] || return 0
          # Behind a wrapper or an assignment only a known WRITER is read further (its
          # operands are checked below); any other word there is closed: a wrapper whose
          # argument grammar this scan misread would otherwise hand the body to a word it
          # took for a reader (the security lens, twice).
          if [ "$peeled" = 1 ]; then
            case "${w[0]##*/}" in tee|dd|sponge|cp|install|mv) ;; *) return 0 ;; esac
          fi
          case "${w[0]##*/}" in
            tee) maude_tee_writes_runnable "${w[@]:1}" "$1" && return 0 ;;
            dd) for name in "${w[@]:1}"; do case "$name" in of=*) maude_runnable_name "${name#of=}" "$1" && return 0 ;; esac; done ;;
            sponge|cp|install|mv) [ "${#w[@]}" -ge 2 ] && maude_runnable_name "${w[${#w[@]}-1]}" "$1" && return 0 ;;
            # A body handed to a scheduler runs; a body handed to xargs goes to a command
            # this scan cannot see (round 3, B2): closed.
            xargs|crontab|at|batch) return 0 ;;
          esac ;;
        P)
          read -r -a w <<< "$name"
          [ "${#w[@]}" -gt 0 ] || return 0
          case "${w[0]##*/}" in
            tee) maude_tee_writes_runnable "${w[@]:1}" "$1" && return 0 ;;
            *) maude_pipe_segment_is_text "${w[@]}" || return 0 ;;
          esac ;;
        R|R1|'R&')
          # An EXACT alias of an fd dups it; `/dev/fd/../../tmp/f.sh` is a path (the
          # security lens) and goes to the name check, where it closes.
          if [ "$name" = /dev/stderr ] || [ "$name" = /dev/stdout ] || printf '%s' "$name" | grep -qE '^/(dev|proc/self)/fd/[0-9]+$'; then
            dup=1; dupfd="${name##*/}"; case "$dupfd" in stderr) dupfd=2 ;; stdout) dupfd=1 ;; esac
          else
            maude_runnable_name "$name" "$1" && return 0
          fi ;;
        Rd|R1d|'R&d')
          # a dup of stdout: `>&N` sends the body to fd N (see dup above), `>&-` closes
          # it, `>& name` is the csh file
          case "$name" in ''|-) ;; *) if printf '%s' "$name" | grep -qE '^[0-9]+$'; then dup=1; dupfd="$name"; else maude_runnable_name "$name" "$1" && return 0; fi ;; esac ;;
        R2d) : ;;   # `2>&1`: stderr onto stdout, the body is not in it
        R*d) return 0 ;;   # a dup of an fd above 2 (`3>&4`): a chain this scan does not follow, closed
        R*) others="$others"$'\n'"$name"; opened="$opened ${kind#R} " ;;   # a file on another fd: read only if stdout is dup'd
      esac
    done <<< "$(maude_opener_tokens "$line")"
    if [ "$dup" = 1 ]; then
      # A dup onto an fd above 2 that this line does not open was opened elsewhere (an
      # exec this scan did not see, a `3>` on another line): closed (the security lens).
      case "$dupfd" in 0|1|2) ;; *) case "$opened" in *" $dupfd "*) ;; *) return 0 ;; esac ;; esac
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        maude_runnable_name "$name" "$1" && return 0
      done <<< "$others"
    fi
  done <<< "$1"
  return 1
}
# Every stage below runs until the key is red, not until there is one: a yellow match
# from the tables must not stop the red stages from reading the rest (the commit
# security review on 965d025: `git push; \rm -rf /` was keyed git-push, and a yellow
# token Claude may mint passed the rm). A red stage replaces a yellow key; a yellow one
# never replaces anything.
WCMD=""; BACKSTOP_VIEW=""
if ! maude_gate_key_red "$MATCHED_KEY"; then
  if [ "$(printf '%s\n' "$STRIPPED" | wc -l)" -gt "$MAUDE_GATE_SCAN_LINES_CAP" ]; then
    WCMD="$CMD"; BV="$CMD"   # past the scan cap (see above): read whole, closed
  else
    WCMD="$STRIPPED"
    maude_heredoc_shell_fed "$WCMD" && WCMD="$CMD"
    BV="$WCMD"
    # The inequality is a cost skip only (no heredoc, nothing to ask): the verdict is the same.
    [ "$STRIPPED" != "$CMD" ] && maude_heredoc_to_runnable_file "$STRIPPED" && BV="$CMD"
  fi
  BACKSTOP_VIEW="$(maude_home_view "$BV")"
fi

# ── Red-key self-clear backstop (v0.10.0) ────────────────────────────────────
# Claude must not self-authorize a RED gate key by running the clear-script via
# the Bash TOOL (which fires this hook). John's ! line runs in his shell and
# skips PreToolUse, so it is unaffected — that channel asymmetry is the whole
# discriminator. Matched against the body-stripped BACKSTOP_VIEW (quote content kept)
# so a quoted script path still resolves and a heredoc that merely quotes the line
# does not.
# SOFT: a direct care.json Write bypasses this (the gate is Bash-only, the token
# carries no provenance); the harness deny-rules in .scratch/maude-spine-deny.json
# are the real, unbypassable layer. The 'red-self-clear' block key is itself not
# clearable here (maude-clear-gate.sh refuses unknown keys).
# WIDENED 2026-07-30: the arg run was `-[^space]+`, i.e. only FLAGS, so a flag VALUE
# before the key slipped past — `maude-clear-gate.sh --marker abc sole-copy-target`
# was measured ALLOWED by a redteam while the same command with the key first was
# blocked. Now any token run precedes the key. Still bypassable by wrapping the call
# in a script file; that residual is the harness deny-rules' job, not this grep's.
if ! maude_gate_key_red "$MATCHED_KEY"; then
  for _rk in $(maude_red_keys); do
    # The key may be followed by a separator, not only blank or end: UNQUOTED joins lines
    # with `;`, so `… force-push` ⏎ `echo hi` read as `force-push;echo` and passed (the
    # lens on this change; it passed on main too).
    if printf '%s' "$BACKSTOP_VIEW" | grep -qE -- "maude-clear-(gate|red)\.sh([[:space:]]+[^[:space:]]+)*[[:space:]]+${_rk}([[:space:];&|()<>\`}]|$)"; then
      MATCHED_KEY="red-self-clear"
      MATCHED_RED_KEY="$_rk"
      MATCHED_MSG="self-clearing a red key from the tool gate is blocked; this is the account owner's hand. "
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
# BACKSTOP_VIEW (quote content kept, heredoc bodies out unless shell-fed or written
# into a runnable file) so a quoted path still resolves and a note that quotes the
# redirect does not.
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
# 2026-11-03 (ported from fix/gate-false-pass, 10-19): the verb-and-redirect net above
# lost to sed -i, >|, tee -a, xargs, a name parked in a variable, a write inside a loop
# body (lens 8 on that branch; 25 of its 46 cases passed main's gate on 11-02). Now an
# ALLOWLIST (maude_redclear_touch): when a command names the file by its stem, in any
# case or spelling the view can fold, every command word in it must be a plain reader
# and no redirect may point into the file, into a quoted target, or into one the shell
# builds. Anything else is refused, the honest cost included: a read beside other work,
# a read copied into a quoted path, or a commit message that spells the file is refused
# too, and the refusal says why. What the view cannot see is listed on the function.
if ! maude_gate_key_red "$MATCHED_KEY"; then
  # the skeleton is STRIPPED (heredocs out) with its quoted spans erased, each leaving one
  # the skeleton is STRIPPED (heredocs out) with its quoted spans erased, each leaving one
  # marker byte (the rule reads a marker as a word the shell builds), when the view was
  # built from STRIPPED; when a heredoc re-admitted the raw command whole (shell-fed, or
  # written to a runnable file) there is no skeleton for it and the content view stands in
  # (pinned: a bash-fed heredoc writing the file refuses). Past the scan cap with no
  # heredoc, STRIPPED is CMD and the skeleton is passed as usual.

  if maude_redclear_touch "$BACKSTOP_VIEW" "$([ "$BV" = "$STRIPPED" ] && MAUDE_SQ_MARK=1 maude_strip_quotes "$STRIPPED")"; then
    MATCHED_KEY="redclear-write"
    MATCHED_TIER="red"
    # The label says what was read (2026-11-05): one line said "names the token file" for
    # every refusal, and most refusals named no token at all (a closet path beside an
    # expansion the fold could not read, refused unread as the rule says); a refusal that
    # states the wrong reason is a lying refusal, and a gate that lies gets switched off.
    _rc_rule="a command that names the red-clear token file may only read it (cat, grep, jq, a checksum, a test): writes, moves and rewrites are the account owner's hand only, by a ! line pasted in their own shell. /maude:conscience shows the line to paste."
    _rc_how="${MAUDE_REDCLEAR_WHY#*:}"; _rc_how="${_rc_how%%:*}"
    case "$_rc_how" in
      built) _rc_named="this command names a word inside .maude/plugin the gate cannot read whole (a \$(…), a glob character, quoted or not, a brace, a backtick), which it must read as the red-clear token file, and" ;;
      *)     _rc_named="this command names the red-clear token file and" ;;
    esac
    case "${MAUDE_REDCLEAR_WHY:-}" in
      unread)     MATCHED_MSG="this command spells \`.maude\` beside something the gate could not read (a \$(…), a \${X:-…}, a \$NAME it did not see assigned, a binding builtin, a cd), so what it names there is unknown and it is refused unread; a write elsewhere in it was not read either. The rule: $_rc_rule Name the path as a literal in its own call, or move the expansion out." ;;
      unread:cap) MATCHED_MSG="this command spells \`.maude\` and holds more than the gate's fold reads (more than 64 literal assignments, a value past 4 KB, or more than 64 KB of text), so what it names there is not read whole and it is refused unread; a write elsewhere in it was not read either. The rule: $_rc_rule Split it into smaller calls." ;;
      redirect:*) MATCHED_MSG="$_rc_named redirects into it, or into a target the shell quotes or builds. The rule: $_rc_rule" ;;
      word:*)     MATCHED_MSG="$_rc_named has \`${MAUDE_REDCLEAR_WHY#word:*:}\` beside it, read as a command word, and that is not a plain reader (the gate takes the first word after every \`;\` \`&\` \`|\` \`(\` \`)\` \`{\` \`}\` or backtick as one that may run, so a case pattern, an arithmetic operand, an array element, a function name or a comment there reads the same). The rule: $_rc_rule Split the read from the other work into its own call." ;;
      *)          MATCHED_MSG="$_rc_rule Split a read from other work into its own call." ;;
    esac
    unset _rc_rule _rc_how _rc_named
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
if ! maude_gate_key_red "$MATCHED_KEY"; then
  if printf '%s' "$UNQUOTED" | grep -qiE -- 'drop[[:space:]]+table' &&
     printf '%s' "$UNQUOTED" | grep -qiE -- '(^|[[:space:];&|(`])(psql|mysql|mariadb|sqlite3|sqlplus)([[:space:]]|$)'; then
    MATCHED_KEY="drop-table"
    MATCHED_MSG="SQL DROP TABLE in an execution context. Run /maude:conscience drop-table to override."
  fi
fi

# ── The shell parser's read (maude_shell/judge.py) ───────────────────────────
# The tables above guess at bash from text; the parser reads it the way bash does and
# judges the words: a quoted or escaped command word, brace expansion, a wrapper, `~`,
# `$HOME`, `${HOME}`, a payload fed to a shell (tier B of docs/gate-threat-model.md). It
# runs until the key is red and can only ADD a block or raise a yellow key to red: the
# tables' verdicts stand, and a missing python3 leaves today's verdict alone. A command
# it cannot read whole refuses a yellow token at the token check (JUDGE_PARTIAL); a slow
# read is cut, and counts the same. It sits before the wrapped-payload walk because that walk passes
# a command whose payload it cannot read (`bash -c "$x"; \rm -rf /` would leave there).
# The red backstops and the sole-copy TARGET table stay on the regex.
maude_judge_msg() {  # <key> → the message the tables give that key
  case "$1" in
    force-push) printf '%s' "force-push detected. Public, irreversible. Run /maude:conscience force-push if you have verified." ;;
    git-push) printf '%s' "git push detected. Public, irreversible. Run /maude:conscience git-push to override." ;;
    reset-hard) printf '%s' "git reset --hard loses local work. Run /maude:conscience reset-hard once you have stashed." ;;
    commit-amend) printf '%s' "git commit --amend rewrites the last commit. If pushed, this needs force-push. Run /maude:conscience commit-amend." ;;
    filter-repo) printf '%s' "git filter-repo rewrites history. Run /maude:conscience filter-repo to override." ;;
    filter-branch) printf '%s' "git filter-branch rewrites history. Run /maude:conscience filter-branch to override." ;;
    no-verify) printf '%s' "--no-verify skips hooks. Run /maude:conscience no-verify if intentional." ;;
    no-gpg-sign) printf '%s' "--no-gpg-sign skips signing. Run /maude:conscience no-gpg-sign if intentional." ;;
    public-publish) printf '%s' "public-facing publish (gh release / twine / uv publish / hf upload), only after the pre-public-push checklist and the account owner's go. Run /maude:conscience public-publish." ;;
    rm-rf-root) printf '%s' "\"rm -rf /\" wipes the system. STOP. Run /maude:conscience rm-rf-root only if you really mean it." ;;
    rm-rf-glob) printf '%s' "\"rm -rf *\" — wide blast. Run /maude:conscience rm-rf-glob if you mean it." ;;
    sudo-rm-rf) printf '%s' "sudo rm -rf is destructive at root. Run /maude:conscience sudo-rm-rf if intentional." ;;
    parser-depth) printf '%s' "the command nests deeper than the shell parser reads, so what it runs is unknown; nothing clears this key. Flatten or split the command." ;;
    parser-budget) maude_budget_msg ;;
    rm-rf-sole-copy) printf '%s' "rm -rf of a protected sole-copy path (workspace / repo root / .git / configured path), or of a directory holding one. Sole copy, no fallback. Run /maude:conscience rm-rf-sole-copy only if you truly mean it." ;;
    *) return 1 ;;
  esac
}
# The judge gets the time the hook has left, at most its 2 s: the tables, the walks and
# the judge in turn on a padded command outran the hook's 5 s, and a killed hook blocks
# nothing (lens 3 on 652bbd9, BLOCKING-1). MAUDE_GATE_JUDGE_BUDGET: whole seconds from the
# walks' start (default 3). Past the budget the judge does not run, and the command counts
# as not read whole, which on a command with no key is red (below). Under the budget it
# always gets a second, measured by the real clock: a twenty-heredoc command whose walk
# took 2.97 s was refused for want of a judge the whole-second clock could not fit
# (2026-11-04). The judge is done by budget + 1 s real, 4 s of the hook's 5, at the latest.
_EL_US="$(maude_walk_elapsed_us)" || _EL_US=999999999   # a clock it cannot read: no time
case "${MAUDE_GATE_JUDGE_BUDGET:-}" in ''|*[!0-9]*) MAUDE_GATE_JUDGE_BUDGET=3 ;; esac   # whole seconds, or the default
_JB_US=$(( 10#$MAUDE_GATE_JUDGE_BUDGET * 1000000 ))
if [ "$_EL_US" -ge "$_JB_US" ]; then
  _JUDGE_SECS=0
else
  _JUDGE_SECS=$(( (_JB_US - _EL_US) / 1000000 ))
  [ "$_JUDGE_SECS" -lt 1 ] && _JUDGE_SECS=1
  [ "$_JUDGE_SECS" -gt 2 ] && _JUDGE_SECS=2
fi
unset _EL_US _JB_US
if ! maude_gate_key_red "$MATCHED_KEY" && [ "$_JUDGE_SECS" -lt 1 ]; then
  maude_log_trace "gate" "parser=skipped-no-time"
  JUDGE_PARTIAL=1
  JUDGE_CUT=1
elif ! maude_gate_key_red "$MATCHED_KEY"; then
  # One line per key hit, in run order: take the first red one, else the first yellow
  # one when nothing above matched. A last "unreadable" line means part of the command
  # was not read (JUDGE_PARTIAL, used at the token check below: "opaque" for a payload
  # known only at run time, "unreadable" for text that does not parse, which also sets
  # JUDGE_UNREAD); "cut" that the clock ended the read (JUDGE_CUT, read below).
  while IFS= read -r JV; do
    [ "$JV" = "unreadable" ] && { JUDGE_PARTIAL=1; JUDGE_UNREAD=1; }
    [ "$JV" = "opaque" ] && JUDGE_PARTIAL=1
    [ "$JV" = "cut" ] && JUDGE_CUT=1
    case "$JV" in "block "*) ;; *) continue ;; esac
    JV="${JV#block }"; _jk="${JV%% *}"; _jw="${JV#"$_jk"}"; _jw="${_jw# }"
    _jm="$(maude_judge_msg "$_jk")" || continue
    # the tables keyed it first: the judge's words still reach the label (the lens on 4b3cd91, finding 4)
    [ "$_jk" = "$MATCHED_KEY" ] && [ -z "${JUDGE_SAID:-}" ] && JUDGE_SAID="$_jw"
    if maude_gate_key_red "$_jk" || [ -z "$MATCHED_KEY" ]; then
      maude_log_trace "gate" "parser=$_jk"
      MATCHED_KEY="$_jk"
      MATCHED_MSG="$_jm (read through the shell parser as: $_jw)"
      JUDGE_SAID="$_jw"   # the two refusal paths that cut the message at its conscience sentence print it on their own
      maude_gate_key_red "$_jk" && break
    fi
  done <<< "$(maude_shell_judge "$CMD" "$_JUDGE_SECS")"
fi
# A judge the clock cut, skipped for want of time, or started and died, on a command the
# tables did not key:
# red, parser-budget, the same rule as a table walk the clock cut. Until 2026-11-04 the
# command passed ("a command with no key still passes"), and `env -C <dir> git push`, keyed
# by the judge alone, ran whenever the judge was cut, as it was under a loaded suite. A
# fail-closed rule ends what more parsing cannot. The judge that cannot START (no python3)
# is the soft dependency it always was: the tables' verdict stands. Cost, named: on a box
# slow enough to cut the judge, a plain command is refused too; it passes on retry.
if [ -n "${JUDGE_CUT:-}" ] && [ "$MODE" != "consume" ] && [ -z "$MATCHED_KEY" ]; then
  maude_log_trace "gate" "parser=cut-no-key"
  MATCHED_KEY="parser-budget"
  MATCHED_MSG="the gate's shell parser did not finish reading this command (it ran out of time, or stopped), so what it runs is unknown; nothing clears this key. Retry when the box is quieter, or split the command."
fi
# The cut's sibling (the lens on c898dca, M4): a judge that read the command and could not
# read all of it (a construct it does not know: extglob was the one found, in 25 tried)
# said "unreadable", which refused a yellow token and nothing else, so one such line ahead
# of a key only the judge reads passed, and bash ran it. Unread with no key is red too,
# parser-unread, which nothing clears. Cost, named: a command in a syntax the parser does
# not read is refused until it is rewritten in plain bash, or split.
# "opaque" (the text parsed; a payload it runs is known only at run time) is not this: it
# refuses a yellow token, and the wrapped-payload walk below whispers and passes it, as
# before. One rule for both turned `eval "$x"` red (the advisor, 2026-11-04).
if [ -n "${JUDGE_UNREAD:-}" ] && [ -z "${JUDGE_CUT:-}" ] && [ "$MODE" != "consume" ] && [ -z "$MATCHED_KEY" ]; then
  maude_log_trace "gate" "parser=unread-no-key"
  MATCHED_KEY="parser-unread"
  MATCHED_MSG="the gate's shell parser could not read all of this command (a construct it does not know), so what it runs is unknown; nothing clears this key. Rewrite it in plain bash, or split it."
fi

# ── #3 shell wrapping ────────────────────────────────────────────────────────
# The key is not red yet: inspect literal wrapped payloads (bash -c 'rm -rf /',
# eval 'git push --force', nested). A red inner key replaces a yellow one; with no key
# yet, block with the inner key. A wrapper whose payload we CAN'T read (variable /
# interpolated) with no key at all → whisper and pass (consistent with #4
# var-indirection: noticed, not gated).
if ! maude_gate_key_red "$MATCHED_KEY"; then
  # A heredoc body is text unless a shell reads it. The plain patterns excise bodies
  # already (v0.27.0); this scan did not, so a python heredoc carrying the string
  # "bash -c '... --amend'" was blocked (2026-09-28, live). A heredoc fed to a shell
  # keeps EVERY body in the scan: that body runs, and the gate must not read less of it
  # than it did. The first cut grepped the whole command for a shell word before a `<<`,
  # so `git add . && …`, a `cat > x.sh <<EOF`, and a body that mentioned `bash <<EOF`
  # all read as shell-fed and kept blocking, while `cat <<EOF | bash` (the shell AFTER
  # the heredoc) read as text (lens round 1). The decision is made per opener line, on
  # the stripped command, with quotes blanked, in the segment that carries the `<<` and
  # the one after it. WCMD is that decision, made once above the backstops.
  if WM="$(maude_wrapped_match "$WCMD" 3)"; then
    if [ -z "$MATCHED_KEY" ] || maude_gate_key_red "${WM%% ||| *}"; then
      MATCHED_KEY="${WM%% ||| *}"
      MATCHED_MSG="${WM#* ||| }"
    fi
  elif [ -z "$MATCHED_KEY" ] && maude_has_opaque_wrap "$CMD"; then
    maude_log_trace "gate" "wrap-opaque-whisper"
    printf "Maude: a wrapped command (bash -c / eval) carries a payload I can't inspect — the gate is blind to it here. Eyeball it yourself.\n" >&2
    exit 0
  fi
  if maude_walk_overdue; then
    maude_log_trace "gate" "wrapped=overdue"
    JUDGE_PARTIAL=1  # the walk stopped on the clock: what it did not reach was not read
  fi
fi

[ -z "$MATCHED_KEY" ] && exit 0

# A yellow token opens only a command the parser read whole. bash runs every complete
# line before a later syntax error, and one appended `(` made the whole command
# unreadable, so a red key in the lines before it hid behind the tables' yellow key and
# passed on a yellow token Claude may mint (lens on 25c9ad2, BLOCKING-1). This refuses the
# token for any command not read whole (docs/gate-threat-model.md lists what counts).
# Cost, named: a yellow-keyed command with a syntax error is blocked even with its token.
# The parser's words, where the message does not carry them already: a message with no
# conscience sentence to cut at (parser-depth) kept its label through the cut and got it
# twice (lens 2 on fa4225c, finding 5).
# No live token — block.
# NAME THE FILE WE LOOKED IN. The clear-script names the file it WROTE; without
# this the reader stayed silent, so a resolver split showed up only as "cleared"
# followed by a refusal, with nothing on either side to compare. That is exactly
# how the 2026-09-02 bug hid. One line closes the loop from the reader's side.
# ── The push label (2026-11-04) ─────────────────────────────────────────────
# A git-push block names the class of remote the push aims at, read from the remote's push
# URL (maude_push_class in _maude-common.sh). Read HERE, on the block path only: a command
# that passes never runs git for it, and the one `git remote get-url` costs milliseconds
# against the harness's 5 s kill. The label downgrades the wording only on a positive read
# of a command whose push the gate can place: one push, at the front, in the hook's cwd or
# a plain -C, with nothing in the command that could move it (a -c config override can
# rewrite a URL by pushInsteadOf; a GIT_* or HOME assignment can swap the config that does;
# cd, env -C, --git-dir, --work-tree, --receive-pack move the repo or what runs for it).
# Everything the gate cannot place keeps the public wording and says why, so a wrong
# "internal" never trains a clear. Force-push keeps its red row: history dies on any remote.
# The word walk below splits $rest, so no glob may expand in it: noglob is set for the body
# and put back after. `local -` did that on bash 4.4+, and on bash 3.2 (macOS) it is an
# error, so `set -f` leaked into the rest of the gate (PR #90's macOS leg, 2026-11-09).
maude_push_label() {  # <cmd> <cwd> → "internal <host>" | "public <host>" | "unknown <why>"
  local _had_f="" _rc
  case $- in *f*) _had_f=1 ;; esac
  set -f
  _maude_push_label_body "$@"; _rc=$?
  [ -n "$_had_f" ] || set +f
  return "$_rc"
}
_maude_push_label_body() {
  local cmd="$1" cwd="$2" rest dir="" spec="" w cls host="" unk="" n
  # The label never prints a URL, a path or a directory: the host is all it vouches for,
  # and a remote URL can carry a token, a path a name (the lens on c898dca, M2).
  case "$cmd" in
    *' -c '*|*' -c='*|*--config-env*|*GIT_*|*HOME=*|*--repo*|*--git-dir*|*--work-tree*|*--receive-pack*|*--exec*|*' -o '*|*--push-option*|*recurse-submodules*|*'cd '*|*pushd*|*'env '*|*'exec '*|*'$'*|*'`'*|*'~'*)
      printf 'unknown the command could move the push before it runs'; return ;;
  esac
  n="$(printf '%s' "$cmd" | grep -o -w 'push' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || { printf 'unknown the command holds more than one push'; return; }
  if [[ "$cmd" =~ ^[[:space:]]*git[[:space:]]+(-C[[:space:]]+([^[:space:]]+)[[:space:]]+)?push([[:space:]]+(.*))?$ ]]; then
    dir="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[4]}"
  else
    printf 'unknown the push is not the first command'; return
  fi
  # Up to the first separator or redirect, by regex: `${rest%%[|;&<>]*}` is a longest-match
  # removal, quadratic in bash 3.2, and took 941 ms of a 120 KB command there (macOS, PR #90).
  local _sep_re='^([^|;&<>]*)'
  [[ $rest =~ $_sep_re ]] && rest="${BASH_REMATCH[1]}"
  case "$dir" in
    '') dir="$cwd" ;;
    /*) ;;
    *[!A-Za-z0-9._/-]*) printf 'unknown the -C directory holds more than a plain path'; return ;;
    *) dir="$cwd/$dir" ;;
  esac
  [ -n "$cwd" ] || { printf 'unknown the hook input names no working directory'; return; }
  [ -d "$dir" ] || { printf 'unknown the push directory does not exist'; return; }
  # A push that recurses into submodules sends each to ITS remote, which the label does not
  # read (the commit review on c898dca): the flag above, or the config here, reads unknown.
  case "$(GIT_TERMINAL_PROMPT=0 git -C "$dir" config --get push.recurseSubmodules 2>/dev/null | tr 'A-Z' 'a-z')" in
    ''|no|check) ;;
    *) printf 'unknown the push recurses into submodules, each to its own remote'; return ;;
  esac
  for w in $rest; do
    case "$w" in -*) continue ;; [0-9]*'>'*|'>'*|'<'*) continue ;; esac
    spec="$w"; break
  done
  # One URL, wherever git takes one: the command's positional, or the config an argless
  # push consults (branch.<b>.pushRemote, remote.pushDefault, branch.<b>.remote, in git's
  # order; a URL is taken wherever a name goes, so `git push` went to github by
  # branch.<b>.pushRemote while the label read `git remote`'s names: the lens on c898dca,
  # M1). A name is read through `git remote get-url --push`.
  maude_push_one() {  # <url-or-name> → prints the class line, or returns 1 for "not a URL"
    local u="$1" c h
    case "$u" in
      *://*|*@*:*|/*|./*|../*)
        c="$(maude_push_class "$u")"; h="$(maude_push_url_host "$u")"
        case "$c" in
          internal) printf 'internal %s' "${h:-a local path}" ;;
          public)   printf 'public %s' "$h" ;;
          *)        printf 'unknown the remote URL has no host the gate reads' ;;
        esac
        return 0 ;;
    esac
    return 1
  }
  if [ -n "$spec" ]; then
    maude_push_one "$spec" && return
    case "$spec" in *[!A-Za-z0-9._-]*|-*) printf 'unknown the remote is not a plain name'; return ;; esac
  else
    local b="" pr="" pd="" br=""
    b="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)" || b=""
    [ -n "$b" ] && pr="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" config --get "branch.$b.pushRemote" 2>/dev/null)"
    pd="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" config --get remote.pushDefault 2>/dev/null)"
    [ -n "$b" ] && br="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" config --get "branch.$b.remote" 2>/dev/null)"
    spec="${pr:-${pd:-$br}}"
    if [ -n "$spec" ]; then
      maude_push_one "$spec" && return
      case "$spec" in *[!A-Za-z0-9._-]*|-*) printf 'unknown the configured push remote is not a plain name'; return ;; esac
    elif [ -z "$b" ]; then
      printf 'unknown HEAD is detached and no push remote is configured'; return
    fi
  fi
  local url urls="" count=0
  if [ -n "$spec" ]; then
    url="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" remote get-url --push "$spec" 2>/dev/null)" ||
      { printf 'unknown no remote named %s' "$spec"; return; }
    urls="$url"
  else
    # No name anywhere: git takes origin when it exists, else refuses. Read origin, or
    # every remote up to eight of them (the label has no clock of its own and 300 remotes
    # cost it 3.4 s: the lens on c898dca, M3); more than that reads unknown.
    if url="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" remote get-url --push origin 2>/dev/null)"; then
      urls="$url"
    else
      while IFS= read -r w; do
        [ -n "$w" ] || continue
        count=$((count + 1)); [ "$count" -le 8 ] || { printf 'unknown more remotes than the gate reads'; return; }
        url="$(GIT_TERMINAL_PROMPT=0 git -C "$dir" remote get-url --push "$w" 2>/dev/null)" || continue
        urls="${urls}${urls:+$'\n'}${url}"
      done < <(GIT_TERMINAL_PROMPT=0 git -C "$dir" remote 2>/dev/null)
      [ -n "$urls" ] || { printf 'unknown no remote is configured'; return; }
    fi
  fi
  local all_internal=1
  while IFS= read -r url; do
    cls="$(maude_push_class "$url")"; host="$(maude_push_url_host "$url")"
    case "$cls" in
      public) printf 'public %s' "$host"; return ;;
      internal) [ -n "$host" ] || host="a local path" ;;
      *) all_internal=0; [ -n "$unk" ] || unk="$host" ;;
    esac
  done <<< "$urls"
  [ "$all_internal" = 1 ] && { printf 'internal %s' "$host"; return; }
  printf 'unknown %s is of no class the gate knows' "${unk:-the remote}"
}

# The push label is read before the partial-read refusal below prints the message: a
# push behind a run-time word (`$x git push`) is keyed by the tables, marked opaque by
# the judge, and refused there, and it reached stderr with the flat lead the label was
# written to replace (lens 4 on dd9d405, finding 5).
if [ "$MATCHED_KEY" = "git-push" ]; then
  _lead="git push detected. Public, irreversible. Run /maude:conscience git-push to override."
  case "$MATCHED_MSG" in
    "$_lead"*)
      if maude_walk_overdue; then _lbl="unknown the gate's clock ran out before the remote was read"
      else _lbl="$(maude_push_label "$CMD" "$HOOK_CWD")"; fi
      case "$_lbl" in
        internal\ *) _new="git push detected, to an internal remote (${_lbl#internal }): not public, still gated. Run /maude:conscience git-push to clear it." ;;
        public\ *)   _new="git push detected, to a PUBLIC remote (${_lbl#public }). Public, irreversible. Run /maude:conscience git-push to override." ;;
        *)           _new="git push detected; the gate could not class its remote (${_lbl#unknown }), so it reads as public. Public, irreversible. Run /maude:conscience git-push to override." ;;
      esac
      MATCHED_MSG="${_new}${MATCHED_MSG#"$_lead"}"
      maude_log_trace "gate" "push-label=${_lbl%% *}"
      unset _new _lbl ;;
  esac
  unset _lead
fi
_JS=""
case "${MATCHED_MSG%%Run /maude:conscience*}" in *"(read through the shell parser as: "*) ;; *) _JS="${JUDGE_SAID:+(read through the shell parser as: $JUDGE_SAID) }" ;; esac
if [ -n "${JUDGE_PARTIAL:-}" ] && [ "$MODE" != "consume" ] && ! maude_gate_key_red "$MATCHED_KEY"; then
  maude_log_trace "gate" "blocked=$MATCHED_KEY partial-read"
  # "Fix the syntax" fits text that did not parse; a run-time word in command position is
  # valid bash, and the way out is to write the word out (the lens on 4b3cd91, finding 4)
  if [ -n "${JUDGE_UNREAD:-}" ]; then _fix="Fix the syntax or split the command."; else _fix="Write the run-time word out, or split the command."; fi
  printf 'Maude: %s%sThe gate could not read all of this command, so a %s token does not open it: the part it could not read may hold a red key. %s\n' \
    "${MATCHED_MSG%%Run /maude:conscience*}" "$_JS" "$MATCHED_KEY" "$_fix" >&2
  exit 2
fi

# Check for a live conscience token for this key. RED keys read from the locked
# care-redclear.json; yellow keys from care.json. The keys that rank red without being in
# the red list (red-self-clear, redclear-write, parser-depth, parser-budget, parser-unread) read the red file too:
# care.json is a file Claude can write, so a token for one of them there was a red pass
# minted from the Bash tool (lens on 25c9ad2, MAJOR-1).
NOW=$(date +%s)
if maude_gate_key_red "$MATCHED_KEY"; then
  CARE="$(maude_redclear_file)"
else
  CARE="$(maude_self_dir)/care.json"
fi
if [ -f "$CARE" ] && command -v jq >/dev/null 2>&1; then
  # Read and consume as ONE locked step (the memory lens, 2026-09-06: read on one open,
  # consumed on a second, so a concurrent writer could resurrect a spent token). Say so:
  # the spend of a one-shot token was the only moment in its life with no output, so
  # "is my gate still open" was answerable only from memory.
  # The reservation belongs to the exact call: this session and these tool_input bytes
  # (the 24th lens, BLOCKING-2: {sid, at} alone was a lease). Same bytes at PreToolUse
  # and PostToolUse, so the consume finds its own reservation.
  FP="$(maude_call_fp "$INPUT")"
  HEAD="$(maude_call_head "$CMD")"
  if [ "$MODE" = "consume" ]; then
    # PostToolUse: the command RAN. Spend the token this call reserved (or an
    # unreserved one). Never blocks; silent when there is nothing to spend.
    case "$(maude_care_consume_token "$CARE" "$MATCHED_KEY" "$FP" "$HEAD" "$SID")" in
      spent)
        maude_log_trace "gate" "spent=$MATCHED_KEY"
        printf 'Maude: %s is spent; the gate is closed again.\n' "$MATCHED_KEY" >&2 ;;
      queued)
        maude_log_trace "gate" "spent-queued=$MATCHED_KEY"
        printf 'Maude: %s ran; the token store was busy, so its spend is queued and lands on the next gate read. It will not pass again.\n' "$MATCHED_KEY" >&2 ;;
    esac
    exit 0
  fi
  # PreToolUse: RESERVE, do not spend. PreToolUse hooks run in parallel and a sibling
  # may still refuse this command, and PostToolUse never fires for a refused command;
  # the spend belongs to the command that ran (2026-09-06: a version gate's refusal
  # spent a clear on a push that never happened). The same call passes again on its
  # own reservation; any other call waits for it to run, or for the clear to expire
  # or be made again.
  RES="$(maude_care_reserve_token "$CARE" "$MATCHED_KEY" "$SID" "$NOW" "$FP" "$HEAD")"
  case "${RES%%$'\037'*}" in
    live)
      maude_log_trace "gate" "passed=$MATCHED_KEY"
      printf 'Maude: %s passed on its token; it is spent when the command runs.\n' "$MATCHED_KEY" >&2
      exit 0 ;;
    reserved)
      IFS="$(printf '\037')" read -r _ RSID RLEFT RHEAD <<EOF
$RES
EOF
      maude_log_trace "gate" "blocked=$MATCHED_KEY reserved"
      printf 'Maude: %s has a live token, but it is reserved by another call (session %s: `%s`, %s s left). That exact command retried rides it; anything else waits for it to run, or clears again.\n' \
        "$MATCHED_KEY" "${RSID:-?}" "$RHEAD" "${RLEFT:-?}" >&2
      printf '       (looked in: %s)\n' "$CARE" >&2
      exit 2 ;;
    inflight)
      maude_log_trace "gate" "blocked=$MATCHED_KEY inflight"
      printf 'Maude: %s has a live token, but a command of yours is already passing on it; one token opens one command.\n' "$MATCHED_KEY" >&2
      printf '       (looked in: %s)\n' "$CARE" >&2
      exit 2 ;;
    unwritable)
      # The person holds a clear the gate cannot record (care.json unwritable, a full
      # disk, a jq that fails on the write). The ordinary refusal would send him to get
      # a token he already has (the 23rd lens, IMPORTANT-2): say what actually failed.
      maude_log_trace "gate" "blocked=$MATCHED_KEY unwritable"
      printf 'Maude: %s has a live token, but the gate could not record its use; nothing passes until %s is writable.\n' "$MATCHED_KEY" "$CARE" >&2
      exit 2 ;;
    busy)
      # Another hook held the token store past the lock's bound; nothing was read. The
      # "no token" refusal below would send him for a clear he may already hold.
      maude_log_trace "gate" "blocked=$MATCHED_KEY busy"
      printf 'Maude: the token store is busy (another hook holds its lock); nothing was checked for %s. Retry the same command.\n' "$MATCHED_KEY" >&2
      printf '       (looked in: %s)\n' "$CARE" >&2
      exit 2 ;;
  esac
fi
# consume never blocks: nothing to spend is nothing to say.
[ "$MODE" = "consume" ] && exit 0


maude_log_trace "gate" "blocked=$MATCHED_KEY"
if maude_gate_key_red "$MATCHED_KEY" || [ -n "${MATCHED_RED_KEY:-}" ] || [ "${MATCHED_TIER:-}" = "red" ]; then
  # A red key is the human's hand, never Claude's. The table rows end in "Run
  # /maude:conscience <key> …", the yellow self-clear, a dead end for a red key (the UX
  # lens, 2026-09-06: six of nine refusals). One place: drop that sentence, say the tier
  # first so a scanning eye lands on the class, then the one sentence every red refusal
  # ends with. The two backstops ABOUT red keys (self-clear, red-file write) are red
  # refusals too (the 23rd lens, IMPORTANT-3): the self-clear names the key it was
  # about; the file write has no single key and carries its own hand sentence.
  RED_SENT=""
  if maude_is_red_key "$MATCHED_KEY"; then RED_SENT="$(maude_red_refusal_line "$MATCHED_KEY")"
  elif [ -n "${MATCHED_RED_KEY:-}" ]; then RED_SENT="$(maude_red_refusal_line "$MATCHED_RED_KEY")"; fi
  printf 'Maude [RED]: %s%s%s\n' "${MATCHED_MSG%%Run /maude:conscience*}" "$_JS" "$RED_SENT" >&2
else
  printf 'Maude: %s\n' "$MATCHED_MSG" >&2
fi
# Deliberately does NOT repeat the matched key. An earlier draft did, and that
# put the key into stderr from a second source — which let nine assertions in
# test-gate.sh ("...block names its conscience key") pass even with the primary
# message suppressed. A diagnostic must not become an alternative supply of the
# thing other tests are checking for.
printf '       (looked in: %s)\n' "$CARE" >&2
exit 2
