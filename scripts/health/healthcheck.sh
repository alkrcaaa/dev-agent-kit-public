#!/usr/bin/env bash
# shellcheck disable=SC2088  # literal ~/ is intentional: these are display
#                             strings telling the user which path to look at,
#                             never expanded as paths. Same call as doctor.sh.
# healthcheck.sh — cross-platform smoke test
# Qwen Code + Claude Code setup verification (macOS / Ubuntu / Arch)

set -euo pipefail

# ── Platform auto-detect ───────────────────────────────────────────────────
PLATFORM="linux"
uname_out="$(uname -s)"
case "$uname_out" in
  Darwin*)    PLATFORM="macos" ;;
  Linux*)     PLATFORM="linux" ;;
  *)          PLATFORM="unknown" ;;
esac

# ── vLLM config — override via env vars or .dev-agent-kit.env ──────────────
VLLM_HOST="${OPENAI_BASE_URL:-}"
VLLM_MODEL="${OPENAI_MODEL:-/models/qwen3.8-27b}"

# Load from .dev-agent-kit.env if not already set
if [[ -z "$VLLM_HOST" && -f "$HOME/.dev-agent-kit.env" ]]; then
  set -a; source "$HOME/.dev-agent-kit.env"; set +a
  VLLM_HOST="${OPENAI_BASE_URL:-$VLLM_HOST}"
  VLLM_MODEL="${OPENAI_MODEL:-$VLLM_MODEL}"
fi

# ── Binary detection — portable across platforms ───────────────────────────
# Try command -v first (works on all platforms if in PATH)
CLAUDE_BIN="$(command -v claude 2>/dev/null || echo '')"
if [[ -z "$CLAUDE_BIN" ]]; then
  case "$PLATFORM" in
    macos)  CLAUDE_BIN="/opt/homebrew/bin/claude" ;;   # macOS Homebrew
    linux)  CLAUDE_BIN="/usr/local/bin/claude" ;;       # typical Linux install
  esac
fi
# Final fallback: try common paths
if [[ -z "$CLAUDE_BIN" || ! -x "$CLAUDE_BIN" ]]; then
  for _p in /opt/homebrew/bin/claude /usr/local/bin/claude ~/.nvm/versions/node/*/bin/claude ~/snap/bin/claude; do
    [[ -x "$_p" ]] && { CLAUDE_BIN="$_p"; break; }
  done
fi

QWEN_BIN="$(command -v qwen 2>/dev/null || echo '')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve to repo root (scripts/health/../../ = repo root)
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()      { echo -e "  ${GREEN}✓${RESET} $*"; PASS=$((PASS+1)); }
fail()    { echo -e "  ${RED}✗${RESET} $*"; FAIL=$((FAIL+1)); }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; WARN=$((WARN+1)); }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── 1. Binaries ────────────────────────────────────────────────────────────
section "Binaries"

if [[ -x "$CLAUDE_BIN" ]]; then
  version=$(ANTHROPIC_API_KEY=dummy "$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  ok "claude: $CLAUDE_BIN ($version)"
else
  warn "claude binary not found at $CLAUDE_BIN (normal if not using cloud)"
fi

if [[ -n "$QWEN_BIN" ]]; then
  qwen_ver=$("$QWEN_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  ok "qwen: $QWEN_BIN ($qwen_ver)"
else
  fail "qwen binary not found  →  run: npm install -g @qwen-code/qwen-code"
fi

# ── 2. Global CLAUDE.md ────────────────────────────────────────────────────
section "Global orchestrator config"

GLOBAL_MD="$HOME/.claude/CLAUDE.md"
if [[ -f "$GLOBAL_MD" ]]; then
  if grep -q "Core Principles" "$GLOBAL_MD" 2>/dev/null; then
    ok "~/.claude/CLAUDE.md — core rules present"
  else
    warn "~/.claude/CLAUDE.md exists but core rules are missing  →  run: claude-deploy"
  fi
else
  warn "~/.claude/CLAUDE.md not found  →  run: claude-deploy"
fi

# ── 6. vLLM connectivity ───────────────────────────────────────────────────
section "vLLM connectivity ($VLLM_HOST)"

if curl -sf "$VLLM_HOST/v1/models" -o /dev/null --max-time 5; then
  ok "vLLM reachable at $VLLM_HOST"

  available=$(curl -sf "$VLLM_HOST/v1/models" | python3 -c "
import json,sys
data = json.load(sys.stdin).get('data', [])
for m in data: print(m['id'])
" 2>/dev/null || echo "")

  if echo "$available" | grep -qF "$VLLM_MODEL"; then
    ok "model present: $VLLM_MODEL"
  else
    fail "model not found: $VLLM_MODEL  →  check if loaded in vLLM"
  fi
else
  fail "vLLM unreachable: $VLLM_HOST"
fi

# ── 7. MCP server connectivity ─────────────────────────────────────────────
# This section used to be an empty heading: nothing here ever verified that a
# single MCP server answers, so a dead one looked exactly like a healthy one
# until an agent tried to call it mid-task. mcp_probe.py speaks real MCP
# (initialize -> tools/list) to every configured server on both hosts and
# prints its own per-server lines; we fold its verdict into our counters.
section "MCP servers"

MCP_PROBE="$SCRIPT_DIR/mcp_probe.py"
if [[ -f "$MCP_PROBE" ]]; then
  if python3 "$MCP_PROBE" --host both; then
    ok "MCP probe: all expected servers answered"
  else
    fail "MCP probe: see failures above  →  run: bash install.sh"
  fi
else
  warn "mcp_probe.py not found next to healthcheck.sh — skipping MCP probe"
fi

echo ""

# ── 8. Qwen settings.json ──────────────────────────────────────────────────
section "Qwen settings (~/.qwen/settings.json)"

QWEN_SETTINGS="$HOME/.qwen/settings.json"
if [[ -f "$QWEN_SETTINGS" ]]; then
  if python3 -c "import json; d=json.load(open('$QWEN_SETTINGS')); assert d.get('\$version') in (3, 4)" 2>/dev/null; then
    ok "settings.json valid (\$version: 3 or 4)"
  else
    warn "settings.json exists but \$version is invalid  →  run: qwen-deploy"
  fi
else
  warn "~/.qwen/settings.json not found  →  run: qwen-deploy"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Summary ===${RESET}"
echo -e "  Pass: ${GREEN}$PASS${RESET}  Fail: ${RED}$FAIL${RESET}  Warn: ${YELLOW}$WARN${RESET}"

if [[ $FAIL -gt 0 ]]; then
  echo -e "\n${RED}Setup missing. Fix the errors above.${RESET}"
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo -e "\n${YELLOW}Setup usable but warnings present.${RESET}"
  exit 0
else
  echo -e "\n${GREEN}All checks passed.${RESET}"
  exit 0
fi
