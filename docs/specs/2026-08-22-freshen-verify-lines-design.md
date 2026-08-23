<!-- Created: 2026-08-22 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Freshen — verify lines on live-state claims

**The problem (one day's evidence, 2026-08-22):** a memory vault stores claims
about live state — "the site push is waiting", "the fleet is 9/11", "the daily
gate runs" — with no attached way to re-check them. In one session, eleven such
claims failed a live look: pushes that had already landed, sockets dark for nine
days behind a green panel, a "daily" workflow that had never run once. Every
catch happened because someone chose to look. The fix is a mechanism that looks.

## The three bricks

1. **The `verify:` convention** (this spec) — an open item that asserts live
   state carries one read-only command plus an explicit expectation, inline.
2. **The freshen ritual** (`/maude:freshen`, `scripts/maude-freshen.sh`) — walks
   the vault's `now_*.md` files, parses verify lines, executes them read-only,
   reports CONFIRMED / STALE / CHECK-FAILED / UNVERIFIABLE. Report-first: it
   never edits memory. The wake ritual runs only the cheap local subset.
3. **Sensors** (OUT of scope, named so nobody mistakes brick 2 for the end
   state) — where a domain goes stale repeatedly, the durable answer is a small
   watcher whose output IS the truth (a socket doorwatch, a published-artifact
   smoke job, a canon-drift job). Freshen is the net under the claims that
   don't yet have a sensor; it is not the sensor.

## Brick 1 — the grammar

A verify line is a trailing annotation inside a markdown bullet:

    - 🔴 the site push is pending · verify: `git -C /path/to/repo rev-list origin/main..HEAD --count` ⇒ `2`

Grammar, exactly:

    verify: `<command>` ⇒ `<expected>`

- `<command>` — one read-only shell command (single pipes allowed). Backticked.
- `⇒` — U+21D2, mandatory separator. **The expectation is mandatory**: a probe
  that reads the same pass-or-fail is not a check.
- `<expected>` — the exact expected stdout, backticked. Matched against the
  command's stdout after trimming leading/trailing whitespace. Exact match
  only (no regex, no contains — none of the real seed claims needed one; add
  an operator only when a real claim forces it).
- One verify line per bullet. The first parsed wins.
- A bullet with no verify line is legal — it reports in the summary as a
  memory, not a reading.

Authoring rules:

- **Absolute paths.** The command runs from an unspecified cwd.
- **Exit 0 is part of the claim.** The pipeline runs under `pipefail`; any
  nonzero segment → CHECK-FAILED, never a silent empty-output STALE. Prefer
  commands that exit 0 on the expected state (`find … | wc -l` over `grep -c`,
  which exits 1 on a zero count).
- **Write each line from the live command that just proved the item** — derive,
  don't guess. A verify line that never ran is a claim wearing a check's
  clothes. (The seed sweep for this spec ran all five seeds against the wire
  first; one had a guessed repo name and the wire refused it.)
- No secrets, no secret-shaped paths — the parser denies them unexecuted.

## Brick 2 — the engine

`scripts/maude-freshen.sh [--wake] [project]`

- Memory dir: `$HOME/.claude/projects/<slug>/memory` (slug from
  `$CLAUDE_PROJECT_DIR`), overridable via `MAUDE_FRESHEN_MEMDIR`.
- Scope: all `now_*.md` files; a `project` argument narrows to
  `now_<project>.md`. Roster-wide is the default because the evidence was
  roster-wide and wake runs from the umbrella root.
- **Freshen is not `/maude:verify`**: verify audits a repo's internal
  consistency (versions, links, JSON); freshen audits the vault against the
  live world. Different subject, different cadence. They cross-reference.

### Execution mode note

The classified command runs via `bash -c "set -f; set -o pipefail; <cmd>"` so
real pipes and quoting work. Shell **injection** (`;`, `$()`, redirects) is
closed at the classify step, not the exec step — the operator/expansion denies
above refuse those strings before anything runs, and the lens confirmed that
layer holds. What the classifier adds on top is the per-tool flag/verb
discipline, because the danger that survives a clean shell is the *tool's own*
capabilities (a plain `git diff --output=` needs no shell metacharacter).

### Safety: fail-closed, per-flag, never executed on doubt

A command is classified before anything runs. Any failure of any check →
**UNVERIFIABLE (+reason), never executed.**

**The architecture, after an adversarial lens broke the first draft six ways.**
The first classifier allowlisted a command *head* (`git`, `curl`, `sqlite3`,
`find`, `jq`) and denied a hand-list of dangerous tokens. A reviewer achieved
arbitrary code execution (`find -execdir … {} +`, `sqlite3 -readonly db
".shell …"`), arbitrary file write (`git diff --output=`, `curl --trace`,
`find -fprint`), file deletion, and secret exfiltration — every one through a
flag or verb no deny named, several via a **tab** that walked past a
space-anchored deny. The lesson: **a command head on an allowlist is not a
gate; every multi-tool reaches write/exec through a flag or verb.** So the
redesign is per-flag and deny-by-default, and it *removes* the two tools whose
normal operation is exec/write.

- **Forbidden operators/expansions anywhere:** `;` `&` (covers `&&`,
  background), `||`, `>` (covers `>>`), backtick, **`$` and `~`** (an
  expansion can rewrite a path *after* the secret-deny read it), and — after a
  second lens — **`"` `'` `\` `{` `}`**, and after a third — **`<` `(` `)`**.
  The classifier tokenizes the raw string but bash strips quotes, expands
  braces, and word-splits on `< ( )` *before* executing, so a quoted flag
  (`--"output"=`), a brace path (`data.e{n..n}v`), or a redirect (`cat < f`)
  reads one way here and parses another at exec. Banning every character bash
  treats specially that this whitespace tokenizer does not makes the two agree
  exactly — **classify == exec** — so no denylist can be desynced. (`< ( )`
  were not weaponizable for write/exec, but banning them closes the
  redirect/subshell surface and makes the equality honest, not approximate.)
  The cost is that jq filters must use bare simple keys (`.a.b`, `.[0].x`); a
  key needing a quote (`.["a-b"]`) can't be expressed and is a sensor's job.
  Single `|` pipes allowed.
- **`set -f` (noglob) at classify AND at exec** — a glob (`cat /path/.cr?ds/x`)
  can no longer expand into a real secret path past the substring deny; it
  reaches the literal (absent) path and reports CHECK-FAILED, no leak.
- **Secret deny** (case-insensitive substring): `.credentials`,
  `secrets.yaml`, `.env`, `.ssh`, `_token`, `api_key`, `password`, `id_rsa`,
  `id_ed25519`, `.pem`, `vault.db`, `/vault/` (the me-model vault is
  schema-walk-only — capture ≠ exposure).
- **`sqlite3` and `find` are NOT allowlisted at all.** Their normal operation
  is exec/write (`.shell`/`.system`/`.import`/extension-load; `-execdir`/
  `-fprint`/`-delete`) and no real verify line needs them. A local DB or
  filesystem check that genuinely recurs is a **sensor's** job (brick 3).
- **Per-command allowlists** (every pipe segment's leading word):
  - LOCAL readers: `ls stat grep wc head tail cat du tr cut test` — pure
    stdin/stdout or read-only-path only. Deliberately excluded: `sort` (`-o`
    writes), `uniq` (2nd positional is an output file), `file` (`-C`/`--compile`
    writes `magic.mgc`), `tee`/`split`/`dd`. The bar for adding one: no flag
    AND no positional argument names a file it writes (sort, uniq, and file
    were each write-capable readers a successive lens caught)
  - LOCAL `git` — pre-verb options ONLY `-C <path>` / `--no-pager` (`-c` is
    config-as-code-exec, denied by name). Read verbs only: `status log
    rev-list rev-parse diff show describe shortlog ls-files` — `branch`/`tag`
    (ref writes) and `remote` (`remote add` mutates config) are dropped; any
    `-o`/`--output`/`--output-directory` word is denied (it writes a file).
    **On-disk config-as-code is neutered too** (a fourth lens): banning `-c`
    only stops *command-line* config-exec, so freshen runs every command with
    `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null` (a poisoned
    `~/.gitconfig` can't run `core.fsmonitor`/`diff.external` on our own
    trusted-repo reads) and force-sets those knobs plus `core.pager`/
    `core.hooksPath` inert with `GIT_CONFIG_*` (highest precedence, overrides
    an attacker repo's own config). Residual, inside the author-hostile
    boundary (a fifth lens mapped it): per-driver attribute programs — a
    `[diff "n"].textconv` or a `[filter "n"].clean`/`.smudge` a repo's own
    `.git/config` defines and `.gitattributes` selects, firing on
    `show`/`diff`/`status`/`log -p`. Driver names are arbitrary so
    `GIT_CONFIG_*` can't force them inert; it needs an attacker-authored
    repo-local config on disk (not reachable from a text-only verify line).
    Fully closing it means restricting git to the exec-free verbs
    (`rev-list rev-parse ls-files shortlog describe` / `show <rev>:<path>`) —
    John's design call, not a silent patch
  - NET `curl` — **deny-by-default flag allowlist**: only a URL, valueless
    safe short flags (any cluster of `s S L f i I`), the value-taking
    `-H/--header -A/--user-agent -m/--max-time --connect-timeout --retry`, and
    a short long-flag allowlist pass. Every other flag is denied, so
    `--trace/--stderr/--libcurl/--etag-save/-o` and anything curl adds later
    are refused without being enumerated
  - NET `gh` — read shapes only: `gh {run,pr,issue,release,repo}
    {list,view,status}`, or `gh api`; mutation flags (`-X --method -f -F
    --field --input --raw-field`) and `--web` denied word-level (held under
    the lens)
  - `jq` — read-only projection: the file/env/input flags (`-n --null-input
    --rawfile --slurpfile -f --from-file --args --jsonargs --stream -L`) are
    denied, and a filter naming `env`/`input`/`getpath`/`builtins`/`$ENV`/
    `$__loc__`/module keywords is refused (so `jq -n env` can't dump the
    environment into the report). jq cannot write files or exec
  - Anything else: UNVERIFIABLE.

Residuals, stated honestly. **The trust boundary is explicit: verify lines are
authored into the vault the author already controls, and freshen is
defense-in-depth against accidents and drift, not a sandbox against a hostile
author.** Within that boundary:
- A reader (`cat`/`head`/`grep`/…) can read any file whose path is *not* on the
  secret-deny list into the report's `got` field. The deny-list is a finite
  substring set — it names the known secret stores (creds/ssh/pem/vault plus,
  after a fourth lens, `/etc/shadow`, `/proc/*/environ`, `.aws/`, `.docker/
  config`, `.kube/`, gcloud, `.netrc`, `.pgpass`, `.git-credentials`, `.npmrc`,
  `.pypirc`) but cannot name every one. An arbitrary non-secret path a reader
  dumps is bounded only by author intent. This is read-only and inside the
  trust boundary; widening the list is the mitigation, not a claim of
  completeness.
- The pipe/word splitter does not parse quotes, but quotes are now *banned*, so
  the splitter and bash agree exactly; a jq filter that would need an internal
  `|` or a space simply can't be written and goes UNVERIFIABLE (fail-closed).
- The jq-filter builtin deny is a substring test, so a field literally named
  `.environment` is refused too — fail-closed, and rare.
All residuals fail *toward* UNVERIFIABLE or toward the author's own reach, never
toward silent execution of something the author didn't write.

### Execution

- `timeout <T>s bash -c 'set -o pipefail; <cmd>' </dev/null`, stderr dropped,
  stdout captured and trimmed.
- Full sweep: T=10s per command (`MAUDE_FRESHEN_TIMEOUT` overrides).
- `--wake` (the cheap subset): LOCAL-class commands only — NET lines report as
  WAKE-SKIPPED; T=2s per command and a ~8s total budget, after which remaining
  lines report SKIPPED(budget). Wake must stay fast — that is a design law of
  the wake ritual. **Note what this means: most real live-state claims are
  network-class (registries, remote CI, sockets), so a clean wake pass is NOT
  a clean roster** — it covers ahead-counts and file states, and says so.

### Verdicts

| Verdict | Meaning | Exit contribution |
|---|---|---|
| CONFIRMED | exit 0 and trimmed stdout == expected | 0 |
| STALE | exit 0, stdout differs — the vault claim no longer matches the world | 1 |
| CHECK-FAILED | nonzero exit or timeout — the probe itself broke; **loud, never folded into either other verdict** (a checker that fails open into a plausible answer is worse than one that crashes) | 1 |
| UNVERIFIABLE | never executed (forbidden operator / secret-shaped / unlisted verb / malformed line) | 0 |
| WAKE-SKIPPED / SKIPPED | out of the current mode's tier or budget | 0 |

Output: one line per verify-line claim, **verdict first**, then location, then
detail; window stamped `as of <ISO8601>Z (UTC)` — never presented as the
user's local hour. Summary line counts every verdict plus the open-marker
lines carrying no verify line. No percentages, no theatre.

### Receipts

Each run appends one metadata-only trace event (`kind:"freshen"`, payload =
counts, never claim content). `/maude:receipts` counts stale catches from it.

### Concurrency

Read-only by construction — freshen has **no write path** into any memory
file (the shared-file multi-writer wound stays closed). Its only writes are
its own trace event.

## Seed shapes (illustrative; use your own absolute paths and repo names)

Each was derived live before it was written — the command run against the wire,
its real output taken as the expectation. Paths and names are shown generically
here; a real verify line uses an absolute workspace path (tilde is banned).

    verify: `git -C /abs/path/to/a-repo rev-list origin/main..HEAD --count` ⇒ `0`
    verify: `git -C /abs/path/to/another-repo rev-list origin/build..build --count` ⇒ `0`
    verify: `curl -s https://pypi.org/pypi/your-package/json | jq -r .info.version` ⇒ `1.2.3`
    verify: `gh run list -R you/your-repo --workflow smoke.yml -L 1 --json conclusion -q .[0].conclusion` ⇒ `success`

The git lines are LOCAL (wake-eligible); the `curl`/`gh` lines are NET (full
sweep only). Every filter is quote-free — bare jq paths (`.info.version`,
`.[0].conclusion`) per the quote ban above. One retired shape is worth naming:
an installed-plugin-version check whose jq key needed quotes
(`.plugins["a-name"]`) can't be expressed under the quote ban — that's a
sensor's job. (In its brief life that very seed live-caught its own staleness
when a background reload changed the version mid-session: the mechanism
working on itself.)
