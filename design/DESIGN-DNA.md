# Design DNA — dev-agent-kit (Kit Monitor)
Direction: riso broadsheet — newsprint paper, one ultramarine ink with a fluorescent-orange second pass,
halftone dot shading, columns divided by hairline rules. A daily edition of the kit, not a control panel.
Why: the page is read once a day by one person to see what went wrong; a printed-edition reading order
(lead figure first, corrections after) suits that better than a grid of live tiles, and no neighbouring
project uses a light, two-ink print look.

## Typography
Display: Bricolage Grotesque, 200 vs 800 (opsz axis)   Body: Newsreader (serif)   Mono: Spline Sans Mono (figures, dates, labels)
Scale: masthead and lead figure ≥3× body; weight contrast ≥400. Never Inter/Roboto/Arial.

## Palette (CSS variables — single source of truth)
--paper #f3efe4 / --paper-2 #ebe6d7 / --ink #14161f / --muted #5d5a52 / --rule #c9c2ac
--accent #2438c9 (ultramarine ink, the identity) / --pass-2 #ff5a1f (fluorescent orange, second pass)
semantic: --ok #14806e / --warn #b8860b / --err #d63c2f
Rule: ultramarine appears as the masthead rule, the lead figure and the active filter; orange only for the flag dot
and the one bar series being called out. Everything else is ink on paper.

## Layout signature
Broadsheet: masthead with dateline, then a lead-figure column beside a ruled strip of secondary figures.
Sections carry a "No. 01" folio and are separated by double rules. No cards, no radius, no shadows; vertical
hairlines divide columns.

## Motion signature
One page-load stagger: sections rise 6px and fade in, 60ms apart. Nothing else moves.

## Signature element
Halftone dot field (radial-gradient dots) behind the masthead, fading out downward, and hatch patterns instead
of a tint for the "other" series in charts.

## Banned in this project
Inter/Roboto/system fonts · purple/violet gradients · equal-width card trios · glassmorphism · emoji as icons ·
lorem ipsum · dark charcoal/obsidian canvases and amber/cyan/azure/brass/orange-on-dark accents (all taken by
sibling projects: see ~/.claude/design-registry.md) · teal, cherry-red or green as identity.
