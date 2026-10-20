#!/usr/bin/env bash
# Project-scoped Grafana MCP setup (github.com/grafana/mcp-grafana).
#
# Deliberately NOT registered globally: the server carries ~40 tools and only
# pays for itself in repos that actually work against a live Grafana. Writes
# the server into <target-repo>/.mcp.json so it loads only in that project's
# sessions.
#
# Usage: bash scripts/setup-grafana-mcp.sh <target-repo> [grafana-url]
#
# Token: never stored in .mcp.json — referenced as ${GRAFANA_SERVICE_ACCOUNT_TOKEN}
# and resolved from the environment at session start. Create one in Grafana:
# Administration -> Service accounts -> Add -> role Viewer -> Add token,
# then `export GRAFANA_SERVICE_ACCOUNT_TOKEN=...` (shell rc or direnv).
#
# Tool surface is trimmed for IaC repos: query/verify only. Write tools are
# disabled on purpose — dashboards live as JSON in the repo and deploy via
# terraform; API-side edits would drift and be clobbered on the next apply.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/platform.sh"

TARGET="${1:?usage: setup-grafana-mcp.sh <target-repo> [grafana-url]}"
GRAFANA_URL="${2:-http://localhost:3000}"
[[ -d "$TARGET" ]] || { warn "target repo not found: $TARGET"; exit 1; }

# Kept: search, dashboard (read), datasource, prometheus, loki, alerting,
# folder, navigation (deeplinks), config. Everything else is dead weight here.
DISABLE_FLAGS=(
  --disable-write --disable-api --disable-proxied
  --disable-incident --disable-sift --disable-oncall
  --disable-annotations --disable-snapshot --disable-rendering
  --disable-provisioning --disable-asserts --disable-pyroscope
  --disable-plugin
)

# --- 1) binary (single static Go binary, idempotent) ---
BIN="$(command -v mcp-grafana || true)"
[[ -z "$BIN" && -x "$HOME/go/bin/mcp-grafana" ]] && BIN="$HOME/go/bin/mcp-grafana"
if [[ -z "$BIN" ]]; then
  command -v go &>/dev/null || { warn "go not found — install go or mcp-grafana manually"; exit 1; }
  info "installing mcp-grafana (go install)..."
  go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest
  BIN="$HOME/go/bin/mcp-grafana"
fi
[[ -x "$BIN" ]] || { warn "mcp-grafana binary not found after install"; exit 1; }
ok "mcp-grafana: $BIN"

# --- 2) merge into the project config of BOTH agents (preserves other servers) ---
# Claude reads <repo>/.mcp.json; Qwen reads <repo>/.qwen/settings.json.
mkdir -p "$TARGET/.qwen"
python3 - "$BIN" "$GRAFANA_URL" "$TARGET/.mcp.json" "$TARGET/.qwen/settings.json" \
         -- "${DISABLE_FLAGS[@]}" <<'PYEOF'
import json
import os
import sys

bin_, url = sys.argv[1:3]
sep = sys.argv.index("--")
paths = sys.argv[3:sep]
flags = sys.argv[sep + 1:]
for path in paths:
    cfg = {}
    if os.path.exists(path):
        with open(path) as f:
            cfg = json.load(f)
    cfg.setdefault("mcpServers", {})["grafana"] = {
        "command": bin_,
        "args": flags,
        "env": {
            "GRAFANA_URL": url,
            "GRAFANA_SERVICE_ACCOUNT_TOKEN": "${GRAFANA_SERVICE_ACCOUNT_TOKEN}",
        },
    }
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PYEOF
ok "grafana server merged -> $TARGET/.mcp.json + .qwen/settings.json (url: $GRAFANA_URL)"

if [[ -z "${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  info "GRAFANA_SERVICE_ACCOUNT_TOKEN is not set in this shell."
  info "Grafana: Administration -> Service accounts -> Add account (role: Viewer) -> Add token"
  info "then:    export GRAFANA_SERVICE_ACCOUNT_TOKEN=<token>   (shell rc or direnv)"
fi
