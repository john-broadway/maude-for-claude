#!/usr/bin/env bash
# ship.sh — the one-button ship rail (PUBLISHING.md, mechanized).
#
#   scripts/ship.sh build [-m "msg"]   → clean public branch off origin/main,
#                                        internal set stripped (.publishignore),
#                                        leak-audit + gates, prints John's line
#   <John pastes the one push line>
#   scripts/ship.sh open --review "…"  → PR with the second lens documented,
#                                        auto-merge armed; without --review the
#                                        PR opens as a DRAFT (the no-self-merge
#                                        law is structural, not remembered)
#
# Env seams (tests): SHIP_BRANCH (branch name), SHIP_SOURCE_REF (default main),
# SHIP_SKIP_GATES=1 (skip make test/lint/verify — test fixtures only).
set -u

die() { printf 'ship: %s\n' "$1" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repo"
cd "$ROOT" || die "cannot cd to repo root"
SRC="${SHIP_SOURCE_REF:-main}"

# ── leak-audit: the pre-push guard's shapes, run LOCALLY before any push ──
# Patterns are regexes, never literals, so this script can't bait the guard.
# Audits ADDED lines of what would ship (index vs origin/main) — parity with
# the guard's commit-scan, without re-judging pre-existing public content.
audit_staged() {
  # Patterns assembled by concatenation so no line of THIS script carries a
  # guard-shaped literal — the rail must be able to ship itself (the audit
  # flagged its own pattern-definition line on the first dogfood run).
  local p_ip='([0-9]{1,3}\.){3}[0-9]{1,3}'
  local p_paths='/ro'; p_paths="${p_paths}ot/|/ho"; p_paths="${p_paths}me/[a-z]|/Us"; p_paths="${p_paths}ers/[A-Za-z]"
  local p_infra='\.bf'; p_infra="${p_infra}f\.lan|gite"; p_infra="${p_infra}a@"
  local p_key='BEGIN[A-Z ]*PRIVATE KEY'
  local p_cred='(sk-|ghp_|gho_|ghu_|ghs_|github_pat_|xox[abprs]-|AKIA|AIza)[A-Za-z0-9_-]{8,}'
  local pats="$p_ip|$p_paths|$p_infra|$p_key|$p_cred"
  local f bad=0 hits
  # -z + read -d '': raw NUL-delimited paths. Without this, git quotes
  # non-ASCII names ("caf\303\251.md") and the per-file pathspec silently
  # matches nothing — an audited-looking file the audit never read.
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    # Binary blobs expand to no diff text at all — un-auditable, so they
    # don't ship through this rail. (numstat prints "-<TAB>-" for binaries.)
    if git diff --cached origin/main --numstat -- "$f" 2>/dev/null | grep -q '^-'; then
      printf 'ship: BINARY — %s: cannot be leak-audited; ship it by hand with John or add to .publishignore\n' "$f" >&2
      bad=1
      continue
    fi
    hits="$(git diff --cached origin/main --unified=0 -- "$f" 2>/dev/null \
      | grep '^+' | grep -v '^+++' | grep -cE "$pats")"
    if [ "${hits:-0}" -gt 0 ]; then
      printf 'ship: LEAK SHAPE — %s: %s added line(s) match guard patterns\n' "$f" "$hits" >&2
      bad=1
    fi
  done < <(git diff --cached --name-only -z origin/main 2>/dev/null)
  [ "$bad" -eq 0 ] || die "leak-audit failed — fix the files above (never override the guard)"
}

# Printed on any exit after the branch switch until the build succeeds — a
# failed build must hand the operator the way back, not a mystery state.
SHIP_ORIG_BRANCH=""
SHIP_BUILD_BRANCH=""
SHIP_BUILD_OK=0
build_epilogue() {
  [ "$SHIP_BUILD_OK" = 1 ] && return 0
  [ -n "$SHIP_BUILD_BRANCH" ] || return 0
  printf 'ship: build did NOT complete — you are on "%s" with staged changes.\n' "$SHIP_BUILD_BRANCH" >&2
  printf 'ship: recover with: git checkout -f %s && git branch -D %s\n' \
    "${SHIP_ORIG_BRANCH:-main}" "$SHIP_BUILD_BRANCH" >&2
}

cmd_build() {
  local msg="ship: public build from $SRC"
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--message) [ $# -ge 2 ] || die "build: missing value for $1"; msg="$2"; shift 2 ;;
      *) die "build: unknown arg $1" ;;
    esac
  done

  [ -z "$(git status --porcelain)" ] || die "working tree not clean — commit or stash first"
  git rev-parse --verify -q "$SRC" >/dev/null || die "source ref '$SRC' not found"
  # Fail-closed: no manifest, no build. A missing .publishignore must never
  # mean "ship everything" — it's the list of what may not leave the house.
  if ! git show "$SRC:.publishignore" 2>/dev/null | grep -qvE '^[[:space:]]*(#|$)'; then
    die "no usable .publishignore on '$SRC' — refusing to build (fail-closed)"
  fi
  git fetch -q origin || die "cannot fetch origin"
  git rev-parse --verify -q origin/main >/dev/null || die "origin/main not found"

  local branch="${SHIP_BRANCH:-ship-$(date -u +%Y%m%d-%H%M%S)}"
  git rev-parse --verify -q "refs/heads/$branch" >/dev/null \
    && die "branch '$branch' already exists — inspect it, then delete (git branch -D $branch) or pick another name"
  SHIP_ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  git checkout -q -B "$branch" origin/main || die "cannot create branch $branch"
  SHIP_BUILD_BRANCH="$branch"
  trap build_epilogue EXIT
  # Worktree/index = the source tree, then strip the internal set.
  git read-tree --reset -u "$SRC" || die "read-tree from $SRC failed"
  local p
  while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    git rm -rqf --ignore-unmatch -- "$p" >/dev/null 2>&1
  done < <(git show "$SRC:.publishignore" 2>/dev/null)

  audit_staged

  if [ -z "${SHIP_SKIP_GATES:-}" ]; then
    make test  || die "gate failed: make test"
    make lint  || die "gate failed: make lint"
    make verify || die "gate failed: make verify"
  fi

  if git diff --cached --quiet origin/main; then
    die "nothing to ship — public tree already matches $SRC minus the internal set"
  fi
  git commit -qm "$msg" || die "commit failed"
  SHIP_BUILD_OK=1

  printf '\nship: branch %s built, audited%s, committed.\n' \
    "$branch" "$([ -n "${SHIP_SKIP_GATES:-}" ] && printf ' (gates SKIPPED)')"
  printf 'ship: John'\''s hand — paste this line:\n\n'
  printf '  ! cd %s && git push -u origin %s\n\n' "$ROOT" "$branch"
  printf 'ship: then run: scripts/ship.sh open --review "<one-line second-lens reference>"\n'
  # RETURN to the source branch. A warning was tried first and was not enough: on
  # 2026-08-17 a fix was written, tested green and committed onto the ship branch after a
  # build, and the next build drew from the source ref that never had it — TWICE, the
  # second time with the warning printed and quoted. A warning is a diary; leaving the
  # working tree in a safe state is a rail. `open` checks the branch out itself.
  git checkout -q "$SRC" 2>/dev/null || printf 'ship: WARNING could not return to %s\n' "$SRC" >&2
  printf '\nship: back on %s. The ship branch %s is built and waiting.\n' "$SRC" "$branch"
  printf 'ship: work stays here; `open` moves you to the ship branch when you need it.\n'
}

# ── The second lens must have RUN, not merely been written down (v0.27.0) ──
# --review is prose, and prose is not a guardrail: `open --review "looks fine"`
# was accepted on faith. When her care.json state is reachable, a non-draft
# open ALSO requires a redteam-watch STAMP — an adversarial dispatch that
# actually COMPLETED (hooks/scripts/maude-redteam-watch.sh writes it) — newer
# than the last commit of the content being shipped.
#
# SOFT, and honestly so (same framing as maude-gate.sh's care-file backstops):
# care.json has no write-protection, so a planted stamp — or deleting the file,
# which degrades to prose-only — walks past this. The threat model is
# FORGETTING the lens, not evading it; what this closes is the silent nothing
# (shipping with no lens ever dispatched), not the deliberate forgery.
# Further seams, stated: the stamp is HOUSE-wide, not session-scoped
# (redteam-watch stores per-sid but ship.sh cannot know which sid shipped —
# a sibling session's lens can satisfy it); it proves a lens RAN, not that it
# was good or read THIS diff; freshness is measured against $SRC (what build
# ships), so a commit added to the ship branch after build is outside it.
# A home without her state keeps the prose-only behavior — the rail tightens
# where the mechanism exists. Env seam (tests): SHIP_CARE_FILE.
# Returns 0 = satisfied or unknowable; 1 = stamp missing/stale (msg printed).
# ISO→epoch, GNU then BSD (Z and ±HHMM forms); empty on failure (an
# unparseable time is "unknowable", and lens_check degrades open, not guesses).
iso_epoch() {
  local e t
  e="$(date -d "$1" +%s 2>/dev/null)"                                  # portability-shim (GNU)
  [ -n "$e" ] || e="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)"  # portability-shim (BSD, Z form)
  if [ -z "$e" ]; then
    t="$(printf '%s' "$1" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
    e="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$t" +%s 2>/dev/null)"       # portability-shim (BSD, offset form)
  fi
  printf '%s' "$e"
}
lens_check() {
  local care="" c stamp tip tip_s stamp_s now_s
  if [ -n "${SHIP_CARE_FILE:-}" ]; then
    care="$SHIP_CARE_FILE"
  else
    # Take the candidate carrying the NEWEST stamp, not the first that EXISTS. A
    # repo-local care.json that exists and is empty used to shadow the real one
    # permanently — and under the canonical-root law the session's project dir IS the
    # workspace root, so the stamp always lands in the parent and the repo-local file is
    # always empty. The gate was unsatisfiable for this repo and silent about it.
    local best="" best_s="" c_stamp c_s
    for c in "$ROOT/.maude/plugin/care.json" "$(dirname "$ROOT")/.maude/plugin/care.json"; do
      [ -f "$c" ] || continue
      [ -n "$care" ] || care="$c"          # remember one, so the message can name a file
      command -v jq >/dev/null 2>&1 || continue
      c_stamp="$(jq -r '(.last_redteam_iso // {}) | [.[]] | max // empty' "$c" 2>/dev/null)"
      [ -n "$c_stamp" ] || continue
      c_s="$(iso_epoch "$c_stamp")"
      [ -n "$c_s" ] || continue
      if [ -z "$best_s" ] || [ "$c_s" -gt "$best_s" ]; then best_s="$c_s"; best="$c"; fi
    done
    [ -n "$best" ] && care="$best"
  fi
  [ -n "$care" ] && [ -f "$care" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tip="$(git log -1 --format=%cI "$SRC" 2>/dev/null)"
  tip_s="$(iso_epoch "$tip")"
  [ -n "$tip_s" ] || return 0
  stamp="$(jq -r '(.last_redteam_iso // {}) | [.[]] | max // empty' "$care" 2>/dev/null)"
  stamp_s=""
  [ -n "$stamp" ] && stamp_s="$(iso_epoch "$stamp")"
  # A stamp from the FUTURE is nonsense, not freshness — redteam-watch writes
  # `date -u` at completion, so anything past now+60s (skew allowance) reads
  # as planted/garbage and counts as no stamp at all.
  now_s="$(date +%s)"
  if [ -n "$stamp_s" ] && [ "$stamp_s" -gt $((now_s + 60)) ]; then stamp_s=""; fi
  if [ -z "$stamp_s" ] || [ "$stamp_s" -lt "$tip_s" ]; then
    printf 'ship: SECOND LENS NOT PROVEN — care.json (%s) has no adversarial-pass stamp newer than the shipped tip (%s).\n' "$care" "$tip" >&2
    printf 'ship: dispatch an adversarial review of the diff (the stamp writes itself on completion), then re-run open.\n' >&2
    printf 'ship: a DRAFT open (no --review) stays available meanwhile.\n' >&2
    return 1
  fi
  return 0
}

cmd_open() {
  local dry=0 review="" title=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --review)  [ $# -ge 2 ] || die "open: missing value for --review"; review="$2"; shift 2 ;;
      --title)   [ $# -ge 2 ] || die "open: missing value for --title"; title="$2"; shift 2 ;;
      *) die "open: unknown arg $1" ;;
    esac
  done
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)" || die "cannot read current branch"
  [ "$branch" != "main" ] || { b="$(git for-each-ref --sort=-committerdate --format="%(refname:short)" "refs/heads/ship-*" | head -1)"; [ -n "$b" ] && { printf "ship: open: moving to %s\\n" "$b"; git checkout -q "$b"; } || die "open: no ship branch found — run build first"; }
  [ -n "$title" ] || title="ship: $branch"

  local body draft_flag=""
  if [ -n "$review" ] && ! lens_check; then
    die "open: second lens required — see the lines above (or open as DRAFT without --review)"
  fi
  if [ -n "$review" ]; then
    body="## Second lens (PUBLISHING.md §4a)

$review

## Gates

Built by ship.sh: internal set stripped per .publishignore, leak-audit clean,
make test / lint / verify green at build time; CI re-proves on this PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  else
    draft_flag="--draft"
    body="## DRAFT — no documented second lens yet

The no-self-merge law (PUBLISHING.md §4) requires a documented independent
review before merge. Run the adversarial review, then re-open with:
  scripts/ship.sh open --review \"<reference>\"
or mark ready + comment the review reference manually.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    printf 'ship: WARNING — no --review given; opening as DRAFT (second lens required before merge)\n' >&2
  fi

  if [ "$dry" -eq 1 ]; then
    printf 'DRY-RUN would run:\n'
    printf '  gh pr create --base main --head %s --title "%s" %s --body <<BODY\n%s\nBODY\n' \
      "$branch" "$title" "$draft_flag" "$body"
    [ -n "$draft_flag" ] || printf '  gh pr merge %s --auto --merge --delete-branch\n' "$branch"
    return 0
  fi

  # shellcheck disable=SC2086  # draft_flag is intentionally word-split ('' or --draft)
  gh pr create --base main --head "$branch" --title "$title" $draft_flag --body "$body" \
    || die "gh pr create failed"
  if [ -z "$draft_flag" ]; then
    if ! gh pr merge "$branch" --auto --merge --delete-branch; then
      # The PR exists and is documented — only the self-merge convenience
      # failed. Exit nonzero so the caller KNOWS the promise wasn't kept.
      die "PR is OPEN but auto-merge did not arm (repo setting?) — merge manually when checks are green"
    fi
  fi
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  open)  shift; cmd_open "$@" ;;
  *) die "usage: ship.sh build [-m msg] | ship.sh open [--dry-run] [--review TEXT] [--title T]" ;;
esac
