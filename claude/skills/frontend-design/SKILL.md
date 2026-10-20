---
name: frontend-design
description: Build polished, distinctive UI — web pages, dashboards, components, prototypes, mobile screens. Use for ANY task that creates or edits UI code (HTML/CSS/templates/webui), even when the UI is only one part of a larger app or ansible/backend build — not just when the user says "design".
---

# Frontend Design

**First:** check `design/DESIGN-DNA.md` in the project (see `design-dna` skill). If it
exists, it overrides all defaults below. If you're creating a new UI and it doesn't
exist, create it first via the `design-dna` skill.

<!-- gate:begin -->
**Craft baseline.**

- **Pick a direction and execute it precisely.** Name the tone before writing CSS (brutally minimal, editorial, industrial terminal, warm paper…). Intentionality beats intensity — both maximalism and restraint work; the mushy middle doesn't.
- **Typography carries the character.** A distinctive display face paired with a refined body face. Never Arial/Inter/Roboto as the statement font.
- **Color:** CSS variables as the single source of truth. One dominant plus a sharp accent beats an evenly-distributed pastel set.
- **Composition:** asymmetry, overlap, deliberate density or generous negative space — not three equal cards in a row.
- **Motion:** one orchestrated moment (staggered page-load or a state-change flourish), CSS-only where possible. Scattered micro-interactions add noise, not delight.
- **Backgrounds:** atmosphere over flat fill — gradient mesh, grain, geometric pattern, layered transparency, in service of the chosen tone.
- **Match code complexity to the vision** — a refined minimal design needs restraint and precise spacing, not more effects.
- **Functional truth beats appearance:** every control you draw must work. A button that renders but doesn't submit, or a form whose failure path shows raw JSON instead of an error state, is unfinished UI — not a backend problem.
<!-- gate:end -->

## Depth

Read the full skill now and follow it:

```
~/.claude/extern/skills/skills/frontend-design/SKILL.md
```

Routing for specialized cases:
- **Landing pages / portfolios** → `~/.claude/extern/taste-skill/skills/taste-skill/SKILL.md`
  (design-read + variance/motion/density dials; aesthetic variants: `soft-skill`,
  `minimalist-skill`, `brutalist-skill` in the same dir)
- **Upgrading an existing generic-looking UI without a rewrite** →
  `~/.claude/extern/taste-skill/skills/redesign-skill/SKILL.md` (audit-first: scan,
  diagnose generic patterns, fix in the existing stack)
- **Richer pattern libraries** (90+ patterns: pitch decks, carousels, marketing pages) →
  browse `~/.claude/extern/open-design/skills/` and load the matching pattern's skill.

Verify the result in a browser with the `webapp-testing` skill — drive the real flow, don't
just screenshot the happy path.
