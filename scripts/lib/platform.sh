#!/usr/bin/env bash
# sourced — not executed directly

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
fail()    { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
info()    { echo -e "  ${CYAN}→${RESET} $*"; }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "mac"
  elif [[ -f /etc/arch-release ]]; then
    echo "arch"
  elif grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    echo "ubuntu"
  elif [[ -f /etc/fedora-release ]] || grep -qi "fedora\|rhel\|centos" /etc/os-release 2>/dev/null; then
    echo "fedora"
  else
    fail "Unsupported platform. Supported: macOS, Arch Linux, Ubuntu/Debian, Fedora"
  fi
}

# On macOS every system package goes through Homebrew (pipx, shellcheck, llvm,
# tflint...). Without it the first `brew install` dies on "command not found"
# and set -e aborts the run mid-install. Check once, up front, with a fix.
require_package_manager() {
  [[ "$1" == "mac" ]] || return 0
  command -v brew &>/dev/null && return 0
  fail "Homebrew not found — required on macOS. Install it first:
       /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
       then re-run: bash install.sh"
}

# Reachability probe for the optional network-wired MCPs (vLLM, GitLab).
# Deliberately not -f: a 401/404 still proves something is listening, and that
# is all we need to decide whether wiring the MCP is honest. Only a connection
# failure or timeout counts as unreachable.
host_reachable() {
  local url="$1" timeout="${2:-3}"
  curl -sS --max-time "$timeout" -o /dev/null "$url" 2>/dev/null
}

# Network and package steps must never wait on a prompt nobody sees, or on a
# download that stalls. Set once, inherited by every child of install.sh:
#   git  — a private or renamed submodule asks "Username for github.com:" and
#          blocks; fail instead and let init_submodules name it.
#   npm  — no "Ok to proceed?", no fund/audit/update chatter.
#   brew — no auto-update in the middle of an install, no confirmations.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"
export npm_config_yes=true npm_config_fund=false npm_config_audit=false
export npm_config_update_notifier=false
export NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1

# run_bounded SECS CMD... — run an external command with stdin from /dev/null,
# killed after SECS. Returns the command's status; 124 means it timed out.
# Not for shell functions (timeout execs a binary) and not for sudo (a password
# prompt cannot reach the tty from timeout's background process group).
run_bounded() {
  local secs="$1"; shift
  local t=""
  if command -v timeout &>/dev/null; then t=timeout
  elif command -v gtimeout &>/dev/null; then t=gtimeout
  fi
  if [[ -n "$t" ]]; then
    "$t" -k 10 "$secs" "$@" </dev/null
  else
    "$@" </dev/null
  fi
}

# apt-get that can neither prompt (debconf, conffile questions) nor wait
# forever behind an unattended-upgrades lock. `sudo env` because sudo's
# env_reset would drop a plain exported DEBIAN_FRONTEND.
apt_get() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o DPkg::Lock::Timeout=120 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    "$@" </dev/null
}

# Cross-platform port-in-use check (ss on Linux, lsof on Mac)
port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | grep -q ":${port} "
  elif command -v lsof &>/dev/null; then
    lsof -i ":${port}" -sTCP:LISTEN &>/dev/null 2>&1
  else
    netstat -an 2>/dev/null | grep -q ":${port}.*LISTEN"
  fi
}

# Persist a PATH dir into the user's shell RC (idempotent) so new terminals
# see it too — the installer's own `export PATH` only lasts for this session.
persist_path_entry() {
  local dir="$1"
  local rc
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *)    rc="$HOME/.profile" ;;
  esac
  # Match any spelling already present: ~/.local/bin, $HOME/.local/bin, absolute
  local token="${dir#"$HOME"/}"
  if [[ -f "$rc" ]] && grep -qF "$token" "$rc"; then
    return 0
  fi
  local line
  if [[ "$dir" == "$HOME/"* ]]; then
    line="export PATH=\"\$HOME/$token:\$PATH\""
  else
    line="export PATH=\"$dir:\$PATH\""
  fi
  printf '\n%s # added by dev-agent-kit install.sh\n' "$line" >> "$rc"
  ok "PATH persisted: $dir → ${rc##*/}"
}

ensure_local_bin_on_path() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
    persist_path_entry "$HOME/.local/bin"
  fi
}

# Package dir name from an npm spec, version stripped:
#   @scope/name@1.2 → @scope/name   name@1.2 → name   @scope/name → @scope/name
_npm_pkg_name() {
  local pkg="$1"
  if [[ "$pkg" == @* ]]; then
    local rest="${pkg#@}"
    if [[ "$rest" == *@* ]]; then
      echo "@${rest%%@*}"
    else
      echo "$pkg"
    fi
  else
    echo "${pkg%%@*}"
  fi
}

# Safe npm -g install: works on Arch, Ubuntu, Mac (Homebrew Intel/ARM), NVM.
# Ensures ~/.npmrc prefix is user-writable so npm and tools' auto-updaters
# (e.g. Qwen Code) all install to the same user-owned location.
npm_global_install() {
  local pkg="$1"

  # Source NVM if present — gives us a user-owned npm on all platforms
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

  local prefix
  prefix=$(npm config get prefix 2>/dev/null || echo "/usr")

  # If the prefix is not writable (system-owned), permanently redirect to
  # ~/.npm-global via ~/.npmrc so ALL future npm -g calls use it too —
  # including auto-updaters inside tools like Qwen Code.
  if [[ ! -w "$prefix" ]]; then
    local user_prefix="$HOME/.npm-global"
    mkdir -p "$user_prefix/bin"
    npm config set prefix "$user_prefix"
    if [[ ":$PATH:" != *":$user_prefix/bin:"* ]]; then
      export PATH="$user_prefix/bin:$PATH"
      persist_path_entry "$user_prefix/bin"
    fi
  fi

  # First attempt
  if run_bounded 600 npm install -g "$pkg" 2>&1; then
    return 0
  fi

  # Retry once: ENOTEMPTY means the old package dir is stuck — remove and reinstall
  local pkg_name
  pkg_name=$(_npm_pkg_name "$pkg")
  local npm_prefix
  npm_prefix=$(npm config get prefix 2>/dev/null)
  local stuck_dir="$npm_prefix/lib/node_modules/$pkg_name"
  if [[ -n "$pkg_name" && -d "$stuck_dir" ]]; then
    warn "npm ENOTEMPTY on $pkg_name — removing stuck directory and retrying"
    rm -rf "$stuck_dir"
  fi
  run_bounded 600 npm install -g "$pkg"
}
