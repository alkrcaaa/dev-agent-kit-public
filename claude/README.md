# Claude Code Templates

This directory contains the **source files** for Claude Code agent installations. Deployed automatically by `install.sh` to `~/.claude/`.

## Structure

```
claude/
├── CLAUDE.md              # Global orchestrator (agent routing + rules)
├── models.env             # Claude model settings
└── commands/              # Custom commands
    ├── help.md            # /project:help
    └── setup.md           # /project:setup
```

## Files

### CLAUDE.md — Orchestrator

Deployed to `~/.claude/CLAUDE.md`. It is injected into every session and re-billed on every API call, so it holds rules only (~8.6KB, down from 18.2KB on 2026-09-29). The reasons behind those rules live in the next section. Before adding to CLAUDE.md, ask whether the model needs the line on every call. If it only needs it at one decision point, put it in a hook message, a skill, or a tool description instead.

## Why the CLAUDE.md rules are what they are

**Graph before grep.** The gate uses a budget: each graph consult grants 3 manual reads. A one-shot gate opens once and the model drifts back to bulk-reading. A budget keeps the pressure on for the whole session. The gate is coverage-aware: steering the model to a graph that cannot answer for `.tf`/`.yaml` is worse than no gate.

**Keep sessions short.** Measured 2026-08-08: sessions past 500 calls averaged 347k context per call, against 191k for sessions of 101-500 calls. The 13 mega-sessions carried 84% of all context tokens. `session-size-nudge.py` warns on both transcript MB and context per call.

**Never pass a path as `project` to mem_save.** Measured 2026-08-08: 51 of 282 observations were stranded in absolute-path namespaces, including 18 of dev-agent-kit's 27. `mem_search` is global, but `mem_recent` and the session-start injection are namespace-scoped. The rule used to be "never pass `project`", which was wrong for Antigravity: its mem-lite server runs from `~/.gemini/config`, so every save it made was keyed `.gemini--config` and a triage note collected six repos' work. Now Claude/Qwen omit it unless the save is about another repo, Antigravity always passes the repo's key, and `mem-save-guard` (obsidian-vault-bridge) blocks a path, an unknown key, or a keyless Antigravity save at write time.

**Personal facts go to the vault profile.** Measured 2026-08-23: personal notes had scattered across 30 project folders and produced two rival profiles ("four-year expert" vs "new to infra"). Whichever repo was open decided who the model thought the user was. The inverse also holds: agent-behaviour rules stay in `memory/`. `memory/` auto-injects every session and the vault does not, so moving a behavioural rule into the vault silently repeals it.

**vault-search triggers.** Measured 2026-09-22: 85 vault writes per week and 0 reads. The earlier wording "don't call it reflexively" was read as "never". The explicit trigger list fixes that. vault-search, the `obsidian-mirror`/`vault-inject` hooks and the `vault-compile` timer live in `extern/obsidian-vault-bridge`, not in core dev-agent-kit.

**llm-council.** Only `ask_council` is gated, and `type1_rationale` is a required argument, so that string is the gate. Your own model is filtered out of the panel and the chairman is never a panelist, so the value is an outside view: frame options neutrally. The council is registered for Claude and Antigravity, not Qwen. Its source is the `mcp-infra/llm-council-mcp` submodule.

**The write-capable `delegate` CLI was removed (2026-10-06).** Early Gemini/Qwen runs caused bugs, and one deleted uncommitted files; it was paused on 2026-09-27 and then deleted. Read-only `ask_worker` advisors remain. The old routing policy is in commit f35a9ca. `qwen-consider.py` (a one-time nudge toward the Qwen offload before the first subagent) stays unwired from `settings.json`, because it contradicts that policy and costs a blocked round trip.

### Claude/Qwen: shared hooks, three deliberate asymmetries

The hook scripts and skills deploy to `~/.qwen/` too, so a Qwen session is gated exactly like a Claude one. `claude/hooks/agent_env.py` maps Qwen's wire tool names (`read_file`, `run_shell_command`, `edit`) onto the canonical ones. It also picks the output channel each host honours: Qwen drops PostToolUse stderr and plain UserPromptSubmit stdout, and only JSON `additionalContext` lands. Qwen matchers in `qwen/settings.json` must use wire names; a `"Read"` matcher there fails silently.

Don't "fix" these three asymmetries back to symmetric. Claude's ceiling is money; Qwen's is a 235k window, past which the vLLM server refuses requests.
- **Session thresholds** are absolute on Claude and derived from `model.sessionTokenLimit` on Qwen. Claude's 300k escalation sits above Qwen's entire window.
- **Tool menus are trimmed on Qwen only** (`includeTools` in `_configure_qwen_settings`): 30 graph tools become 13, and 24 playwright tools become 14. A 27B model chooses worse from a longer menu. The allowlist is exactly what CLAUDE.md, QWEN.md and the skills name, and a test enforces this.
- **claude-mem-lite is bridged, not re-wired** (`mem-bridge.py`). It hard-codes Claude's tool names, so Qwen's `edit`/`read_file` recalled nothing until the bridge canonicalised them.

### Subagents

The kit ships no Claude subagents (removed 2026-10-20: their `tools:` listed Qwen
tool names, so Claude Code refused to spawn them). Use the built-in `Explore`,
`Plan` and `general-purpose` agents; specialist knowledge lives in `skills/`.

Claude uses stdio transports for all MCP servers. Full details: [mcp-infra/README.md](../mcp-infra/README.md)

### commands/ — Custom Commands

| File | Command | Description |
|---|---|---|
| `help.md` | `/project:help` | Shows project information |
| `setup.md` | `/project:setup` | Project agent setup |

## Deployment

Deployed automatically by `install.sh`:

```bash
bash install.sh
```

This copies:
- `claude/CLAUDE.md` → `~/.claude/CLAUDE.md` (global orchestrator)
- `extern/` → `~/.claude/extern` (skill symlink)

To re-deploy after a `git pull` without re-running the full install:

```bash
bash deploy-agents.sh
```

## Deployed Structure

After installation:

```
~/.claude/
├── CLAUDE.md              # Global orchestrator
├── commands/              # Custom commands
├── settings.json          # Claude Code settings
└── ...
```

## License

These templates are distributed under the dev-agent-kit license. Extern submodules have their own licenses.
