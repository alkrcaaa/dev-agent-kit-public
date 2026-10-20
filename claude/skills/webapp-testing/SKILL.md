---
name: webapp-testing
description: Test a running web app end-to-end — drive the UI in a real browser, verify flows, capture screenshots, read console/network errors. Use when verifying a web UI works (forms, buttons, navigation, dynamic panels), debugging frontend behavior, or asked "does the UI work?".
---

# Web App Testing (Anthropic)

<!-- gate:begin -->
**Drive the UI the way a user would.**

- **Recon, then act:** `browser_navigate` → one `browser_snapshot` to get element refs → interact using those refs. Re-snapshot only after the page state actually changed.
- **If a click or form submit doesn't do what you expect, you have found a bug — investigate it.** Falling back to `browser_evaluate` + `fetch()` bypasses the very layer under test and turns a red result green. The server working via curl does not mean the UI works.
- **Read the evidence before theorising:** `browser_console_messages` and `browser_network_requests` show the real status code and redirect chain. Never explain away a failure with a guess ("probably cookie timing") you haven't checked.
- **Screenshot the state you are claiming**, after the transition completes — not before.
- **Report honestly:** which steps ran through the UI, which were worked around, and what remains unverified.

Token discipline: `browser_snapshot` dumps the full accessibility tree (5–20k tokens) — take one
only when you need element refs, never twice on the same state. For re-checking a single value use
`browser_evaluate` (~50 tokens) or `browser_find`; for visual proof use `browser_take_screenshot`.
On pages built from very large templates ANY playwright result can reach hundreds of KB — a hook
warns above ~100KB; treat that as a hard signal to switch to targeted queries.
<!-- gate:end -->

## Depth

Read the full skill now and follow it:

```
~/.claude/extern/skills/skills/webapp-testing/SKILL.md
```

Its `scripts/` helpers (e.g. `with_server.py`, which starts servers and tears them down around a
test) are meant to be run as black boxes — call them with `--help`, don't read the source into
context. Read `examples/` as the task requires.

The playwright MCP (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`,
`browser_console_messages`, `browser_network_requests`, `browser_take_screenshot`) drives the browser.
