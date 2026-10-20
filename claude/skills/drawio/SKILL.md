---
name: drawio
description: Create diagrams from natural language or code — architecture, UML, ER, network, cloud (AWS/Azure/GCP/K8s), ML pipelines. Produces .drawio files with auto-layout, exports PNG/SVG/PDF. Use whenever the user asks for a diagram, chart of a system, or visualization of code structure.
---

# Draw.io Diagrams

<!-- gate:begin -->
**Loop: generate → export → look at it → fix.**

1. **Settle the inputs first** — diagram type (ERD / UML / sequence / architecture / flowchart), output format (PNG default, else SVG/PDF), and output path. Use the user's path if they gave one; don't ask if they didn't.
2. **Check the CLI exists** before promising an export: `drawio --version`. Without it you can still deliver the `.drawio` XML — say which you produced.
3. **Write the `.drawio` XML**, then export:
   `drawio -x -f png -o out.png diagram.drawio`
4. **Self-check by reading the exported image back.** A diagram you never looked at is not finished — check for overlapping nodes, clipped labels, crossed edges, unreadable contrast.
   Export the *preview* without `-e`: draw.io's `-e` flag emits a PNG with a truncated IEND chunk that the vision API rejects with a 400.
5. **Fix with minimal XML edits** — move/resize the offending cells, don't regenerate the whole file. After ~5 rounds, hand off and suggest opening it in draw.io desktop.
6. **Final export keeps `-e`** (embeds the editable XML) so the user can keep working on it.
<!-- gate:end -->

## Depth

Read the full skill now and follow it (presets, shape libraries, layout, export flags, review loop):

```
~/.claude/extern/drawio-skill/skills/drawio-skill/SKILL.md
```

Read the reference files it points to (shape libraries, layout, export) as the task requires.
