# Qwen Code Templates

This directory contains the **source files** for Qwen Code agent installations. Deployed automatically by `install.sh` to `~/.qwen/`.

## Structure

```
qwen/
├── QWEN.md                 # Global orchestrator (agent routing + rules)
└── commands/               # (deployed to projects)
```

## Qwen vs Claude Differences

| Feature | Qwen Code | Claude Code |
|---|---|---|
| Model | `qwen3.6-27b` (local vLLM) | Claude Sonnet/Haiku (Anthropic Cloud) |
| Tool names | `read_file`, `write_file`, `edit_file` | `Read`, `Write`, `Edit` |
| Orchestrator | `QWEN.md` | `CLAUDE.md` |
| Commands | `.qwen/commands/` | `.claude/commands/` |

## Subagents

The kit ships no Qwen agents (removed 2026-10-20); Qwen's built-in
`general-purpose` handles explicit subagent requests.

Qwen uses HTTP MCP transports for code-review-graph (port 7000), playwright (port 8932), and fetch (port 8935). LSP uses stdio via `~/.local/bin/lsp-coercion-proxy`. All configured automatically in `~/.qwen/settings.json` by `install.sh`.

## Deployment

Deployed automatically by `install.sh`:

```bash
bash install.sh
```

This copies:
- `qwen/QWEN.md` → `~/.qwen/QWEN.md` (global orchestrator)
- `extern/` → `~/.qwen/extern` (skill symlink)

To re-deploy after a `git pull`:

```bash
bash deploy-agents.sh
```

## Deployed Structure

After installation:

```
~/.qwen/
├── commands/               # Custom commands
├── settings.json           # Qwen Code settings
└── QWEN.md                 # Global orchestrator

<project>/
└── .qwen/
    ├── settings.json       # Project-level settings
    └── commands/           # Project-level commands
```

## License

These templates are distributed under the dev-agent-kit license. Extern submodules have their own licenses.
