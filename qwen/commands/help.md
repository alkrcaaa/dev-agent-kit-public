# /project:help
# Location: .qwen/commands/help.md
# Usage: /project:help [soru]

You are an interactive assistant for this project's Qwen Code (vLLM) setup.

## If the user wrote ONLY "/project:help" with no question:
Print the cheatsheet below exactly as shown.

## If the user wrote "/project:help [soru]":
Answer the question directly in English. Be practical and specific.
Use the cheatsheet below as your knowledge base.
Give concrete examples relevant to THIS project's current setup.
Do NOT print the full cheatsheet when answering a question.

---

```
╔══════════════════════════════════════════════════════════════════╗
║                   QWEN CODE CHEATSHEET                           ║
╚══════════════════════════════════════════════════════════════════╝

AGENT USAGE

  The primary Qwen handles work itself; expertise comes from skills.
  The kit carries no custom agents; built-in general-purpose is used when explicitly requested.

MCP SERVERS

  code-review-graph  ✅ INSTALLED  (pipx, v2.3.2)
  ─────────────────────────────────────────────────────────────────
  Builds a code map with Tree-sitter. Use instead of Grep.
  Reduces token usage by ~8x.

  Tools:
    detect_changes        → risk score of changed code
    get_review_context    → token-efficient code snippet
    get_impact_radius     → blast radius of a change
    query_graph           → caller/callee/import/test relationships
    semantic_search_nodes → search for functions/classes

  Graph update:
    (auto-updates on git commit)

  To add to another project:
    code-review-graph install --platform qwen
    code-review-graph build

BUILT-IN QWEN CODE COMMANDS

  **SESSION MANAGEMENT**
  /help              → show this command list
  /exit / /quit      → exit Qwen Code
  /resume            → continue a previous session
  /clear             → reset conversation history
  /rename            → rename current conversation
  /recap             → generate session summary
  /rewind            → go back to previous step
  /restore           → restore a tool call

  **MODEL & CONTEXT**
  /model             → switch model
  /context           → show context window usage
  /compress          → compress context
  /stats             → session statistics
  /btw               → quick reply question

  **MEMORY**
  /memory            → open memory manager
  /remember          → save to persistent memory
  /forget            → delete a memory entry

  **PERMISSIONS & CONFIGURATION**
  /auth              → authentication
  /permissions       → manage permission rules
  /settings          → edit Qwen settings
  /theme             → change theme
  /language          → change language

  **MCP & ORCHESTRATION**
  /agents            → manage built-in subagents
  /skills            → list available skills

  > **/mcp** — Qwen Code's built-in MCP management command. Opens an interactive menu. Not explained in QWEN.md; the model does not interpret it.

  **WORK & REVIEW**
  /init              → analyze project, create QWEN.md
  /summary           → generate project summary
  /tasks             → list background tasks
  /plan              → enter plan mode
  /docs              → open Qwen documentation

  **VIM MODE**
  /vim               → toggle vim mode
  /editor            → change editor preference

FILE STRUCTURE

  qwen/QWEN.md           ← primary Qwen config (source)
  ~/.qwen/settings.json  ← Qwen Code settings + MCP config
  .qwen/commands/
    help.md              ← /project:help (this file)

vLLM SERVER

  Model:  /models/qwen3.6-27b
  API:    OpenAI compatible
  Host:   $QWEN_HOST (set via env var OPENAI_BASE_URL)

  Healthcheck:
  curl "$OPENAI_BASE_URL"/v1/models

TROUBLESHOOTING

  Model not found    → is the vLLM server running? test with curl
```
