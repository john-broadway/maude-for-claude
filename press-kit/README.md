<!-- Version: 0.21.0 -->
<!-- Created: 2026-07-13 -->
<!-- Authors: John Broadway, Claude (Anthropic) -->

# Maude — press kit

The 1950s campaign. Her runtime voice (ruled 2026-07-13: **Ward & June** —
warm, composed, never raised, runs the entire household) is the brand, so the
marketing speaks it: period print-advertisement grammar, and every poster ends
the way she actually ends a line in the product — signed `Maude:`.

Every claim on every surface here is mechanism the plugin ships. No invented
numbers, no vapor.

## What's here

| Path | What |
|---|---|
| `copy/launch-posts.md` | Taglines, the X thread, the LinkedIn post, the one-pager blurb — plus where NOT to post |
| `images/poster-1-meet-maude.svg` | Series one: the introduction — sunburst, the house-map in her hand |
| `images/poster-2-the-gate.svg` | Series one: the gate — "She'll stop you, dear." |
| `images/poster-3-the-vault.svg` | Series one: the vault floor — "She pulls the paper — not the filing cabinet." |
| `images/poster-4-the-eye.svg` | Series one: the eye — "Almost always, silence." |
| `images/poster-5-testimonial.svg` | Series two: the Packard-style testimonial — "Ask the developer who has one." |
| `images/poster-6-the-house.svg` | Series two: the appliance cut-away — "Look at all she does!" (eye/vault/trace/gate called out by room) |
| `images/poster-7-the-strip.svg` | Series two: the three-panel comic strip — "A word before you push, dear." |
| `images/poster-8-the-quiet-type.svg` | Series two: the typographic spec sheet — "The quiet type." (0 daemons · 0 databases · 0 pip installs · 8 watchful moments · 1 signed voice) |
| `images/poster-*.jpg` | 1200×1600 exports of all eight, ready to attach |
| `fonts/OFL.txt` | Pacifico's SIL OFL 1.1 license (a subset of the face is embedded in each SVG) |

## Palette & type (the campaign tokens)

Aged paper `#F3E8CE` · cherry `#C23B2E` · teal `#2E7A78` · mustard `#D9A441` ·
walnut `#2B2118`. Headlines: **Pacifico** (OFL, embedded as a ~22KB woff2
subset — the SVGs are self-contained and render the same everywhere).
Body: Georgia/serif. Utility: spaced small-caps sans.

The print craft (what makes them read *printed*, not digital): paper grain
(SVG turbulence at ~5%), a soft vignette, halftone ground shadows under each
illustration, and a slightly offset second ink plate behind every headline —
the misregistration a real 1955 press left on the page.

## Regenerating the exports

```bash
cd press-kit/images
for p in poster-*.svg; do
  google-chrome --headless --disable-gpu --hide-scrollbars \
    --window-size=1200,1600 --screenshot="${p%.svg}.png" "file://$PWD/$p"
  convert "${p%.svg}.png" -quality 88 "${p%.svg}.jpg" && rm "${p%.svg}.png"
done
```

## The rules of firing

- Posting is **John's hand** — nothing in this kit publishes itself.
- Re-verify every number against the live repo before firing
  (`scripts/check-satellites.sh <version>`); copy claims drift the moment a
  release lands.
- Reddit stays dark until the account appeal clears.
