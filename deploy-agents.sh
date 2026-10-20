#!/usr/bin/env bash
# Re-deploy CLAUDE.md/QWEN.md, hooks and skills after git pull.
# Usage: bash deploy-agents.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/scripts/lib/platform.sh"
source "$REPO_ROOT/scripts/lib/agents.sh"

detect_os >/dev/null  # fail early on an unsupported platform
deploy_agents
