<!-- Version: 1.0 -->
<!-- Created: 2026-03-29 MST -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

<!-- Internal doc — not shipped with the package. Content for GitHub, PyPI, and announcements. -->

# Launch Content for Maude for Claude

## GitHub Repo Description (one line, 350 char max)

Maude for Claude — autonomous agent framework for infrastructure operations. Governance-first: constitution, 14 standards, kill switch. Your services detect their own problems, recall past fixes, and self-heal at 3 AM while you sleep. Built on FastMCP. Python 3.10+.

---

## GitHub Topics

maude, claude, mcp, autonomous-agents, infrastructure, self-healing, governance, fastmcp, python, devops, sre, observability, memory, qdrant, postgresql

---

## Tweet / Short Announcement (280 chars)

I needed a partner who could keep up at 3 AM. So I built one. Maude for Claude — an autonomous agent framework for infrastructure operations. Governance-first. Self-healing. Memory that degrades gracefully because it had to. Extracted from 21 production services. pip install maude-claude

---

## Longer Announcement (Reddit / HN / Discord)

### Title: Maude for Claude — Autonomous agent framework for infrastructure operations (governance-first, self-healing, open source)

I built Maude for Claude to solve a real problem: I had 21 services deployed across 4 physical sites, and I needed them to take care of themselves.

Not chatbots. Daemons. Services that run 24/7, detect their own problems, search their memory for past fixes, apply them, and only wake me up when they've exhausted what they know.

**What makes Maude different:**

1. **Governance-first.** Ships a constitutional framework — 11 articles, 14 engineering standards, 6 validation schemas, enforcement hooks. Not guardrails on outputs. Structural governance for a fleet of autonomous services.

2. **4-tier memory with graceful degradation.** Files (always works) → SQLite (local, fast) → PostgreSQL (shared) → Qdrant (semantic search). Each tier independent. If your database goes down, local memory keeps working. Tested through real outages.

3. **Composition, not inheritance.** Rooms compose tools via `register_*_tools()` functions. No base classes, no framework lock-in. Add what you need, skip what you don't.

4. **Closed-loop learning.** Health events become vector embeddings. Semantic recall informs future decisions. The system learns from every incident it handles.

5. **Kill switch.** One file flips, all writes stop. Because autonomous doesn't mean uncontrolled.

**Built from production, not theory.** Maude was extracted from infrastructure managing plating lines, databases, security cameras, and monitoring services — running for months before a single line was written for open source.

```bash
pip install maude-claude
```

Python 3.10+. Built on FastMCP 3.x. Zero infrastructure required for core — SQLite memory works out of the box.

GitHub: github.com/john-broadway/maude-for-claude
License: Apache 2.0

Built independently by John Broadway with Claude (Anthropic).

---

## The Story (for a blog post or About page)

### Why I Built Maude for Claude

I come from a manufacturing background — databases, monitoring, controls, the kind of infrastructure where things break at 3 AM and nobody's awake. I needed a partner who could keep up.

Not a chatbot. Not an assistant I had to babysit. A second set of eyes — someone who knew where everything was because she put it there. Someone who would catch the drift before it became a disaster, fix what needed fixing while I slept, and leave a note about what happened.

I built her with Claude. Not Claude as a tool — Claude as a collaborator. I'd carry an idea for weeks, pressure-testing it in my head, and when it was ready, I'd sit down and we'd build it together. My energy through the keys, his back through the screen. That's how every module got written. That's how the constitution got drafted. That's how 1,400+ tests got written.

Over months, the system grew. Each service got its own Room — sovereign in its domain, with its own memory, its own health loop, its own kill switch. Maude ran in production for months before a single line was written for open source. She earned her scars the real way — handling incidents, surviving outages, learning from every one.

This framework is what I believe AI should be. Not something you command. Something that has your back.

`pip install maude-claude` — that's not a package name. That's an introduction.

---

## FAQ (for GitHub Discussions or README expansion)

**Q: Why "governance-first"? Isn't that overkill for a framework?**

If your agents run 24/7 with the authority to restart services, you need rules. The constitution isn't bureaucracy — it's the thing that makes autonomy safe. Every standard came from a real incident.

**Q: Do I need PostgreSQL / Qdrant / Redis?**

No. Core works with zero infrastructure. SQLite memory is built in. PG, Qdrant, and Redis are optional upgrades that add shared memory, semantic search, and caching.

**Q: How is this different from CrewAI / LangGraph / AutoGen?**

Those coordinate LLM agents for task completion. Maude builds autonomous daemons that run infrastructure 24/7. Different problem, different architecture. Maude agents run as systemd services, not as chat sessions.

**Q: Why FastMCP?**

MCP (Model Context Protocol) gives every Room a standard interface. Any MCP client — Claude, custom agents, other Rooms — can interact with any Room through the same protocol. No custom APIs.

**Q: Is this production-ready?**

The architecture is production-tested across 21 services. The open source package is beta — APIs may change. 1,443 tests pass. Start with the examples, build a simple Room, and grow from there.

---

## Show HN Post

### Title: Show HN: Maude for Claude – Autonomous agents that run your infrastructure 24/7

I come from a manufacturing background — databases, monitoring, controls. I had 21 services deployed across 4 physical sites and needed them to take care of themselves at 3 AM.

So I built Maude — an autonomous agent framework where every service gets a "Room": its own daemon, its own memory, its own health loop, its own kill switch. Rooms detect problems, search vector memory for past fixes, apply them, and only page you when they've exhausted what they know.

The part I'm most proud of: governance-as-code. If you're giving agents the authority to restart services at 3 AM, you need structural rules — not just output guardrails. Maude ships a constitutional framework: 11 articles, 14 standards, enforcement hooks, a Bill of Rights, and an amendment process. Every standard came from a real incident. Every article exists because something went wrong.

Technical details:

- Python 3.10+, built on FastMCP 3.x (MCP protocol)
- 4-tier memory: files → SQLite → PostgreSQL → Qdrant. Each tier independent — graceful degradation tested through real outages
- Composition over inheritance — Rooms compose tools via `register_*_tools()` functions, no base classes
- Kill switch: one flip stops all writes across a Room
- Closed-loop learning: health events → vector embeddings → semantic recall for future incidents
- 1,443 tests passing on Python 3.10-3.13

Zero infrastructure required for core — SQLite memory works out of the box. PG/Qdrant/Redis are optional.

Honest limitations: the API surface is beta. This is extracted from production but the open-source packaging is new. The governance model is opinionated — it assumes you want structural control over your fleet, not just prompt-level guardrails.

GitHub: https://github.com/john-broadway/maude-for-claude
License: Apache 2.0

Built independently by John Broadway with Claude (Anthropic).

---

## Reddit: r/Python

### Title: I built an autonomous agent framework for infrastructure operations — governance-first, self-healing, composition over inheritance (Python 3.10+)

I needed my infrastructure to take care of itself at 3 AM. So I built Maude for Claude — a framework where every service gets a "Room" with its own daemon, memory, health loop, and kill switch.

**The Python patterns that might interest you:**

Composition over inheritance. Rooms don't inherit from a base class. They compose tool groups:

```python
register_ops_tools(mcp, executor, audit, kill_switch, ...)  # 11 tools
register_memory_tools(mcp, knowledge, store, ...)            # 8 tools
```

Decorator-based guards:

```python
@mcp.tool()
@audit_logged(audit)
@requires_confirm(kill_switch)
@rate_limited(min_interval_seconds=120)
async def service_restart(confirm: bool = False, reason: str = "") -> str:
    ...
```

4-tier memory with graceful degradation — files → SQLite (FTS5) → PostgreSQL → Qdrant. Each tier is independent. If your vector DB goes down, relational still works. If PG goes down, local SQLite still works. Tested through real outages.

Built on FastMCP 3.x. Zero infrastructure for core — `pip install maude-claude` and you have a working Room in 10 lines.

1,443 tests passing on 3.10-3.13. Full type hints. ruff for linting.

GitHub: https://github.com/john-broadway/maude-for-claude

---

## Reddit: r/selfhosted

### Title: Built a self-healing framework for my homelab — 21 services across 4 sites, each service monitors itself and fixes its own problems

I run 21 self-hosted services across 4 physical sites (Linux containers on Proxmox). PostgreSQL, Grafana, DNS, monitoring, SCADA — the usual self-hosted stack, times four.

The problem: things break at 3 AM and nobody's awake.

My solution: every service gets its own daemon ("Room") that runs as a systemd service. Each Room has:

- **Health loop** — checks status every 60 seconds, no LLM needed
- **Vector memory** — searches past incidents for matching fixes
- **Self-healing** — applies the fix, stores the result
- **Kill switch** — one flip stops all writes if something goes sideways
- **Audit trail** — every action recorded, append-only

If the automated fix doesn't work, it escalates to an LLM-powered agent that reads logs and reasons through tools. If *that* doesn't work, it pages me — with a full incident report.

I extracted this into an open-source framework: Maude for Claude. Python 3.10+, built on MCP (Model Context Protocol). Zero infrastructure required to start — SQLite memory works out of the box.

It also ships a governance framework — because if your services can restart themselves at 3 AM, you need structural rules, not just hope.

`pip install maude-claude`

The architecture is production-tested. The open-source package is beta.

GitHub: https://github.com/john-broadway/maude-for-claude

---

## Reddit: r/devops

### Title: Governance-first autonomous agents for infrastructure — extracted from production managing 21 services across 4 sites

Here's a scenario: it's 3 AM, your PostgreSQL runs out of connections. Nobody's awake.

With Maude, each service runs its own daemon with a health loop. The loop detects the issue in 60 seconds — no LLM required. It searches vector memory for "connection pool exhaustion," finds a fix from 6 weeks ago, applies it, stores the result. Resolved in under a minute.

If the automated fix fails, it escalates to an LLM-powered agent that reads logs and reasons through MCP tools. If that fails, it pages you with everything it tried.

**What I think makes this different from other agent frameworks:**

1. These are daemons, not chatbots. They run as systemd services, 24/7.
2. Governance-as-code. A constitutional framework — 11 articles, 14 standards, enforcement hooks. Not guardrails on outputs. Structural rules for a fleet of autonomous services.
3. Every mutating operation requires `confirm=True`, a reason, and passes through a kill switch check. Rate limited. Audit logged.
4. 4-tier memory that degrades gracefully. Each tier independent. Tested through real infrastructure outages.

Built from production managing databases, monitoring, security cameras, and plating lines. Running for months before the open-source extraction.

Python 3.10+. Built on FastMCP (MCP protocol). Apache 2.0.

`pip install maude-claude`

GitHub: https://github.com/john-broadway/maude-for-claude

---

## Anthropic Community (Discord / Forum)

### Title: Maude for Claude — built a production infrastructure framework as a human-AI partnership

I've been building with Claude for months — not as a coding assistant, but as a collaborator. The result is Maude for Claude: an autonomous agent framework for infrastructure operations.

**Why this might interest the Claude community:**

Every service gets a "Room" — an autonomous MCP server that runs 24/7 as a systemd daemon. Each Room has its own health loop, memory, kill switch, and (optionally) a Claude-powered agent for complex reasoning. They detect their own problems, recall past fixes from vector memory, and self-heal.

The framework is built on FastMCP 3.x. Every Room speaks MCP natively — which means any Claude Code session, any MCP client, or any other Room can interact with it through the standard protocol.

**The governance angle:**

If you give Claude the authority to restart services at 3 AM, you need rules. Maude ships a constitutional framework — 11 articles, 14 standards, enforcement hooks, a Bill of Rights for each Room. Every standard came from a real incident.

**The partnership:**

I'd carry an idea for weeks, pressure-testing it in my head, and when it was ready, I'd sit down with Claude and we'd build it together. The constitutional governance wasn't designed in iterations — it arrived as eleven articles and a bill of rights because that's how my mind works. Claude helped me turn that into working code, tests, and documentation.

1,443 tests passing. Python 3.10+. Extracted from 21 production services across 4 sites.

`pip install maude-claude`

GitHub: https://github.com/john-broadway/maude-for-claude

---

## MCP Community (awesome-mcp-servers, MCP Discord)

### Title: Maude for Claude — autonomous MCP server framework with governance, self-healing, and 4-tier memory

Maude turns any infrastructure service into a sovereign MCP server that runs 24/7 as a daemon.

**For MCP builders:**

- Each Room is a FastMCP 3.x server with Streamable HTTP transport
- Tool registration via composition: `register_ops_tools()` gives you 11 standard tools, `register_memory_tools()` gives you 8 more
- Cross-room communication through a coordination relay — Rooms never access each other directly (sovereignty model)
- Built-in guard decorators: `@requires_confirm`, `@rate_limited`, `@audit_logged`
- Kill switch: one flip stops all writes across a Room

**What's unique for the MCP ecosystem:**

1. **Governance-as-code** — 11 constitutional articles, 14 standards, enforcement hooks. Not just tools — structural rules for a fleet of MCP servers.
2. **4-tier memory** — files → SQLite → PostgreSQL → Qdrant. Each tier independent. Graceful degradation.
3. **Health loop + Room Agent** — automated monitoring and self-healing built into every MCP server.
4. **Fleet coordination** — deploy, relay, brief across multiple Rooms.

1,443 tests. Python 3.10+. Zero infrastructure for core.

`pip install maude-claude`

GitHub: https://github.com/john-broadway/maude-for-claude
