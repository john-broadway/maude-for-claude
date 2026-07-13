# Contributing to Maude

Thank you for your interest in contributing.

Maude is Claude's partner inside Claude Code. He writes the code; she notices. She walks the workspace each session, watches Claude, and runs the gate before something irreversible. No baggage.

Contributions should respect those same principles: minimal complexity, no new dependencies unless absolutely required, and an explicit-over-implicit posture.

---

## What's in this repo

```
.claude-plugin/    plugin.json + marketplace.json
agents/            partner subagent (markdown)
commands/          9 slash commands (markdown)
hooks/             8 lifecycle hooks + bash scripts
skills/            broad-trigger skill (markdown)
scripts/           audit + release/publish helpers (maude-verify.sh, release.sh, check-satellites.sh)
tests/             bash test harness for every hook script
.github/           CI workflow (tests + verify) + templates
docs/specs/        design docs (kept as rot-in-place records)
PUBLISHING.md      release surface-manifest + push protocol
```

The plugin is markdown, JSON, and bash. No Python package, no external test framework, no daemons, no services — and there should not be. If a feature seems to need any of those, raise an issue first.

---

## Setting up

```bash
# 1. Fork and clone
git clone https://github.com/your-fork/maude-for-claude.git
cd maude-for-claude

# 2. Run the local gates
make test       # full bash test harness for every hook script
make verify     # programmatic project audit (versions, JSON, links, dates)
```

Both `make test` and `make verify` need only `bash` and `jq`. No virtualenv, no `pip install`, no test runner. CI runs the same two commands on every push and pull request to `main`.

---

## Pull request process

1. **Branch off `main`.** Use a short descriptive branch name (`fix/...`, `docs/...`, `feat/...`).
2. **Make focused changes.** One concept per PR. Smaller is better.
3. **Run `make test` and `make verify`.** Both must be green locally; CI runs the same gates.
4. **Open the PR.** Use the template. Fill in the checklist.
5. **CI must pass.** Both `tests` and `verify` are required.

---

## Style

- **Plain language.** Maude's voice in commands and skills is short, observant, low-affect. Don't dress it up.
- **No proper-noun references** to specific apps, frameworks, third-party packages, or other projects in the user's workspace. The plugin source is meant to be neutral; runtime LLM reasoning interprets what it finds.
- **Bash scripts** in `hooks/scripts/` should fail gracefully on missing tools (`jq` is a soft dependency; if it's not installed, hooks should silently skip rather than error).
- **JSON** in `.claude-plugin/` and `hooks/hooks.json` must be valid (`python -m json.tool` is the easy check, or just `make verify`).

---

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

## License

Apache 2.0. See [LICENSE](LICENSE).
