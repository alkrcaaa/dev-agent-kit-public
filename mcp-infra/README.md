# MCP Infrastructure

Local MCP servers + skill libraries for dev-agent-kit. No Docker — everything runs as local processes (pipx, npx, python venv, systemd user services).

## MCP Servers

Seven servers are configured automatically by `install.sh`. Each agent only accesses the servers it needs (see access matrix below).

| Server | Transport | Claude | Qwen | Port |
|--------|-----------|--------|------|------|
| `code-review-graph` | stdio (pipx) | ✅ | ✅ HTTP | 7000 |
| `playwright` | stdio (npx) | ✅ | ✅ HTTP | 8932 |
| `local-model` | stdio (python venv) | ✅ | ❌ | — |
| `lsp` | stdio (lsp-coercion-proxy → lsp-mcp-server) | ✅ | ✅ | — |
| `fetch` | stdio (npx) | ✅ | ✅ HTTP | 8935 |
| `mem-lite` | stdio (node) | ✅ | ✅ | — |
| `vault-search` | stdio (python venv) | ✅ | ✅ | — |

Claude and Qwen both use stdio transports for LSP — the proxy starts on-demand per session. Qwen uses HTTP daemons for code-review-graph, playwright, and fetch (ports 7000, 8932, 8935).

---

### code-review-graph

Parses source code into a persistent knowledge graph using Tree-sitter. Understands callers, callees, imports, tests, and architectural communities. Much faster and cheaper than scanning files manually — a single call can answer questions that would take 10+ `grep`/`read_file` calls.

**When to use:** Any code analysis task — before `grep_search` or `read_file`.  
**Rule:** Always call `get_minimal_context_tool` first (~100 tokens, full structural picture).

**Example — find what calls a function:**
```
User: "What calls process_frame()?"
Agent: query_graph_tool(pattern="callers_of", node="process_frame")
→ Returns: [camera_loop.py:47, video_pipeline.cpp:203, tests/test_frame.py:18]
```

**Example — blast radius of a change:**
```
User: "I'm changing the MotorController interface — what breaks?"
Agent: get_impact_radius_tool(node="MotorController")
→ Returns: 12 files, 3 critical flows affected, risk score 0.87
```

**Example — code review:**
```
Agent (reviewer): detect_changes_tool() → risk-scored list of changed functions
Agent (reviewer): get_review_context_tool(files=[...]) → source snippets for changed code only
```

| Tool | Use When |
|------|----------|
| `get_minimal_context_tool` | **Always first** — any code task |
| `detect_changes_tool` | Reviewing a diff — risk-scored, priority-ordered |
| `get_review_context_tool` | Need source for changed functions only (token-efficient) |
| `semantic_search_nodes_tool` | Find functions/classes by name or concept |
| `query_graph_tool` | callers_of / callees_of / imports_of / tests_for |
| `get_affected_flows_tool` | Which execution paths are impacted |
| `get_impact_radius_tool` | Blast radius of a change |
| `get_architecture_overview_tool` | High-level structure when starting a new task |
| `list_flows_tool` + `get_flow_tool` | Trace execution paths end-to-end |

**Config (Claude):** Global `~/.claude/claude.json` — no `cwd`, no per-project `.mcp.json`. Claude inherits the session directory at startup; `find_project_root()` walks up to the nearest `.git` and opens that project's isolated `.code-review-graph/graph.db`. Each project has its own graph — repos never mix.

**Config (Qwen):** `crg-mcp.service` systemd user service — runs `code-review-graph serve --http --host 127.0.0.1 --port 7000`. No `--repo` flag; Qwen passes `repo_root` as a parameter in each tool call.

**Auto-build:** A `UserPromptSubmit` hook in `~/.claude/settings.json` automatically runs `code-review-graph build` in the background on the first prompt in any git repo that doesn't have a graph yet. No manual setup needed for new projects.

**Freshness (Claude):** A `PostToolUse` (Edit/Write) hook — `~/.claude/hooks/crg-update.py` — runs incremental `code-review-graph update` after edits, coalesced via a lock so rapid edits don't pile up. Keeps the graph from going stale without needing the `crg-daemon` watcher.

**Gate (Claude):** A `PreToolUse` (Read/Grep) hook — `~/.claude/hooks/crg-gate.py` — blocks the *first* manual code Read/Grep each session in a repo that has a graph, until a graph tool is called; then it opens for the rest of the session. Docs/config files and graphless repos are never gated. This is what makes "graph before grep" actually happen instead of being ignored. Disable all graph hooks for a session with `export CRG_HOOKS_OFF=1`. Source lives in `claude/hooks/`, deployed by `deploy-agents.sh`.

**Daemon:** `crg-daemon` watches registered repos and rebuilds the graph incrementally on file changes. Register additional repos with:
```bash
crg-daemon add ~/workspace/your-project
```

---

### playwright

Headless Chromium browser for E2E testing, UI validation, and web scraping. Claude uses it in stdio mode; Qwen connects to an HTTP daemon on port 8932 via systemd user service.

**When to use:** After implementing a UI change, for automated form testing, or to validate web output visually.

**Example — tester agent validates a form:**
```
Agent: browser_navigate(url="http://localhost:3000/login")
Agent: browser_snapshot()  → accessibility tree of the page
Agent: browser_fill_form(fields={"email": "test@example.com", "password": "secret"})
Agent: browser_click(selector="button[type=submit]")
Agent: browser_snapshot()  → verify redirect to dashboard
```

**Example — screenshot for UI review:**
```
Agent: browser_navigate(url="http://localhost:3000/dashboard")
Agent: browser_take_screenshot()  → visual comparison
Agent: browser_console_messages()  → check for JS errors
```

| Tool | Use When |
|------|----------|
| `browser_navigate` | Open a URL |
| `browser_snapshot` | Get accessibility tree (preferred — cheaper than screenshot for interaction) |
| `browser_take_screenshot` | Visual capture |
| `browser_click` | Click buttons, links, elements |
| `browser_type` | Type into input fields |
| `browser_fill_form` | Fill multiple fields at once |
| `browser_console_messages` | Check for JS errors |
| `browser_network_requests` | Inspect API calls made by the page |
| `browser_wait_for` | Wait for element or condition |

**Config:** `~/.claude/claude.json` (Claude stdio), `~/.qwen/settings.json` (Qwen HTTP).  
**Daemon (Qwen):** `playwright-mcp.service` — wrapper at `~/.local/bin/playwright-mcp-start` sources nvm then runs `npx @playwright/mcp@latest --port 8932 --headless`.

---

### local-model

Delegates code-writing tasks to a local model (Qwen by default) running on a vLLM server, via [`mcp-infra/local-model-mcp`](https://github.com/alkrcaaa/local-llm-mcp) (its own repo, pulled in as a git submodule). Claude is the orchestrator; the local model is the worker. All implementation goes through this server — Claude never writes code itself when it's online.

**When to use:** Any implementation task — new files, bug fixes, refactors, test writing.  
**Claude-only** — the worker does not call itself.

**Example — implementation task:**
```
User: "Add input validation to the /upload endpoint"
Claude: health_check()  → online
Claude: execute_task(task="Add validation to /upload endpoint in app/routes.py...", working_dir="/project")
→ Returns: {status: "success", files_changed: ["app/routes.py"], stdout: "..."}
Claude: verifies file exists, greps for validation logic, reads file for quality review
```

**Example — what happens inside execute_task:**
```
1. Validate working_dir exists
2. Git snapshot — record dirty files before execution
3. Build prompt: [WORKER PREFIX] + project-conventions.md + task + [WORKER SUFFIX]
4. Run: worker CLI (WORKER_CLI_BIN, default qwen) --approval-mode yolo --output-format text
5. Git snapshot — detect changed files
6. Return: status, stdout, stderr, files_changed, warning
```

| Tool | Use When |
|------|----------|
| `health_check` | Before every implementation task — verify vLLM is reachable |
| `execute_task` | Standard code-writing task with working directory |
| `execute_task_with_context` | Task that needs extra context (previous results, prior attempts) |
| `list_workers` | Which advisor workers (Qwen hosts, Gemini) are up and what model each serves |
| `ask_worker` | Read-only question/review/explore/plan answered by a worker in a throwaway copy of the project — check `status` for `VIOLATION` |

Workers are defined in `local-model-mcp/workers.json` (gitignored, re-read every call): moving a vLLM host or swapping a model is one edit, no restart. See the submodule README.

**Config:** `~/.claude/claude.json` — added by `install.sh` when `MODEL_BASE_URL` is set (registered under the `local-model` key).  
**Requires:** vLLM server running at `QWEN_BASE_URL` (set in `.env` or passed to `install.sh`).

---

### lsp

Language Server Protocol bridge — provides semantic code intelligence for C++, ROS2, and Python. A single `lsp-mcp-server` instance manages all language servers; they start automatically when you open a file of that language.

- **clangd** — C++ and ROS2 C++ nodes. Works with `compile_commands.json` (generate with `colcon build --cmake-args -DCMAKE_EXPORT_COMPILE_COMMANDS=ON`).
- **pyright** — Python and ROS2 Python nodes. Type-aware, finds undefined names, wrong argument types.

**When to use:** Any code navigation task in C++/Python — instead of grep for symbol lookups.  
**Priority:** Use AFTER `code-review-graph` (structure/architecture) and BEFORE `grep_search` (text patterns).

**Example — find a symbol definition:**
```
User: "Where is MotorController defined?"
Agent: lsp_goto_definition(file_path="/ws/src/motor/include/motor.hpp", line=1, character=1, symbol="MotorController")
→ Returns: /ws/src/motor/src/motor_controller.cpp:42
```

**Example — find all usages:**
```
User: "What uses the publish() method on this topic?"
Agent: lsp_find_references(file_path="/ws/src/node.cpp", line=15, character=8)
→ Returns: 6 references across 4 files with line numbers
```

**Example — check diagnostics (compiler errors without compiling):**
```
Agent (security): lsp_diagnostics(file_path="/ws/src/parser.cpp")
→ Returns: [WARNING:line:34 buffer may overflow, ERROR:line:67 use after free]
```

**Example — understand a type:**
```
Agent: lsp_hover(file_path="/ws/src/planner.cpp", line=23, character=12)
→ Returns: "class TrajectoryPlanner { ... } — Plans robot trajectories using A* search"
```

| Tool | Use When |
|------|----------|
| `lsp_goto_definition` | Find where a function/class/variable is defined |
| `lsp_find_references` | Find all usages of a symbol across the project |
| `lsp_hover` | Get type info, signature, and documentation for a symbol |
| `lsp_document_symbols` | Get outline/structure of a file (all functions, classes) |
| `lsp_workspace_symbols` | Search for a symbol by name across the whole project |
| `lsp_find_symbol` | Like workspace_symbols but also returns definition + references |
| `lsp_diagnostics` | Errors and warnings for a file (push-based, very fast) |
| `lsp_call_hierarchy` | Who calls this function? What does it call? |
| `lsp_type_hierarchy` | Class inheritance and interface implementations |
| `lsp_smart_search` | All of: hover + definition + references in one call |
| `lsp_server_status` | Check which language servers are running |

**Config:** Both Claude (`~/.claude/claude.json`) and Qwen (`~/.qwen/settings.json`) use stdio via `~/.local/bin/lsp-coercion-proxy`.

**lsp-coercion-proxy:** Wraps `lsp-mcp-server` with two fixes:
1. Injects NVM `bin/` dirs into PATH so `pyright-langserver` (npm-installed) is found by child processes.
2. Coerces string→int for numeric params (`line`, `column`, etc.) — Qwen Code sends `"1"` instead of `1`.

**pyright instead of pylsp:** `~/.lsp-mcp.json` overrides `lsp-mcp-server`'s default Python server from `pylsp` (not installed) to `pyright-langserver` (already installed via npm). Created by `install.sh`.

---

### fetch

Lightweight HTTP content fetcher. Much lighter than playwright for reading URLs — no browser, no JavaScript execution. Returns content as markdown, plain text, or JSON.

**When to use:** Reading a GitHub issue linked in a PR, fetching API documentation, checking a ROS2 REP, reading internal wiki pages.  
**Not for:** Pages that require JavaScript rendering or user interaction — use `playwright` for those.

**Example — read a GitHub issue:**
```
Agent (reviewer): fetch_readable(url="https://github.com/org/repo/issues/42")
→ Returns: clean article text of the issue, stripped of nav and sidebar
```

**Example — fetch JSON from an API:**
```
Agent: fetch_json(url="https://api.osv.dev/v1/vulns/GHSA-xxxx")
→ Returns: parsed JSON with vulnerability details
```

**Example — read documentation page as markdown:**
```
Agent: fetch_markdown(url="https://docs.ros.org/en/humble/Tutorials/...")
→ Returns: page content as markdown, ready to use as context
```

| Tool | Use When |
|------|----------|
| `fetch_markdown` | Docs, wikis, GitHub pages — best general-purpose format |
| `fetch_readable` | Articles and long pages — strips nav/ads with Mozilla Readability |
| `fetch_json` | REST API responses, JSON endpoints |
| `fetch_txt` | Plain text without any markup |
| `fetch_html` | Raw HTML when you need the full structure |

**Config:** `~/.claude/claude.json` (Claude stdio via npx), `~/.qwen/settings.json` (Qwen HTTP on port 8935).  
**Daemon (Qwen):** `fetch-mcp.service` — wrapper at `~/.local/bin/fetch-mcp-start`.

---

### mem-lite

Persistent, project-scoped memory backed by SQLite (FTS5 + TF-IDF) at `~/.claude-mem-lite/`. The DB is **shared across both runtimes** — what Claude or Qwen saves in a project, both can recall.

**Tools:** `mem_save`, `mem_search`, `mem_recall`, `mem_recent`, `mem_get`, `mem_timeline`.

**Config (Claude):** registered via `claude mcp add`; lifecycle hooks (SessionStart / UserPromptSubmit / PostToolUse / Stop) **auto-inject** relevant memory — you only call tools to *save*, not to *recall*.

**Config (Qwen):** stdio MCP (`node ~/.claude-mem-lite/server.mjs`) in `~/.qwen/settings.json`. Qwen has **no** auto-inject hooks — call `mem_search` / `mem_save` **explicitly**.

---

### vault-search

Keyword + backlink-aware search over an Obsidian vault (or any folder of markdown notes). Optional — skipped entirely if `VAULT_DIR` is unset. Not part of code review; this is a personal-notes/knowledge-base tool, separate from `mem-lite`'s per-project SQLite memory.

**Tools:** `vault_search` (ranked keyword search — title/frontmatter/body/wikilinks), `vault_list` (list files, optionally with wikilink targets).

**Config (Claude & Qwen):** stdio (`extern/obsidian-vault-bridge/mcp-infra/vault-search/.venv/bin/python server.py`), `env.VAULT_DIR` set from the `VAULT_DIR` env var at install time. Distinct from `MEM_OBSIDIAN_VAULT` (the mem-lite→vault mirror hook's target directory) — see `.env.example`. Lives in the [obsidian-vault-bridge](https://github.com/alkrcaaa/obsidian-vault-bridge) submodule, pulled in the same way `extern/drawio-skill` is.

---

## Agent Access Matrix

| MCP | general-purpose | reviewer | security | tester | ops | designer |
|-----|:-:|:-:|:-:|:-:|:-:|:-:|
| `code-review-graph` | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `playwright` | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ |
| `qwen` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `lsp` | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| `fetch` | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| `mem-lite` | ✅ (orchestrator) | ❌ | ❌ | ❌ | ❌ | ❌ |
| `vault-search` | ✅ (orchestrator) | ❌ | ❌ | ❌ | ❌ | ❌ |

**Why these restrictions:**
- `reviewer` and `security` are read-only — no browser (can't click/submit) and no code writing (no qwen)
- `ops` works with infra files (YAML, Dockerfile, CI) — no code navigation or browser needed
- `designer` generates HTML artifacts — no code analysis tools needed
- `lsp` is only useful for C++/Python source code — ops and designer don't work with those

---

## Skills

Skills are markdown files that agents read as context at task start. They give the agent specialized knowledge — security patterns, testing strategies, design systems — that the base model doesn't apply by default.

Skills live in `extern/` as git submodules. They are NOT auto-loaded; agents load them explicitly in their system prompt when a task needs them.

### Universal — All Agents

**Karpathy Guidelines** (`extern/andrej-karpathy-skills/`)  
Four behavioral rules applied by every agent before starting any task:
1. **Think Before Coding** — state assumptions explicitly, don't code silently into ambiguity
2. **Simplicity First** — minimum code that solves the problem, no speculative features
3. **Surgical Changes** — touch only what the task requires, match existing style
4. **Goal-Driven Execution** — turn tasks into verifiable goals ("make this test pass") before writing code

*Why it exists:* These rules prevent the most common AI coding failure modes — over-engineering, scope creep, and silent assumption-making.

---

### Security Agent Skills

**OWASP Top 10:2025** (`extern/claude-code-owasp/`)  
Complete OWASP Top 10:2025, LLM01-LLM10 (AI-specific), ASI01-ASI10, ASVS 5.0 verification requirements, and security quirks for 20+ languages. Maps findings to CWE IDs.

*Example:* When auditing an API endpoint, the agent checks against A01 (Broken Access Control), A03 (Injection), and LLM02 (Insecure Output Handling) if the endpoint feeds an AI model.

**TrailOfBits Static Analysis** (`extern/trailofbits-skills/plugins/static-analysis/`)  
Semgrep rule patterns and code smell detection for common vulnerability patterns. Pairs with `semgrep scan` CLI.

*Example:* Detects `strcpy`/`sprintf` usage in C++ (buffer overflow risk), unvalidated `eval()` in Python, hardcoded secrets in config files.

**TrailOfBits Supply Chain** (`extern/trailofbits-skills/plugins/supply-chain-risk-auditor/`)  
Checks dependency files (requirements.txt, package.json, CMakeLists.txt) for known-vulnerable versions, typosquatting risks, and transitive dependency issues. Uses `curl api.osv.dev` for CVE lookups.

*Example:* Finds that `requests==2.18.0` has 3 known CVEs, suggests pinning to `2.31.0`.

**TrailOfBits Insecure Defaults** (`extern/trailofbits-skills/plugins/insecure-defaults/`)  
Catches configuration anti-patterns: debug mode left on, SSL verification disabled, default credentials, world-readable file permissions.

**TrailOfBits Sharp Edges** (`extern/trailofbits-skills/plugins/sharp-edges/`)  
Documents dangerous API designs and language-specific footguns. Flags use of `pickle` for deserialization, `yaml.load()` without `Loader=`, `tempfile.mktemp()` (race condition).

**TrailOfBits Semgrep Rule Creator** (`extern/trailofbits-skills/plugins/semgrep-rule-creator/`)  
Creates custom Semgrep rules tuned to the current codebase. Used when the project has domain-specific patterns (e.g., a custom auth decorator that must always be applied).

---

### Reviewer Agent Skills

**TrailOfBits Differential Review** (`extern/trailofbits-skills/plugins/differential-review/`)  
Code review methodology focused on diffs — what changed, what the change enables, what invariants it breaks. Pairs with `detect_changes_tool` from code-review-graph.

*Example:* Reviewer sees a new `async def` function added without `await` on the result — flags as logic bug. Also checks that new public APIs have corresponding tests in the diff.

---

### Tester Agent Skills

**TrailOfBits Testing Handbook** (`extern/trailofbits-skills/plugins/testing-handbook-skills/`)  
Test strategy guide: unit vs integration vs property-based testing, when to mock vs hit real services, coverage heuristics, flakiness prevention.

*Example:* For a new parser function, the skill recommends property-based tests (hypothesis) over fixed examples — catches edge cases the developer didn't think of.

---

### Ops Agent Skills

**DevOps Skills** (`extern/devops-claude-skills/`)  
Kubernetes troubleshooting, Terraform patterns, AWS cost optimization, CI/CD best practices, GitOps workflows, monitoring and observability patterns.

*Example:* When reviewing a Dockerfile, checks for multi-stage builds, non-root user, pinned base image digest, and `.dockerignore` completeness.

---

### Designer Agent Skills

**Open Design Skills** (`extern/open-design/skills/`)  
90+ design patterns: buttons, forms, data tables, dashboards, mobile screens, pitch decks, social carousels. Each skill is a self-contained HTML/CSS template the agent adapts.

*Example:* User asks for a "ROS2 node monitoring dashboard" — agent loads the dashboard skill, adapts it with node status panels and topic throughput charts.

**Anthropic Frontend Design** (`extern/skills/skills/frontend-design/`)  
Principles for distinctive, production-quality frontends. Anti-patterns: generic Bootstrap look, excessive whitespace, lorem ipsum left in, no error states.

**gstack design-html / design-consultation** (`extern/gstack/`)  
Finalization and design-system strategy skills. Used when the designer needs to produce deployment-ready HTML or advise on component architecture.

---

## CLI Tools (not MCP)

These run via `bash` — not MCP tools. Available to all agents with shell access.

| Tool | Command | Use Case |
|------|---------|----------|
| `gh` | `gh pr create / gh issue list` | PR management, issue tracking, CI status |
| `semgrep` | `semgrep scan --config=auto .` | Static analysis — pairs with TrailOfBits Static Analysis skill |
| `curl api.osv.dev` | `curl https://api.osv.dev/v1/query -d '{"package":...}'` | CVE lookup for dependencies |

---

## Verify Installation

```bash
# MCP servers
code-review-graph --version
crg-daemon status
lsp-mcp-server --version 2>/dev/null || echo "check: npm ls -g lsp-mcp-server"
systemctl --user status playwright-mcp crg-mcp fetch-mcp

# Ports (Qwen HTTP daemons)
ss -tlnp | grep -E '8932|8935|7000'

# In Claude Code
/mcp   # should show: code-review-graph, playwright, qwen, lsp, fetch
```