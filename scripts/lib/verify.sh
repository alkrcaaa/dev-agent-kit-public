#!/usr/bin/env bash
# sourced — not executed directly
#
# Post-install verification. Individual steps are deliberately non-fatal (an
# optional package must not abort the run), which means a partial install used
# to end on "✓ Installation complete!" while MCPs were silently missing. This
# checks the artifacts that actually matter and reports them loudly.

# Servers that only exist on some hosts: absent is normal, never an error.
#   qwen  — requires a reachable vLLM host

_verify_mcp_registered() {
  local name="$1"
  python3 - "$HOME/.claude/claude.json" "$name" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(0 if sys.argv[2] in cfg.get('mcpServers', {}) else 1)
PYEOF
}

_verify_antigravity_mcp_registered() {
  local name="$1"
  python3 - "${ANTIGRAVITY_CONFIG_DIR:-$HOME/.gemini/config}/mcp_config.json" "$name" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(0 if sys.argv[2] in cfg.get('mcpServers', {}) else 1)
PYEOF
}

# Prints "<hooks> <dangling>" for one host's hook file: how many hook commands
# it registers, and how many of those name a script that does not exist.
# A dangling hook is the silent kind -- the kit wires optional hooks as
# `[ -f "$H" ] && ... || true`, so a missing script is a no-op, not an error. $2=hooks reads the top-level "hooks" key (Claude, Qwen); $2=root
# walks the whole file (Antigravity's hooks.json).
_verify_hook_counts() {
  python3 - "$1" "$2" <<'PYEOF' 2>/dev/null || echo "0 0 "
import json, os, re, sys
path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    print("0 0 "); sys.exit(0)
root = cfg.get("hooks", {}) if mode == "hooks" else cfg
cmds = []
def walk(node):
    if isinstance(node, dict):
        if isinstance(node.get("command"), str):
            cmds.append(node["command"])
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)
walk(root)
home = os.path.expanduser("~")
script = re.compile(r'(?:\$HOME|\$\{HOME\}|~)(/[^\s"\';|&]+\.(?:py|sh|mjs|js))')
dangling, names = 0, set()
for c in cmds:
    for rel in script.findall(c):
        # An empty bridge submodule is reported once, as a warning, by
        # _verify_vault_env / _warn_empty_submodules -- not as N failures here.
        if "/obsidian-vault-bridge/" in rel:
            continue
        if not os.path.isfile(home + rel):
            dangling += 1
            names.add("~" + rel)
print(len(cmds), dangling, ",".join(sorted(names)))
PYEOF
}

# Per-host hook report. A host counts as installed when its CLI is on PATH or
# its config dir exists; an installed host with 0 hooks is a failed install.
# Appends to the caller's `missing` array (bash locals are dynamically scoped;
# no `local -n`, which macOS's bash 3.2 lacks).
_verify_hooks() {
  local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local qwen_dir="${QWEN_CONFIG_DIR:-$HOME/.qwen}"
  local ag_dir="${ANTIGRAVITY_CONFIG_DIR:-$HOME/.gemini/config}"
  local spec host cli dir file mode n dangling names s
  for spec in "Claude|claude|$claude_dir|$claude_dir/settings.json|hooks" \
              "Qwen|qwen|$qwen_dir|$qwen_dir/settings.json|hooks" \
              "Antigravity|agy|$ag_dir|$ag_dir/hooks.json|root"; do
    IFS='|' read -r host cli dir file mode <<<"$spec"
    if ! command -v "$cli" &>/dev/null && [[ ! -d "$dir" ]]; then
      info "$host: not installed — hook check skipped"
      continue
    fi
    read -r n dangling names <<<"$(_verify_hook_counts "$file" "$mode")"
    if [[ "${n:-0}" -eq 0 ]]; then
      warn "MISSING: $host hooks — 0 registered in $file"
      missing+=("hooks:$host")
    elif [[ "$dangling" -gt 0 ]]; then
      warn "$host hooks: $n registered, $dangling point at a script that does not exist (silent no-ops):"
      for s in ${names//,/ }; do warn "    $s"; done
      missing+=("hooks:$host ($dangling dangling)")
    else
      ok "$host hooks: $n registered ($file)"
    fi
  done
}

# vault.env is what the bridge hooks read when the agent's own env lacks the
# vault variables. Report what it holds. Everything here is a warning, never a
# failure: running without a vault is a valid setup.
_verify_vault_env() {
  local conf="$HOME/.config/dev-agent-kit/vault.env"
  if [[ ! -f "$REPO_ROOT/extern/obsidian-vault-bridge/hooks/obsidian-mirror.py" ]]; then
    warn "VAULT BRIDGE ABSENT: extern/obsidian-vault-bridge is empty — obsidian-mirror and vault hooks are OFF"
    warn "  fix: git -C $REPO_ROOT submodule update --init extern/obsidian-vault-bridge; bash install.sh"
    return 0
  fi
  if [[ ! -f "$conf" ]]; then
    warn "vault.env: not written — VAULT_DIR and MEM_OBSIDIAN_VAULT unset, vault hooks OFF (see the warning above)"
    return 0
  fi
  local v
  for v in VAULT_DIR MEM_OBSIDIAN_VAULT; do
    if grep -q "^$v=" "$conf"; then
      ok "vault.env: $(grep "^$v=" "$conf" | head -1)"
    else
      warn "vault.env: $v not set — add $v=... to $REPO_ROOT/.env and re-run install.sh"
    fi
  done
}

verify_install() {
  section "Verification"

  local missing=()

  _verify_hooks

  # binary/file artifacts: label|test-path
  local checks=(
    "claude CLI|command:claude"
    "code-review-graph|command:code-review-graph"
    "mcp-fetch-server|command:mcp-fetch-server"
    "claude-mem-lite|file:$HOME/.claude-mem-lite/server.mjs"
    "deployed skills|dir:$HOME/.claude/skills"
    # A symlink into the clone, not a copy — the submodules under it have to
    # stay attached to their repo. `dir:` fails on a dangling link, which is
    # what a moved or deleted clone leaves behind, and which otherwise shows
    # up much later as skills that load but arrive empty.
    "extern skills (symlink into the clone)|dir:$HOME/.claude/extern"
  )

  # LSP is opt-in; only demand its artifacts when it was actually requested,
  # otherwise a deliberate skip reports as a broken install.
  if [[ "${ENABLE_LSP:-0}" == "1" ]]; then
    checks+=(
      "lsp-mcp-server|command:lsp-mcp-server"
      "lsp-coercion-proxy|file:$HOME/.local/bin/lsp-coercion-proxy"
    )
  fi

  local entry label kind target
  for entry in "${checks[@]}"; do
    label="${entry%%|*}"
    kind="${entry#*|}"
    target="${kind#*:}"
    kind="${kind%%:*}"

    case "$kind" in
      command) command -v "$target" &>/dev/null ;;
      file)    [[ -f "$target" ]] ;;
      dir)     [[ -d "$target" ]] ;;
    esac && ok "$label" || { warn "MISSING: $label"; missing+=("$label"); }
  done

  # MCP registrations in ~/.claude/claude.json
  local mcp
  local required_mcp=(code-review-graph playwright fetch mem-lite)
  [[ "${ENABLE_LSP:-0}" == "1" ]] && required_mcp+=(lsp)
  for mcp in "${required_mcp[@]}"; do
    if _verify_mcp_registered "$mcp"; then
      ok "MCP registered: $mcp"
    else
      warn "MISSING: MCP not registered: $mcp"
      missing+=("mcp:$mcp")
    fi
  done

  # Host-conditional — report status, never fail the run
  # The Qwen server registers as local-model (mcp-infra/local-model-mcp);
  # checking for "qwen" reported it missing on every install that had it.
  for mcp in local-model GitLab; do
    _verify_mcp_registered "$mcp" && ok "MCP registered: $mcp" \
      || info "$mcp not registered (host-conditional — vLLM/GitLab URL absent)"
  done

  # Antigravity (agy) — optional host, like LSP: only demand its artifacts if
  # the CLI is actually installed, otherwise a machine without it reports a
  # broken install for a component that was never supposed to be there.
  if command -v agy &>/dev/null; then
    local ag_home="${ANTIGRAVITY_HOME_DIR:-$HOME/.gemini}"
    local ag_config="${ANTIGRAVITY_CONFIG_DIR:-$HOME/.gemini/config}"
    local ag_checks=(
      "antigravity GEMINI.md|file:$ag_home/GEMINI.md"
      "antigravity AGENTS.md|file:$ag_config/AGENTS.md"
      "antigravity hooks.json|file:$ag_config/hooks.json"
      "antigravity agents|dir:$ag_config/agents"
      "antigravity skills|dir:$ag_config/skills"
    )
    for entry in "${ag_checks[@]}"; do
      label="${entry%%|*}"
      kind="${entry#*|}"
      target="${kind#*:}"
      kind="${kind%%:*}"
      case "$kind" in
        file) [[ -f "$target" ]] ;;
        dir)  [[ -d "$target" ]] ;;
      esac && ok "$label" || { warn "MISSING: $label"; missing+=("$label"); }
    done

    for mcp in code-review-graph playwright fetch mem-lite; do
      if _verify_antigravity_mcp_registered "$mcp"; then
        ok "Antigravity MCP registered: $mcp"
      else
        warn "MISSING: Antigravity MCP not registered: $mcp"
        missing+=("antigravity-mcp:$mcp")
      fi
    done
    for mcp in local-model GitLab vault-search; do
      _verify_antigravity_mcp_registered "$mcp" && ok "Antigravity MCP registered: $mcp" \
        || info "Antigravity: $mcp not registered (host-conditional)"
    done
  else
    info "agy (Antigravity CLI) not installed — Antigravity checks skipped"
  fi

  # Last on purpose: these are the warnings that must not scroll away above
  # the final banner.
  declare -F _warn_empty_submodules &>/dev/null && _warn_empty_submodules
  _verify_vault_env

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}${BOLD}Installation INCOMPLETE — ${#missing[@]} item(s) missing:${RESET}"
    local m
    for m in "${missing[@]}"; do
      echo -e "    ${RED}✗${RESET} $m"
    done
    echo ""
    echo "  Scroll up for the failing step, or re-run: bash install.sh 2>&1 | tee /tmp/dak-install.log"
    return 1
  fi

  ok "all components verified"
  return 0
}
