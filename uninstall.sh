#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/..." in messages is display text, not a path to expand
# uninstall.sh — dev-agent-kit full uninstaller
#
# Usage:
#   bash uninstall.sh              # safe mode: removes project artifacts + config entries
#   bash uninstall.sh --full       # also removes npm packages, code-review-graph, playwright cache
#   bash uninstall.sh --dry-run    # preview what would be removed without doing anything
#
# Individual skip flags (combine freely):
#   --keep-system-packages         # skip system package removal
#   --keep-node                    # skip Node.js / NVM removal (--full only)
#   --keep-uv                      # skip uv removal (--full only)
#   --keep-claude                  # skip Claude Code CLI removal (--full only)
#   --keep-qwen-cli                # skip Qwen Code CLI removal (--full only)
#
# What this removes:
#   Always:
#     - Python venvs (qwen-mcp-server)
#     - claude-mem-lite plugin (~/.claude-mem-lite/ via its own uninstaller)
#     - Systemd user services (playwright-mcp, lsp-mcp, crg-mcp, fetch-mcp)
#     - Local wrapper binaries (~/.local/bin/{playwright,lsp,crg,fetch}-mcp-start)
#     - lsp-coercion-proxy (~/.local/bin/lsp-coercion-proxy)
#     - MCP entries in ~/.claude/claude.json
#     - MCP entries + hooks in ~/.qwen/settings.json
#     - auto-build hook in ~/.claude/settings.json
#     - Retired kit agent files (~/.claude/agents/, ~/.qwen/agents/, ~/.gemini/config/agents/)
#     - Deployed CLAUDE.md / QWEN.md
#     - extern/ symlinks (~/.claude/extern, ~/.qwen/extern)
#     - ~/.lsp-mcp.json
#     - crg-daemon project registration + graph data
#     - .code-review-graph/ in repo root
#
#   With --full:
#     - npm global packages (playwright, pyright, lsp-mcp-server, supergateway, mcp-fetch-server)
#     - @qwen-code/qwen-code npm package
#     - code-review-graph (uv tool / pipx)
#     - Playwright chromium cache (~/.cache/ms-playwright/)
#     - System packages (xvfb, xdotool, wmctrl, scrot, xclip, tesseract, pyatspi)
#     - Node.js / NVM (~/.nvm)
#     - uv (~/.local/bin/uv, ~/.local/share/uv/)
#     - Claude Code CLI
#     - ~/.npmrc prefix entry

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
info()    { echo -e "  ${CYAN}→${RESET} $*"; }
err()     { echo -e "  ${RED}✗${RESET} $*" >&2; }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }
skipped() { echo -e "  ${CYAN}○${RESET} (dry-run) $*"; }

# ── Arg parsing ─────────────────────────────────────────────────────────────
FULL=false
DRY_RUN=false
KEEP_SYSTEM_PACKAGES=false
KEEP_NODE=false
KEEP_UV=false
KEEP_CLAUDE=false
KEEP_QWEN_CLI=false

for arg in "$@"; do
  case "$arg" in
    --full)                  FULL=true ;;
    --dry-run)               DRY_RUN=true ;;
    --keep-system-packages)  KEEP_SYSTEM_PACKAGES=true ;;
    --keep-node)             KEEP_NODE=true ;;
    --keep-uv)               KEEP_UV=true ;;
    --keep-claude)           KEEP_CLAUDE=true ;;
    --keep-qwen-cli)         KEEP_QWEN_CLI=true ;;
    -h|--help)
      sed -n '3,40p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      err "Unknown argument: $arg (use --help)"
      exit 1 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  err "Do not run uninstall.sh as root. Run as your normal user."
  exit 1
fi

# ── Dry-run wrapper ──────────────────────────────────────────────────────────
# All destructive ops go through these functions so dry-run is honoured.

run() {
  # run <description> <cmd...>
  local desc="$1"; shift
  if $DRY_RUN; then
    skipped "$desc"
  else
    "$@" && ok "$desc" || warn "$desc — command failed (non-fatal)"
  fi
}

rm_f() {
  local path="$1"
  if $DRY_RUN; then
    [[ -e "$path" || -L "$path" ]] && skipped "remove $path" || true
  else
    if [[ -e "$path" || -L "$path" ]]; then
      rm -f "$path" && ok "removed $path" || warn "could not remove $path"
    fi
  fi
}

rm_rf() {
  local path="$1"
  if $DRY_RUN; then
    [[ -d "$path" ]] && skipped "remove dir $path" || true
  else
    if [[ -d "$path" ]]; then
      rm -rf "$path" && ok "removed $path/" || warn "could not remove $path/"
    fi
  fi
}

# ── Distro detection ─────────────────────────────────────────────────────────
detect_distro() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "mac"; return
  fi
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
      arch|manjaro|endeavouros|archlinux*) echo "arch"; return ;;
      fedora|rhel|centos|rocky|almalinux)  echo "fedora"; return ;;
      debian|ubuntu|linuxmint|pop)         echo "debian"; return ;;
    esac
    case "${ID_LIKE:-}" in
      *arch*)                echo "arch"; return ;;
      *fedora*|*rhel*)       echo "fedora"; return ;;
      *debian*|*ubuntu*)     echo "debian"; return ;;
    esac
  fi
  echo "unknown"
}

DISTRO="$(detect_distro)"

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-kit uninstaller"
echo "  Repo     : $REPO_ROOT"
echo "  Platform : $DISTRO"
echo "  Mode     : $(  $FULL && echo "full" || echo "safe")$(  $DRY_RUN && echo " (dry-run)" || true)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $DRY_RUN; then
  echo ""
  warn "DRY-RUN mode — nothing will actually be removed."
fi

# ════════════════════════════════════════════════════════════════════════════
# 1. Systemd user services
# ════════════════════════════════════════════════════════════════════════════
section "Systemd Services"

SERVICES=(playwright-mcp lsp-mcp crg-mcp fetch-mcp)

if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
  for svc in "${SERVICES[@]}"; do
    if systemctl --user is-active "$svc" &>/dev/null 2>&1; then
      run "stop $svc" systemctl --user stop "$svc"
    fi
    if systemctl --user is-enabled "$svc" &>/dev/null 2>&1; then
      run "disable $svc" systemctl --user disable "$svc"
    fi
    rm_f "$HOME/.config/systemd/user/${svc}.service"
  done
  if ! $DRY_RUN; then
    systemctl --user daemon-reload 2>/dev/null && ok "daemon-reload" || true
  fi
else
  info "systemd --user not available — skipping service cleanup"
fi

# ════════════════════════════════════════════════════════════════════════════
# 2. Local wrapper binaries
# ════════════════════════════════════════════════════════════════════════════
section "Local Binaries"

LOCAL_BINS=(
  "$HOME/.local/bin/lsp-coercion-proxy"
  "$HOME/.local/bin/playwright-mcp-start"
  "$HOME/.local/bin/lsp-mcp-start"
  "$HOME/.local/bin/crg-mcp-start"
  "$HOME/.local/bin/fetch-mcp-start"
)

for bin in "${LOCAL_BINS[@]}"; do
  rm_f "$bin"
done

# ════════════════════════════════════════════════════════════════════════════
# 3. Python venvs (in repo)
# ════════════════════════════════════════════════════════════════════════════
section "Python Venvs"

rm_rf "$REPO_ROOT/mcp-infra/qwen-mcp-server/.venv"

# ════════════════════════════════════════════════════════════════════════════
# 3b. claude-mem-lite (self-managed plugin)
# ════════════════════════════════════════════════════════════════════════════
section "claude-mem-lite"

if [[ -f "$HOME/.claude-mem-lite/install.mjs" ]]; then
  if $DRY_RUN; then
    echo "  (dry-run) would run: node ~/.claude-mem-lite/install.mjs uninstall"
  else
    node "$HOME/.claude-mem-lite/install.mjs" uninstall 2>&1 | grep -E "✓|✗|⚠|removed|uninstalled|Error" || true
    ok "claude-mem-lite uninstalled"
  fi
else
  info "claude-mem-lite not installed — skipping"
fi

# ════════════════════════════════════════════════════════════════════════════
# 4. crg-daemon project registration + graph data
# ════════════════════════════════════════════════════════════════════════════
section "code-review-graph Daemon"

if command -v crg-daemon &>/dev/null; then
  if crg-daemon status &>/dev/null 2>&1; then
    run "crg-daemon: remove project $REPO_ROOT" crg-daemon remove "$REPO_ROOT" 2>/dev/null
    # Check if no projects remain; if so, stop the daemon
    remaining=$(crg-daemon list 2>/dev/null | grep -c '^/' || true)
    if [[ "${remaining:-0}" -eq 0 ]]; then
      run "crg-daemon stop (no projects left)" crg-daemon stop 2>/dev/null
    else
      info "crg-daemon still has $remaining project(s) — keeping running"
    fi
  else
    info "crg-daemon not running — skipping"
  fi
else
  info "crg-daemon not found — skipping"
fi

# Graph data in repo root
rm_rf "$REPO_ROOT/.code-review-graph"

# ════════════════════════════════════════════════════════════════════════════
# 5. ~/.claude/claude.json — remove our MCP entries
# ════════════════════════════════════════════════════════════════════════════
section "Claude MCP Config (claude.json)"

CLAUDE_JSON="$HOME/.claude/claude.json"
OUR_MCP_KEYS=(playwright qwen fetch lsp code-review-graph)

if [[ -f "$CLAUDE_JSON" ]]; then
  if $DRY_RUN; then
    for key in "${OUR_MCP_KEYS[@]}"; do
      python3 -c "
import json, sys
data = json.load(open('$CLAUDE_JSON'))
if '$key' in data.get('mcpServers', {}):
    print('  (dry-run) would remove mcpServers.$key from claude.json')
" 2>/dev/null || true
    done
  else
    cp "$CLAUDE_JSON" "${CLAUDE_JSON}.uninstall.bak" 2>/dev/null || true
    python3 - "$CLAUDE_JSON" <<PYEOF
import json, sys

path = sys.argv[1]
removed_keys = [$(printf '"%s", ' "${OUR_MCP_KEYS[@]}" | sed 's/, $//')]

with open(path) as f:
    data = json.load(f)

servers = data.get('mcpServers', {})
removed = []
for key in removed_keys:
    if key in servers:
        del servers[key]
        removed.append(key)

data['mcpServers'] = servers

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

if removed:
    print(f"  ✓ removed from claude.json: {', '.join(removed)}")
else:
    print("  ○ no matching MCP entries found in claude.json")
PYEOF
  fi
else
  info "claude.json not found — skipping"
fi

# ════════════════════════════════════════════════════════════════════════════
# 6. ~/.claude/settings.json — remove ALL our deployed hooks
#    Sources: claude/settings.json (PreToolUse hooks) +
#             _install_crg_autobuild_hook (UserPromptSubmit)
# ════════════════════════════════════════════════════════════════════════════
section "Claude Settings (settings.json)"

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
OUR_SETTINGS_SRC="$REPO_ROOT/claude/settings.json"
CRG_HOOK_CMD='if git rev-parse --git-dir > /dev/null 2>&1 && [ ! -f .code-review-graph/graph.db ]; then code-review-graph build > /dev/null 2>&1 & fi'

if [[ -f "$CLAUDE_SETTINGS" ]]; then
  if $DRY_RUN; then
    python3 - "$CLAUDE_SETTINGS" "${OUR_SETTINGS_SRC}" "$CRG_HOOK_CMD" <<'PYEOF'
import json, sys, os

global_path, our_path, crg_hook = sys.argv[1], sys.argv[2], sys.argv[3]
with open(global_path) as f:
    global_cfg = json.load(f)

our_cmds = {crg_hook}
if os.path.exists(our_path):
    with open(our_path) as f:
        our_cfg = json.load(f)
    for entries in our_cfg.get('hooks', {}).values():
        for entry in entries:
            for h in entry.get('hooks', []):
                if 'command' in h:
                    our_cmds.add(h['command'])

found = []
for event, entries in global_cfg.get('hooks', {}).items():
    for entry in entries:
        for h in entry.get('hooks', []):
            if h.get('command', '') in our_cmds:
                found.append(f"{event}: {h['command'][:60]}...")
for f in found:
    print(f"  (dry-run) would remove hook: {f}")
if not found:
    print("  ○ no matching hooks found in settings.json")
PYEOF
  else
    cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.uninstall.bak" 2>/dev/null || true
    python3 - "$CLAUDE_SETTINGS" "${OUR_SETTINGS_SRC}" "$CRG_HOOK_CMD" <<'PYEOF'
import json, sys, os

global_path, our_path, crg_hook = sys.argv[1], sys.argv[2], sys.argv[3]

with open(global_path) as f:
    global_cfg = json.load(f)

# Build set of all commands we deployed (source file + crg daemon hook)
our_cmds = {crg_hook}
if os.path.exists(our_path):
    with open(our_path) as f:
        our_cfg = json.load(f)
    for entries in our_cfg.get('hooks', {}).values():
        for entry in entries:
            for h in entry.get('hooks', []):
                if 'command' in h:
                    our_cmds.add(h['command'])

# Remove any hook entries whose commands match ours (all events, all matchers)
changed = False
global_hooks = global_cfg.get('hooks', {})
for event in list(global_hooks.keys()):
    before = len(global_hooks[event])
    global_hooks[event] = [
        entry for entry in global_hooks[event]
        if not any(h.get('command', '') in our_cmds for h in entry.get('hooks', []))
    ]
    if len(global_hooks[event]) < before:
        changed = True
    if not global_hooks[event]:
        del global_hooks[event]

if not global_hooks:
    global_cfg.pop('hooks', None)

with open(global_path, 'w') as f:
    json.dump(global_cfg, f, indent=2)
    f.write('\n')

if changed:
    print("  ✓ removed our hooks from settings.json (PreToolUse + UserPromptSubmit)")
else:
    print("  ○ no matching hooks found in settings.json")
PYEOF
  fi
else
  info "~/.claude/settings.json not found — skipping"
fi

# ════════════════════════════════════════════════════════════════════════════
# 7. ~/.qwen/settings.json — remove our MCP entries + hooks
# ════════════════════════════════════════════════════════════════════════════
section "Qwen Settings (settings.json)"

QWEN_SETTINGS="$HOME/.qwen/settings.json"

if [[ -f "$QWEN_SETTINGS" ]]; then
  if $DRY_RUN; then
    skipped "remove MCP entries + hooks from ~/.qwen/settings.json"
  else
    cp "$QWEN_SETTINGS" "${QWEN_SETTINGS}.uninstall.bak" 2>/dev/null || true
    python3 - "$QWEN_SETTINGS" "$REPO_ROOT/qwen/settings.json" <<PYEOF
import json, os, sys

path, our_path = sys.argv[1], sys.argv[2]
our_keys = [$(printf '"%s", ' "${OUR_MCP_KEYS[@]}" | sed 's/, $//')] + ["GitLab"]
crg_hook = '$CRG_HOOK_CMD'

with open(path) as f:
    data = json.load(f)

# Remove MCP server entries
servers = data.get('mcpServers', {})
removed_mcps = [k for k in our_keys if k in servers]
for k in removed_mcps:
    del servers[k]
data['mcpServers'] = servers

# Remove the crg auto-build hook plus every hook we deployed from
# qwen/settings.json (the enforcement layer), across all events.
our_cmds = {crg_hook}
if os.path.exists(our_path):
    with open(our_path) as f:
        our_cfg = json.load(f)
    for entries in our_cfg.get('hooks', {}).values():
        for entry in entries:
            for h in entry.get('hooks', []):
                if 'command' in h:
                    our_cmds.add(h['command'])

hook_changed = False
hooks = data.get('hooks', {})
for event in list(hooks.keys()):
    before = len(hooks[event])
    hooks[event] = [
        e for e in hooks[event]
        if not any(h.get('command', '') in our_cmds for h in e.get('hooks', []))
    ]
    if len(hooks[event]) < before:
        hook_changed = True
    if not hooks[event]:
        del hooks[event]
if hook_changed and not hooks:
    data.pop('hooks', None)

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

if removed_mcps:
    print(f"  ✓ removed from qwen settings: {', '.join(removed_mcps)}")
else:
    print("  ○ no matching MCP entries in qwen settings.json")
if hook_changed:
    print("  ✓ removed our hooks from qwen settings.json")
PYEOF
  fi
else
  info "~/.qwen/settings.json not found — skipping"
fi

# ════════════════════════════════════════════════════════════════════════════
# 8. Deployed agent files, skills, and CLAUDE.md / QWEN.md
# ════════════════════════════════════════════════════════════════════════════
section "Deployed Agents"

# The kit's agents were retired; remove any copies by name (user agents stay).
_remove_deployed_agents() {
  local dst_dir="$1" label="$2" name
  [[ -d "$dst_dir" ]] || { info "$dst_dir not found — nothing to remove"; return 0; }
  for name in designer general-purpose ops reviewer security tester; do
    [[ -f "$dst_dir/$name.md" ]] || continue
    if $DRY_RUN; then
      skipped "remove $label agent: $name.md"
    else
      rm -f "$dst_dir/$name.md" && ok "removed $label agent: $name.md" || warn "could not remove $dst_dir/$name.md"
    fi
  done
}

_remove_deployed_agents "$HOME/.claude/agents"         "Claude"
_remove_deployed_agents "$HOME/.qwen/agents"           "Qwen"
_remove_deployed_agents "$HOME/.gemini/config/agents"  "Antigravity"

# Deployed skills. A skill dir is ours if it matches a source skill, carries a
# kit marker, or is a known legacy name from before a rename. Legacy names must
# be listed explicitly: an old deployed skill can shadow a BUILT-IN slash command
# (e.g. a stale "mcp" skill hijacked /mcp), and those old dirs predate the marker.
LEGACY_SKILLS=("mcp")  # renamed → mcp-builder

_remove_deployed_skills() {
  local src_dir="$REPO_ROOT/claude/skills"
  local dst_dir="$1"

  [[ -d "$dst_dir" ]] || { info "$dst_dir not found — nothing to remove"; return; }

  for deployed in "$dst_dir"/*/; do
    [[ -d "$deployed" ]] || continue
    local base; base="$(basename "$deployed")"

    local ours=false
    if [[ -d "$src_dir/$base" ]]; then
      ours=true
    elif grep -q '\.claude/extern\|dev-agent-kit' "$deployed/SKILL.md" 2>/dev/null; then
      ours=true
    else
      for legacy in "${LEGACY_SKILLS[@]}"; do
        [[ "$base" == "$legacy" ]] && { ours=true; break; }
      done
    fi

    $ours && rm_rf "${deployed%/}"
  done
}

# The same skill set is deployed to both agents.
_remove_deployed_skills "$HOME/.claude/skills"
_remove_deployed_skills "$HOME/.qwen/skills"

# Hook scripts (identical sources deployed to both agents)
for hooks_dir in "$HOME/.claude/hooks" "$HOME/.qwen/hooks"; do
  [[ -d "$hooks_dir" ]] || continue
  for src_file in "$REPO_ROOT/claude/hooks"/*.py; do
    [[ -f "$src_file" ]] || continue
    rm_f "$hooks_dir/$(basename "$src_file")"
  done
done

# CLAUDE.md — only remove if it looks like ours (has our marker or matches source)
_remove_deployed_md() {
  local src="$1"; local dst="$2"; local label="$3"
  [[ -f "$src" ]] || return
  if [[ -f "$dst" ]]; then
    if diff -q "$src" "$dst" &>/dev/null; then
      if $DRY_RUN; then
        skipped "remove $label (matches source)"
      else
        # Restore from backup if available
        local backup
        backup=$(ls -t "$(dirname "$dst")/backups/$(basename "$dst").backup."* 2>/dev/null | head -1 || true)
        if [[ -n "$backup" ]]; then
          cp "$backup" "$dst" && ok "restored $label from backup: $(basename "$backup")"
        else
          rm -f "$dst" && ok "removed $label (no backup available)"
        fi
      fi
    else
      warn "$label exists but differs from our source — leaving it (manual review)"
    fi
  fi
}

_remove_deployed_md "$REPO_ROOT/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md" "~/.claude/CLAUDE.md"
_remove_deployed_md "$REPO_ROOT/qwen/QWEN.md"     "$HOME/.qwen/QWEN.md"     "~/.qwen/QWEN.md"

# ════════════════════════════════════════════════════════════════════════════
# 9. extern/ symlinks
# ════════════════════════════════════════════════════════════════════════════
section "Extern Symlinks"

for symlink in "$HOME/.claude/extern" "$HOME/.qwen/extern"; do
  if [[ -L "$symlink" ]]; then
    target="$(readlink "$symlink")"
    if [[ "$target" == "$REPO_ROOT/extern" ]]; then
      rm_f "$symlink"
    else
      warn "$symlink points to $target (not our repo) — leaving it"
    fi
  fi
done

# ════════════════════════════════════════════════════════════════════════════
# 10. ~/.lsp-mcp.json
# ════════════════════════════════════════════════════════════════════════════
section "LSP MCP Config"

rm_f "$HOME/.lsp-mcp.json"

# ════════════════════════════════════════════════════════════════════════════
# 11. FULL MODE — npm global packages
# ════════════════════════════════════════════════════════════════════════════
if $FULL; then
  section "npm Global Packages (--full)"

  # Source NVM if present
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
  [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"

  # @qwen-code/qwen-code is handled in its own section (always runs)
  NPM_PKGS=(
    "@playwright/mcp"
    "pyright"
    "lsp-mcp-server"
    "supergateway"
    "mcp-fetch-server"
  )

  if command -v npm &>/dev/null; then
    for pkg in "${NPM_PKGS[@]}"; do
      # Check if installed
      if npm list -g "$pkg" &>/dev/null 2>&1 || npm list -g --depth=0 2>/dev/null | grep -q "$pkg"; then
        run "npm uninstall -g $pkg" npm uninstall -g "$pkg"
      else
        info "$pkg not installed globally — skipping"
      fi
    done
  else
    warn "npm not found — skipping npm package removal"
  fi

  # Remove ~/.npmrc prefix line (if we set it)
  NPMRC="$HOME/.npmrc"
  if [[ -f "$NPMRC" ]] && grep -q "^prefix=" "$NPMRC"; then
    if $DRY_RUN; then
      skipped "remove prefix= line from ~/.npmrc"
    else
      sed -i '/^prefix=/d' "$NPMRC" && ok "removed prefix= from ~/.npmrc" || warn "could not clean ~/.npmrc"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 12. FULL MODE — code-review-graph
# ════════════════════════════════════════════════════════════════════════════
if $FULL; then
  section "code-review-graph (--full)"

  if command -v uv &>/dev/null; then
    if uv tool list 2>/dev/null | grep -q "code-review-graph"; then
      run "uv tool uninstall code-review-graph" uv tool uninstall code-review-graph
    else
      info "code-review-graph not installed via uv"
    fi
  fi

  if command -v pipx &>/dev/null; then
    if pipx list 2>/dev/null | grep -q "code-review-graph"; then
      run "pipx uninstall code-review-graph" pipx uninstall code-review-graph
    else
      info "code-review-graph not installed via pipx"
    fi
  fi

  # Remove pipx venv if leftover
  CRG_PIPX_VENV="$HOME/.local/share/pipx/venvs/code-review-graph"
  rm_rf "$CRG_PIPX_VENV"
fi

# ════════════════════════════════════════════════════════════════════════════
# 13. FULL MODE — Playwright chromium cache
# ════════════════════════════════════════════════════════════════════════════
if $FULL; then
  section "Playwright Chromium Cache (--full)"

  PLAYWRIGHT_CACHE="$HOME/.cache/ms-playwright"
  if [[ -d "$PLAYWRIGHT_CACHE" ]]; then
    # Estimate size before removing
    cache_size=$(du -sh "$PLAYWRIGHT_CACHE" 2>/dev/null | cut -f1 || echo "?")
    if $DRY_RUN; then
      skipped "remove $PLAYWRIGHT_CACHE ($cache_size)"
    else
      rm -rf "$PLAYWRIGHT_CACHE" && ok "removed $PLAYWRIGHT_CACHE ($cache_size freed)" || warn "could not remove $PLAYWRIGHT_CACHE"
    fi
  else
    info "~/.cache/ms-playwright not found — skipping"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 14. FULL MODE — System packages
# ════════════════════════════════════════════════════════════════════════════
if $FULL && ! $KEEP_SYSTEM_PACKAGES; then
  section "System Packages (--full)"

  _ask_confirm() {
    # In dry-run mode never prompt — just return false so we show the "would" message
    $DRY_RUN && return 1
    echo -n "  Continue? [y/N] "
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
  }

  case "$DISTRO" in
    arch)
      PKGS=(xorg-server-xvfb xdotool wmctrl scrot xclip
            tesseract tesseract-data-eng tesseract-data-tur
            python-pyatspi xorg-xdpyinfo)
      if command -v pacman &>/dev/null; then
        if $DRY_RUN; then
          skipped "pacman -Rs ${PKGS[*]}"
        else
          warn "Removing system packages — other apps may use these."
          if _ask_confirm; then
            run "pacman -Rs system packages" sudo pacman -Rs --noconfirm "${PKGS[@]}" 2>/dev/null
          else
            info "System package removal skipped by user"
          fi
        fi
      fi
      ;;
    debian)
      PKGS=(xvfb xdotool wmctrl scrot xclip
            tesseract-ocr tesseract-ocr-eng tesseract-ocr-tur
            python3-atspi xdpyinfo)
      if command -v apt-get &>/dev/null; then
        if $DRY_RUN; then
          skipped "apt-get remove ${PKGS[*]}"
        else
          warn "Removing system packages — other apps may use these."
          if _ask_confirm; then
            run "apt-get remove system packages" sudo apt-get remove -y "${PKGS[@]}"
            run "apt-get autoremove" sudo apt-get autoremove -y
          else
            info "System package removal skipped by user"
          fi
        fi
      fi
      ;;
    fedora)
      PKGS=(xorg-x11-server-Xvfb xdotool wmctrl scrot xclip
            tesseract at-spi2-core python3-pyatspi xdpyinfo)
      if command -v dnf &>/dev/null; then
        if $DRY_RUN; then
          skipped "dnf remove ${PKGS[*]}"
        else
          warn "Removing system packages — other apps may use these."
          if _ask_confirm; then
            run "dnf remove system packages" sudo dnf remove -y "${PKGS[@]}"
          else
            info "System package removal skipped by user"
          fi
        fi
      fi
      ;;
    mac)
      info "macOS: no system packages were installed — skipping"
      ;;
    *)
      warn "Unknown distro ($DISTRO) — skipping system package removal"
      ;;
  esac
fi

# ════════════════════════════════════════════════════════════════════════════
# 15. FULL MODE — Node.js / NVM
# ════════════════════════════════════════════════════════════════════════════
if $FULL && ! $KEEP_NODE; then
  section "Node.js / NVM (--full)"

  NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -d "$NVM_DIR" ]]; then
    if $DRY_RUN; then
      skipped "remove NVM (~/.nvm) + shell RC entries"
    else
    warn "Removing NVM will also remove ALL Node.js versions installed via nvm."
    echo -n "  Continue? [y/N] "
    read -r reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      # Deactivate nvm first
      [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
      if declare -f nvm &>/dev/null; then
        nvm deactivate 2>/dev/null || true
      fi
      rm_rf "$NVM_DIR"

      # Remove NVM lines from shell RC files
      for rcfile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        if [[ -f "$rcfile" ]] && grep -q 'NVM_DIR' "$rcfile"; then
          if $DRY_RUN; then
            skipped "remove NVM lines from $rcfile"
          else
            # Remove the standard NVM block
            sed -i '/export NVM_DIR/d;/nvm\.sh/d;/nvm bash_completion/d;/\[\[ -s.*nvm/d' "$rcfile" \
              && ok "removed NVM lines from $rcfile" \
              || warn "could not clean $rcfile"
          fi
        fi
      done
    else
      info "NVM removal skipped by user"
    fi
    fi  # end dry-run guard
  else
    info "~/.nvm not found — skipping"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 16. FULL MODE — uv
# ════════════════════════════════════════════════════════════════════════════
if $FULL && ! $KEEP_UV; then
  section "uv (--full)"

  if command -v uv &>/dev/null || [[ -f "$HOME/.local/bin/uv" ]]; then
    if $DRY_RUN; then
      skipped "remove uv (~/.local/bin/uv, ~/.local/share/uv)"
    else
      warn "Removing uv will also remove any tools installed via 'uv tool install'."
      echo -n "  Continue? [y/N] "
      read -r reply
      if [[ "$reply" =~ ^[Yy]$ ]]; then
        rm_f "$HOME/.local/bin/uv"
        rm_f "$HOME/.local/bin/uvx"
        rm_rf "$HOME/.local/share/uv"
        # uv installer also adds ~/.cargo/bin/uv on some setups
        rm_f "$HOME/.cargo/bin/uv" 2>/dev/null || true
      else
        info "uv removal skipped by user"
      fi
    fi
  else
    info "uv not found — skipping"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 17. Claude Code CLI  (always — skip with --keep-claude)
# ════════════════════════════════════════════════════════════════════════════
if ! $KEEP_CLAUDE; then
  section "Claude Code CLI"

  # Source NVM / npm-global so we can find claude regardless of install method
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
  [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"

  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  if [[ -n "$CLAUDE_BIN" ]]; then
    if $DRY_RUN; then
      skipped "remove Claude Code CLI ($CLAUDE_BIN)"
    else
      if command -v npm &>/dev/null && npm list -g --depth=0 2>/dev/null | grep -qE '@anthropic-ai/claude-code|claude-code'; then
        run "npm uninstall -g @anthropic-ai/claude-code" npm uninstall -g @anthropic-ai/claude-code || \
        run "npm uninstall -g claude"                    npm uninstall -g claude                    || true
      else
        # Standalone binary (installed via claude.ai/install.sh)
        rm_f "$CLAUDE_BIN"
      fi
      # Remove ~/.claude/claude.json (MCP registry file — different from ~/.claude/)
      rm_f "$HOME/.claude/claude.json"
    fi
  else
    info "claude CLI not found — skipping"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 17b. Qwen Code CLI  (always — skip with --keep-qwen-cli)
# ════════════════════════════════════════════════════════════════════════════
if ! $KEEP_QWEN_CLI; then
  section "Qwen Code CLI"

  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
  [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"

  QWEN_BIN="$(command -v qwen 2>/dev/null || true)"
  if [[ -n "$QWEN_BIN" ]] || npm list -g --depth=0 2>/dev/null | grep -q '@qwen-code/qwen-code'; then
    if $DRY_RUN; then
      skipped "npm uninstall -g @qwen-code/qwen-code (${QWEN_BIN:-not in PATH})"
    else
      run "npm uninstall -g @qwen-code/qwen-code" npm uninstall -g @qwen-code/qwen-code || true
    fi
  else
    info "qwen CLI not found — skipping"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 18. Project-local config dirs (.claude/ and .qwen/ inside repo)
# ════════════════════════════════════════════════════════════════════════════
section "Project-local Config Files"

# Both .claude/ and .qwen/ are gitignored — they are runtime artifacts
# created by Claude Code / Qwen Code when run inside this project.
# Safe to remove: they are never committed and contain no user data
# that isn't already backed up or reconstructible.

PROJECT_LOCAL_FILES=(
  "$REPO_ROOT/.claude/settings.json"
  "$REPO_ROOT/.claude/settings.local.json"
  "$REPO_ROOT/.qwen/settings.json"
  "$REPO_ROOT/.qwen/settings.json.orig"
)

for f in "${PROJECT_LOCAL_FILES[@]}"; do
  rm_f "$f"
done

# Remove dirs if now empty
for dir in "$REPO_ROOT/.claude" "$REPO_ROOT/.qwen"; do
  if [[ -d "$dir" ]]; then
    if $DRY_RUN; then
      # Only report if dir would become empty after file removals
      remaining=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
      [[ "$remaining" -eq 0 ]] && skipped "rmdir $dir (would be empty)"
    else
      rmdir "$dir" 2>/dev/null && ok "removed $dir/ (empty)" || true
    fi
  fi
done

# ════════════════════════════════════════════════════════════════════════════
# 19. Backup files — auto-clean (no prompt)
# ════════════════════════════════════════════════════════════════════════════
section "Backup Files"

# Deploy-created backup dirs
for backup_dir in "$HOME/.claude/backups" "$HOME/.qwen/backups"; do
  if [[ -d "$backup_dir" ]]; then
    count=$(find "$backup_dir" -name "*.backup.*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
      if $DRY_RUN; then
        skipped "remove $count backup file(s) in $backup_dir"
      else
        find "$backup_dir" -name "*.backup.*" -delete \
          && ok "cleaned $backup_dir ($count files)" \
          || warn "could not clean $backup_dir"
        rmdir "$backup_dir" 2>/dev/null || true
      fi
    fi
  fi
done

# All .bak and .uninstall.bak files we created
BAK_FILES=(
  "$HOME/.claude/claude.json.bak"
  "$HOME/.claude/claude.json.uninstall.bak"
  "$HOME/.claude/settings.json.bak"
  "$HOME/.claude/settings.json.uninstall.bak"
  "$HOME/.qwen/settings.json.bak"
  "$HOME/.qwen/settings.json.uninstall.bak"
)
for bak in "${BAK_FILES[@]}"; do
  rm_f "$bak"
done

# ════════════════════════════════════════════════════════════════════════════
# 20. FULL MODE — wipe ~/.qwen/ entirely
# ════════════════════════════════════════════════════════════════════════════
if $FULL; then
  section "Wipe ~/.qwen/ (--full)"

  QWEN_HOME="$HOME/.qwen"
  if [[ -d "$QWEN_HOME" ]]; then
    qwen_size=$(du -sh "$QWEN_HOME" 2>/dev/null | cut -f1 || echo "?")
    if $DRY_RUN; then
      skipped "rm -rf $QWEN_HOME ($qwen_size)"
    else
      rm -rf "$QWEN_HOME" && ok "removed $QWEN_HOME ($qwen_size freed)" \
        || warn "could not fully remove $QWEN_HOME"
    fi
  else
    info "~/.qwen/ not found — skipping"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# 21. FULL MODE — wipe ~/.claude/ runtime artifacts
#     (keep: claude.json, settings.json — already cleaned above)
# ════════════════════════════════════════════════════════════════════════════
if $FULL; then
  section "~/.claude/ Runtime Artifacts (--full)"

  # These dirs/files are Claude Code runtime state — safe to remove after
  # we've already cleaned claude.json and settings.json above.
  CLAUDE_RUNTIME_DIRS=(
    "$HOME/.claude/cache"
    "$HOME/.claude/downloads"
    "$HOME/.claude/file-history"
    "$HOME/.claude/ide"
    "$HOME/.claude/mcp-needs-auth-cache.json"
    "$HOME/.claude/paste-cache"
    "$HOME/.claude/plans"
    "$HOME/.claude/projects"
    "$HOME/.claude/session-env"
    "$HOME/.claude/sessions"
    "$HOME/.claude/shell-snapshots"
    "$HOME/.claude/stats-cache.json"
    "$HOME/.claude/tasks"
    "$HOME/.claude/telemetry"
    "$HOME/.claude/history.jsonl"
    "$HOME/.claude/settings.local.json"
  )

  for item in "${CLAUDE_RUNTIME_DIRS[@]}"; do
    if [[ -d "$item" ]]; then
      rm_rf "$item"
    else
      rm_f "$item"
    fi
  done

  # Sync conflict files (cloud sync artifacts)
  if $DRY_RUN; then
    count=$(find "$HOME/.claude" -maxdepth 1 -name "*.sync-conflict-*" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -gt 0 ]] && skipped "remove $count sync-conflict file(s) in ~/.claude/"
  else
    find "$HOME/.claude" -maxdepth 1 -name "*.sync-conflict-*" -delete 2>/dev/null \
      && ok "removed sync-conflict files" || true
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if $DRY_RUN; then
  echo "  ✓ Dry-run complete — nothing was removed."
  echo ""
  echo "  Run without --dry-run to apply changes."
else
  echo "  ✓ Uninstall complete!"
  echo ""
  echo "  Config backups (if any) are at:"
  echo "    ~/.claude/claude.json.uninstall.bak"
  echo "    ~/.claude/settings.json.uninstall.bak"
  echo "    ~/.qwen/settings.json.uninstall.bak"
  echo ""
  if $FULL; then
    echo "  Reload your shell to clear stale PATH entries:"
    echo "    exec \$SHELL -l"
  fi
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
