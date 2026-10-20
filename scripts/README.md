# scripts/

Installation helpers and health checks for dev-agent-kit.

## Structure

| Path | Description |
|---|---|
| `lib/platform.sh` | `detect_os()`, `ensure_local_bin_on_path()`, color helpers |
| `lib/submodules.sh` | `init_submodules()` — git submodule update |
| `lib/deps.sh` | `install_deps()` — Node.js, pipx, qwen CLI, claude CLI |
| `lib/mcp.sh` | `setup_mcp_servers(vllm_host)` + `setup_lsp_servers()` — code-review-graph, playwright, qwen, lsp, fetch MCP |
| `lib/agents.sh` | `deploy_agents()` — CLAUDE.md/QWEN.md, hooks, skills (Claude, Qwen, Codex, Antigravity) |
| `health/healthcheck.sh` | Smoke test of a deployed machine: binaries, vLLM, MCP liveness |
| `health/doctor.sh` | Repo self-consistency — compares doc claims against `.gitmodules`, dir listings, `settings.json` and the MCP inventory. Exits non-zero on drift; safe to run in CI |
| `health/mcp_probe.py` | MCP liveness: speaks `initialize` + `tools/list` to every configured server on both hosts and reports the tool count. Catches a dead server, and a stale Qwen `includeTools` allowlist that the settings file still makes look correct. `--host claude\|qwen\|both` |
| `agent-stats.sh` | Usage audit from Claude Code transcripts — tool distribution, structural ratio, tokens |
| `hook-stats.sh` | Enforcement audit — how often each hook actually blocked/nudged, by hook, domain and project. The tuning signal `agent-stats.sh` cannot give |
| `claude/hooks/consistency-check.py` | The one that *asserts* rather than counts. Five invariants (recent mem-lite rows are mirrored, wired hooks exist on disk, wired hooks are instrumented, no absolute-path mem namespaces, compiled notes aren't stale). Silent when healthy; wired on SessionStart with `--oneline`, run bare for the full report. Exits 1 on any violation. Every counter above reports what happened — a `mem_save` still went missing without one of them noticing, because a call that never fires increments nothing |
| `migrate-mem-namespaces.py` | One-shot repair: merges stranded absolute-path project keys in the claude-mem-lite DB into the canonical `workspace--<repo>` form. Dry-run by default, `--apply` to commit |
| `qwen-stats.sh` | Same audit for Qwen Code sessions — plus mem-lite/MCP usage, API errors, context compressions. `bash scripts/qwen-stats.sh [project] [--since 7d]` |

## Usage

These files are **sourced, not executed directly**. Entry points are at the **repo root** (not inside `scripts/`):

```bash
# Full install — Qwen URL via .env (recommended)
cp .env.example .env   # QWEN_BASE_URL=<your-vllm-host>:8002/v1
bash install.sh

# Full install — Qwen URL as argument
bash install.sh http://<your-vllm-host>:8002/v1

# Claude-only install (Qwen MCP skipped)
bash install.sh

# Re-deploy CLAUDE.md, hooks and skills after git pull (fast, no re-install)
bash deploy-agents.sh
```

## install.sh flow

```
init_submodules     → git submodule update --init --recursive
install_deps        → Node.js + pipx + qwen CLI + claude CLI
setup_lsp_servers   → clangd + pyright + lsp-mcp-server + supergateway + lsp-coercion-proxy + ~/.lsp-mcp.json
setup_mcp_servers   → code-review-graph + playwright + fetch (+ qwen MCP & qwen CLI ~/.qwen/.env if URL provided)
deploy_agents       → CLAUDE.md/QWEN.md, hooks, skills → ~/.claude/ and ~/.qwen/
```

PATH entries needed by the installed tools (`~/.local/bin`, `~/.npm-global/bin`
when npm's prefix is system-owned) are persisted to the active shell's RC file
(zsh → `~/.zshrc`, bash → `~/.bashrc`, other → `~/.profile`) — idempotent, one
line, only when missing. No aliases are created; the qwen CLI endpoint lives in
`~/.qwen/.env`, not in shell config.

## Health check

```bash
./scripts/health/healthcheck.sh
```

Checks: platform, binaries (claude, qwen), vLLM connectivity, MCP servers.
