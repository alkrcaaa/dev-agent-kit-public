# dev-agent-kit

Local and cloud AI coding agent setup kit. Install Claude Code and Qwen Code agent frameworks with one command, deploy across your workspace, and start coding immediately.

- **2 runtimes**: Claude Code (cloud) + Qwen Code (local vLLM)
- **7 MCP servers**: code-review-graph, playwright, qwen, fetch, mem-lite (persistent project memory), lsp (opt-in via `ENABLE_LSP=1`) + project-scoped grafana and terraform
- **15 native skills** (security, devops, ansible, remote-ops, design, diagrams, simplicity, skill discovery, vault maintenance…) routing into **10 skill libraries**: OWASP, TrailOfBits, Karpathy, DevOps, Open Design, Taste (anti-slop design), Skills CLI, and more — deployed to both runtimes
- Auto-deployment: one script installs and distributes everything

## Contents

| Directory | Description |
|---|---|
| [scripts/](scripts/) | Installation, deployment, health checks, MCP server management |
| [extern/](extern/) | 11 git submodules — skills (karpathy, owasp, trailofbits, open-design, devops, anthropic, ansible, drawio, taste, skills-cli) + obsidian-vault-bridge |
| [claude/](claude/) | Claude Code source templates (orchestrator, hooks, skills) |
| [qwen/](qwen/) | Qwen Code source templates (orchestrator, settings) |
| [codex/](codex/) | Codex source templates (AGENTS.md, config, agents) |
| [mcp-infra/](mcp-infra/) | MCP server sources — local-model bridge, llm-council, vault-search, code-review-graph submodule |
| [tests/](tests/) | Library test suites, plus clean-machine and remote install tests |
| [.github/workflows/](.github/) | CI: shellcheck, ruff, pyright and the test suite |

## Quick Start

```bash
git clone https://github.com/alkrcaaa/dev-agent-kit-public.git ~/workspace/dev-agent-kit
cd ~/workspace/dev-agent-kit
bash install.sh http://<your-vllm-host>:8002/v1   # your vLLM server (must include /v1)
```

`install.sh` fetches the submodules itself, pinned commit only (`--depth 1`,
a few hundred MB). Do not clone with `--recursive`: that pulls every branch of every
submodule and runs to several GB.

`install.sh` is a one-shot installer — a fresh machine goes from zero to
working `claude` and `qwen` commands with no manual steps and no shell aliases:

- Node.js 22, Claude CLI, `qwen` CLI, linters (ruff, shellcheck, ansible-lint,
  yamllint, tflint, cppcheck)
- MCP servers: code-review-graph, playwright, qwen, fetch, mem-lite,
  GitLab (Claude: OAuth via `GITLAB_URL`; Qwen has no OAuth flow, so it is
  registered there only with a `GITLAB_TOKEN` PAT)
- Skill symlinks (`~/.claude/extern`)
- **Qwen parity** — the same skills, hook scripts and enforcement wiring deploy
  to `~/.qwen/` as well, so a `qwen` session runs under the same gates as a
  `claude` one. One hook source for both: `claude/hooks/agent_env.py` maps
  Qwen's wire tool names and picks the output channel each host honours.
- **PATH persistence** — `~/.local/bin` (and `~/.npm-global/bin` when npm's
  global prefix is system-owned) are written to your shell RC automatically,
  based on your active shell (`~/.zshrc`, `~/.bashrc`, or `~/.profile`)
- **Qwen CLI wiring** — with a vLLM URL, `~/.qwen/.env` gets `OPENAI_BASE_URL`
  plus the model id auto-detected from the server, and auth is pinned to
  `openai`. Plain `qwen` connects to your vLLM directly — no `qwen-local`-style
  alias needed.

Instead of passing the URL, you can keep it in `.env` (survives re-runs;
edit it when the server address changes, then re-run `bash install.sh`):
```bash
cp .env.example .env   # edit QWEN_BASE_URL inside
bash install.sh
```

Passing no URL does not mean no Qwen: the defaults above still apply. What
decides is reachability — the vLLM and GitLab endpoints are probed before
anything is wired to them, and a host that does not answer is skipped with the
reason rather than registered as an MCP pointing nowhere. So off that network
you get a clean Claude-only install, and on it you get everything, from the
same command. Re-run `install.sh` once a skipped host is up.

When it finishes, open a new terminal and start with `claude` or `qwen`.

> **Keep the clone where it is.** `~/.claude/extern` and `~/.qwen/extern` are
> symlinks into it — the skill libraries are git submodules and cannot be
> copied out. Moving or deleting the clone leaves those skills loading but
> empty. After a move, re-run `install.sh`.

## Remote Install (Qwen only)

Puts the Qwen half of the kit on another machine over SSH — a Jetson, a robot,
a build box — without installing Claude there:

```bash
bash scripts/remote-qwen-install.sh --host user@gpu-host
```

What lands on the remote: `QWEN.md`, the hook scripts and their
wiring, every skill, the `extern` skill libraries, the `qwen` CLI, and an MCP
subset. What does not: Claude, `~/.claude`, and the browser stack.

```bash
--profile edge          # default: graph + fetch
--profile workstation   # edge plus playwright
--vllm http://HOST:PORT/v1   # defaults to QWEN_BASE_URL from .env
--with-gitlab-token     # opt-in; see below
--dry-run               # stage and report, change nothing on the remote
```

Four things worth knowing about how it works:

- **It stages locally and ships the result.** The remote never clones this repo
  and never fetches submodules — a robot is frequently on a network that cannot
  reach GitHub. What arrives is exactly the tree you have checked out here.
- **`extern` ships as real directories**, not the symlink a local install uses;
  there is no clone on the far side to point at. The skills are rewritten from
  `~/.claude/extern` to `~/.qwen/extern` on the way out, because on a
  Claude-less host the original path would load every skill empty.
- **The vLLM endpoint is probed from the remote**, not from your machine. The
  two are not in the same network position, and yours answering proves nothing
  about theirs.
- **MCP entries naming paths from your machine are dropped on arrival** — you
  will see lines like `dropped mem-lite: /home/you/... does not exist on this
  host`. That is the intended outcome: a server registered against a path the
  remote does not have fails on every session there.

`GITLAB_TOKEN` is **not** sent unless you pass `--with-gitlab-token`. It is a
personal credential, and a shared robot is a place several people can read it
from — make that an explicit decision each time.

### What the remote needs

Key-based SSH that already works (`BatchMode` — the installer never prompts),
`python3`, and network access to npm. That is the whole list.

Notably **not** required: root. Nothing is installed system-wide — node arrives
through nvm, the CLI and MCP servers through npm and uv, all inside the target
user's home. You can point this at a machine where you have an ordinary
account, and uninstalling is `rm -rf ~/.qwen`.

### A successful run ends like this

```
--- verify
  QWEN.md ok
  skills: 14
  hooks: 13
  extern: 10 libraries
  settings.json parses

  ✓ Remote Qwen install complete on user@target-host

  Start it there:  ssh user@target-host -t qwen
```

Anything missing is named instead, and the command exits non-zero — a partial
install never reports success.

### Re-running it

Safe and expected: that is how you push a change you made here out to the
device. Files are overwritten, not deleted, so a skill you removed locally
stays behind on the remote until you delete it there. Start with `--dry-run`
against a machine you have not touched before — it stages everything and
reports what it would send without opening a single write to the target.

Verify a target end to end without touching real hardware with
`bash tests/remote-install/remote-install-test.sh`.

## Subagents

The kit ships no custom subagents for Claude, Qwen or Antigravity (they were
removed on 2026-10-20: the Claude copies listed Qwen tool names, so Claude Code
refused to spawn them, and none had been used in the preceding two months).
Each runtime uses its built-in agents (Explore, Plan, general-purpose); the
specialist knowledge lives in skills (`owasp-security`, `devops`, `design-dna`,
…) and in `/code-review` / `/security-review`. Codex keeps its own
`codex/agents/`.

## How It Works

Claude is a god-mode principal engineer — it has every tool, MCP, and skill that any subagent has, and does the work itself by default. It writes code, writes tests, reviews, audits, and designs directly with the right skill loaded. Delegation is a strategic choice, not a reflex: Claude splits work to a subagent or to Qwen only when it genuinely pays off (parallel workstreams, isolated large-scope refactors, or a deep specialized audit). Qwen is an optional code-writing worker — a local model Claude can offload bulk/boilerplate or parallel implementation to, then verifies. It has no memory between calls.

### Task Routing

```
User task
    │
    ▼
Claude (god-mode principal engineer — does it himself by default)
    │
    ├── Most work (code, tests, review, fixes, infra, design) → Claude, skill loaded
    │
    ├── Offload bulk / boilerplate / parallel impl ─────→ Qwen (via qwen MCP)
    │                                                          │
    │                                                    verify output
    │                                                    (disk + grep + read)
    │
    └── Delegate ONLY when it pays off:
            ├── parallel independent workstreams      → built-in subagents / fork
            ├── isolated large-scope refactor          → worktree subagent
            └── broad read-only sweep                  → Explore / ask_worker
```

### Qwen Call Flow

Every `execute_task` call goes through this pipeline inside the MCP server:

```
Claude calls execute_task(task, working_dir)
    │
    ├─ 1. Validate working_dir exists
    │
    ├─ 2. Git snapshot: record dirty files before execution
    │
    ├─ 3. Build prompt:
    │       [WORKER PREFIX]
    │       + project-conventions.md (if qwen-memory/ exists)
    │       + task
    │       + [WORKER SUFFIX]
    │
    ├─ 4. subprocess: qwen CLI --approval-mode yolo --output-format text
    │
    ├─ 5. Git snapshot: record dirty files after execution
    │
    └─ 6. Return:
            status, stdout, stderr, return_code
            files_changed  (after − before, git-based)
            warning        (non-null if Qwen responded but changed nothing)

Claude then verifies:
    ├─ ls <expected file>  → exists?
    ├─ grep critical lines → correct content?
    ├─ read_file           → quality review
    └─ retry (max 3×) if insufficient
```

## Re-deploy

After a `git pull`, re-sync CLAUDE.md, hooks and skills without re-running the full install:

```bash
bash deploy-agents.sh
```

```bash
# Health check
./scripts/health/healthcheck.sh
```

Details: [scripts/README.md](scripts/README.md)

## Tests

```bash
for t in tests/test_*.sh; do bash "$t"; done   # seconds
```

These source the library functions and check their behaviour. They cannot tell
you whether a from-scratch install works, because they run on a machine that
already has one. For that:

```bash
bash tests/fresh-install/fresh-install-test.sh   # ~15 min, needs Docker
```

It installs into a clean Ubuntu container and asserts the result — including
that the MCPs land in the file Claude Code actually reads. Run it after
touching `install.sh` or `scripts/lib/`. See
[tests/fresh-install/README.md](tests/fresh-install/README.md).

```bash
bash tests/remote-install/remote-install-test.sh   # ~10 min, needs Docker
```

The same idea for `scripts/remote-qwen-install.sh`: a throwaway SSH container
stands in for the robot, so the installer is exercised end to end before it
ever runs against real hardware.

## MCP Servers & Skills

7 MCP servers — no Docker; all local. GitLab is opt-in (`GITLAB_URL` in .env, needs
a GitLab with the MCP endpoint). Claude uses stdio transports; Qwen uses HTTP daemons on fixed ports.

| Server | What it does |
|--------|-------------|
| `code-review-graph` | Code knowledge graph — structure, blast radius, call chains |
| `playwright` | Headless Chromium — E2E tests, UI validation |
| `qwen` | Local Qwen model — optional code-writing worker Claude offloads to |
| `lsp` | Language server bridge — **off by default**, set `ENABLE_LSP=1` in .env (rarely triggered; the graph covers navigation) |
| `fetch` | Lightweight HTTP fetch — GitHub issues, docs, API responses, internal wiki |
| `mem-lite` | Persistent project-scoped memory (SQLite FTS5) — shared DB across both runtimes |

Project-scoped (per-repo `.mcp.json`, not global): `grafana` (`scripts/setup-grafana-mcp.sh`) and `terraform` (`scripts/setup-terraform-mcp.sh` — Registry queries only, tf operations disabled).

### code-review-graph automation (Claude side)

Three hooks keep the graph built, fresh, and actually used (in `~/.claude/hooks/`, deployed from `claude/hooks/`):

- **Auto-build** (`UserPromptSubmit`) — on the first prompt in any git repo without a graph, builds `.code-review-graph/graph.db` in the background.
- **Freshness** (`PostToolUse` on Edit/Write) — runs incremental `code-review-graph update` after edits, coalesced via a lock so rapid edits don't pile up.
- **Gate** (`PreToolUse` on Read/Grep) — in a repo that has a graph, blocks the *first* manual code Read/Grep each session until a graph tool is called, then opens for the rest of the session. Docs/config files and graphless repos are never gated.

Disable all three for a session with `export CRG_HOOKS_OFF=1`.

Skills are markdown files loaded by agents at task time — OWASP, TrailOfBits security patterns, Karpathy guidelines, DevOps playbooks, and design systems.

Full documentation with examples: **[mcp-infra/README.md](mcp-infra/README.md)**

## License

MIT — `Copyright (c) 2026 alkrcaaa`. Each extern submodule carries its own license.

## Privacy

Hooks send session text to `QWEN_BASE_URL` (your local vLLM endpoint). Nothing checks
that this endpoint is local — if you point it at a remote server, all prompts and tool
output travel there. Secret filtering is keyword-based and not guaranteed. The nightly
`vault-compile` runs `claude -p`, which is a cloud call.
