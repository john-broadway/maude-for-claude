<!-- Version: 0.20.0 -->
<!-- Created: 2026-06-30 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Publishing Maude — the surface manifest + the push protocol

> **Why this file exists.** A release touches more than this repo. Version refs live in
> *satellite* surfaces (the profile README, the website) that drift stale the moment the repo
> bumps and nobody walks past them. This file is the **complete list of every leaf** plus the
> recipe — so a release is a checklist, not a hunt. Update this file when a new surface appears.

## Single source of truth

`.claude-plugin/plugin.json` → `version`. That is the only authoritative version. Everything
else must be made to agree with it.

- `make verify` enforces **in-repo** consistency (every `<!-- Version: -->` header, the
  CHANGELOG header, the README "What's new" ≤6-entry cap). A release that drifts in-repo fails CI.
- `make verify` does **not** see the satellites — they live in other repos. That's what the
  manifest below is for.

## Surface manifest — every leaf that carries a version

### A. In-repo (CI-enforced; bump together, `make verify` catches misses)
- `.claude-plugin/plugin.json` — canonical `version`
- `.claude-plugin/marketplace.json` — plugin entry `version`
- `CHANGELOG.md` — `<!-- Version: -->` header + a new `## vX` entry at top
- `.claude/CLAUDE.md` — `> **Version:**`
- `README.md` — `<!-- Version: -->` header + the "What's new" lead entry (≤6 total)
- every `docs/**/*.md` — `<!-- Version: -->` header

### B. Satellites (NOT in this repo — sweep by hand every release; nothing here catches a miss)
| Repo | File | What to update |
|---|---|---|
| `john-broadway/john-broadway` | `README.md` | the **Maude bullet** — version + ship date + one-line ("…vX shipped YYYY-MM-DD (…). Apache 2.0.") |
| `john-broadway/john-broadway.github.io` | `index.html` | the **Maude card** `<p class="status">` — version + date + blurb |
| `john-broadway/john-broadway.github.io` | `maude/index.html` | **three places**: (1) front-matter `description:` version, (2) `.subtitle` `&middot; vX &middot;`, (3) **add a new `<h2>vX &mdash; …</h2>` release-highlight block at the top of the highlights series** (keep the prior one below as history) |

> Note: the **internal set** is intentionally excluded from the public repo — it lives only on
> local + gitea: `docs/superpowers/` (SDD build scaffolding), `docs/VISION.md` (the family
> vision — names people), `docs/dogfood/` (living tuning logs), and any spec whose header marks
> it internal (currently `docs/specs/2026-07-13-maude-body-light-first-design.md`). The public
> tree = local `main` minus the internal set. Test fixtures must be SYNTHETIC — never excerpts
> of a real workspace's memory notes (swapped 2026-07-13, same class as the `/srv/app` path
> fixtures).

## The push protocol

### 0. Land it privately first
Normal dev flow: feature branch → tests green (`make test` / `make lint` / `make verify`) →
CHANGELOG entry → version bumped → merged to local `main` + pushed to **gitea** (private).
GitHub gets a *clean squash*, never this history.

### 1. Build the clean public squash
GitHub's `main` keeps a **scrubbed** history (pre-v0.8 commits carry since-removed infra
identifiers). **Never** push local/gitea full history to `origin`. Instead:

```bash
git fetch origin
git checkout -B publish-vX origin/main
git read-tree --reset -u main          # worktree/index = local main's exact tree
git rm -r --cached docs/superpowers     # exclude dev scaffolding from public
git commit -m "release: vX — <summary>"
git diff origin/main..HEAD              # LEAK-AUDIT what actually ships
```

### 2. Pre-public-push checklist (all four, every time)
1. **Leak-audit** the `origin/main..HEAD` diff — no secrets, IPs, real paths, hostnames, or the
   redacted-marker shapes. (Test fixtures use synthetic `/srv/app/...` paths, so the pre-push
   guard stays quiet — a root-or-home path hit now means a real leak to investigate, not a fixture.)
2. **Independent review** of substantive changes (a second-lens / redteam pass, not just green CI).
3. **Accuracy** — version, CHANGELOG, and any claims in the diff are actually true.
4. **John's go** for the public flip.

### 3. Push the publish branch — **John's hand**
The auto-mode classifier reserves a raw public-content `git push` for John. He runs (the leading
`!` runs in his shell, outside the tool-gate and the classifier; `ALLOW_PUBLIC_PUSH=1` satisfies
the pre-push guard's known-fixture flag):

```
! cd <repo> && ALLOW_PUBLIC_PUSH=1 git push -u origin publish-vX
```

### 4. PR → CI → merge → tag (Claude may drive — gh API is classifier-allowed)
```bash
gh pr create --base main --head publish-vX --title "release: vX — …" --body "…"
gh pr checks <PR#> --watch          # lint · verify · tests · gitleaks must pass
gh pr merge <PR#> --merge --delete-branch
git fetch origin
git tag -a vX origin/main -m "vX — <summary>"
# clear the maude git-push gate first (see Gotchas), then:
git push origin vX                  # 0-commit tag push — classifier-allowed
```

### 5. Sweep the satellites (Section B) — `gh api` contents PUT (classifier-allowed)
For each satellite file: fetch content+sha, apply the version edit(s), `gh api --method PUT
.../contents/<path>` with the new base64 content + sha. (A small helper:
`scripts/check-satellites.sh` greps the live satellites for an expected version.)

### 6. Verify — run it like an end-user
Grep **every** surface (repo on `origin` + the satellites) for the **old** version. Expect zero,
excluding historical CHANGELOG / highlight entries. If a leaf is stale, you missed it — go back.

## Gotchas (the leaves that bit us, 2026-06-30)
- **Maude's own gate blocks `git push`** (a YELLOW key). Clear it *as a separate command* before
  the push (the gate evaluates the whole command line, so `clear && push` blocks):
  `CLAUDE_PROJECT_DIR="$(git rev-parse --show-toplevel | xargs dirname)" bash "$CLAUDE_PLUGIN_ROOT/hooks/scripts/maude-clear-gate.sh" git-push`
  — note the session's project dir is the **umbrella launch root**, not this repo, so the token
  must be written there (that's where the live gate reads it). One-shot: re-clear per push.
- **Classifier split:** raw public-content `git push` → John's hand. `gh` API writes (pr merge,
  contents PUT) and 0-commit tag pushes → Claude may do them.
- **Pre-push guard** flags root- and home-path shapes. The canonicalizer test fixtures were
  swapped to synthetic `/srv/app/...` (2026-06-30), so the guard no longer fires on them and
  `ALLOW_PUBLIC_PUSH=1` is **not** needed for a routine release. If the guard ever fires again,
  a real root- or home-path entered the diff — investigate it, don't reflexively override.
- **Contents API lag:** a `gh api` PUT can read back stale for a few seconds — re-verify.
