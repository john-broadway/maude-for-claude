# For Humans Explainer Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone HTML explainer page that teaches Maude's architecture through the John Wick (2014) universe.

**Architecture:** Single self-contained HTML file with inline CSS. Three acts: narrative (3 AM scenario), character map, quickstart. Dark theme, Art Deco gold accents, responsive. Scrub exclusion for JW character names.

**Tech Stack:** HTML, CSS (inline). Google Fonts CDN for Playfair Display + system font fallbacks. Zero JavaScript.

**Spec:** `docs/superpowers/specs/2026-04-03-for-humans-explainer-design.md`

**Source of truth for character mappings:** `~/projects/agency/reference/continental-naming.md` (JW1 characters only)

---

### Task 1: Scrub exclusion for docs/for-humans.html

**Files:**
- Modify: `scripts/scrub-check.sh`
- Modify: `.github/workflows/ci.yml`

This must be done first — the page will contain `Charon`, `Winston`, and other scrub-trigger words intentionally.

- [ ] **Step 1: Update scrub-check.sh to exclude for-humans.html**

In `scripts/scrub-check.sh`, add `--exclude=for-humans.html` to the grep command. Find the line:

```bash
if grep -rEn "$pattern" src/ tests/ template/ .github/ docs/ examples/ skills/ \
     --exclude-dir=__pycache__ --exclude='*.pyc' \
     --exclude=scrub-patterns.txt 2>/dev/null; then
```

Change to:

```bash
if grep -rEn "$pattern" src/ tests/ template/ .github/ docs/ examples/ skills/ \
     --exclude-dir=__pycache__ --exclude='*.pyc' \
     --exclude=scrub-patterns.txt \
     --exclude=for-humans.html 2>/dev/null; then
```

- [ ] **Step 2: Update ci.yml with same exclusion**

In `.github/workflows/ci.yml`, find the identical grep line in the scrub job and add the same `--exclude=for-humans.html`.

- [ ] **Step 3: Verify scrub still passes**

Run: `make scrub`
Expected: `PASS: No internal references detected.`

- [ ] **Step 4: Commit**

```bash
git add scripts/scrub-check.sh .github/workflows/ci.yml
git commit -m "ci: exclude for-humans.html from scrub (deliberate JW references)"
```

---

### Task 2: Write the HTML page — Act 1 (The Story)

**Files:**
- Create: `docs/for-humans.html`

- [ ] **Step 1: Create the HTML file with full document structure, CSS, and Act 1**

Create `docs/for-humans.html` with:

**Document head:**
- `<!DOCTYPE html>`, charset UTF-8, viewport meta for responsive
- `<title>Maude for Claude — For Humans</title>`
- Google Fonts: Playfair Display (700) + Inter (400, 500)
- All CSS in a single `<style>` block

**CSS requirements (inline `<style>`):**
```
Body: background #0a0a0a, color #ccc, font-family Inter/system sans-serif
Headings: Playfair Display, color #c9a96e (Continental gold)
Max-width: 800px centered container, padding 20px
Sections: margin-bottom 80px, section dividers with thin gold rule
Scene cards: background #111, border-left 3px solid #c9a96e, padding 24px, margin 24px 0
Quotes: font-style italic, color #e8d5b0, Playfair Display
Character names in scenes: color #c9a96e, uppercase, letter-spacing 2px, font-size 12px
Responsive: @media (max-width: 600px) reduce padding, font sizes
```

**Act 1 content — "A Night at the Continental":**

Opening:
```
It's 3 AM. Your PostgreSQL just ran out of connections.

You're asleep. The Continental is not.
```

Scene 1 — The Health Loop:
```
Every 60 seconds, the health loop checks vitals. CPU, memory, disk,
error count, HTTP endpoints. No AI — just pattern matching.

Tonight it catches the connection exhaustion. It searches memory:
"connection pool exhaustion" — and finds a fix from six weeks ago.
Kill idle connections. Restart the pooler.

It applies the fix. 47 seconds. You're still asleep.
```

Scene 2 — The Room Agent:
```
Sometimes the old fix doesn't work. The pattern has changed.

The Room Agent wakes up. This is the AI — an LLM that reads your
service's logs, reasons through its available tools, and tries
something it hasn't tried before.

It stores every attempt. What it tried, what worked, what didn't.
So next time, the health loop has a new fix to find.
```

Scene 3 — Charon:
```
CHARON — THE CONCIERGE

Charon sees every Room. When the Room Agent resolves the issue,
Charon records it across the fleet. If a different Room hits the
same problem tomorrow, the fix is already waiting.

When the Room Agent can't resolve it, Charon routes the escalation
upward. Cross-room context flows — what else is broken, what
depends on this service, who's affected.
```

Scene 4 — Winston:
```
WINSTON — THE MANAGEMENT

Winston runs the same model as every Room Agent. He's not smarter.
He sees more.

When an escalation arrives, Winston has fleet-wide visibility —
every recent incident, every dependency, every Room's status. He
investigates across boundaries that individual agents can't cross.

Not higher authority. Wider context.
```

Scene 5 — John Wick:
```
JOHN WICK — ROOM 911

Winston resolved it? You sleep through. The Continental handled it.

Winston couldn't? You get the call. But not a raw alert — a full
incident report. What happened. What was tried. What failed. What
needs your decision.

You make one call. Go back to sleep.
```

Closing:
```
The Continental handled it.

That's what Maude does. Every service gets a Room. Every Room is
sovereign — its own daemon, its own memory, its own health loop,
its own kill switch. The framework gives them the tools.
They do the rest.
```

- [ ] **Step 2: Open in browser and verify Act 1 renders**

Run: open `docs/for-humans.html` in Chrome (or `python3 -m http.server 8080 -d docs/` and visit `http://10.10.0.71:8080/for-humans.html`)

Verify: dark background, gold headings, scenes flow top to bottom, readable on full-width and narrow window.

- [ ] **Step 3: Commit**

```bash
git add docs/for-humans.html
git commit -m "docs: add for-humans explainer — Act 1 (the story)"
```

---

### Task 3: Add Act 2 (The Cast)

**Files:**
- Modify: `docs/for-humans.html`

- [ ] **Step 1: Add Act 2 section after Act 1**

Add a gold rule divider, then the "Meet the Staff" section.

**CSS for character cards (add to existing `<style>`):**
```
.cast-grid: display grid, grid-template-columns repeat(auto-fill, minmax(280px, 1fr)), gap 16px
.cast-card: background #111, border 1px solid #333, border-radius 8px, padding 20px
.cast-card .name: color #c9a96e, font-family Playfair Display, font-size 18px
.cast-card .role: color #888, font-size 13px, text-transform uppercase, letter-spacing 1px
.cast-card .mapping: color #666, font-size 12px, margin-top 12px, font-family monospace
.cast-card .line: color #aaa, font-size 14px, font-style italic, margin-top 8px
Currency/rules cards: same but border-color #c9a96e, background #1a1510
Cautionary cards: border-left 3px solid #8b2500, background #1a0a0a
```

**Characters (8 cards):**

Winston — Continental Manager — Human Authority — "Runs the hotel. Final say."
John Wick — The Protagonist — Claude Code + control plane — "The one they call when everything fails."
Charon — The Concierge — maude.daemon (framework) — "Routes guests, manages Rooms. Every daemon runs his code."
Marcus — Old friend on the rooftop — Backup (PBS) — "Silent guardian. You don't notice him until you need him."
Aurelio — The mechanic — Build/deploy pipeline — "Honest mechanic. Clean builds."
Jimmy — The cop — Firewall — "Sees everything. Doesn't ask too many questions."
Harry — The doorman — Authentication — "You're on the list or you're not."
Francis — The bouncer — Rate limiting — "Controls the flow."

**Currency & Rules (3 cards):**

Gold Coins — Currency of trust — 4-tier memory — "Every incident stored, every pattern learned, every fix remembered."
The Rules — No business on hotel grounds — Constitution — "11 articles. 14 standards. A Bill of Rights. An amendment process."
Excommunicado — All doors close — Kill switch — "One command. All writes blocked. Fleet-wide."

**Cautionary Tales (2 cards):**

Ms. Perkins — Broke the rules — "Bypass the hooks, end up like Perkins."
Iosef — Touched what wasn't his — "Don't touch production without authorization."

- [ ] **Step 2: Verify in browser**

Refresh the page. Verify: character grid renders, cards are readable, responsive at narrow width (single column), gold accents on currency cards, red accents on cautionary cards.

- [ ] **Step 3: Commit**

```bash
git add docs/for-humans.html
git commit -m "docs: add for-humans explainer — Act 2 (the cast)"
```

---

### Task 4: Add Act 3 (Build Your Own Continental)

**Files:**
- Modify: `docs/for-humans.html`

- [ ] **Step 1: Add Act 3 section after Act 2**

Gold rule divider, then "Build Your Own Continental" section.

**Content:**

Heading: "Build Your Own Continental"
Subheading: `pip install maude-claude`

Three steps, each in a card:

Step 1 — "Copy the template"
```
cp -r template/ my-room/
```
"One Room. One service. Everything wired — daemon, health loop, memory, guards."

Step 2 — "Add your tools"
```python
@mcp.tool()
async def my_health_check() -> str:
    """Your service, your checks."""
    ...
```
"MCP tools. Health checks. Domain logic. Whatever your service needs."

Step 3 — "Run it"
```bash
python -m my_room
```
"Charon takes over. Health loop starts. Memory connects. Guards arm. Your Room is open for business."

**Footer links:**

"→ README · Quickstart · Examples · GitHub"

Each links to the appropriate relative path or GitHub URL:
- README: `../README.md`
- Quickstart: `quickstart.md`
- Examples: `../examples/`
- GitHub: `https://github.com/john-broadway/maude-for-claude`

Final quote:
```
"Rules. Without them, we live with the animals."
— Winston
```

- [ ] **Step 2: Verify in browser**

Refresh. Verify: Act 3 renders, code blocks styled (dark bg, monospace), links work (relative paths resolve), quote at bottom renders in serif italic.

- [ ] **Step 3: Verify all links work**

Click each link in Act 3. README, quickstart, examples, GitHub — all should resolve.

- [ ] **Step 4: Commit**

```bash
git add docs/for-humans.html
git commit -m "docs: add for-humans explainer — Act 3 (build your own)"
```

---

### Task 5: Scrub + responsive + final verification

**Files:**
- No new files — verification only

- [ ] **Step 1: Run scrub**

Run: `make scrub`
Expected: PASS (for-humans.html excluded)

- [ ] **Step 2: Test responsive**

Open `docs/for-humans.html` in Chrome. Resize to narrow width (~375px, phone size). Verify:
- Single column layout
- Text readable without horizontal scroll
- Character cards stack vertically
- Code blocks don't overflow

- [ ] **Step 3: Check for jargon**

Read through the page as a non-technical person. Flag any term used without explanation:
- MCP → should say "tools" or be explained
- LLM → should say "AI" or be explained
- daemon → should say "background service" or be explained
- asyncio → should not appear at all

- [ ] **Step 4: User gate**

Show the page to John Broadway in browser. Get approval on:
- Story accuracy
- Character mapping accuracy
- Tone and visual design

- [ ] **Step 5: Commit and push**

```bash
git add -A
git commit -m "docs: for-humans explainer — complete (3 acts, JW1 cast, responsive)"
```

Push branch, create PR, wait for CI.
