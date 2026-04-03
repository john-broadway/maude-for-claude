# For Humans — Explainer Page Design

> **Created:** 2026-04-03
> **Author:** John Broadway, Claude (Anthropic)
> **Status:** Draft — awaiting approval

## Purpose

A standalone HTML page in the Maude repo that explains the architecture to anyone curious — developers, decision makers, or someone who just stumbled on the repo. Uses the John Wick (2014) universe as the metaphor. The movie IS the hook.

## Audience

General. No assumed knowledge of MCP, asyncio, or infrastructure patterns. If you've seen the movie, you get it.

## Location

`docs/for-humans.html` — standalone, styled, servable via GitHub Pages. No build step. Self-contained CSS. No external dependencies.

## Structure — Three Acts

### Act 1: "A Night at the Continental"

Narrative walkthrough of the 3 AM scenario. The reader experiences the escalation chain through the characters.

**Scene flow:**

1. **Opening** — "It's 3 AM. Your PostgreSQL just ran out of connections." Set the mood. Dark, urgent, the hotel is quiet.

2. **The Health Loop** — No character name here (the health loop doesn't map to a named JW1 character cleanly enough). Every 60 seconds, vitals are checked. Pattern matching finds a fix from 6 weeks ago. Applies it.

3. **The Room Agent** — Past fix worked? Scene over, you never wake up. Past fix failed? The Room Agent activates. LLM-powered reasoning. Reads logs, picks tools, tries a new approach.

4. **Charon (The Concierge)** — Agent fixed it? Charon records the resolution across the fleet. Agent failed? Charon routes the escalation upward. Cross-room context flows.

5. **Winston (The Management)** — Winston investigates with fleet-wide visibility. Same model as the Room Agent — but Winston sees every Room, every recent incident, every dependency. Not higher authority. Wider context.

6. **John Wick (Room 911)** — Winston resolved it? You sleep through. Winston couldn't? John Wick gets the call. You wake up to a full incident report — what happened, what was tried, what failed, what needs your decision.

7. **Closing** — "You go back to sleep. The Continental handled it."

**Tone:** Cinematic. Short sentences. Dark backgrounds, gold accents (Art Deco, matching the Continental aesthetic and the existing web dashboard).

### Act 2: "Meet the Staff"

The complete JW1 character map. Each character gets a card with:
- Character name and JW role
- Maude concept and module path
- One-line description in the character's voice

**Characters (JW1 only):**

| Character | JW Role | Maude Mapping | One-liner |
|-----------|---------|---------------|-----------|
| Winston | Continental Manager | Human Authority (Art. I) | Runs the hotel. Final say. |
| John Wick | The Protagonist | Claude Code + control plane | The one they call when everything fails. |
| Charon | The Concierge | `maude.daemon` — framework code | Routes guests, manages Rooms. Every daemon runs his code. |
| Marcus | Old friend on the rooftop | Proxmox Backup Server | Silent guardian. You don't notice him until you need him. |
| Aurelio | The mechanic | Build / deploy pipeline | Honest mechanic. Clean builds. |
| Jimmy | The cop | Firewall / network policy | Sees everything. Doesn't ask too many questions. |
| Harry | The doorman | Authentication (Authentik) | You're on the list or you're not. |
| Francis | The bouncer | Rate limiting / throttling | Controls the flow. |

**Currency & Rules:**

| Concept | JW Element | Maude Mapping |
|---------|-----------|---------------|
| Gold Coins | Currency of trust | 4-tier memory (md → PG → Qdrant → Training) |
| The Rules | No business on hotel grounds | Constitution (11 articles, 14 standards, Bill of Rights) |
| Excommunicado | All doors close | Kill switch — all writes blocked, fleet-wide |

**Cautionary Tales:**

| Character | What They Did | Lesson |
|-----------|--------------|--------|
| Ms. Perkins | Broke the rules | "Bypass the hooks, end up like Perkins." |
| Iosef | Touched what wasn't his | "Don't touch production without authorization." |

### Act 3: "Build Your Own Continental"

Transition from story to action. Three steps:

1. `pip install maude-claude`
2. Copy the template. One Room, one service.
3. Add your tools. Run it. Charon takes over.

Links to: README, Quickstart guide, Examples, GitHub repo.

## Visual Design

- **Dark theme** — black/near-black backgrounds (#0a0a0a, #111)
- **Gold accents** — Continental gold (#c9a96e) for headings, borders, highlights
- **Typography** — Serif for character names/quotes (Playfair Display or Cormorant Garamond, both already in the web dashboard fonts). Sans-serif for descriptions.
- **Art Deco touches** — geometric borders, thin gold rules, uppercase labels with letter-spacing. Matches the existing Continental Dashboard aesthetic.
- **Self-contained** — all CSS inline or in a `<style>` block. No external stylesheets. Fonts loaded from Google Fonts CDN (or embedded as base64 if we want zero dependencies).
- **Responsive** — works on phone (people share links on mobile)

## Scrub Considerations

This page deliberately references John Wick characters by name (Winston, Charon, etc.). These names are scrub-pattern triggers. The scrub check script must exclude `docs/for-humans.html` from the scrub scan.

Add to `scripts/scrub-check.sh` exclusion: `--exclude=for-humans.html`

## What This Page Is NOT

- Not a replacement for the README (which has install instructions and code examples)
- Not a technical architecture doc (that's `docs/architecture.md`)
- Not documentation (no API references, no module paths beyond the character map)
- Not using any copyrighted Lionsgate imagery — all original styling inspired by the film's aesthetic

## Acceptance Criteria

Every item must be verified before the page ships. **P0 = must ship. P1 = should ship. P2 = nice to have.**

### P0 — Page is broken without these

- [ ] Act 1 tells the 3 AM story through 6 scenes (health loop → room agent → Charon → Winston → John Wick → resolution)
- [ ] A non-technical reader who has seen John Wick (2014) can follow the story
- [ ] A technical reader who hasn't seen the film still understands what Maude does
- [ ] Act 2 includes all 8 JW1 staff characters mapped to real Maude functions
- [ ] Act 3 has working `pip install` command and links to README/GitHub
- [ ] No Lionsgate copyrighted imagery
- [ ] Self-contained single HTML file at `docs/for-humans.html`
- [ ] `make scrub` passes (for-humans.html excluded from scrub scan)
- [ ] Renders correctly in Chrome (primary browser)

### P1 — Page is weak without these

- [ ] Act 2 includes Gold Coins, The Rules, Excommunicado mappings
- [ ] Act 2 includes Perkins and Iosef cautionary tales
- [ ] Act 3 has 3-step quickstart and links to quickstart/examples
- [ ] No jargon without explanation (MCP, asyncio, daemon, LLM get plain-English treatment)
- [ ] Dark theme with Continental gold (#c9a96e) accents
- [ ] Art Deco typography (serif headings, geometric borders)
- [ ] Responsive — readable on mobile (single column at narrow widths)
- [ ] Firefox and Safari render correctly

### P2 — Polish

- [ ] Page loads in under 2 seconds on cold browser
- [ ] `make lint` still passes
- [ ] Fonts from CDN with fallback system fonts
- [ ] All Act 3 links resolve to real repo files/URLs

### Gate — Nothing ships without this

- [ ] John Broadway reads the page in a browser and approves it
- [ ] John Broadway confirms the JW1 character mappings are accurate to his design intent
- [ ] John Broadway confirms the story doesn't misrepresent how Maude works
