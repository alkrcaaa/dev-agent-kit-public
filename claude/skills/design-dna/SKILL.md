---
name: design-dna
description: Per-project visual identity protocol that keeps apps from converging on one generic look; creates or follows design/DESIGN-DNA.md. Use before writing or editing any UI code (HTML, CSS, templates, dashboards), even when the UI is a small part of a larger build.
---

# Design DNA (dev-agent-kit native skill)

Every LLM converges on the statistical center of design: Inter + slate, purple gradients,
three equal cards, glass dashboards. Worse: even "good" outputs converge on the SAME good
output across projects, so all your apps look like siblings. The fix is a **committed,
per-project design identity** created once and obeyed forever.

<!-- gate:begin -->
**Before writing UI code:**

1. **`design/DESIGN-DNA.md` exists?** Read it and obey it — fonts, palette, layout language are already decided; do not re-decide them.
2. **Missing?** Write it first (template below), from the product's domain and audience — then build against it. Check `~/.claude/design-registry.md` first: every direction listed there is TAKEN by another project; pick one that isn't, and append your line after.
3. **Banned by default:** Inter/Roboto/system fonts · purple-violet gradients · three equal cards · glassmorphism · emoji as icons · generic bootstrap-looking rounded cards.
4. **Commit to an extreme, not the middle** — display type ≥3× body, weight contrast ≥300, one dominant accent used in ≤2 places per screen. Timid reads as generic.
5. **Load webfonts you actually reference**, and give every family a real fallback chain — a design that silently degrades to system-sans is not the design you specified.
6. **The test:** if "make me a dashboard" with an empty prompt would produce this, it fails.
<!-- gate:end -->

## Protocol

1. **Check for `design/DESIGN-DNA.md` in the project root.**
   - **Exists** → read it, obey it in every UI change. Do not re-decide fonts, palette,
     or layout language. Done — skip to work.
   - **Missing and you are about to create or substantially restyle UI** → create it
     first (template below), show the user a 3-line summary of the direction, then build.

2. **Derive the direction from the product, not from your defaults.** Read the room:
   domain (robotics fleet tool? finance? internal ops?), audience, existing brand assets
   (logo colors, company name), and what neighboring projects already look like — then
   pick a direction those neighbors did NOT use.
   **Check the cross-project registry:** read `~/.claude/design-registry.md` before
   choosing — every direction listed there is TAKEN. After creating a DNA file, append
   one line to the registry: `- <project>: <direction one-liner> | <fonts> | <accent> | <layout signature>`
   (create the registry file if missing). This is what makes "don't repeat your other
   apps" enforceable with data instead of vibes.

3. **For craft-level guidance while implementing**, load the matching skill:
   - Product UI / dashboards / app screens → `frontend-design` skill (Anthropic anti-slop)
   - Landing pages, portfolios, full redesigns → `~/.claude/extern/taste-skill/skills/`
     (`taste-skill` for new, `redesign-skill` for upgrading an existing UI)

## DESIGN-DNA.md template

```markdown
# Design DNA — <project>
Direction: <named aesthetic, one line: e.g. "industrial terminal — dense, monospace-led,
signal-orange on near-black" or "swiss editorial — warm paper, hairline rules, serif display">
Why: <one line tying it to domain + audience>

## Typography
Display: <font, weights>   Body: <font>   Mono: <font, where used>
Scale: display ≥3× body; weight contrast ≥400 (e.g. 200 vs 800). Never Inter/Roboto/Arial.

## Palette (CSS variables — single source of truth)
--bg / --surface / --text / --muted / --accent (+ semantic: ok/warn/err)
Rule: ONE dominant accent used sparingly (≤2 places per screen), derived from brand/domain.

## Layout signature
<the ONE structural motif that makes this app recognizable — e.g. "left ledger rail +
ruled rows, no cards" / "asymmetric 2:1 split" / "dense tables, zero rounded corners" /
"top command bar + full-bleed panels". Pick something neighbors don't use.>

## Motion signature
<one orchestrated moment (page-load stagger OR state-change) + easing; everything else static>

## Signature element
<one memorable detail: custom empty-state, distinctive focus ring, chart style, cursor,
section numbering, timestamp treatment…>

## Banned in this project
Inter/Roboto/system fonts · purple/violet gradients · equal-width card trios ·
glassmorphism-by-default · emoji as icons · lorem ipsum · <plus choices your OTHER
projects already used — list them>
```

## Anti-convergence rules (apply even without a DNA file)

- **Commit to extremes, not the middle.** Timid = generic. Type: 3×+ size jumps, extreme
  weight pairs. Color: dominant + sharp accent beats evenly-distributed pastels.
- **Product UIs get character from structure, not chaos:** typography, density, border/
  radius language, one signature element. Usability stays intact — a fleet-ops dashboard
  is not an Awwwards entry, but it can still be unmistakably itself.
- **Vary across projects deliberately.** If the last project was dark charcoal + orange,
  this one is not. Light themes, warm paper, high-contrast print looks are all valid —
  dark mode is not the only "serious" option.
- **No design should be reproducible by another model with an empty prompt.** If the
  result would come out of "make me a dashboard" verbatim, it fails.
