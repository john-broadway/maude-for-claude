---
title: FAB + AI Chat + Feedback Pattern
type: standard
version: 1.1.0
authors:
  - "John Broadway <271895126+john-broadway@users.noreply.github.com>"
  - "Claude (Anthropic) <noreply@anthropic.com>"
updated: 2026-03-29
status: MANDATORY
---

# FAB + AI Chat + Feedback Pattern

## Purpose

Standard UI pattern for the floating action button (FAB), AI chat assistant, and
feedback submission across all Maude web applications. Every app with authenticated
users gets this pattern. One implementation per app, consistent UX everywhere.
Implements Art. III Sec. 2 (authorship/accountability via feedback capture) and
Art. IV Sec. 1 (safety via XSS prevention).

## Reference Implementations

| App | File | Status |
|-----|------|--------|
| ERP app | `app/public/js/ai_chat.js` | Reference (jQuery/Frappe) |
| Lab-service | `src/app/templates/components/chat_panel.html` | Reference (vanilla JS/Jinja2) |
| EHS-service | `src/app/templates/base.html` (inline) | Feedback-only (no AI chat yet) |

## The Pattern

Three top-level UI elements, all fixed-position bottom-right:

### 1. Speed-Dial FAB

A 52px circle button that expands a vertical speed-dial menu upward.

| Property | Value |
|----------|-------|
| Size | 52px circle |
| Position | `fixed`, bottom 1.5rem, right 1.5rem |
| Background | App accent color (`var(--accent-primary)` or equivalent) |
| Icon | **Lucide `lightbulb`** — white stroke on accent background |
| z-index | 1060 |
| Click | Toggle speed-dial open/closed |
| Open state | Rotate 45deg, show speed-dial |
| Session indicator | Subtle ring glow (`.has-session`) when chat has messages |
| Print | Hidden |

**FAB icon (Lucide lightbulb):**
```svg
<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor"
     stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/>
    <path d="M9 18h6"/><path d="M10 22h4"/>
</svg>
```

### Speed-Dial Menu

Two labeled action buttons, stacked vertically above the FAB using `column-reverse`.

| Item | Icon | Label | Action |
|------|------|-------|--------|
| AI Assistant | App-specific (beaker for lab apps, comments for ERP apps) | "AI Assistant" | Open chat panel |
| Feedback | Person speaking (see SVG below) | "Feedback" | Open feedback modal |

Both dial buttons: 42px circle, accent-colored background, white icon.

**Feedback icon (person speaking):**
```svg
<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"
     stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="9" cy="9" r="4"/>
    <path d="M13 15c-2.7 0-7 1.3-7 4v2h14v-2c0-1.2-.8-2.2-2-3"/>
    <path d="M18 8h2"/><path d="M17.3 4.7l1.4-1.4"/><path d="M17.3 11.3l1.4 1.4"/>
</svg>
```

**Speed-dial labels:** Small tooltip-style text to the left of each button.

**Close behavior:**
- Click outside closes dial
- Clicking a dial button closes dial and opens the target
- Escape key closes dial (lowest priority)

### 2. AI Chat Panel

A 380x520px floating card anchored above the FAB.

| Property | Value |
|----------|-------|
| Size | 380px wide, 520px tall |
| Position | `fixed`, bottom-right, above FAB |
| Shape | Rounded card (`border-radius: 12px` or `var(--radius-xl)`) |
| Shadow | Elevated (`0 8px 32px rgba(0,0,0,0.18)`) |
| z-index | 1061 |
| Visibility | Hidden by default, shown via `.open` class |
| Mobile (480px) | Fullscreen |

**Panel structure (top to bottom):**

1. **Header** — accent-colored background, title, [+] new chat button, [x] close button
2. **Context bar** — hidden by default, shows "Viewing: {context}" when context detected
3. **Messages area** — scrollable, welcome state with suggestion buttons initially
4. **Input row** — auto-resizing textarea + send button

**Message rendering:**
- User messages: `textContent` only (no HTML)
- Assistant messages: Safe markdown via `DocumentFragment` + `createElement`
  - Handles: `**bold**`, `*italic*`, `` `code` ``, code blocks, `- lists`, `## headings`
  - All leaf text via `document.createTextNode()` — never `innerHTML` on LLM text
- Sources: Collapsible "Sources (N)" toggle with score badges

**Session persistence:**
- Key: `{app}_chat_messages` in `sessionStorage`
- Format: JSON array of `{role, content, sources?}` objects
- Max: 50 messages (trim oldest)
- "New Chat" button: clears storage, resets to welcome state
- FAB gets `.has-session` class when messages exist

**Context detection (app-specific):**
- Primary: `#page-data` JSON script tag (if present on the page)
- Fallback: URL path matching against a screen map
- Context label passed to backend as `context_label` in the request body
- Backend prepends "The user is currently viewing: {label}" to the AI query

### 3. Feedback Modal

A centered overlay modal, completely separate from the chat panel.

| Property | Value |
|----------|-------|
| Overlay | Full-screen backdrop, `rgba(0,0,0,0.45)` |
| Modal | Max-width 440px, centered |
| z-index | 1070 (above panel) |
| Activation | `.active` class on overlay |

**Modal structure:**
1. Title: "Send Feedback"
2. Category toggles: Idea / Request / Bug (radio-style buttons)
3. Textarea (placeholder: "What would make your job easier?")
4. Actions: Cancel (secondary) + Send (primary)

**Submit:** POST to `/api/feedback` with `{message, category}`.

## CSS Class Namespace

All classes use the `maude-` prefix for cross-project consistency.

| Element | Class |
|---------|-------|
| FAB button | `.maude-fab` |
| FAB open state | `.maude-fab.open` |
| FAB session indicator | `.maude-fab.has-session` |
| Speed-dial container | `.maude-speed-dial` |
| Speed-dial item | `.maude-dial-item` |
| Speed-dial button | `.maude-dial-btn` |
| Speed-dial label | `.maude-dial-label` |
| Chat panel | `.maude-panel` |
| Panel header | `.maude-panel-header` |
| Panel title | `.maude-panel-title` |
| Header buttons | `.maude-panel-btn` |
| Context bar | `.maude-context-bar` |
| Messages container | `.maude-messages` |
| Welcome state | `.maude-welcome` |
| Suggestion buttons | `.maude-suggestion` |
| Input row | `.maude-input-row` |
| Input textarea | `.maude-input` |
| Send button | `.maude-send` |
| Message bubble | `.maude-msg` |
| User message | `.maude-msg-user` |
| Assistant message | `.maude-msg-assistant` |
| Markdown content | `.maude-msg-content` |
| Thinking dots | `.maude-thinking` / `.maude-dot` |
| Sources toggle | `.maude-sources-toggle` |
| Source item | `.maude-source-item` |
| Source score | `.maude-source-score` |
| Feedback overlay | `.maude-fb-overlay` |
| Feedback modal | `.maude-fb-modal` |
| Category button | `.maude-fb-cat` |
| Feedback textarea | `.maude-fb-textarea` |
| Feedback actions | `.maude-fb-actions` |

## Escape Key Priority

When Escape is pressed, close the topmost active element:

1. Feedback modal (highest priority)
2. Chat panel
3. Speed-dial (lowest priority)

## Responsive Behavior

| Breakpoint | FAB | Panel | Feedback |
|------------|-----|-------|----------|
| Desktop (>768px) | 52px, bottom-right | 380x520 floating card | Centered modal |
| Tablet (768px) | 48px | 340x480, adjusted position | Same |
| Phone (480px) | 48px | **Fullscreen** | Same |
| Print | Hidden | Hidden | Hidden |

## Jinja2 / Templating Gotcha

**Never put `{% %}` Jinja tags inside HTML comments.** Jinja2 processes `{% %}`
inside `<!-- -->` comments. If you need to mention Jinja tags in a template
comment, use Jinja's own comment syntax: `{# ... #}`.

If the `<script>` block contains JavaScript that confuses Jinja's tokenizer,
wrap it in `{% raw %}...{% endraw %}`.

## Data Persistence

See **`ai-chat-persistence.md`** for the mandatory dual-write pattern (PostgreSQL +
JSONL training data). Every app with AI chat and feedback must implement that standard.

## Backend API Contract

### AI Chat: `POST /api/ai/ask`

**Request:**
```json
{
    "question": "What causes low nickel?",
    "context_label": "Bath: Acid Copper"
}
```

**Response:**
```json
{
    "answer": "Low nickel sulfate can be caused by...",
    "sources": [{"text": "...", "score": 0.85}],
    "error": null
}
```

### Feedback: `POST /api/feedback`

**Request:**
```json
{
    "message": "It would be nice to have...",
    "category": "idea",
    "page_url": "/dashboard"
}
```

## Per-App Customization Points

| What | How |
|------|-----|
| AI dial icon | App-specific SVG (beaker for lab apps, comments for ERP apps, etc.) |
| Panel title | App-specific (e.g. "AI Chemistry Assistant", "Maude Assistant") |
| Welcome text | App-specific domain description |
| Suggestion buttons | 3 app-specific example questions |
| Context detection | App-specific `#page-data` fields and URL screen map |
| Chat backend | App-specific API endpoint and RAG implementation |
| Translations | App's own i18n system |
| Accent color | App's CSS variables |

## Do Not

- MUST NOT use tabs in the panel (chat and feedback are separate — not tabbed)
- MUST NOT use a full-height slide-out drawer (use a floating card)
- MUST NOT use an overlay/backdrop behind the chat panel (FAB stays visible)
- MUST NOT use `innerHTML` for LLM-generated text (XSS risk — use `createTextNode`)
- MUST NOT put `{% if %}` or other Jinja block tags inside HTML comments
- MUST NOT create a second FAB — one per app, speed-dial expands it
