#!/usr/bin/env bash
# sourced — not executed directly
# Public: setup_mcp_servers(vllm_host)


_crg_works() {
    command -v code-review-graph &>/dev/null && code-review-graph --version &>/dev/null
}

_setup_code_review_graph() {
    local crg_src="$REPO_ROOT/mcp-infra/code-review-graph"

    if [[ ! -d "$crg_src" ]]; then
        warn "code-review-graph submodule not found ($crg_src) — did you run git submodule init?"
        return 1
    fi

    if command -v uv &>/dev/null; then
        # uv has its own resolver — immune to system pip version issues
        if _crg_works; then
            info "updating code-review-graph..."
            run_bounded 600 uv tool upgrade code-review-graph 2>/dev/null || warn "upgrade skipped, continuing"
        else
            uv tool uninstall code-review-graph 2>/dev/null || true
            run_bounded 900 uv tool install "$crg_src" \
                || { warn "code-review-graph install failed or timed out (900s)"; return 1; }
        fi
    elif command -v pipx &>/dev/null; then
        # Upgrade pip first — old pip (Ubuntu 20.04 ships pip 20.x) can't parse modern metadata
        python3 -m pip install --upgrade pip -q --break-system-packages 2>/dev/null \
            || python3 -m pip install --upgrade pip -q --user 2>/dev/null \
            || true
        if _crg_works; then
            info "updating code-review-graph..."
            run_bounded 600 pipx upgrade code-review-graph 2>/dev/null || warn "upgrade skipped, continuing"
        else
            pipx uninstall code-review-graph 2>/dev/null || true
            run_bounded 900 pipx install --force "$crg_src" \
                || { warn "code-review-graph install failed or timed out (900s)"; return 1; }
        fi
    else
        if command -v code-review-graph &>/dev/null && _crg_works; then
            ok "code-review-graph is working, upgrade skipped (no uv/pipx)"
            return
        fi
        warn "uv and pipx not found — installing via pip --user..."
        python3 -m pip install --upgrade pip -q --user 2>/dev/null || true
        run_bounded 900 python3 -m pip install --user "$crg_src" --quiet --break-system-packages \
            || run_bounded 900 python3 -m pip install --user "$crg_src" --quiet \
            || { warn "code-review-graph pip install failed or timed out"; return 1; }
        ensure_local_bin_on_path
    fi
    ok "code-review-graph installed"

    # Embeddings backend for semantic_search_nodes / embed_graph_tool — without
    # it the graph builds but semantic search fails at query time.
    # Pulls torch (GBs) — the slowest download in the kit. Bounded, and
    # DAK_SKIP_EMBEDDINGS=1 skips it on a slow link (semantic search only).
    if [[ -n "${DAK_SKIP_EMBEDDINGS:-}" ]]; then
        warn "sentence-transformers skipped (DAK_SKIP_EMBEDDINGS set) — semantic search unavailable"
    elif ! "$HOME/.local/share/pipx/venvs/code-review-graph/bin/python" \
            -c 'import sentence_transformers' 2>/dev/null \
       && ! "$HOME/.local/share/uv/tools/code-review-graph/bin/python" \
            -c 'import sentence_transformers' 2>/dev/null; then
        info "injecting sentence-transformers (embeddings for semantic search)..."
        if command -v uv &>/dev/null && [[ -d "$HOME/.local/share/uv/tools/code-review-graph" ]]; then
            # --force removes the working install first; if the torch download
            # then fails, put the plain install back or crg-daemon is gone.
            run_bounded 1800 uv tool install --force --with sentence-transformers "$crg_src" 2>/dev/null \
                || { warn "sentence-transformers inject failed — semantic search will be unavailable"
                     _crg_works || run_bounded 900 uv tool install --force "$crg_src" \
                         || warn "code-review-graph reinstall failed"; }
        elif command -v pipx &>/dev/null; then
            run_bounded 1800 pipx inject code-review-graph sentence-transformers 2>/dev/null \
                || warn "sentence-transformers inject failed — semantic search will be unavailable"
        fi
    fi

    # MCP config is written to global claude.json by _configure_claude_json (no cwd — auto-detects project root)
    # No per-project .mcp.json needed.

    info "Adding project to crg-daemon watch list..."
    crg-daemon add "$REPO_ROOT" 2>/dev/null || true
    ok "crg-daemon: $REPO_ROOT added"

    if ! crg-daemon status &>/dev/null 2>&1; then
        info "starting crg-daemon..."
        run_bounded 60 crg-daemon start && ok "crg-daemon started" \
            || warn "crg-daemon did not start — run: crg-daemon start"
    else
        ok "crg-daemon already running"
    fi

    if [[ ! -f "$REPO_ROOT/.code-review-graph/graph.db" ]]; then
        info "Starting initial graph build (background)..."
        (cd "$REPO_ROOT" && code-review-graph build > /dev/null 2>&1) &
        ok "graph build running in background"
    else
        ok "graph.db exists, build skipped"
    fi
}

_setup_playwright() {
    case "$OS" in
        mac)
            ok "macOS — no system dependencies needed"
            ;;
        arch)
            if sudo -n true 2>/dev/null; then
                info "Arch: installing chromium system dependencies..."
                sudo pacman -S --noconfirm --needed \
                    nss nspr atk at-spi2-atk libxkbcommon \
                    libxcomposite libxdamage libxrandr libxshmfence \
                    libdrm mesa alsa-lib 2>/dev/null || true
                ok "Arch system dependencies ready"
            else
                warn "Arch: no sudo — system dependencies skipped."
            fi
            ;;
        ubuntu)
            if sudo -n true 2>/dev/null; then
                info "Ubuntu: installing chromium system dependencies..."
                apt_get install -y --no-install-recommends \
                    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
                    libcups2 libdrm2 libxkbcommon0 libxcomposite1 \
                    libxdamage1 libxrandr2 libgbm1 libxshmfence1 \
                    libasound2 2>/dev/null || \
                apt_get install -y --no-install-recommends \
                    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
                    libcups2 libdrm2 libxkbcommon0 libxcomposite1 \
                    libxdamage1 libxrandr2 libgbm1 libxshmfence1 \
                    libasound2t64 2>/dev/null || true
                ok "Ubuntu system dependencies ready"
            else
                warn "Ubuntu: no sudo — system dependencies skipped."
            fi
            ;;
        fedora)
            if sudo -n true 2>/dev/null; then
                info "Fedora: installing chromium system dependencies..."
                sudo dnf install -y nss nspr atk at-spi2-atk libxkbcommon \
                    libXcomposite libXdamage libXrandr libX11-xcb \
                    libdrm mesa-libgbm alsa-lib 2>/dev/null || true
                ok "Fedora system dependencies ready"
            else
                warn "Fedora: no sudo — system dependencies skipped."
            fi
            ;;
    esac

    # The chromium download (~150MB from a CDN) is the step that has hung a
    # whole install. Bounded, skippable, and never fatal: the MCP still
    # registers, and @playwright/mcp fetches a browser on first use anyway.
    if [[ -n "${DAK_SKIP_PLAYWRIGHT_BROWSER:-}" ]]; then
        warn "Playwright chromium download skipped (DAK_SKIP_PLAYWRIGHT_BROWSER set) — later: npx --yes playwright install chromium"
        return 0
    fi
    local pw_timeout="${DAK_PLAYWRIGHT_TIMEOUT:-600}"
    info "Playwright chromium browser downloading (max ${pw_timeout}s; DAK_SKIP_PLAYWRIGHT_BROWSER=1 skips)..."
    # --yes: without it npx waits on a hidden "Ok to proceed?" prompt when
    # playwright is not in the npx cache. install is idempotent, so run it once.
    local rc=0
    run_bounded "$pw_timeout" npx --yes playwright install chromium || rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "Playwright chromium ready (~/.cache/ms-playwright)"
    elif [[ $rc -eq 124 || $rc -eq 137 ]]; then
        warn "Playwright chromium download TIMED OUT after ${pw_timeout}s — continuing; retry: npx --yes playwright install chromium"
    else
        warn "Playwright chromium install failed (exit $rc) — retry: npx --yes playwright install chromium"
    fi
}

_setup_local_model_mcp() {
    local vllm_host="$1"
    local lm_dir="$REPO_ROOT/mcp-infra/local-model-mcp"

    if [[ ! -d "$lm_dir" ]]; then
        warn "local-model-mcp directory not found at $lm_dir — skipping (git submodule not checked out? try: git submodule update --init)"
        return
    fi

    info "Setting up local-model-mcp venv..."
    run_bounded 900 bash "$lm_dir/install.sh" \
        || { warn "local-model-mcp install failed or timed out (900s)"; return 1; }
    ok "local-model-mcp venv ready ($lm_dir/.venv)"
}

_setup_vault_search() {
    local vault_dir="${1:-}"
    local vs_dir="$REPO_ROOT/extern/obsidian-vault-bridge/mcp-infra/vault-search"

    # No vault to search means no server to register (see _configure_*_json),
    # so there is no venv worth building either.
    if [[ -z "$vault_dir" ]]; then
        info "vault-search skipped (VAULT_DIR unset)"
        return
    fi

    if [[ ! -d "$vs_dir" ]]; then
        warn "vault-search directory not found at $vs_dir — skipping"
        return
    fi

    info "Setting up vault-search MCP Server venv..."
    run_bounded 900 bash "$vs_dir/install.sh" --vault-dir "$vault_dir" \
        || { warn "vault-search install failed or timed out (900s)"; return 1; }
    ok "vault-search MCP Server venv ready ($vs_dir/.venv)"
}

_setup_llm_council() {
    local council_dir="$REPO_ROOT/mcp-infra/llm-council-mcp"
    if [[ -d "$council_dir/mcp" ]]; then
        council_dir="$council_dir/mcp"
    fi

    if [[ ! -d "$council_dir" ]]; then
        warn "llm-council directory not found at $council_dir — skipping"
        return
    fi

    info "Setting up llm-council MCP Server venv..."
    run_bounded 900 bash "$council_dir/install.sh" \
        || { warn "llm-council install failed or timed out (900s)"; return 1; }
    ok "llm-council MCP Server venv ready ($council_dir/.venv)"
}

# Render one council shim unit. Kept separate from _setup_council_shims so the
# unit text can be tested without systemd.
#   $1 unit label  $2 env prefix (CLAUDE|ANTIGRAVITY)  $3 shim script  $4 council root  $5 bind host
_council_shim_unit() {
    local label="$1" prefix="$2" script="$3" root="$4" host="$5"
    cat <<EOF
[Unit]
Description=llm-council ${label} shim (dev-agent-kit)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${root}
# Same file the backend container reads via env_file: one copy of the shim secret.
EnvironmentFile=${root}/.env
Environment=${prefix}_SHIM_HOST=${host}
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
# Without this the shim's print() output never reaches journalctl.
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/env python3 ${root}/infra/local-models/${script}
# docker0 may not exist yet at login; retry until the bind address appears.
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
EOF
}

# The council's local seats (Claude Code, Antigravity) are host processes that the
# backend container reaches through host.docker.internal. They are optional:
# skipped unless systemd --user, the CLI, and a real shim secret are all present.
_setup_council_shims() {
    local root="$REPO_ROOT/mcp-infra/llm-council-mcp"
    local unit_dir="$HOME/.config/systemd/user"

    if ! command -v systemctl &>/dev/null || ! systemctl --user show-environment &>/dev/null; then
        warn "llm-council shims: systemd --user unavailable — skipping"
        return 0
    fi
    if [[ ! -f "$root/.env" ]]; then
        warn "llm-council shims: $root/.env missing — skipping (copy .env.example and set the shim secrets)"
        return 0
    fi

    # Bind to the docker bridge gateway: reachable from the backend container as
    # host.docker.internal, not from the LAN. Without docker, loopback.
    local host="127.0.0.1"
    if command -v docker &>/dev/null; then
        host="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
        [[ -n "$host" ]] || host="127.0.0.1"
    fi

    mkdir -p "$unit_dir"
    local spec label prefix script cli unit changed=0
    for spec in "claude-code:CLAUDE:claude_code_shim.py:claude" "antigravity:ANTIGRAVITY:antigravity_shim.py:agy"; do
        IFS=: read -r label prefix script cli <<<"$spec"
        unit="llm-council-${label}-shim.service"
        if ! command -v "$cli" &>/dev/null; then
            warn "llm-council shims: '$cli' not on PATH — $unit skipped"
            continue
        fi
        if ! grep -Eq "^${prefix}_SHIM_SECRET=.{16,}" "$root/.env"; then
            warn "llm-council shims: ${prefix}_SHIM_SECRET unset or too short in $root/.env — $unit skipped"
            continue
        fi
        local rendered
        rendered="$(_council_shim_unit "$label" "$prefix" "$script" "$root" "$host")"
        if [[ ! -f "$unit_dir/$unit" ]] || [[ "$(cat "$unit_dir/$unit")" != "$rendered" ]]; then
            printf '%s\n' "$rendered" > "$unit_dir/$unit"
            changed=1
        fi
    done

    # Restart only when a unit changed: a restart kills any deliberation in flight.
    local action="start"
    if [[ "$changed" == 1 ]]; then
        systemctl --user daemon-reload
        action="restart"
    fi
    for label in claude-code antigravity; do
        unit="llm-council-${label}-shim.service"
        [[ -f "$unit_dir/$unit" ]] || continue
        if systemctl --user enable "$unit" &>/dev/null && systemctl --user "$action" "$unit"; then
            ok "llm-council shim: $unit (bind $host)"
        else
            warn "llm-council shim: $unit failed to start — journalctl --user -u $unit"
        fi
    done
}

# Claude Code reads ~/.claude.json; every writer in this kit targets
# ~/.claude/claude.json. On the machine this kit grew up on those are one file
# via a hand-made symlink, which is why the split never surfaced. A fresh
# machine has no such link: the MCPs registered here stay invisible to Claude
# Code, and verify_install happily inspects the file nobody reads. Make them
# one file before anything writes to either.
_ensure_claude_json_link() {
    local real="$HOME/.claude/claude.json"
    local link="$HOME/.claude.json"

    mkdir -p "$HOME/.claude"

    # Already the same file — the common case on an established machine.
    if [[ -e "$link" && -e "$real" && "$(readlink -f "$link")" == "$(readlink -f "$real")" ]]; then
        ok "claude.json: ~/.claude.json and ~/.claude/claude.json are one file"
        return 0
    fi

    # Claude Code got there first with a real file: adopt it as canonical, so
    # its auth and project state survive. Any separate copy of ours is kept as
    # a backup — _configure_claude_json re-adds the MCP entries right after.
    if [[ -f "$link" && ! -L "$link" ]]; then
        if [[ -f "$real" ]]; then
            local backup
            backup="$real.split.$(date +%s).bak"
            mv "$real" "$backup"
            warn "two separate claude.json files existed — kept Claude Code's, backed up ours: $backup"
        fi
        mv "$link" "$real"
    fi

    [[ -f "$real" ]] || echo '{"mcpServers":{}}' > "$real"

    ln -sfn "$real" "$link"
    ok "claude.json: ~/.claude.json → $real"
}

_configure_claude_json() {
    local vllm_host="${1:-}"
    local gitlab_url="${2:-}"
    local claude_json="$HOME/.claude/claude.json"

    if [[ ! -f "$claude_json" ]]; then
        warn "claude.json not found, creating..."
        mkdir -p "$(dirname "$claude_json")"
        echo '{"mcpServers":{}}' > "$claude_json"
    fi

    info "updating claude.json..."

    python3 - "$claude_json" "$OS" "$vllm_host" "$REPO_ROOT" "$gitlab_url" <<'PYEOF'
import json, os, shutil, sys

config_path, os_type, vllm_host, repo_root, gitlab_url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

with open(config_path, 'r') as f:
    config = json.load(f)

config.setdefault('mcpServers', {})

# playwright: HTTP → stdio
args = ["@playwright/mcp@latest", "--headless"]
if os_type != "mac":
    args.append("--no-sandbox")

config['mcpServers']['playwright'] = {
    "command": "npx",
    "args": args
}

# local-model MCP (only when vllm_host is set)
if config['mcpServers'].pop('qwen', None):
    print("  ✗ removed stale 'qwen' entry (renamed to local-model)")
if vllm_host:
    venv_python = f"{repo_root}/mcp-infra/local-model-mcp/.venv/bin/python"
    server_py = f"{repo_root}/mcp-infra/local-model-mcp/server.py"
    config['mcpServers']['local-model'] = {
        "command": venv_python,
        "args": [server_py],
        "env": {"MODEL_BASE_URL": vllm_host}
    }
    print(f"  ✓ local-model → {venv_python} (MODEL_BASE_URL={vllm_host})")

# mcp-fetch-server (if installed)
if shutil.which('mcp-fetch-server'):
    config['mcpServers']['fetch'] = {"command": "mcp-fetch-server"}
    print("  ✓ fetch → mcp-fetch-server (stdio)")

# lsp: opt-in only (ENABLE_LSP=1). Measured at 1 call in ~35k fleet-wide;
# the graph covers navigation. When off, actively drop any entry a previous
# install left behind — otherwise its tool schemas keep loading every session.
if os.environ.get("ENABLE_LSP") == "1":
    proxy_bin = os.path.join(os.path.expanduser("~"), ".local", "bin", "lsp-coercion-proxy")
    if os.path.exists(proxy_bin):
        config['mcpServers']['lsp'] = {"command": proxy_bin}
        print(f"  ✓ lsp → {proxy_bin} (stdio)")
    elif shutil.which('lsp-mcp-server'):
        config['mcpServers']['lsp'] = {"command": "lsp-mcp-server"}
        print("  ✓ lsp → lsp-mcp-server (stdio, no proxy)")
elif 'lsp' in config.get('mcpServers', {}):
    del config['mcpServers']['lsp']
    print("  ✗ lsp unregistered (ENABLE_LSP != 1) — graph covers navigation")

# code-review-graph: global stdio, no cwd — find_project_root() auto-detects from Claude's session dir.
# Each project's graph is isolated at <project>/.code-review-graph/graph.db
pipx_python = os.path.expanduser('~/.local/share/pipx/venvs/code-review-graph/bin/python')
if os.path.exists(pipx_python):
    config['mcpServers']['code-review-graph'] = {
        "command": pipx_python,
        "args": ["-m", "code_review_graph", "serve"]
    }
    print("  ✓ code-review-graph → stdio (pipx venv, global)")
elif shutil.which('code-review-graph'):
    config['mcpServers']['code-review-graph'] = {
        "command": "code-review-graph",
        "args": ["serve"]
    }
    print("  ✓ code-review-graph → stdio (PATH)")

# GitLab MCP: HTTP transport, OAuth (docs.gitlab.com/user/model_context_protocol)
if gitlab_url:
    config['mcpServers']['GitLab'] = {
        "type": "http",
        "url": f"{gitlab_url.rstrip('/')}/api/v4/mcp",
        "headers": {"X-Gitlab-Mcp-Server-Tool-Name-Prefix": "gitlab_"}
    }
    print(f"  ✓ GitLab → {gitlab_url}/api/v4/mcp (http, OAuth via /mcp on first use)")
elif config['mcpServers'].pop('GitLab', None):
    print("  ✗ GitLab unregistered (no GITLAB_URL)")

# Cleanup: leftover localhost HTTP entries from old kit installations.
# Touch only the kit's own keys — leave user-added HTTP servers
# (e.g., redmine) alone.
KIT_LEGACY_HTTP = ('lsp', 'fetch', 'code-review-graph', 'crg')
dead = [k for k, v in config['mcpServers'].items()
        if k in KIT_LEGACY_HTTP and isinstance(v, dict)
        and (v.get('type') == 'http' or 'url' in v)]

for key in dead:
    del config['mcpServers'][key]
    print(f"  ✗ removed (stale HTTP entry): {key}")

# Remove stale dev-agent-kit entry if lingering from old installs
if 'dev-agent-kit' in config.get('mcpServers', {}):
    del config['mcpServers']['dev-agent-kit']
    print("  ✗ removed stale dev-agent-kit entry (mcp-infra removed)")

# vault-search: Obsidian vault keyword + backlink search
vs_venv_python = f"{repo_root}/extern/obsidian-vault-bridge/mcp-infra/vault-search/.venv/bin/python"
vs_server_py = f"{repo_root}/extern/obsidian-vault-bridge/mcp-infra/vault-search/server.py"
# Opt-in on VAULT_DIR, the same way GitLab is opt-in on its token: without a
# vault every tool this server exposes can only answer "no vault directory",
# so registering it would spend three tool schemas of every session's context
# on something that cannot answer. Clear a stale entry when it goes unset.
vault_dir = os.environ.get("VAULT_DIR", "")
# The server scores notes under the raw mirror at half weight, so it needs to
# know where that mirror is. Inheriting it from the agent's process env worked
# only where a shell rc happened to export it; pass it explicitly, like
# VAULT_DIR, so the ranking does not quietly change with the launcher.
vs_env = {"VAULT_DIR": vault_dir}
if os.environ.get("MEM_OBSIDIAN_VAULT"):
    vs_env["MEM_OBSIDIAN_VAULT"] = os.environ["MEM_OBSIDIAN_VAULT"]
if vault_dir and os.path.exists(vs_venv_python):
    config['mcpServers']['vault-search'] = {
        "command": vs_venv_python,
        "args": [vs_server_py],
        "env": vs_env,
    }
    print(f"  ✓ vault-search → stdio (VAULT_DIR={vault_dir})")
elif config['mcpServers'].pop('vault-search', None):
    print("  ✗ vault-search unregistered (VAULT_DIR unset)")

# llm-council: deliberative oracle (port 8001 backend)
council_base = f"{repo_root}/mcp-infra/llm-council-mcp"
if os.path.isdir(f"{council_base}/mcp"):
    council_python = f"{council_base}/mcp/.venv/bin/python"
    council_server_py = f"{council_base}/mcp/server.py"
else:
    council_python = f"{council_base}/.venv/bin/python"
    council_server_py = f"{council_base}/server.py"
if os.path.exists(council_python) and os.path.exists(council_server_py):
    config['mcpServers']['llm-council'] = {
        "command": council_python,
        "args": [council_server_py],
        "timeout": 420000,
    }
    print("  ✓ llm-council → stdio (timeout=420s)")

# claude-mem-lite: self-registers via `claude mcp add` during its own install — skip here
# If already registered, preserve the entry; if not, that's OK (plugin not yet installed)
if 'claude-mem-lite' in config.get('mcpServers', {}):
    print("  ✓ claude-mem-lite → already registered (self-managed)")
elif 'memory' in config.get('mcpServers', {}):
    # Remove old memory-server entry if present
    del config['mcpServers']['memory']
    print("  ✗ removed stale memory-server entry (replaced by claude-mem-lite)")

shutil.copy2(config_path, config_path + ".bak")

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print(f"  ✓ playwright → stdio (npx @playwright/mcp@latest{' --no-sandbox' if os_type != 'mac' else ''})")
PYEOF

    ok "claude.json updated"
}

# The graph auto-build used to be an inline shell one-liner appended straight
# into each settings.json. It is now claude/hooks/crg-autobuild.py, deployed
# and wired through claude/settings.json + qwen/settings.json like every other
# hook. This function only migrates: an existing install still carries the old
# line, and leaving it would double every build — worse, the old one rebuilds
# on EVERY prompt whenever the session started below the repo root.
_install_crg_autobuild_hook() {
    local legacy='if git rev-parse --git-dir > /dev/null 2>&1 && [ ! -f .code-review-graph/graph.db ]; then code-review-graph build > /dev/null 2>&1 & fi'

    for settings in "$HOME/.claude/settings.json" "$HOME/.qwen/settings.json"; do
        [[ -f "$settings" ]] || continue
        python3 - "$settings" "$legacy" <<'PYEOF'
import json, sys

path, legacy = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)

removed = 0
hooks = cfg.get("hooks", {})
for event in list(hooks.keys()):
    before = len(hooks[event])
    hooks[event] = [
        e for e in hooks[event]
        if not any(h.get("command", "") == legacy for h in e.get("hooks", []))
    ]
    removed += before - len(hooks[event])
    if not hooks[event]:
        del hooks[event]
if removed:
    if not hooks:
        cfg.pop("hooks", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("  ✓ replaced legacy inline auto-build hook in %s" % path)
PYEOF
    done
}

_setup_playwright_http() {
    local port=8932
    local log_file="$HOME/.qwen/playwright-mcp.log"
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/playwright-mcp.service"
    local wrapper="$HOME/.local/bin/playwright-mcp-start"

    if port_in_use "$port"; then
        ok "Playwright MCP HTTP daemon already running on port $port"
        return
    fi

    mkdir -p "$(dirname "$wrapper")"
    cat > "$wrapper" <<'WRAPEOF'
#!/usr/bin/env bash
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
[[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
exec npx @playwright/mcp@latest --port 8932 --headless
WRAPEOF
    chmod +x "$wrapper"

    if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
        mkdir -p "$service_dir"
        cat > "$service_file" <<SVCEOF
[Unit]
Description=Playwright MCP HTTP Server
After=network.target

[Service]
ExecStart=${wrapper}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF

        info "creating systemd user service: playwright-mcp.service"
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable playwright-mcp 2>/dev/null && ok "playwright-mcp.service enabled" || warn "enable failed"
        # restart, not start: this branch only runs when the unit file was just
        # rewritten (e.g. the port changed). `start` no-ops on an already-active
        # unit, so the old process keeps running under the old ExecStart forever
        # -- every other config (wrapper, MCP registration) says the new port,
        # only the live daemon doesn't. Bit us on crg-mcp: stuck on port 7000
        # for 3 days after the port moved to 8931, "connection refused" downstream.
        systemctl --user restart playwright-mcp 2>/dev/null && ok "playwright-mcp.service started" || warn "start failed"
    else
        warn "systemd --user unavailable, starting with nohup..."
        mkdir -p "$(dirname "$log_file")"
        nohup "$wrapper" > "$log_file" 2>&1 &
        local pid=$!
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            ok "Playwright MCP HTTP daemon started (PID $pid, log: $log_file)"
        else
            warn "Playwright MCP HTTP daemon failed to start (log: $log_file)"
        fi
    fi
}

_configure_qwen_settings() {
    # Resolved at call time — see _configure_qwen_cli_env. Lets the remote
    # installer stage the tool allowlists and session caps for another host.
    local qwen_settings="${QWEN_CONFIG_DIR:-$HOME/.qwen}/settings.json"
    local repo_root="$REPO_ROOT"
    local gitlab_url="${1:-}"

    if [[ ! -f "$qwen_settings" ]]; then
        info "Qwen settings.json not found, creating..."
        mkdir -p "$(dirname "$qwen_settings")"
        echo '{"$version": 4}' > "$qwen_settings"
    fi

    info "updating Qwen settings.json..."

    python3 - "$qwen_settings" "$repo_root" "$gitlab_url" <<'PYEOF'
import json, shutil, sys, os

config_path, repo_root, gitlab_url = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_path, 'r') as f:
    config = json.load(f)

home = os.path.expanduser("~")
proxy_bin = os.path.join(home, ".local", "bin", "lsp-coercion-proxy")

# Tool allowlists, qwen-side only. Claude picks sensibly from a 30-tool menu;
# a 27B does not — every extra tool is one more way to choose wrong, and the
# schemas ride in the context window on every single call (measured 2026-08-09:
# 30 graph tools = ~7.9k tokens, 24 playwright tools = ~4.9k, against a 235k
# session limit). The lists are not hand-picked taste: the graph one is exactly
# the set the kit's own CLAUDE.md/QWEN.md/skills teach, so the menu and the
# guidance cannot drift apart. Playwright keeps that same referenced set plus
# what a form-driven flow actually needs to complete, and drops
# browser_run_code_unsafe along the way.
CRG_TOOLS = [
    "get_minimal_context_tool", "semantic_search_nodes_tool", "query_graph_tool",
    "detect_changes_tool", "get_review_context_tool", "get_impact_radius_tool",
    "get_affected_flows_tool", "list_flows_tool", "traverse_graph_tool",
    "get_architecture_overview_tool", "list_communities_tool",
    "get_bridge_nodes_tool", "refactor_tool",
]
PLAYWRIGHT_TOOLS = [
    "browser_navigate", "browser_snapshot", "browser_click", "browser_type",
    "browser_fill_form", "browser_select_option", "browser_press_key",
    "browser_wait_for", "browser_take_screenshot", "browser_console_messages",
    "browser_network_requests", "browser_find", "browser_evaluate",
    "browser_close",
]

config.setdefault("mcpServers", {})
config["mcpServers"]["code-review-graph"] = {
    "httpUrl": "http://localhost:8931/mcp",
    "includeTools": CRG_TOOLS,
}
config["mcpServers"]["playwright"] = {
    "httpUrl": "http://localhost:8932/mcp",
    "includeTools": PLAYWRIGHT_TOOLS,
}

# lsp: opt-in only (ENABLE_LSP=1); drop a stale entry when disabled.
if os.environ.get("ENABLE_LSP") != "1":
    if 'lsp' in config.get("mcpServers", {}):
        del config["mcpServers"]["lsp"]
        print("  ✗ lsp unregistered (ENABLE_LSP != 1)")
elif os.path.exists(proxy_bin):
    config["mcpServers"]["lsp"] = {"command": proxy_bin}
    print(f"  ✓ lsp → {proxy_bin} (stdio)")
elif shutil.which('lsp-mcp-server'):
    config["mcpServers"]["lsp"] = {"command": "lsp-mcp-server"}
    print("  ✓ lsp → lsp-mcp-server (stdio, no proxy)")
else:
    print("  ⚠ lsp skipped (neither proxy nor lsp-mcp-server found)")

config["mcpServers"]["fetch"] = {"httpUrl": "http://localhost:8935/mcp"}

# The `qwen` offload server is deliberately NOT mirrored here: handing qwen a
# tool that dispatches to qwen is a loop.
#
# GitLab needs a token here, unlike on Claude. Claude Code runs the interactive
# OAuth flow (`/mcp` once); Qwen Code has no such flow, so the endpoint answers
# 404 and the server fails to start on EVERY session — a permanent warning
# banner buying nothing. Register it only with a PAT (GITLAB_TOKEN in .env,
# scope: api), and clear a stale entry otherwise.
gitlab_token = os.environ.get("GITLAB_TOKEN", "").strip()
if gitlab_url and gitlab_token:
    config["mcpServers"]["GitLab"] = {
        "httpUrl": f"{gitlab_url.rstrip('/')}/api/v4/mcp",
        "headers": {
            "Authorization": f"Bearer {gitlab_token}",
            "X-Gitlab-Mcp-Server-Tool-Name-Prefix": "gitlab_",
        },
    }
    print(f"  ✓ GitLab → {gitlab_url}/api/v4/mcp (http, PAT auth)")
else:
    if config["mcpServers"].pop("GitLab", None):
        print("  ✗ GitLab unregistered from qwen (no GITLAB_TOKEN)")
    elif gitlab_url:
        print("  ⚠ GitLab skipped for qwen — set GITLAB_TOKEN in .env "
              "(qwen has no OAuth flow; Claude keeps using OAuth)")

# Remove stale dev-agent-kit entry if lingering
if 'dev-agent-kit' in config.get('mcpServers', {}):
    del config['mcpServers']['dev-agent-kit']
    print("  ✗ removed stale dev-agent-kit entry from qwen settings")

# Remove old custom memory-server entry if lingering (replaced by claude-mem-lite)
if 'memory' in config.get('mcpServers', {}):
    del config['mcpServers']['memory']
    print("  ✗ removed stale memory-server entry from qwen settings")

# vault-search: Obsidian vault keyword + backlink search
vs_venv_python = os.path.join(repo_root, "extern", "obsidian-vault-bridge", "mcp-infra", "vault-search", ".venv", "bin", "python")
vs_server_py = os.path.join(repo_root, "extern", "obsidian-vault-bridge", "mcp-infra", "vault-search", "server.py")
vault_dir = os.environ.get("VAULT_DIR", "")
# Same as the Claude side: the raw mirror's location decides half-weight
# scoring, so it is passed explicitly rather than inherited from the launcher.
vs_env = {"VAULT_DIR": vault_dir}
if os.environ.get("MEM_OBSIDIAN_VAULT"):
    vs_env["MEM_OBSIDIAN_VAULT"] = os.environ["MEM_OBSIDIAN_VAULT"]
if vault_dir and os.path.exists(vs_venv_python):
    config["mcpServers"]["vault-search"] = {
        "command": vs_venv_python,
        "args": [vs_server_py],
        "env": vs_env,
    }
    print(f"  ✓ vault-search → stdio (VAULT_DIR={vault_dir})")
elif config["mcpServers"].pop("vault-search", None):
    print("  ✗ vault-search unregistered from qwen (VAULT_DIR unset)")

# Register claude-mem-lite for qwen too — shared project-scoped memory DB with
# Claude. The auto-injection hooks run here as well now (qwen/settings.json,
# via mem-bridge.py), so qwen gets the same startup dashboard and pre-edit
# recall; the mem_* tools remain for explicit saves.
mem_server = os.path.join(home, ".claude-mem-lite", "server.mjs")
if os.path.exists(mem_server):
    config["mcpServers"]["mem-lite"] = {"command": "node", "args": [mem_server], "env": {}}
    print("  ✓ mem-lite → claude-mem-lite/server.mjs (stdio, shared DB)")
else:
    config["mcpServers"].pop("mem-lite", None)
    print("  ⚠ mem-lite skipped (claude-mem-lite not installed yet)")

# Graph auto-build is wired through qwen/settings.json now (crg-autobuild.py),
# alongside the rest of the enforcement hooks — nothing to append here.

shutil.copy2(config_path, config_path + ".bak")

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print("  ✓ code-review-graph → http://localhost:8931/mcp")
print("  ✓ playwright → http://localhost:8932/mcp")
print("  ✓ fetch → http://localhost:8935/mcp")

PYEOF

    ok "Qwen settings.json updated"
}

# Antigravity's MCP config is a dedicated mcp_config.json (not a sub-key of a
# shared settings.json like Qwen/Claude) — see antigravity/AGENTS.md, which
# assumes these servers are present. Unlike
# Qwen, no includeTools trimming: that trimming exists specifically for the
# 27B model's context ceiling (see CLAUDE.md "Tool menus are trimmed on Qwen
# only"), which does not apply to Antigravity's Gemini 3 Pro.
_configure_antigravity_mcp() {
    local ag_config="${ANTIGRAVITY_CONFIG_DIR:-$HOME/.gemini/config}/mcp_config.json"
    local repo_root="$REPO_ROOT"
    local gitlab_url="${1:-}"
    local vllm_host="${2:-}"

    # This config is global (read from any workspace Antigravity opens), so a
    # relative repo_root here writes commands that only resolve by accident
    # when the active workspace happens to be this repo — and fail silently
    # (fork/exec ... no such file or directory) everywhere else.
    if [[ "$repo_root" != /* ]]; then
        warn "REPO_ROOT is not set to an absolute path (got: '${repo_root}') — refusing to write Antigravity mcp_config.json with relative commands"
        return 1
    fi

    mkdir -p "$(dirname "$ag_config")"
    if [[ ! -f "$ag_config" ]]; then
        info "Antigravity mcp_config.json not found, creating..."
        echo '{}' > "$ag_config"
    fi

    info "updating Antigravity mcp_config.json..."

    python3 - "$ag_config" "$repo_root" "$gitlab_url" "$vllm_host" <<'PYEOF'
import json, shutil, sys, os

config_path, repo_root, gitlab_url, vllm_host = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(config_path, 'r') as f:
    config = json.load(f) if os.path.getsize(config_path) else {}

home = os.path.expanduser("~")

config.setdefault("mcpServers", {})
config["mcpServers"]["code-review-graph"] = {"serverUrl": "http://localhost:8931/mcp"}
config["mcpServers"]["playwright"] = {"serverUrl": "http://localhost:8932/mcp"}
config["mcpServers"]["fetch"] = {"serverUrl": "http://localhost:8935/mcp"}

gitlab_token = os.environ.get("GITLAB_TOKEN", "").strip()
if gitlab_url and gitlab_token:
    config["mcpServers"]["GitLab"] = {
        "serverUrl": f"{gitlab_url.rstrip('/')}/api/v4/mcp",
        "headers": {
            "Authorization": f"Bearer {gitlab_token}",
            "X-Gitlab-Mcp-Server-Tool-Name-Prefix": "gitlab_",
        },
    }
    print(f"  ✓ GitLab → {gitlab_url}/api/v4/mcp (http, PAT auth)")
else:
    if config["mcpServers"].pop("GitLab", None):
        print("  ✗ GitLab unregistered from antigravity (no GITLAB_TOKEN)")

local_model_venv_python = os.path.join(repo_root, "mcp-infra", "local-model-mcp", ".venv", "bin", "python")
local_model_server_py = os.path.join(repo_root, "mcp-infra", "local-model-mcp", "server.py")
config["mcpServers"].pop("qwen", None)  # renamed to local-model
if vllm_host and os.path.exists(local_model_venv_python):
    config["mcpServers"]["local-model"] = {
        "command": local_model_venv_python,
        "args": [local_model_server_py],
        "env": {"MODEL_BASE_URL": vllm_host},
    }
    print(f"  ✓ local-model → {local_model_venv_python} (MODEL_BASE_URL={vllm_host})")
elif config["mcpServers"].pop("local-model", None):
    print("  ✗ local-model unregistered from antigravity (no vLLM host / venv missing)")

vs_venv_python = os.path.join(repo_root, "extern", "obsidian-vault-bridge", "mcp-infra", "vault-search", ".venv", "bin", "python")
vs_server_py = os.path.join(repo_root, "extern", "obsidian-vault-bridge", "mcp-infra", "vault-search", "server.py")
vault_dir = os.environ.get("VAULT_DIR", "")
vs_env = {"VAULT_DIR": vault_dir}
if os.environ.get("MEM_OBSIDIAN_VAULT"):
    vs_env["MEM_OBSIDIAN_VAULT"] = os.environ["MEM_OBSIDIAN_VAULT"]
if vault_dir and os.path.exists(vs_venv_python):
    config["mcpServers"]["vault-search"] = {
        "command": vs_venv_python,
        "args": [vs_server_py],
        "env": vs_env,
    }
    print(f"  ✓ vault-search → stdio (VAULT_DIR={vault_dir})")
elif config["mcpServers"].pop("vault-search", None):
    print("  ✗ vault-search unregistered from antigravity (VAULT_DIR unset)")

mem_server = os.path.join(home, ".claude-mem-lite", "server.mjs")
if os.path.exists(mem_server):
    config["mcpServers"]["mem-lite"] = {"command": "node", "args": [mem_server], "env": {}}
    print("  ✓ mem-lite → claude-mem-lite/server.mjs (stdio, shared DB)")
else:
    config["mcpServers"].pop("mem-lite", None)
    print("  ⚠ mem-lite skipped (claude-mem-lite not installed yet)")

council_base = os.path.join(repo_root, "mcp-infra", "llm-council-mcp")
if os.path.isdir(os.path.join(council_base, "mcp")):
    council_venv_python = os.path.join(council_base, "mcp", ".venv", "bin", "python")
    council_server_py = os.path.join(council_base, "mcp", "server.py")
else:
    council_venv_python = os.path.join(council_base, ".venv", "bin", "python")
    council_server_py = os.path.join(council_base, "server.py")
if os.path.exists(council_venv_python) and os.path.exists(council_server_py):
    config["mcpServers"]["llm-council"] = {
        "command": council_venv_python,
        "args": [council_server_py],
        "timeout": 420000,
    }
    print("  ✓ llm-council → stdio (timeout=420s)")
elif config["mcpServers"].pop("llm-council", None):
    print("  ✗ llm-council unregistered from antigravity (venv/server missing)")

if os.path.getsize(config_path):
    shutil.copy2(config_path, config_path + ".bak")

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print("  ✓ code-review-graph → http://localhost:8931/mcp")
print("  ✓ playwright → http://localhost:8932/mcp")
print("  ✓ fetch → http://localhost:8935/mcp")

PYEOF

    ok "Antigravity mcp_config.json updated"
}

# antigravity-cli's settings.json permissions.allow gates each tool behind an
# interactive approval until it's listed here — separate from mcp_config.json
# above (which only registers the server). Measured 2026-09-05: only
# get_minimal_context_tool/list_graph_stats_tool had ever been approved (grown
# organically, one approval at a time), so Gemini fell back to raw read/grep
# for everything else — structural ratio 0% despite the graph being wired and
# reachable. _configure_antigravity_mcp's own comment says no includeTools
# trimming applies here (unlike Qwen's 27B ceiling), so the fix is to
# pre-approve the full graph tool set, not a curated subset.
_configure_antigravity_permissions() {
    local ag_settings="$HOME/.gemini/antigravity-cli/settings.json"

    if [[ ! -f "$ag_settings" ]]; then
        return 0
    fi

    info "updating Antigravity permissions.allow (code-review-graph tools)..."

    python3 - "$ag_settings" <<'PYEOF'
import json, shutil, sys

config_path = sys.argv[1]

with open(config_path, 'r') as f:
    config = json.load(f)

# Keep in sync with the CRG_TOOLS set documented in CLAUDE.md/QWEN.md — this
# is the full menu (no trimming), not the smaller Qwen allowlist.
CRG_TOOLS = [
    "apply_refactor_tool", "build_or_update_graph_tool", "cross_repo_search_tool",
    "detect_changes_tool", "embed_graph_tool", "find_large_functions_tool",
    "generate_wiki_tool", "get_affected_flows_tool", "get_architecture_overview_tool",
    "get_bridge_nodes_tool", "get_community_tool", "get_docs_section_tool",
    "get_flow_tool", "get_hub_nodes_tool", "get_impact_radius_tool",
    "get_knowledge_gaps_tool", "get_minimal_context_tool", "get_review_context_tool",
    "get_suggested_questions_tool", "get_surprising_connections_tool",
    "get_wiki_page_tool", "list_communities_tool", "list_flows_tool",
    "list_graph_stats_tool", "list_repos_tool", "query_graph_tool",
    "refactor_tool", "run_postprocess_tool", "semantic_search_nodes_tool",
    "traverse_graph_tool",
]

config.setdefault("permissions", {}).setdefault("allow", [])
allow = config["permissions"]["allow"]
existing = set(allow)
added = 0
for tool in CRG_TOOLS:
    entry = f"mcp(code-review-graph/{tool})"
    if entry not in existing:
        allow.append(entry)
        existing.add(entry)
        added += 1

COUNCIL_TOOLS = ["ask_council", "list_councils", "scout_candidates"]
for tool in COUNCIL_TOOLS:
    entry = f"mcp(llm-council/{tool})"
    if entry not in existing:
        allow.append(entry)
        existing.add(entry)
        added += 1

shutil.copy2(config_path, config_path + ".bak")

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print(f"  ✓ permissions.allow: {added} tool(s) newly pre-approved")
PYEOF

    ok "Antigravity permissions.allow updated"
}

# Rewrite the managed OPENAI_* keys in an env file, preserving all other lines.
_write_openai_env() {
    local env_file="$1" host="$2" model="$3"
    local keep=""
    if [[ -f "$env_file" ]]; then
        keep=$(grep -Ev '^OPENAI_(API_KEY|BASE_URL|MODEL)=' "$env_file" || true)
    fi
    {
        if [[ -n "$keep" ]]; then printf '%s\n' "$keep"; fi
        echo "OPENAI_API_KEY=not-needed"
        echo "OPENAI_BASE_URL=$host"
        if [[ -n "$model" ]]; then echo "OPENAI_MODEL=$model"; fi
    } > "$env_file"
}

# Point the qwen CLI itself at the vLLM server so plain `qwen` works — no
# shell alias. Qwen Code loads the first .env found walking up from the cwd
# and falls back to ~/.qwen/.env, so the repo .env (which shadows the home
# one inside this repo) is kept in sync too. Re-run install.sh after changing
# QWEN_BASE_URL in .env and both files are updated.
_configure_qwen_cli_env() {
    local vllm_host="$1"
    # Resolved at call time so the remote installer can stage this exact
    # configuration into a temp dir instead of the local ~/.qwen. Default is
    # unchanged for every local caller.
    local qdir="${QWEN_CONFIG_DIR:-$HOME/.qwen}"
    local staging=0
    [[ "$qdir" != "$HOME/.qwen" ]] && staging=1
    mkdir -p "$qdir"

    info "configuring qwen CLI endpoint (no shell alias needed)..."

    # Auto-detect the served model id and context window from the
    # OpenAI-compatible endpoint (vLLM reports max_model_len)
    local model="" max_len=""
    local models_json=""
    models_json=$(curl -fsS --max-time 5 "${vllm_host%/}/models" 2>/dev/null) || true
    if [[ -n "$models_json" ]]; then
        model=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" <<<"$models_json" 2>/dev/null) || true
        max_len=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0].get('max_model_len') or '')" <<<"$models_json" 2>/dev/null) || true
    fi
    # Server unreachable → keep a previously configured model if there is one
    if [[ -z "$model" && -f "$qdir/.env" ]]; then
        model=$(grep -E '^OPENAI_MODEL=' "$qdir/.env" | head -1 | cut -d'=' -f2-) || true
    fi

    _write_openai_env "$qdir/.env" "$vllm_host" "$model"
    # The repo .env describes this machine. A staged build aimed at another
    # host must not rewrite it with that host's endpoint.
    if [[ $staging -eq 0 && -f "$REPO_ROOT/.env" ]]; then
        _write_openai_env "$REPO_ROOT/.env" "$vllm_host" "$model"
    fi

    if [[ -n "$model" ]]; then
        ok "qwen CLI → $vllm_host (model: $model, $qdir/.env)"
    else
        warn "could not detect model from ${vllm_host%/}/models — set OPENAI_MODEL in ~/.qwen/.env or re-run install.sh while the server is up"
    fi

    # Pin auth type so the first `qwen` launch doesn't stop at the auth dialog,
    # and cap the session at ~90% of the server context window so qwen warns
    # (suggesting /compress or a fresh session) instead of the API erroring out.
    local qwen_settings="$qdir/settings.json"
    if [[ ! -f "$qwen_settings" ]]; then
        echo '{"$version": 4}' > "$qwen_settings"
    fi

    # `/model` switch list: the primary endpoint first (it is the default),
    # then every QWEN_EXTRA_BASE_URLS endpoint that answers right now. One
    # "host<TAB>model<TAB>max_len" line each; an unreachable spare is dropped.
    local endpoints="" extra extra_json extra_model extra_len extras=()
    [[ -n "$model" ]] && endpoints=$(printf '%s\t%s\t%s' "$vllm_host" "$model" "$max_len")
    IFS=',' read -ra extras <<<"${QWEN_EXTRA_BASE_URLS:-}"
    for extra in "${extras[@]}"; do
        extra="${extra// /}"
        [[ -z "$extra" || "$extra" == "$vllm_host" ]] && continue
        extra_json=$(curl -fsS --max-time 5 "${extra%/}/models" 2>/dev/null) || extra_json=""
        extra_model=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" <<<"$extra_json" 2>/dev/null) || extra_model=""
        extra_len=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0].get('max_model_len') or '')" <<<"$extra_json" 2>/dev/null) || extra_len=""
        if [[ -z "$extra_model" ]]; then
            warn "spare qwen endpoint $extra did not answer — left out of /model"
            continue
        fi
        endpoints+=$'\n'$(printf '%s\t%s\t%s' "$extra" "$extra_model" "$extra_len")
    done

    python3 - "$qwen_settings" "$max_len" "$endpoints" <<'PYEOF'
import json, sys
path, max_len, endpoints_raw = sys.argv[1], sys.argv[2], sys.argv[3]
endpoints = [l.split('\t') for l in endpoints_raw.splitlines() if l.strip()]
with open(path) as f:
    config = json.load(f)
config.setdefault("security", {}).setdefault("auth", {})["selectedType"] = "openai"
print('  ✓ qwen auth → openai (settings.json)')

# Sampling is qwen-side only — the Claude side has no equivalent knob, so this
# is not an asymmetry to reconcile. Left unset, qwen-code/vLLM fall back to a
# generic default (typically temperature 1.0), and Qwen3.6's own model card is
# explicit that this breaks agentic use: above 0.6 the output diverges into
# malformed tool calls and hallucinated function names, below 0.3 it collapses
# into repeated identical failed calls. 0.6 / 0.95 is the pair the model was
# trained and validated at for thinking-mode coding and tool calling.
sampling = config.setdefault("model", {}).setdefault(
    "generationConfig", {}).setdefault("samplingParams", {})
sampling["temperature"] = 0.6
sampling["top_p"] = 0.95
print('  ✓ qwen samplingParams → temperature 0.6, top_p 0.95 (Qwen3.6 agentic/coding defaults)')

if max_len:
    # sessionTokenLimit is global, not per model — sized on the smallest
    # window in the /model list so switching models can never overrun one.
    windows = [int(e[2]) for e in endpoints if e[2]] or [int(max_len)]
    limit = int(min(windows + [int(max_len)]) * 0.9)
    model_cfg = config.setdefault("model", {})
    model_cfg["sessionTokenLimit"] = limit
    # Without this, qwen-code assumes a default context window for
    # OpenAI-compat models and auto-compresses around ~47k tokens —
    # each compression is a full-history summarization call that looks
    # like a multi-minute hang on a local vLLM.
    model_cfg.setdefault("generationConfig", {})["contextWindowSize"] = int(max_len)
    print(f'  ✓ qwen sessionTokenLimit → {limit} (90% of server max_model_len {max_len})')
    print(f'  ✓ qwen contextWindowSize → {max_len} (compression threshold now tracks the real window)')

    # Thinking mode is on by default and its tokens come out of the SAME output
    # budget as the answer: measured against this vLLM host, a 200-token cap on
    # "2+2?" returned finish_reason=length with content=null — the whole budget
    # went to <think>. Unset, qwen-code starts at 8k and silently re-runs the
    # turn at 64k when it truncates, paying for the turn twice. Sized from the
    # headroom the session cap already reserves (prompt + completion must fit
    # max_model_len), then capped at the 81,920 the model card recommends for
    # complex coding — past that the number is decorative.
    # No floor: vLLM rejects a request whose prompt + max_tokens overruns
    # max_model_len, so a floor above the reserved headroom would turn long
    # sessions into hard errors instead of short answers.
    sampling["max_tokens"] = min(81920, int(max_len) - limit)
    print(f'  ✓ qwen samplingParams.max_tokens → {sampling["max_tokens"]} '
          f'(thinking + answer share one budget)')

# Model registry behind `/model`. model.name picks the default (the primary
# endpoint); each entry carries its own baseUrl and window, since the spares
# may sit on other hosts with a different max_model_len.
if endpoints:
    entries = []
    for host, mid, mlen in endpoints:
        gen = {"samplingParams": {"temperature": 0.6, "top_p": 0.95}}
        if mlen and max_len:
            gen["contextWindowSize"] = int(mlen)
            gen["samplingParams"]["max_tokens"] = min(81920, int(mlen) - limit)
        entries.append({"id": mid, "name": mid, "baseUrl": host,
                        "envKey": "OPENAI_API_KEY", "generationConfig": gen})
    config.setdefault("modelProviders", {})["openai"] = entries
    config.setdefault("model", {})["name"] = endpoints[0][1]
    print(f'  ✓ qwen /model list → {", ".join(e[1] for e in endpoints)} '
          f'(default: {endpoints[0][1]})')
with open(path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF
}

_install_lsp_tools() {
    # clangd — system package (C++ and ROS2)
    if ! command -v clangd &>/dev/null; then
        # Optional dependency: a failure here must not abort the whole install
        # (set -e) — everything after it, incl. the MCP wiring, would be skipped.
        case "$OS" in
            mac)    brew install llvm || true ;;
            arch)   sudo pacman -S --noconfirm --needed clang || true ;;
            ubuntu) apt_get install -y clangd 2>/dev/null || \
                    apt_get install -y clangd-15 2>/dev/null || true ;;
            fedora) sudo dnf install -y clang-tools-extra 2>/dev/null || true ;;
        esac
    fi
    if command -v clangd &>/dev/null; then
        ok "clangd: $(clangd --version 2>/dev/null | head -1 | tr -d '\n')"
    else
        warn "clangd not found — C++/ROS2 LSP disabled"
    fi

    # pyright — Python type-aware LSP
    info "updating pyright..."
    npm_global_install pyright
    ok "pyright: $(pyright --version 2>/dev/null | tr -d '\n')"

    # lsp-mcp-server — LSP → MCP bridge (single instance manages all languages)
    info "updating lsp-mcp-server..."
    npm_global_install lsp-mcp-server
    ok "lsp-mcp-server updated"

    # supergateway — stdio MCP → streamable HTTP (Qwen HTTP bridge)
    info "updating supergateway..."
    npm_global_install supergateway
    ok "supergateway updated"

    # lsp-coercion-proxy — always install to ~/.local/bin/ (Qwen Code STDIO transport uses this)
    local proxy_src="$REPO_ROOT/scripts/lib/lsp-coercion-proxy"
    local proxy_dst="$HOME/.local/bin/lsp-coercion-proxy"
    if [[ -f "$proxy_src" ]]; then
        cp "$proxy_src" "$proxy_dst"
        chmod +x "$proxy_dst"
        ok "lsp-coercion-proxy → $proxy_dst"
    else
        warn "lsp-coercion-proxy not found: $proxy_src"
    fi

    # ~/.lsp-mcp.json — override default pylsp with pyright-langserver for Python
    # lsp-mcp-server defaults to pylsp but pyright-langserver is already installed via npm.
    local lsp_config="$HOME/.lsp-mcp.json"
    if [[ ! -f "$lsp_config" ]]; then
        cat > "$lsp_config" <<'LSPCFG'
{
  "servers": [
    {
      "id": "python",
      "extensions": [".py", ".pyi"],
      "languageIds": ["python"],
      "command": "pyright-langserver",
      "args": ["--stdio"]
    }
  ]
}
LSPCFG
        ok "\$HOME/.lsp-mcp.json created (pyright-langserver)"
    else
        ok "\$HOME/.lsp-mcp.json already exists"
    fi
}

_setup_lsp_http() {
    local port=8933
    local log_file="$HOME/.qwen/lsp-mcp.log"
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/lsp-mcp.service"
    local wrapper="$HOME/.local/bin/lsp-mcp-start"
    local proxy_dst="$HOME/.local/bin/lsp-coercion-proxy"

    if port_in_use "$port"; then
        ok "LSP MCP HTTP daemon already running on port $port"
        return
    fi

    [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
    if ! command -v supergateway &>/dev/null || ! command -v lsp-mcp-server &>/dev/null; then
        warn "supergateway or lsp-mcp-server not found — LSP HTTP daemon skipped"
        return
    fi

    mkdir -p "$(dirname "$wrapper")"

    if [[ ! -f "$proxy_dst" ]]; then
        warn "lsp-coercion-proxy not found ($proxy_dst) — continuing without proxy"
        proxy_dst="lsp-mcp-server"
    fi

    cat > "$wrapper" <<WRAPEOF
#!/usr/bin/env bash
export NVM_DIR="\$HOME/.nvm"
[[ -s "\$NVM_DIR/nvm.sh" ]] && source "\$NVM_DIR/nvm.sh"
[[ -d "\$HOME/.npm-global/bin" ]] && export PATH="\$HOME/.npm-global/bin:\$PATH"
exec supergateway --stdio ${proxy_dst} --port 8933 --outputTransport streamableHttp
WRAPEOF
    chmod +x "$wrapper"

    if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
        mkdir -p "$service_dir"
        cat > "$service_file" <<SVCEOF
[Unit]
Description=LSP MCP HTTP Server
After=network.target

[Service]
ExecStart=${wrapper}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
        info "creating systemd user service: lsp-mcp.service"
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable lsp-mcp 2>/dev/null && ok "lsp-mcp.service enabled" || warn "enable failed"
        systemctl --user restart lsp-mcp 2>/dev/null && ok "lsp-mcp.service started" || warn "start failed"
    else
        warn "systemd --user unavailable, starting with nohup..."
        mkdir -p "$(dirname "$log_file")"
        nohup "$wrapper" > "$log_file" 2>&1 &
        local pid=$!
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            ok "LSP MCP HTTP daemon started (PID $pid, port: $port)"
        else
            warn "LSP MCP HTTP daemon failed to start (log: $log_file)"
        fi
    fi
}

_setup_crg_http() {
    local port=8931
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/crg-mcp.service"
    local wrapper="$HOME/.local/bin/crg-mcp-start"

    if port_in_use "$port"; then
        ok "code-review-graph MCP HTTP daemon already running on port $port"
        return
    fi

    if ! _crg_works; then
        warn "code-review-graph not found — CRG HTTP daemon skipped"
        return
    fi

    local crg_bin
    crg_bin="$(command -v code-review-graph)"

    mkdir -p "$(dirname "$wrapper")"
    cat > "$wrapper" <<WRAPEOF
#!/usr/bin/env bash
export NVM_DIR="\$HOME/.nvm"
[[ -s "\$NVM_DIR/nvm.sh" ]] && source "\$NVM_DIR/nvm.sh"
[[ -d "\$HOME/.npm-global/bin" ]] && export PATH="\$HOME/.npm-global/bin:\$PATH"
exec "${crg_bin}" serve --http --host 127.0.0.1 --port ${port}
WRAPEOF
    chmod +x "$wrapper"

    if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
        mkdir -p "$service_dir"
        cat > "$service_file" <<SVCEOF
[Unit]
Description=code-review-graph MCP HTTP Server
After=network.target

[Service]
ExecStart=${wrapper}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
        info "creating systemd user service: crg-mcp.service"
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable crg-mcp 2>/dev/null && ok "crg-mcp.service enabled" || warn "enable failed"
        systemctl --user restart crg-mcp 2>/dev/null && ok "crg-mcp.service started" || warn "start failed"
    else
        warn "systemd --user unavailable, starting with nohup..."
        nohup "$wrapper" > "$HOME/.qwen/crg-mcp.log" 2>&1 &
        local pid=$!
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            ok "CRG MCP HTTP daemon started (PID $pid)"
        else
            warn "CRG MCP HTTP daemon failed to start"
        fi
    fi
}

_install_fetch_mcp() {
    info "updating mcp-fetch-server..."
    npm_global_install mcp-fetch-server
    ok "mcp-fetch-server: $(run_bounded 30 npm show mcp-fetch-server version 2>/dev/null | tr -d '\n')"

    # supergateway bridges this stdio server to the streamable-HTTP daemon
    # (fetch-mcp-start, port 8935) that Qwen/Antigravity need. It used to only
    # get installed via _install_lsp_tools (ENABLE_LSP=1), so on a default
    # install (ENABLE_LSP=0) the fetch HTTP daemon silently failed to start
    # ("exec: supergateway: not found") on every machine.
    npm_global_install supergateway
}

_setup_fetch_http() {
    local port=8935
    local log_file="$HOME/.qwen/fetch-mcp.log"
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/fetch-mcp.service"
    local wrapper="$HOME/.local/bin/fetch-mcp-start"

    if port_in_use "$port"; then
        ok "Fetch MCP HTTP daemon already running on port $port"
        return
    fi

    [[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
    if ! command -v mcp-fetch-server &>/dev/null; then
        warn "mcp-fetch-server not found — Fetch HTTP daemon skipped"
        return
    fi

    mkdir -p "$(dirname "$wrapper")"
    cat > "$wrapper" <<'WRAPEOF'
#!/usr/bin/env bash
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
[[ -d "$HOME/.npm-global/bin" ]] && export PATH="$HOME/.npm-global/bin:$PATH"
exec supergateway --stdio "mcp-fetch-server" --port 8935 --outputTransport streamableHttp
WRAPEOF
    chmod +x "$wrapper"

    if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
        mkdir -p "$service_dir"
        cat > "$service_file" <<SVCEOF
[Unit]
Description=Fetch MCP HTTP Server
After=network.target

[Service]
ExecStart=${wrapper}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
        info "creating systemd user service: fetch-mcp.service"
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user enable fetch-mcp 2>/dev/null && ok "fetch-mcp.service enabled" || warn "enable failed"
        systemctl --user restart fetch-mcp 2>/dev/null && ok "fetch-mcp.service started" || warn "start failed"
    else
        warn "systemd --user unavailable, starting with nohup..."
        mkdir -p "$(dirname "$log_file")"
        nohup "$wrapper" > "$log_file" 2>&1 &
        local pid=$!
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            ok "Fetch MCP HTTP daemon started (PID $pid, port: $port)"
        else
            warn "Fetch MCP HTTP daemon failed to start (log: $log_file)"
        fi
    fi
}

# LSP is opt-in (ENABLE_LSP=1 in .env). Usage audit over the full transcript
# history found exactly ONE lsp_* call across ~35k API calls fleet-wide — the
# code graph answers the same navigation questions and is what the gate steers
# to. The machinery it drags in is not free: clangd, pyright, lsp-mcp-server,
# supergateway, a systemd unit, an HTTP daemon and a coercion proxy, plus a
# global MCP entry whose tool schemas load in every session. Keeping the code
# (flip the flag) but not paying for it by default.
setup_lsp_servers() {
    if [[ "${ENABLE_LSP:-0}" != "1" ]]; then
        section "LSP Servers"
        info "skipped (ENABLE_LSP != 1) — code-review-graph covers navigation"
        info "enable with ENABLE_LSP=1 in .env if you want pyright/clangd symbols"
        return 0
    fi
    section "LSP Servers"
    _install_lsp_tools
    _setup_lsp_http
}


# Keep a rolling copy of the memory DB, newest first, and drop the rest.
# The DB is the only place the project memory lives, and the one moment it is
# genuinely at risk is an upstream update running over it. Before this there
# was a single hand-made .bak from whenever someone last thought of it: 18 days
# and 188 observations old, so the backup covered none of the work it existed
# to protect. The copy is cheap (~10MB) and the retention is what stops it
# turning into a pile nobody prunes.
_backup_mem_lite_db() {
    local install_dir="$1" keep=5
    local db="$install_dir/claude-mem-lite.db"
    [[ -f "$db" ]] || return 0
    # sqlite3 is not a dependency of this kit, and copying a live DB without it
    # can catch a write in progress -- so take the WAL along, which is what
    # makes the pair recoverable.
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    cp -p "$db" "$install_dir/claude-mem-lite.db.bak-$stamp" 2>/dev/null || return 0
    [[ -f "$db-wal" ]] && cp -p "$db-wal" "$install_dir/claude-mem-lite.db.bak-$stamp-wal" 2>/dev/null
    # Prune by the .db copies alone, newest first, and take each one's -wal
    # with it. Counting both together instead would mean a backup taken while
    # no WAL existed shifted the count and pruned a pair early. The stamp is
    # YYYYmmdd-HHMMSS, so a reverse name sort is a reverse time sort -- no need
    # to ask the filesystem, which is what SC2010 warns about.
    local copies=() f
    for f in "$install_dir"/claude-mem-lite.db.bak-*; do
        [[ -f "$f" && "$f" != *-wal ]] && copies+=("$f")
    done
    local n=0
    while IFS= read -r f; do
        n=$((n + 1))
        (( n > keep )) && rm -f "$f" "$f-wal"
    done < <(printf '%s\n' "${copies[@]}" | sort -r)
    ok "memory DB backed up (son $keep kopya tutuluyor)"
}

_setup_claude_mem_lite() {
    local install_dir="$HOME/.claude-mem-lite"

    # Already installed — update from upstream.
    #
    # This used to run "$install_dir/install.mjs", the copy that was already
    # on disk. That reinstalls the version already installed: it never fetches,
    # so every kit install reported "claude-mem-lite updated" while pinning
    # whatever was first cloned. Measured 2026-08-26, that had held the local
    # copy at 2.92.0 since June while upstream was at 3.83.0 -- a whole major
    # version, announced as an update on every run. Both paths clone now, and
    # only the message differs.
    local action="Installing claude-mem-lite (project-scoped persistent memory)..."
    if [[ -f "$install_dir/install.mjs" ]]; then
        action="Updating claude-mem-lite from upstream..."
        # The upgrade is the moment the DB is most at risk: a version jump can
        # migrate the schema, and there is no second copy of the memory.
        _backup_mem_lite_db "$install_dir"
    fi
    info "$action"

    # Clone to temp, run installer, installer moves files to ~/.claude-mem-lite
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! run_bounded 300 git clone --depth=1 https://github.com/sdsrss/claude-mem-lite.git "$tmp_dir/claude-mem-lite" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        warn "claude-mem-lite clone failed or timed out — memory hooks/MCP not updated"
        return 1
    fi
    # Take the memory DB and nothing else. 3.83 also ships a skill/agent
    # registry that clones 15 third-party GitHub repos (154MB of unvetted
    # agent and skill prompts), indexes them as MCP resources and fetches
    # their star counts. Upstream's own installer says the memory features
    # work without it, and this kit curates its skill list deliberately --
    # a second, unreviewed pile of agent definitions next to it is surface,
    # not capability. MEM_NO_AUTO_ADOPT declines the same for the dogfood
    # repo the installer otherwise adopts on its own.
    CLAUDE_MEM_SKIP_REPOS=1 MEM_NO_AUTO_ADOPT=1 \
        run_bounded 600 node "$tmp_dir/claude-mem-lite/install.mjs" install 2>&1 \
        | grep -E "✓|✗|⚠|Error|error|ready|installed" || true
    rm -rf "$tmp_dir"

    if [[ -d "$install_dir" ]]; then
        ok "claude-mem-lite installed ($install_dir)"
    else
        warn "claude-mem-lite install may have failed — check $install_dir"
    fi
}

setup_mcp_servers() {
    local vllm_host="${1:-}"
    local gitlab_url="${2:-}"

    section "MCP Servers"
    # First: everything below writes MCP entries, and they must land in the
    # file Claude Code actually reads.
    _ensure_claude_json_link
    # Each network-bound step is contained: one failed or timed-out download
    # must not stop the config writers below (and, via set -e, every hook
    # and agent deployed after this function). verify_install names the hole.
    _setup_code_review_graph || warn "code-review-graph setup incomplete — continuing"
    _setup_playwright || warn "Playwright setup incomplete — continuing"

    if [[ -n "$vllm_host" ]]; then
        _setup_local_model_mcp "$vllm_host" || warn "local-model-mcp setup incomplete — continuing"
    else
        warn "vLLM host not set — Qwen MCP skipped. Run: bash install.sh --vllm-host http://HOST:PORT"
    fi

    _install_fetch_mcp || warn "mcp-fetch-server install incomplete — continuing"
    _setup_claude_mem_lite || warn "claude-mem-lite setup incomplete — continuing"
    _setup_vault_search "${VAULT_DIR:-}" || warn "vault-search setup incomplete — continuing"
    _setup_llm_council || warn "llm-council setup incomplete — continuing"
    _setup_council_shims
    _configure_claude_json "$vllm_host" "$gitlab_url"
    _install_crg_autobuild_hook

    _setup_crg_http
    _setup_playwright_http
    _setup_fetch_http
    _configure_qwen_settings "$gitlab_url"
    if [[ -n "$vllm_host" ]]; then
        _configure_qwen_cli_env "$vllm_host"
    fi

    _configure_antigravity_mcp "$gitlab_url" "$vllm_host"
    _configure_antigravity_permissions
}
