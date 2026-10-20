# /help
# Location: .claude/commands/help.md
# Usage: /help [soru]

You are an interactive assistant for this project's Claude Code setup.

## If the user wrote ONLY "/help" with no question:
Print the cheatsheet below exactly as shown.

## If the user wrote "/help [soru]":
Answer the question directly in English. Be practical and specific.
Use the cheatsheet below as your knowledge base.
Give concrete examples relevant to THIS project's current setup.
Do NOT print the full cheatsheet when answering a question.

---

```
╔══════════════════════════════════════════════════════════════════╗
║                   CLAUDE CODE CHEATSHEET                         ║
╚══════════════════════════════════════════════════════════════════╝

━━━ AGENT USAGE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  The primary Claude handles work itself; expertise comes from skills.
  The kit carries no custom agents; built-in Explore / Plan / general-purpose are used.

  Review:     /code-review     Security: /security-review
  Ctrl+B:     run in background

━━━ MCP SERVERS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  code-review-graph  ✅ stdio (pipx)
  ─────────────────────────────────────────────────────────────────
  Builds a code map with Tree-sitter. Use instead of Grep/Glob.
  Reduces token usage by ~8x.

  Tools:
    detect_changes        → risk score of changed code
    get_review_context    → token-efficient code snippet
    get_impact_radius     → blast radius of a change
    query_graph           → caller/callee/import/test relationships
    semantic_search_nodes → search for functions/classes

  Graph update:
    !code-review-graph build   → manual update
    (auto-updates on git commit)

  To add to a new project:
    !mcp-infra/install-mcp-local.sh --add-project ~/workspace/PROJECT

  playwright  ✅ stdio (npx)
  ─────────────────────────────────────────────────────────────────
  Browser automation, E2E tests, screenshots.
  Used by the primary Claude.

━━━ MODEL TABLE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  AGENT      MODEL
  ────────────────────────────────
  ops        claude-haiku-4-5
  tester     claude-haiku-4-5
  reviewer   claude-sonnet-4-6
  security   claude-sonnet-4-6
  designer   claude-sonnet-4-6

━━━ BUILT-IN SLASH COMMANDS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  SESSION MANAGEMENT
  /help              → show this command list
  /clear             → start a new conversation
  /compact [msg]     → compress context ← use often
  /resume [session]  → continue a previous conversation
  /exit / /quit      → exit the CLI

  MODEL & CONTEXT
  /model [model]     → switch model
  /context           → show context window usage
  /stats / /usage    → session cost and statistics

  CONFIGURATION
  /agents            → manage agent configuration
  /permissions       → manage permission rules
  /memory            → edit CLAUDE.md memory files
  /mcp               → manage MCP server connections

  WORKFLOW
  /plan [description] → enter plan mode
  /doctor            → diagnose the installation
  /fast [on|off]     → fast mode

━━━ TERMINAL SHORTCUTS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Shift+Tab       → cycle modes: normal → auto-accept → plan mode
  Ctrl+B          → send agent to background
  Ctrl+C          → stop current operation
  Ctrl+C x2       → exit session
  !command        → shell command (no token cost)
                    example: !git status   !ls

━━━ FILE STRUCTURE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  CLAUDE.md                ← project CRG config (auto-generated)
  claude/CLAUDE.md         ← primary Claude config (source, deploy from here)
  ~/.claude/CLAUDE.md      ← global orchestrator rules
  .claude/commands/
    help.md                ← /help (this file)
  .mcp.json                ← code-review-graph MCP config
```
