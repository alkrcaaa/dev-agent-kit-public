---
name: vault-review
description: Interactive Obsidian vault health check — runs vault-lint.py (stale raw notes, broken backlinks, stray notes) and walks the findings one by one. Use for "vault review", "weekly maintenance" or /vault-review. Needs VAULT_DIR; stop and say so if unset.
---

# Vault Review

<!-- gate:begin -->
1. Run `python3 ~/.claude/extern/obsidian-vault-bridge/tools/vault-lint.py`. If it prints
   "no vault configured", tell the user `VAULT_DIR` isn't set up and stop — this skill has
   nothing to do without it.
2. Present the findings grouped by category, most actionable first: broken backlinks →
   unclassified/stray notes → stale raw notes → stale auto-captures. Don't just paste the
   raw output — summarize counts, then go through them.
3. For each finding, ask what to do. Never batch-decide or silently fix — `vault-lint.py`
   is read-only by design (the vault's own `CLAUDE.md` Section 5: "no auto-delete or
   bulk changes"), and this skill exists to make each fix a deliberate, one-at-a-time
   human decision, not to automate around that rule.
   - **Broken backlink** — fix the link, create the missing note (often just a missing
     folder-index note), or leave it.
   - **Unclassified/stray note** — file it into the right folder / fill the missing
     frontmatter, or leave it.
   - **Stale raw note** (`Raw/`, `compiled: false`) — if it was actually read and
     doesn't warrant a wiki article, mark `compiled: true`; otherwise leave it.
   - **Stale auto-capture** (`<!-- auto:DATE -->`, unpromoted >45d) — promote the line into
     the note's curated prose, delete it if it's no longer true, or leave it (it resurfaces
     on the next review, per the vault's OKM policy — CLAUDE.md Section 2c).
4. Never touch `_mem-log/` or `Templates/`, and never delete a note outright without
   explicit confirmation on that exact note — this is the user's personal/work vault, not
   a scratch directory.
<!-- gate:end -->

## Depth

What each check means and why it's scoped the way it is:
`~/.claude/extern/obsidian-vault-bridge/DECISIONS.md` (D15, D16) and the vault's own
`CLAUDE.md` Sections 2c and 5.
