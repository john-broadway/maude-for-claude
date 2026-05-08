# Contributing to Maude

Thank you for your interest in contributing.

Maude is Claude's partner inside Claude Code. He writes the code; she notices. She walks the workspace each session, watches Claude, and runs the gate before something irreversible. No baggage.

Contributions should respect those same principles: minimal complexity, no new dependencies unless absolutely required, and an explicit-over-implicit posture.

---

## What's in this repo

```
.claude-plugin/    plugin.json + marketplace.json
agents/            partner subagent (markdown)
commands/          14 slash commands (markdown)
hooks/             7 lifecycle hooks + bash scripts
skills/            broad-trigger skill (markdown)
scripts/           scrub gate (single source of truth: scrub-patterns.txt)
.github/           CI workflow (origin scrub) + templates
docs/launch/       internal launch artifacts (not user-facing)
```

The plugin is markdown, JSON, and bash. No Python package, no test suite, no daemons, no services — and there should not be. If a feature seems to need any of those, raise an issue first.

---

## Setting up

```bash
# 1. Fork and clone
git clone https://github.com/your-fork/maude-for-claude.git
cd maude-for-claude

# 2. Run the scrub gate (no-op locally for contributors; runs in CI)
make scrub
```

That's it. No virtualenv, no `pip install`, no test runner. The scrub gate is the only thing CI runs.

**For contributors:** `make scrub` is a no-op locally — it skips because the patterns file is private to the maintainer. The same gate runs in CI on every PR using a repo secret. You don't need to do anything special.

---

## Pull request process

1. **Branch off `main`.** Use a short descriptive branch name (`fix/...`, `docs/...`, `feat/...`).
2. **Make focused changes.** One concept per PR. Smaller is better.
3. **Run `make scrub`.** It must pass locally. CI runs the same gate.
4. **Open the PR.** Use the template. Fill in the checklist.
5. **CI must pass.** Scrub is required.

---

## Style

- **Plain language.** Maude's voice in commands and skills is short, observant, low-affect. Don't dress it up.
- **No proper-noun references** to specific apps, frameworks, third-party packages, or other projects in the user's workspace. The plugin source is meant to be neutral; runtime LLM reasoning interprets what it finds.
- **Bash scripts** in `hooks/scripts/` should fail gracefully on missing tools (`jq` is a soft dependency; if it's not installed, hooks should silently skip rather than error).
- **JSON** in `.claude-plugin/` and `hooks/hooks.json` must be valid (`python -m json.tool` is the easy check).

---

## Origin scrub

The repo's source is scrubbed of internal references; CI enforces it on every PR.

**For contributors:** there's nothing to set up. The patterns file is private to the maintainer, so `make scrub` no-ops locally and the actual check runs in CI. If your PR happens to hit a forbidden pattern, the CI failure will tell you which.

**For the maintainer:** the patterns live in two places —

- `~/.config/maude-scrub-patterns.txt` — local, gitignored, read by `scripts/scrub-check.sh` via `$SCRUB_PATTERNS_FILE` (default path)
- `SCRUB_PATTERNS` repo secret — read by `.github/workflows/ci.yml` and materialized to a runner-temp file

Format: one rule per line, `LABEL ||| GREP_EXTENDED_REGEX`. See [`scripts/scrub-patterns.example.txt`](scripts/scrub-patterns.example.txt). To add a new pattern, append it to BOTH locations (the local file AND the GitHub secret) so local and CI stay in sync.

---

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

## License

Apache 2.0. See [LICENSE](LICENSE).
