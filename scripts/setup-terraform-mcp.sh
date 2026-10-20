#!/usr/bin/env bash
# Project-scoped Terraform MCP setup (github.com/hashicorp/terraform-mcp-server).
#
# Deliberately NOT registered globally: Registry doc/module tools only pay for
# themselves in repos that actually author Terraform. Writes the server into
# <target-repo>/.mcp.json so it loads only in that project's sessions — same
# convention as setup-grafana-mcp.sh.
#
# Usage: bash scripts/setup-terraform-mcp.sh <target-repo>
#
# Safety: ENABLE_TF_OPERATIONS is left at its default (false) — the server
# exposes Registry queries (provider docs, modules, policies) but no
# plan/apply/workspace mutations. Do not flip it while deploys are frozen.
# No token needed for the public Registry; TFE_ADDRESS/TFE_TOKEN env vars
# enable HCP/TFE access later if ever needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/platform.sh"

TARGET="${1:?usage: setup-terraform-mcp.sh <target-repo>}"
[[ -d "$TARGET" ]] || { warn "target repo not found: $TARGET"; exit 1; }

# --- 1) binary (single static Go binary, idempotent) ---
BIN="$(command -v terraform-mcp-server || true)"
[[ -z "$BIN" && -x "$HOME/go/bin/terraform-mcp-server" ]] && BIN="$HOME/go/bin/terraform-mcp-server"
if [[ -z "$BIN" ]]; then
  command -v go &>/dev/null || { warn "go not found — install go or terraform-mcp-server manually"; exit 1; }
  info "installing terraform-mcp-server (go install)..."
  go install github.com/hashicorp/terraform-mcp-server/cmd/terraform-mcp-server@latest
  BIN="$HOME/go/bin/terraform-mcp-server"
fi
[[ -x "$BIN" ]] || { warn "terraform-mcp-server binary not found after install"; exit 1; }
ok "terraform-mcp-server: $BIN"

# --- 2) merge into the project config of BOTH agents (preserves other servers) ---
# Claude reads <repo>/.mcp.json; Qwen reads <repo>/.qwen/settings.json. Writing
# only the first would leave the server invisible in qwen sessions.
mkdir -p "$TARGET/.qwen"
python3 - "$BIN" "$TARGET/.mcp.json" "$TARGET/.qwen/settings.json" <<'PYEOF'
import json
import os
import sys

bin_ = sys.argv[1]
for path in sys.argv[2:]:
    cfg = {}
    if os.path.exists(path):
        with open(path) as f:
            cfg = json.load(f)
    cfg.setdefault("mcpServers", {})["terraform"] = {
        "command": bin_,
        "args": ["stdio"],
    }
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PYEOF
ok "terraform server merged -> $TARGET/.mcp.json + .qwen/settings.json (registry queries only, tf operations disabled)"
