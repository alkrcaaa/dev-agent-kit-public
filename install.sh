#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "ERROR: do not run install.sh as root/sudo."
  echo "       NVM and user-local tools (pipx, npm global) would install to root's home,"
  echo "       making them inaccessible to your user. Run as: bash install.sh"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/scripts/lib/platform.sh"
source "$REPO_ROOT/scripts/lib/submodules.sh"
source "$REPO_ROOT/scripts/lib/deps.sh"
source "$REPO_ROOT/scripts/lib/mcp.sh"
source "$REPO_ROOT/scripts/lib/agents.sh"
source "$REPO_ROOT/scripts/lib/verify.sh"

# Defaults — override in .env or pass a CLI arg. Empty means not configured:
# the Qwen and GitLab parts are skipped. GitLab is opt-in via GITLAB_URL.
VLLM_HOST=""
# Spare Qwen endpoints — offered in qwen's /model list, never the default.
QWEN_EXTRA_BASE_URLS=""
GITLAB_URL=""

# Load from .env if present (user can set QWEN_BASE_URL / GITLAB_URL there)
if [[ -f "$REPO_ROOT/.env" ]]; then
  env_vllm=$(grep -E '^QWEN_BASE_URL=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  env_gitlab=$(grep -E '^GITLAB_URL=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  env_qwen_extra=$(grep -E '^QWEN_EXTRA_BASE_URLS=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  env_lsp=$(grep -E '^ENABLE_LSP=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  # Qwen-only: Claude authorizes GitLab over OAuth, Qwen Code has no such flow.
  env_gitlab_token=$(grep -E '^GITLAB_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  [[ -n "$env_gitlab_token" ]] && export GITLAB_TOKEN="$env_gitlab_token"
  # Only override when actually set — a .env missing one of these must keep the default
  [[ -n "$env_vllm" ]] && VLLM_HOST="$env_vllm"
  [[ -n "$env_gitlab" ]] && GITLAB_URL="$env_gitlab"
  [[ -n "$env_qwen_extra" ]] && QWEN_EXTRA_BASE_URLS="$env_qwen_extra"
  [[ -n "$env_lsp" ]] && ENABLE_LSP="$env_lsp"
  # Vault paths: read here too, or they only ever reached the installer from a
  # hand-written shell rc -- and a fresh machine has none, so vault.env was
  # never written and every obsidian-vault-bridge hook stayed silently off.
  env_vault=$(grep -E '^VAULT_DIR=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  env_mirror=$(grep -E '^MEM_OBSIDIAN_VAULT=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  [[ -n "$env_vault" ]] && VAULT_DIR="${env_vault/#\~/$HOME}"
  [[ -n "$env_mirror" ]] && MEM_OBSIDIAN_VAULT="${env_mirror/#\~/$HOME}"
  env_timer=$(grep -E '^VAULT_COMPILE_TIMER=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  [[ -n "$env_timer" ]] && export VAULT_COMPILE_TIMER="$env_timer"
fi
[[ -n "${VAULT_DIR:-}" ]] && export VAULT_DIR
[[ -n "${MEM_OBSIDIAN_VAULT:-}" ]] && export MEM_OBSIDIAN_VAULT
# Opt-in: LSP measured at 1 call in ~35k fleet-wide; the graph covers navigation.
export ENABLE_LSP="${ENABLE_LSP:-0}"
export QWEN_EXTRA_BASE_URLS

while [[ $# -gt 0 ]]; do
  case "$1" in
    http://*|https://*) VLLM_HOST="$1"; shift ;;
    --vllm-host) VLLM_HOST="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: bash install.sh [http://HOST:PORT/v1]"
      echo ""
      echo "  Pass your Qwen vLLM server URL to enable Qwen MCP:"
      echo "    bash install.sh http://<your-vllm-host>:8002/v1"
      echo ""
      echo "  Or set QWEN_BASE_URL in .env and run without arguments:"
      echo "    cp .env.example .env  # then edit .env"
      echo "    bash install.sh"
      echo ""
      echo "  Without a vLLM URL, all tools install but Qwen MCP is skipped."
      exit 0 ;;
    *) echo "Unknown argument: $1 (use --help)" >&2; exit 1 ;;
  esac
done

OS=$(detect_os)
require_package_manager "$OS"
ensure_local_bin_on_path

# The defaults above belong to one network; they are a convenience, not a
# promise. Registering an MCP against a host that never answers yields an
# install that reports success and fails on first use — worse than a clean
# skip. So each network-wired MCP proves itself here, and anything unreachable
# is dropped with the reason. Re-run install.sh once the host is up.
if [[ -n "$VLLM_HOST" ]] && ! host_reachable "${VLLM_HOST%/}/models"; then
  warn "vLLM at $VLLM_HOST did not answer — Qwen MCP will be skipped"
  VLLM_HOST=""
fi
if [[ -n "$GITLAB_URL" ]] && ! host_reachable "$GITLAB_URL"; then
  warn "GitLab at $GITLAB_URL did not answer — GitLab MCP will be skipped"
  GITLAB_URL=""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-kit installer"
echo "  Platform : $OS"
if [[ -n "$VLLM_HOST" ]]; then
  echo "  vLLM     : $VLLM_HOST"
else
  echo "  vLLM     : not set (Qwen MCP will be skipped)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

init_submodules
# Contained on purpose: an optional dependency must never be able to take the
# whole install down with it. Whatever fails here, MCP setup, agent deployment
# and the verification report below still run — and the report names the holes.
install_deps || warn "dependency step failed — continuing; see Verification below for what is missing"
setup_lsp_servers || warn "LSP step failed — continuing"
# Same containment: an MCP step that died used to end the run here, before
# deploy_agents — the install that "did not bring the hooks over".
setup_mcp_servers "$VLLM_HOST" "$GITLAB_URL" || warn "MCP step failed — continuing; see Verification below"
deploy_agents

# Non-fatal steps above can leave holes; say so instead of claiming success.
VERIFY_RC=0
verify_install || VERIFY_RC=$?

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $VERIFY_RC -eq 0 ]]; then
  echo "  ✓ Installation complete!"
else
  echo "  ! Installation finished WITH MISSING COMPONENTS (see Verification above)"
fi
echo ""
echo "  Open a NEW terminal (PATH changes were persisted to your shell RC)"
echo "  Start Claude : claude"
if [[ -n "$VLLM_HOST" ]]; then
  echo "  Start Qwen   : qwen   (pre-wired to $VLLM_HOST — no alias needed)"
else
  echo "  Start Qwen   : qwen"
fi
if command -v agy &>/dev/null; then
  echo "  Start Antigravity : agy"
fi
echo ""
echo "  NOTE: If Claude Code was already running, restart it"
echo "        (claude.json was updated — takes effect on next session)"
echo ""
echo "  NOTE: Keep this clone where it is — ~/.claude/extern symlinks into it."
echo "        Moving or deleting $REPO_ROOT"
echo "        leaves the extern skills loading but empty. Re-run install.sh"
echo "        after any move."
if [[ -z "$VLLM_HOST" ]]; then
  echo ""
  echo "  To enable Qwen MCP later:"
  echo "    bash install.sh http://HOST:PORT/v1"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $VERIFY_RC
