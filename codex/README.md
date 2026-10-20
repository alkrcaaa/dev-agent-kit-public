# Codex Templates

This directory contains source templates deployed by `install.sh` to `~/.codex/`.

## Structure

| Path | Deployed to | Purpose |
|---|---|---|
| `AGENTS.md` | `~/.codex/AGENTS.md` | Global Codex working agreements and routing rules |
| `config.toml` | merged into `~/.codex/config.toml` | Codex MCP and subagent defaults |
| `agents/*.toml` | `~/.codex/agents/*.toml` | Codex custom subagents |

Codex custom agents are standalone TOML files. Each file defines `name`,
`description`, and `developer_instructions`; optional model, reasoning,
sandbox, MCP, and skill settings inherit from the parent Codex session.

## Deployment

```bash
bash install.sh
```

Or re-sync only agent templates:

```bash
bash deploy-agents.sh
```

`install.sh` also configures Codex MCP servers in `~/.codex/config.toml`.
When a Qwen vLLM URL is supplied, the Codex `qwen` MCP entry is added too.
