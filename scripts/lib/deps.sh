#!/usr/bin/env bash
# sourced — not executed directly

install_node() {
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

  if command -v node &>/dev/null; then
    local node_ver major
    node_ver=$(node --version)
    major=$(echo "$node_ver" | sed 's/v\([0-9]*\).*/\1/')
    if [[ "$major" -ge 22 ]]; then
      ok "Node.js $node_ver (already installed)"
      return
    fi
    info "Node.js $node_ver found — upgrading to 22 (required for latest tooling)..."
  else
    info "Installing Node.js 22 via nvm..."
  fi

  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    run_bounded 300 bash -c 'curl -fsS --connect-timeout 15 --max-time 120 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
    source "$NVM_DIR/nvm.sh"
  fi

  # nvm is a shell function, so the download runs bounded in a child shell;
  # `nvm use` below then only switches to what is already on disk.
  run_bounded 900 bash -c 'source "$NVM_DIR/nvm.sh" && nvm install 22' \
    || { warn "nvm install 22 failed or timed out (900s)"; return 1; }
  nvm use 22
  nvm alias default 22

  ok "Node.js $(node --version) installed"
}

install_uv() {
  if command -v uv &>/dev/null; then
    info "updating uv..."
    run_bounded 120 uv self update 2>/dev/null || true
  else
    info "installing uv..."
    run_bounded 300 sh -c 'curl -LsSf --connect-timeout 15 --max-time 240 https://astral.sh/uv/install.sh | sh' \
      || warn "uv install failed or timed out"
    export PATH="$HOME/.local/bin:$PATH"
  fi
  ok "uv $(uv --version 2>/dev/null | awk '{print $2}')"
}

install_pipx() {
  if command -v pipx &>/dev/null; then
    ok "pipx (already installed)"
    return
  fi

  info "Installing pipx..."

  case "$OS" in
    mac)
      brew install pipx || true
      ;;
    arch)
      sudo pacman -S --noconfirm python-pipx || true
      ;;
    fedora)
      sudo dnf install -y pipx || true
      ;;
    ubuntu)
      apt_get update && apt_get install -y pipx || true
      ;;
  esac

  if ! command -v pipx &>/dev/null; then
    warn "pipx install failed — linters (ruff, yamllint, ansible-lint) will be skipped"
    return
  fi

  pipx ensurepath
  ensure_local_bin_on_path

  ok "pipx installed"
}

install_qwen_cli() {
  info "updating Qwen Code..."
  npm_global_install @qwen-code/qwen-code
  ok "Qwen Code $(qwen --version 2>/dev/null | head -1)"
}

install_claude_cli() {
  info "updating Claude Code..."
  run_bounded 600 bash -c 'curl -fsSL --connect-timeout 15 --max-time 60 https://claude.ai/install.sh | bash' \
    || warn "Claude Code install failed or timed out (600s)"
  ok "Claude Code $(claude --version 2>/dev/null | head -1)"
}

install_drawio_cli() {
  if command -v drawio &>/dev/null; then
    ok "draw.io $(drawio --version 2>/dev/null) (already installed)"
    return
  fi

  info "Installing draw.io Desktop (CLI for diagram export)..."

  case "$OS" in
    mac)
      if command -v brew &>/dev/null; then
        brew install --cask drawio && ok "draw.io installed (Homebrew)" || warn "draw.io install failed — diagrams will fall back to browser URL mode"
      else
        warn "Homebrew not found — skipping draw.io. Install manually from https://github.com/jgraph/drawio-desktop/releases"
      fi
      ;;
    ubuntu)
      local deb_url
      deb_url=$(curl -s --connect-timeout 15 --max-time 30 https://api.github.com/repos/jgraph/drawio-desktop/releases/latest \
        | python3 -c "import json,sys; assets=[a for a in json.load(sys.stdin)['assets'] if a['name'].endswith('.deb') and 'amd64' in a['name']]; print(assets[0]['browser_download_url'] if assets else '')" 2>/dev/null)
      if [[ -z "$deb_url" ]]; then
        warn "Could not resolve draw.io .deb URL — skipping. Install manually from https://github.com/jgraph/drawio-desktop/releases"
        return
      fi
      local tmp_deb
      tmp_deb=$(mktemp /tmp/drawio-XXXXXX.deb)
      # apt-get, not dpkg -i: dpkg cannot resolve dependencies, so on a clean
      # machine it half-installs draw.io and leaves apt in a broken state that
      # fails every later apt install (shellcheck and cppcheck went down with
      # it). apt-get pulls the dependencies or declines cleanly.
      curl -fsSL --connect-timeout 15 --max-time 600 "$deb_url" -o "$tmp_deb" && apt_get install -y "$tmp_deb" && ok "draw.io installed" || warn "draw.io install failed — diagrams will fall back to browser URL mode"
      rm -f "$tmp_deb"
      ;;
    arch)
      if command -v yay &>/dev/null; then
        yay -S --noconfirm drawio-desktop-bin && ok "draw.io installed (AUR)" || warn "draw.io install failed — diagrams will fall back to browser URL mode"
      elif command -v paru &>/dev/null; then
        paru -S --noconfirm drawio-desktop-bin && ok "draw.io installed (AUR)" || warn "draw.io install failed — diagrams will fall back to browser URL mode"
      else
        warn "No AUR helper (yay/paru) found — skipping draw.io. Install manually: yay -S drawio-desktop-bin"
      fi
      ;;
    fedora)
      local rpm_url
      rpm_url=$(curl -s --connect-timeout 15 --max-time 30 https://api.github.com/repos/jgraph/drawio-desktop/releases/latest \
        | python3 -c "import json,sys; assets=[a for a in json.load(sys.stdin)['assets'] if a['name'].endswith('.rpm') and 'x86_64' in a['name']]; print(assets[0]['browser_download_url'] if assets else '')" 2>/dev/null)
      if [[ -z "$rpm_url" ]]; then
        warn "Could not resolve draw.io .rpm URL — skipping. Install manually from https://github.com/jgraph/drawio-desktop/releases"
        return
      fi
      sudo dnf install -y "$rpm_url" && ok "draw.io installed" || warn "draw.io install failed — diagrams will fall back to browser URL mode"
      ;;
  esac
}

install_lint_tools() {
  # Linters consumed by the lint-on-edit hook (claude/hooks/lint-on-edit.py).
  # Each is optional — the hook silently skips missing linters.
  if command -v ruff &>/dev/null; then
    ok "ruff (already installed)"
  else
    run_bounded 600 pipx install ruff &>/dev/null && ok "ruff installed (pipx)" || warn "ruff install failed — .py lint feedback disabled"
  fi

  if command -v ansible-lint &>/dev/null; then
    ok "ansible-lint (already installed)"
  else
    run_bounded 600 pipx install --include-deps ansible-lint &>/dev/null && ok "ansible-lint installed (pipx)" || warn "ansible-lint install failed — ansible lint feedback disabled"
  fi

  if command -v shellcheck &>/dev/null; then
    ok "shellcheck (already installed)"
  else
    case "$OS" in
      mac)    brew install shellcheck || true ;;
      arch)   sudo pacman -S --noconfirm shellcheck || true ;;
      fedora) sudo dnf install -y ShellCheck || true ;;
      ubuntu) apt_get install -y shellcheck || true ;;
    esac
    command -v shellcheck &>/dev/null && ok "shellcheck installed" || warn "shellcheck install failed — .sh lint feedback disabled"
  fi

  if command -v yamllint &>/dev/null; then
    ok "yamllint (already installed)"
  else
    run_bounded 600 pipx install yamllint &>/dev/null && ok "yamllint installed (pipx)" || warn "yamllint install failed — yaml lint feedback disabled"
  fi

  # cppcheck: the C/C++ half of the fleet had no lint feedback at all, in the
  # repos with the most code (2852 C/C++ files in one alone). Distro packages
  # are current enough — single-file analysis needs no compilation database.
  if command -v cppcheck &>/dev/null; then
    ok "cppcheck (already installed)"
  else
    case "$OS" in
      mac)    brew install cppcheck || true ;;
      arch)   sudo pacman -S --noconfirm cppcheck || true ;;
      fedora) sudo dnf install -y cppcheck || true ;;
      ubuntu) apt_get install -y cppcheck || true ;;
    esac
    command -v cppcheck &>/dev/null && ok "cppcheck installed" || warn "cppcheck install failed — C/C++ lint feedback disabled"
  fi

  # tflint: provider-aware terraform lint (lint-on-edit falls back to
  # `terraform fmt -check` when absent). Official installer drops a single
  # static binary into /usr/local/bin.
  if command -v tflint &>/dev/null; then
    ok "tflint (already installed)"
  else
    # Both branches must be guarded. The upstream installer needs unzip and
    # exits 127 without it; unguarded, set -e turned that into a dead install —
    # MCP setup, agent deployment and verification never ran at all.
    if command -v brew &>/dev/null; then
      brew install tflint &>/dev/null || true
    else
      run_bounded 300 bash -c 'curl -fsSL --connect-timeout 15 --max-time 60 https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash' &>/dev/null || true
    fi
    command -v tflint &>/dev/null && ok "tflint installed" || warn "tflint install failed — .tf lint falls back to terraform fmt"
  fi
}

install_mcp_grafana() {
  # Machine-level binary only. Per-project wiring (.mcp.json, URL, token) is
  # scripts/setup-grafana-mcp.sh — rerun it per repo after moving machines.
  if command -v mcp-grafana &>/dev/null || [[ -x "$HOME/go/bin/mcp-grafana" ]]; then
    ok "mcp-grafana (already installed)"
    return
  fi
  if ! command -v go &>/dev/null; then
    warn "go not found — mcp-grafana skipped (needed only for live-Grafana repos; install go, then rerun or use scripts/setup-grafana-mcp.sh)"
    return
  fi
  run_bounded 600 go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest &>/dev/null \
    && ok "mcp-grafana installed (~/go/bin)" \
    || warn "mcp-grafana install failed — Grafana MCP unavailable until scripts/setup-grafana-mcp.sh is run"
}

install_glab_cli() {
  # GitLab CLI — used directly via bash (like gh), NOT registered as an MCP.
  if command -v glab &>/dev/null; then
    ok "glab $(glab --version 2>/dev/null | head -1) (already installed)"
    return
  fi

  info "Installing glab (GitLab CLI)..."
  case "$OS" in
    mac)    brew install glab ;;
    arch)   sudo pacman -S --noconfirm glab ;;
    fedora) sudo dnf install -y glab ;;
    ubuntu)
      local deb_url
      deb_url=$(curl -s --connect-timeout 15 --max-time 30 https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases \
        | python3 -c "import json,sys; links=[l for r in json.load(sys.stdin)[:1] for l in r['assets']['links'] if l['name'].endswith('_amd64.deb')]; print(links[0]['url'] if links else '')" 2>/dev/null)
      if [[ -z "$deb_url" ]]; then
        warn "Could not resolve glab .deb URL — install manually: https://gitlab.com/gitlab-org/cli/-/releases"
        return
      fi
      local tmp_deb
      tmp_deb=$(mktemp /tmp/glab-XXXXXX.deb)
      # apt-get, not dpkg -i — see the draw.io note above.
      curl -fsSL --connect-timeout 15 --max-time 600 "$deb_url" -o "$tmp_deb" && apt_get install -y "$tmp_deb"; rm -f "$tmp_deb"
      ;;
  esac
  if command -v glab &>/dev/null; then
    ok "glab installed"
    info "Authenticate once with: glab auth login"
  else
    warn "glab install failed — GitLab CLI unavailable"
  fi
}

# claude-mem-lite's better-sqlite3 falls back to a node-gyp build when no
# prebuilt binary matches the Node version; without make/g++ that build fails
# and mem-lite is left unregistered.
install_build_tools() {
  if command -v make &>/dev/null && command -v g++ &>/dev/null; then
    ok "build tools (already installed)"
    return
  fi
  case "$OS" in
    mac)    xcode-select --install 2>/dev/null || true ;;
    arch)   sudo pacman -S --needed --noconfirm base-devel || true ;;
    fedora) sudo dnf install -y make gcc-c++ || true ;;
    ubuntu) apt_get update && apt_get install -y build-essential || true ;;
  esac
  command -v make &>/dev/null && command -v g++ &>/dev/null && ok "build tools installed" \
    || warn "make/g++ missing — native npm modules (mem-lite's better-sqlite3) may fail to build"
}

install_deps() {
  section "Dependencies"
  install_build_tools
  install_node
  install_uv
  install_pipx
  install_qwen_cli
  install_claude_cli
  install_drawio_cli
  install_lint_tools
  install_mcp_grafana
  # install_glab_cli  # parked until the GitLab MR workflow starts — reactivate by uncommenting
}
