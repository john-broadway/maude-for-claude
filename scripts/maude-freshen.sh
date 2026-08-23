#!/usr/bin/env bash
# Maude freshen — re-check the vault's live-state claims against the world.
#
# Walks the memory dir's now_*.md files for verify lines
# (`verify: `<cmd>` ⇒ `<expected>``), executes each read-only command under
# a timeout, and reports per claim: CONFIRMED / STALE / CHECK-FAILED /
# UNVERIFIABLE. Report-first: never edits memory. Grammar + safety model:
# docs/specs/2026-08-22-freshen-verify-lines-design.md.
#
# Usage: maude-freshen.sh [--wake] [project]
#   --wake    cheap subset: LOCAL-class commands only, 2s each, ~8s budget
#   project   narrow to now_<project>.md (default: all now_*.md)
#
# Env: MAUDE_FRESHEN_MEMDIR overrides the memory dir (tests);
#      MAUDE_FRESHEN_TIMEOUT overrides the per-command timeout (seconds).
#
# Exit: 0 clean; 1 if any STALE or CHECK-FAILED; 2 usage/setup error.

set +e

DIR="$(cd "$(dirname "$0")" && pwd)"
COMMON="$DIR/../hooks/scripts/_maude-common.sh"
# shellcheck disable=SC1090  # computed path, load guarded
[ -f "$COMMON" ] && . "$COMMON"
# maude_timeout comes from the common lib (macOS has no timeout(1) — the house
# shim covers it). If common is missing the install is broken and every claim
# reports CHECK-FAILED with exit 127 — loud, never silent.

MODE="full"
PROJECT=""
for arg in "$@"; do
  case "$arg" in
    --wake) MODE="wake" ;;
    -*) printf 'freshen: unknown flag %s\n' "$arg" >&2; exit 2 ;;
    *) PROJECT="$arg" ;;
  esac
done

# ── Memory dir resolution (same slug rule the wake ritual uses) ──────
if [ -n "${MAUDE_FRESHEN_MEMDIR:-}" ]; then
  MEM="$MAUDE_FRESHEN_MEMDIR"
else
  PROJ="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  SLUG="$(printf %s "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
  MEM="$HOME/.claude/projects/$SLUG/memory"
fi
[ -d "$MEM" ] || { printf 'freshen: no memory dir at %s\n' "$MEM" >&2; exit 2; }

if [ -n "$PROJECT" ]; then
  set -- "$MEM/now_${PROJECT}.md"
  [ -f "$1" ] || { printf 'freshen: no now_%s.md in %s\n' "$PROJECT" "$MEM" >&2; exit 2; }
else
  set -- "$MEM"/now_*.md
  [ -f "$1" ] || { printf 'freshen: no now_*.md files in %s\n' "$MEM" >&2; exit 2; }
fi

if [ "$MODE" = "wake" ]; then
  TMO="${MAUDE_FRESHEN_TIMEOUT:-2}"
  BUDGET="${MAUDE_FRESHEN_BUDGET:-8}"
else
  TMO="${MAUDE_FRESHEN_TIMEOUT:-10}"
  BUDGET=""
fi

# ── Neuter git's on-disk code-execution config, for every command we run ──
# `-c` (command-line config-as-code) is already classifier-denied; this closes
# the SAME exec reached through ON-DISK config. The realistic vector is not an
# attacker-planted repo — it's a poisoned ~/.gitconfig whose core.fsmonitor or
# diff.external would then run on freshen's OWN trusted-repo reads at session
# start. System+global config are ignored; the command-running knobs are
# force-set inert with highest precedence (GIT_CONFIG_* overrides even
# repo-local config). Harmless to non-git commands (they ignore these vars).
# Residual (a fifth lens mapped it precisely), inside the author-hostile
# boundary the trust model excludes: PER-DRIVER attribute programs — a
# `[diff "n"].textconv` OR a `[filter "n"].clean`/`.smudge` that a repo's own
# .git/config defines and its .gitattributes selects. Driver names are
# arbitrary, so GIT_CONFIG_* can't force them inert. These fire on `git show`
# / `git log -p` (textconv, smudge) and on `git diff` / `git status` /
# `git log -p` (clean) — `git status` being the most natural verify verb, so
# the exposure is real IF the repo is attacker-controlled. It is NOT reachable
# from a text-only verify line: it needs an attacker-authored repo-local
# .git/config AND working-tree .gitattributes on disk — arbitrary-file-write
# territory, which the classifier is not a sandbox against. A clean or
# globally-poisoned repo never execs (both proven). Closing it fully would
# mean dropping status/diff/show/log for the exec-free verbs
# (rev-list/rev-parse/ls-files/shortlog/describe/`show <rev>:<path>`) — a
# utility trade left as John's explicit design call, not silently taken.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=4 \
  GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=diff.external  GIT_CONFIG_VALUE_1='' \
  GIT_CONFIG_KEY_2=core.pager     GIT_CONFIG_VALUE_2=cat \
  GIT_CONFIG_KEY_3=core.hooksPath GIT_CONFIG_VALUE_3=/dev/null

# ── Classifier: LOCAL | NET | DENY:<reason>. Fail-closed. ────────────
# Judged BEFORE anything executes; any DENY is never run. The architecture,
# after an adversarial lens broke the first draft six ways (2026-08-22): a
# command HEAD on an allowlist is not a gate — every multi-tool (git, curl,
# jq, sqlite3, find) reaches write/exec through a flag or verb no operator-deny
# names. So: sqlite3 and find are GONE (their normal operation is exec/write:
# `find -execdir`, `sqlite3 .shell` — and no real verify line needs them); the
# survivors get per-flag/per-verb allowlists (deny-by-default for curl); and
# every check iterates the tokenized words, never a space-anchored substring
# (the lens walked a tab through ` -exec `). Globs are off at exec (`set -f`).

# git: pure-read verbs only. `--output`/`-o` write a file; `branch`/`tag`/
# `remote add` mutate refs/config; `-c` is config-as-code-exec. All refused.
_freshen_check_git() {
  local sub="" w
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) shift; shift ;;
      --no-pager) shift ;;
      -*) printf "DENY:git option '%s' not allowlisted" "$1"; return ;;
      *) sub="$1"; shift; break ;;
    esac
  done
  case "$sub" in
    status|log|rev-list|rev-parse|diff|show|describe|shortlog|ls-files) : ;;
    *) printf "DENY:git verb '%s' not read-allowlisted" "${sub:-<none>}"; return ;;
  esac
  for w in "$@"; do
    case "$w" in
      -o|-o*|--output|--output=*|--output-directory|--output-directory=*)
        printf 'DENY:git write flag (--output)'; return ;;
    esac
  done
}

# curl: deny-by-default. Only URLs, valueless safe short flags (s S L f i I),
# a few value-taking flags, and an explicit long-flag allowlist pass. Every
# other flag — including any curl adds in the future — is denied. This closes
# the write-to-file class (--trace/--stderr/--libcurl/--etag-save/-o/…) at the
# root instead of chasing each one.
_freshen_check_curl() {
  local w rest ch expect=0
  for w in "$@"; do
    # curl's @ reads a local file into the request (`-H @/etc/passwd`,
    # `-d @file`) — an exfil primitive. No verify-line curl needs @, so any
    # word carrying it is denied, value words (expect=1) included.
    case "$w" in *@*) printf "DENY:curl @ (file-read into request) in '%s'" "$w"; return ;; esac
    if [ "$expect" = 1 ]; then expect=0; continue; fi
    case "$w" in
      http://*|https://*) : ;;
      -H|--header|-A|--user-agent|-m|--max-time|--connect-timeout|--retry|--retry-max-time)
        expect=1 ;;
      --header=*|--user-agent=*|--max-time=*|--connect-timeout=*|--retry=*|--silent|--show-error|--fail|--location|--head|--include|--compressed) : ;;
      --*) printf "DENY:curl flag '%s' not allowlisted" "$w"; return ;;
      -*)
        rest="${w#-}"
        while [ -n "$rest" ]; do
          ch="${rest%"${rest#?}"}"; rest="${rest#?}"
          case "$ch" in
            s|S|L|f|i|I) : ;;
            *) printf "DENY:curl flag '-%s' not allowlisted (in %s)" "$ch" "$w"; return ;;
          esac
        done ;;
      *) printf "DENY:curl bare arg '%s' is not a URL" "$w"; return ;;
    esac
  done
}

# jq: read-only projection only. env/$ENV/input/inputs/getpath dump the
# environment or read extra inputs; --rawfile/--slurpfile/-f read files;
# -n evaluates a program with no input (the env-dump shape). Filters that
# name any of those builtins are refused (substring — a rare field literally
# named e.g. `.environment` is denied too; write the check without it).
_freshen_check_jq() {
  local w filter="" seen=0
  for w in "$@"; do
    case "$w" in
      -n|--null-input|--rawfile|--slurpfile|-f|--from-file|--args|--jsonargs|--stream|--seq|-L*)
        printf "DENY:jq flag '%s' (env/file/input access)" "$w"; return ;;
      -r|--raw-output|-c|--compact-output|-e|--exit-status|-a|--ascii-output|-S|--sort-keys|-j|--join-output|-R|--raw-input|--tab|-C|-M|--indent) : ;;
      -*) printf "DENY:jq flag '%s' not allowlisted" "$w"; return ;;
      *) [ "$seen" = 0 ] && { filter="$w"; seen=1; } ;;
    esac
  done
  # `$ENV`/`$__loc__` need not be listed: any `$` is denied globally upstream.
  # These are the bare-word builtins that read env/extra-input or load modules.
  case "$filter" in
    *env*|*input*|*getpath*|*builtins*|*import*|*include*|*modulemeta*)
      printf 'DENY:jq filter names an env/input/module builtin'; return ;;
  esac
}

# gh: held under the lens. Read subcommands only; mutation/--web denied.
_freshen_check_gh() {
  local s1="${1:-}" s2="${2:-}" w
  if [ "$s1" = "api" ]; then
    shift
    for w in "$@"; do
      case "$w" in
        -X*|--method*|-f*|-F*|--field*|--input*|--raw-field*) printf 'DENY:gh api with mutation flag'; return ;;
        -w*|--web*) printf 'DENY:gh --web (spawns a browser)'; return ;;
      esac
    done
  else
    case "$s1" in run|pr|issue|release|repo) : ;; *) printf "DENY:gh subcommand '%s' not read-allowlisted" "${s1:-<none>}"; return ;; esac
    case "$s2" in list|view|status) : ;; *) printf "DENY:gh verb '%s' not read-allowlisted" "${s2:-<none>}"; return ;; esac
    for w in "$@"; do
      case "$w" in -w|--web) printf 'DENY:gh --web (spawns a browser)'; return ;; esac
    done
  fi
}

classify_cmd() {
  local cmd="$1"
  set -f  # command-substitution subshell: noglob so the word-splits below
          # can never expand a glob against the cwd. (Does not leak to caller.)

  case "$cmd" in
    *'||'*) printf 'DENY:forbidden operator ||'; return ;;
    *';'*)  printf 'DENY:forbidden operator ;'; return ;;
    *'&'*)  printf 'DENY:forbidden operator &'; return ;;
    *'>'*)  printf 'DENY:forbidden operator >'; return ;;
    *'`'*)  printf 'DENY:forbidden backtick'; return ;;
    # < ( ) are bash word-separators the whitespace tokenizer below does NOT
    # split on. A third lens proved `cat < /etc/hostname` desyncs (classifier
    # sees `cat` and a path; bash runs a stdin redirect). None is weaponizable
    # for write/exec here, but banning them keeps classify == exec true and
    # closes the redirect/subshell surface entirely. No verify line needs them.
    *'<'*)  printf 'DENY:forbidden redirect/word-separator <'; return ;;
    *'('*)  printf 'DENY:forbidden subshell ('; return ;;
    *')'*)  printf 'DENY:forbidden subshell )'; return ;;
    # $ covers $(…), ${…} and every variable — an expansion can rewrite a path
    # AFTER the secret-deny read it, so none of them run. ~ is the same trick
    # via tilde-expansion. Verify lines use absolute literal paths by law.
    *'$'*)  printf 'DENY:forbidden expansion $'; return ;;
    *'~'*)  printf 'DENY:forbidden expansion ~'; return ;;
    # QUOTES, BRACES, BACKSLASH: the classifier tokenizes the raw string but
    # bash STRIPS quotes and EXPANDS braces before executing — so `--"output"=`
    # reads as safe here yet runs as `--output=`, and `data.e{n..n}v` dodges
    # the secret-deny then expands to `.env`. A second lens proved both. With
    # these characters banned, the whitespace tokenizer here matches bash's
    # word-splitting exactly (classify == exec), and no blacklist can be
    # quote-desynced. Verify lines use bare absolute paths and simple jq
    # filters (no quoted keys) — none needs a quote, brace, or backslash.
    *'"'*)   printf 'DENY:forbidden quote "'; return ;;
    *"'"*)   printf "DENY:forbidden quote '"; return ;;
    *[\\]*)  printf 'DENY:forbidden backslash'; return ;;
    *'{'*)   printf 'DENY:forbidden brace {'; return ;;
    *'}'*)   printf 'DENY:forbidden brace }'; return ;;
  esac

  local low
  low="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
  # A finite substring blocklist can't name every secret store (stated in the
  # spec residuals), but it names the well-known ones. Widened after a lens
  # read /etc/shadow, /proc/self/environ, and the cloud cred stores into a
  # report. Path-shaped tokens (trailing/leading slash) to avoid matching a
  # JSON field that merely contains the word.
  case "$low" in
    *'.credentials'*|*'secrets.yaml'*|*'.env'*|*'.ssh'*|*'_token'*|*'api_key'*|*'password'*|*'id_rsa'*|*'id_ed25519'*|*'.pem'*|*'vault.db'*|*'/vault/'* \
    |*'/proc/'*|*'/etc/shadow'*|*'/etc/gshadow'*|*'.aws/'*|*'.docker/config'*|*'.kube/'*|*'/gcloud/'*|*'.netrc'*|*'.pgpass'*|*'.git-credentials'*|*'.npmrc'*|*'.pypirc'*|*'/environ'*)
      printf 'DENY:secret-shaped target'; return ;;
  esac

  local class="LOCAL" seg deny
  local IFS='|'
  # shellcheck disable=SC2086  # word-splitting into pipe segments is the point
  set -- $cmd
  for seg in "$@"; do
    local IFS=' 	'
    # shellcheck disable=SC2086  # word-splitting into argv is the point (noglob on)
    set -- $seg
    [ $# -eq 0 ] && { printf 'DENY:empty pipe segment'; return; }
    local head1="$1"
    case "$head1" in
      # Pure stdin/stdout or read-only-path readers ONLY. Deliberately NOT
      # here: sort (`-o FILE` writes), uniq (`uniq in out` — 2nd positional
      # is an output file), file (`-C`/`--compile` writes magic.mgc to CWD),
      # tee/split/dd (write). The rule for adding one: it must have no flag
      # AND no positional argument that names a file it writes. (sort, uniq,
      # and file were each write-capable readers a lens flagged in turn.)
      ls|stat|grep|wc|head|tail|cat|du|tr|cut|test)
        : ;;
      git)  shift; deny="$(_freshen_check_git "$@")";  [ -n "$deny" ] && { printf '%s' "$deny"; return; } ;;
      jq)   shift; deny="$(_freshen_check_jq "$@")";   [ -n "$deny" ] && { printf '%s' "$deny"; return; } ;;
      curl) shift; deny="$(_freshen_check_curl "$@")"; [ -n "$deny" ] && { printf '%s' "$deny"; return; }; class="NET" ;;
      gh)   shift; deny="$(_freshen_check_gh "$@")";   [ -n "$deny" ] && { printf '%s' "$deny"; return; }; class="NET" ;;
      *)    printf "DENY:command '%s' not allowlisted" "$head1"; return ;;
    esac
  done
  printf '%s' "$class"
}

# ── Walk + execute ───────────────────────────────────────────────────
CONFIRMED=0 STALE=0 CHECKFAILED=0 UNVERIFIABLE=0 SKIPPED=0 NOLINE=0
START_S=$SECONDS

printf 'Maude freshen: %s\n' "$MEM"
printf 'mode: %s · as of %s (UTC)\n' "$MODE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "----------------------------------------"

report() { # verdict, location, detail
  printf '%-13s %s — %s\n' "$1" "$2" "$3"
}

for f in "$@"; do
  base="${f##*/}"
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Open-marker lines with no verify line: memories, not readings.
    case "$line" in
      *'verify: `'*) : ;;
      *)
        case "$line" in
          *🔴*|*⚠️*) NOLINE=$((NOLINE + 1)) ;;
        esac
        continue ;;
    esac

    loc="$base:$lineno"
    rest="${line#*verify: \`}"
    cmd="${rest%%\`*}"
    after="${rest#*\`}"
    case "$after" in
      *'⇒ `'*) exp="${after#*⇒ \`}"; exp="${exp%%\`*}" ;;
      *)
        report "UNVERIFIABLE" "$loc" "malformed: missing \`⇒ <expected>\` (the expectation is mandatory)"
        UNVERIFIABLE=$((UNVERIFIABLE + 1)); continue ;;
    esac

    verdict_class="$(classify_cmd "$cmd")"
    case "$verdict_class" in
      DENY:*)
        report "UNVERIFIABLE" "$loc" "${verdict_class#DENY:} — \`$cmd\`"
        UNVERIFIABLE=$((UNVERIFIABLE + 1)); continue ;;
    esac

    if [ "$MODE" = "wake" ]; then
      if [ "$verdict_class" = "NET" ]; then
        report "WAKE-SKIPPED" "$loc" "network-class (full sweep only)"
        SKIPPED=$((SKIPPED + 1)); continue
      fi
      if [ -n "$BUDGET" ] && [ $((SECONDS - START_S)) -ge "$BUDGET" ]; then
        report "SKIPPED" "$loc" "wake budget (${BUDGET}s) spent"
        SKIPPED=$((SKIPPED + 1)); continue
      fi
    fi

    # set -f: no glob expansion at exec, so a `cr?dentials` glob can never
    # resolve past the secret-deny into a real secret path (lens finding 9).
    out="$(maude_timeout "$TMO" bash -c "set -f; set -o pipefail; $cmd" </dev/null 2>/dev/null)"
    rc=$?
    got="$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ $rc -eq 124 ]; then
      report "CHECK-FAILED" "$loc" "timed out after ${TMO}s — \`$cmd\`"
      CHECKFAILED=$((CHECKFAILED + 1))
    elif [ $rc -ne 0 ]; then
      report "CHECK-FAILED" "$loc" "exit $rc — \`$cmd\`"
      CHECKFAILED=$((CHECKFAILED + 1))
    elif [ "$got" = "$exp" ]; then
      report "CONFIRMED" "$loc" "\`$cmd\` ⇒ \`$exp\`"
      CONFIRMED=$((CONFIRMED + 1))
    else
      shortgot="$(printf '%s' "$got" | head -c 80)"
      [ "$shortgot" != "$got" ] && shortgot="${shortgot}…"
      report "STALE" "$loc" "expected \`$exp\`, got \`$shortgot\` — \`$cmd\`"
      STALE=$((STALE + 1))
    fi
  done < "$f"
done

TOTAL=$((CONFIRMED + STALE + CHECKFAILED + UNVERIFIABLE + SKIPPED))
printf '%s\n' "----------------------------------------"
printf '%d claims: %d confirmed, %d stale, %d check-failed, %d unverifiable, %d skipped · %d open-marker lines carry no verify line (memories, not readings)\n' \
  "$TOTAL" "$CONFIRMED" "$STALE" "$CHECKFAILED" "$UNVERIFIABLE" "$SKIPPED" "$NOLINE"

# Metadata-only receipt: counts, never claim content.
if command -v maude_log_trace >/dev/null 2>&1; then
  maude_log_trace "freshen" "mode=$MODE confirmed=$CONFIRMED stale=$STALE checkfailed=$CHECKFAILED unverifiable=$UNVERIFIABLE skipped=$SKIPPED" 2>/dev/null
fi

[ $((STALE + CHECKFAILED)) -gt 0 ] && exit 1
exit 0
