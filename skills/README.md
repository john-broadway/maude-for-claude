<!-- Version: 0.1.7 -->
<!-- Revised: 2026-05-24 MST — plugin-only -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Skill

The Maude plugin ships a single skill at [`maude/SKILL.md`](maude/SKILL.md).

It declares broad triggers — recall, drift, fatigue, irreversibility, repetition — so Claude Code's skill runtime activates Maude when those concerns surface in a session.

The skill description is the load-bearing field; Claude Code reads it to decide when to load Maude. Trigger accuracy is a known v0.1.x gap (works in practice; not measured at scale).

The skill loads with the plugin — no separate install step. See the repo [`README.md`](../README.md) for the plugin install path.
