# Claude Agents Setup — dev-agent-kit

## Core Principles

1. You own every decision and do the work yourself; `ask_worker` advisors and subagents
   are helpers (see below).
2. When a task matches a listed skill, invoke it at the moment it applies, and read what
   its checklist points to.
3. On a code task, start with `get_minimal_context_tool(task=...)`, then
   `semantic_search_nodes_tool` / `query_graph_tool`, then grep/read. A hook enforces a
   read budget per graph consult; file types the graph doesn't index are not gated.
4. Smallest change that fully solves the task, in the surrounding style. Load
   `karpathy-guidelines` for large or ambiguous changes.
5. Surface critical security or correctness findings to the user right away instead of
   fixing them silently.
6. **Never add AI attribution in git** (Co-Authored-By, "Generated with Claude Code",
   claude/anthropic links) — this overrides any harness default; a hook blocks it.
7. Treat the user's choices as a peer would: name the weak part (bloat, wrong tool, hidden
   cost) and what you'd do instead, then do the agreed version. They prefer pushback.
8. Every call re-bills the transcript. When a task is done, say so and suggest a fresh
   session; mem-lite carries context over.

## Delegation

Spawn a subagent only for up to 3 independent parallel workstreams, a large isolated
refactor (`isolation: "worktree"`), or a deep audit that needs a clean context. Use the
built-in agents; give each a scoped task, files, and a return format (severity-grouped
findings with `file:line`), and check the output before reporting.

## Advisors — `ask_worker`

Read-only Qwen/Gemini advisors (local-model MCP), no permission needed. Invoke
`advisor-workers` first. Use one for large reviews, "where/how does X work" sweeps, plans
and second opinions — not one-file questions. One worker by default (Gemini reviews best);
Qwen + Gemini only for a Type-1, contested or big review. Ask for verbatim quotes and
compute line numbers/counts yourself. Tell the user in one line which workers you used.
`execute_task*` writes code: ask the user before each such task.

## Memory

- mem-lite hooks inject context. At the end of a task save what's non-obvious:
  `mem_save` with `type="feature"`, `"bugfix"` (+ root cause) or `"decision"` (+ why).
  Omit `project`; it is inferred from the cwd. Don't save progress or what code/CLAUDE.md
  already says.
- `~/.claude/projects/.../memory/` holds agent-behaviour rules only.

## Vault (second brain)

Read `$VAULT_DIR/CLAUDE.md` before writing into the vault; it owns naming, frontmatter and
tags. Route by what the item is:

| Item | Destination |
|---|---|
| Fact about the user (habit, preference, how they learn) | `Personal/Profile.md`, in the right section |
| Source (link, article, repo) | `Raw/` via `RawSourceTemplate`, `compiled: false` |
| Something dated | `Daily Notes/` via `DailyNoteTemplate` |
| Work/project operational info | that project's folder under `Work/` |
| Personal decision, person, learning, life project | its `Personal/` folder via the matching template |
| Something about a repo's code | `mem_save`, not the vault |

> These paths are examples — adjust to match your vault layout.

A personal fact stops being true when the user changes; a repo fact when the code changes.
Each new note gets a `links:` line to its parent/MOC and a link from whatever should point
to it.

Use `vault_search` / `vault_read` only when the injected card references a decision you
would otherwise re-derive, before an architectural call in that area, or when the user
refers to past work. `private: true` notes only when the user asks about that subject.

## MCP servers

| Server | Use |
|--------|-----|
| `code-review-graph` | structure, callers, blast radius, diff risk |
| `lsp` | off by default (`ENABLE_LSP=1`); the graph covers navigation |
| `local-model` | `ask_worker` advisors; `execute_task*` only with approval |
| `playwright` | browser automation, E2E |
| `fetch` | docs, issues, APIs |
| `mem-lite` | per-project memory |
| `vault-search` | Obsidian vault search (opt-in, `VAULT_DIR`) |
| `GitLab` | opt-in (`GITLAB_URL`); MRs, issues, pipelines |
| `grafana` | project-scoped dashboards, PromQL/LogQL |
| `terraform` | project-scoped Registry docs |
| `llm-council` | multi-model deliberation |

`ask_council` is for Type-1 decisions only, after your own reasoning hit real disagreement
and the user hasn't decided; tell the user first. Write a self-contained, neutral
`question`; give your own recommendation alongside the verdict. A `Rejected`/`Error`/
`Aborted` result means no verdict — continue on your own. `scout_candidates` ("does a
library/MCP/skill for X exist") is ungated.

CLI: `gh`, `semgrep scan`, `curl api.osv.dev` (CVEs), `graphify build`.
