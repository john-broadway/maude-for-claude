<!-- Version: 0.3.2 -->
<!-- Revised: 2026-06-09 CDT — plugin-only -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Skill

The Maude plugin ships a single skill at [`maude/SKILL.md`](maude/SKILL.md).

It declares **prompt-shaped** triggers — recall / "where is X", save / remind, a user signalling they're stuck or tired, or invoking any `/maude:*` command — so Claude Code's skill runtime activates Maude when those surface in a prompt. (Drift detection, irreversible-action gating, and fatigue cadence are handled by **hooks**, not the skill matcher — the runtime can't see those from a prompt, so the description no longer claims them.)

The skill description is the load-bearing field; Claude Code reads it to decide when to load Maude. v0.3.0 tightened it to those prompt-detectable triggers (dropping the hook-only behavioral clauses that made it over-fire and over-promise); accuracy is still not benchmarked at scale.

The skill loads with the plugin — no separate install step. See the repo [`README.md`](../README.md) for the plugin install path.
