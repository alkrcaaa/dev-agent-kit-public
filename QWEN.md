# dev-agent-kit

Bash kit that installs and deploys agent setups for Claude Code, Qwen Code, Antigravity
and Codex: instruction files, hooks, skills and MCP servers. No compiled code.

## Layout

| Path | Purpose |
|---|---|
| `install.sh`, `deploy-agents.sh` | entry points; source `scripts/lib/*.sh` |
| `scripts/lib/` | `deps.sh`, `mcp.sh`, `agents.sh`, `submodules.sh`, `verify.sh` |
| `scripts/health/` | `healthcheck.sh` (live smoke test), `doctor.sh` (docs-vs-reality drift) |
| `claude/`, `qwen/`, `antigravity/`, `codex/` | per-host templates, deployed to `~/.claude`, `~/.qwen`, … |
| `claude/hooks/` | hooks shared by every host via `agent_env.py` |
| `claude/skills/` | native skill wrappers over `extern/` submodules (listed in `extern/README.md`) |
| `mcp-infra/` | llm-council, local-model, vault-search, code-review-graph |
| `tests/` | bash tests, each sourcing its library in a temp `HOME`/`REPO_ROOT` |

## Conventions

- Library scripts use `set -euo pipefail` and are sourced, not executed.
- Edit the repo template, never the deployed copy in `~/.qwen` etc.; install overwrites it.
- After adding a skill, hook or MCP server, run `bash scripts/health/doctor.sh`.
- Tests: `bash tests/test_hooks.sh`, `bash tests/test_agents.sh` (plus the other
  `tests/test_*.sh` for the library you touched).
- Commits: short imperative English, no prefix, no AI attribution.
