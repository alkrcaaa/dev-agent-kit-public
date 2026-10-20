#!/usr/bin/env bash
# Install the Qwen half of dev-agent-kit onto a remote host over SSH.
#
#   bash scripts/remote-qwen-install.sh --host user@target-host
#
# Claude is deliberately out of scope: the remote gets QWEN.md,
# the hook scripts and their wiring, every skill, the extern skill libraries
# and a working MCP subset. No Claude CLI, no ~/.claude, and therefore none of
# the claude.json handling the local installer needs.
#
# Model: stage locally, ship, bootstrap. The remote never clones this repo and
# never fetches submodules — a robot is often on a network that cannot reach
# GitHub, and "it worked on my laptop" is not a deployment strategy. What ships
# is exactly the tree you have checked out and tested here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/platform.sh"

HOST=""
PROFILE="edge"
VLLM_HOST=""
SEND_GITLAB_TOKEN=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/remote-qwen-install.sh --host USER@HOST [options]

  --host USER@HOST      target machine (required)
  --profile edge|workstation
                        edge (default): graph + fetch. No browser stack.
                        workstation:    edge plus playwright.
  --vllm URL            vLLM endpoint the REMOTE should use, including /v1.
                        Defaults to QWEN_BASE_URL from .env. Probed from the
                        remote host, not from here — they are not the same
                        network position.
  --with-gitlab-token   also ship GITLAB_TOKEN. Off by default: it is a
                        personal credential and a shared robot is a place
                        several people can read it from.
  --dry-run             show what would happen; touch nothing.
  -h, --help            this text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)              HOST="$2"; shift 2 ;;
    --profile)           PROFILE="$2"; shift 2 ;;
    --vllm)              VLLM_HOST="$2"; shift 2 ;;
    --with-gitlab-token) SEND_GITLAB_TOKEN=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown argument: $1 (use --help)" >&2; exit 1 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "ERROR: --host is required" >&2; usage; exit 1; }
case "$PROFILE" in
  edge|workstation) ;;
  *) echo "ERROR: unknown profile '$PROFILE' (edge|workstation)" >&2; exit 1 ;;
esac

if [[ -z "$VLLM_HOST" && -f "$REPO_ROOT/.env" ]]; then
  VLLM_HOST=$(grep -E '^QWEN_BASE_URL=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)
ssh_run() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

# ---------------------------------------------------------------- preflight

REMOTE_HOME=""

preflight() {
  section "Preflight — $HOST"

  # Orient before changing anything: confirm it is the box you meant.
  local ident
  if ! ident=$(ssh_run 'echo "$(hostname)|$(uname -m)|$(uname -s)|$HOME"' 2>&1); then
    fail "cannot reach $HOST over SSH (BatchMode: key auth must already work)
       $ident"
  fi
  IFS='|' read -r r_host r_arch r_kernel REMOTE_HOME <<<"$ident"
  ok "host=$r_host arch=$r_arch kernel=$r_kernel home=$REMOTE_HOME"

  ssh_run 'command -v python3 >/dev/null' \
    || fail "python3 missing on $HOST — hooks and MCP config generation need it"
  ok "python3 present"

  local node_major
  node_major=$(ssh_run 'command -v node >/dev/null && node --version | sed "s/v\([0-9]*\).*/\1/" || echo 0')
  if [[ "$node_major" -ge 22 ]]; then
    ok "node $(ssh_run 'node --version')"
  else
    info "node <22 or absent — the bootstrap will install it via nvm"
  fi

  # Reachability is a property of the remote's network position, not ours.
  if [[ -n "$VLLM_HOST" ]]; then
    if ssh_run "curl -sS --max-time 5 -o /dev/null '${VLLM_HOST%/}/models'" 2>/dev/null; then
      ok "vLLM reachable from $HOST: $VLLM_HOST"
    else
      warn "vLLM at $VLLM_HOST does NOT answer from $HOST — shipping the config anyway,"
      warn "but qwen there will fail until the endpoint is reachable or --vllm is corrected"
    fi
  else
    warn "no vLLM URL (pass --vllm or set QWEN_BASE_URL in .env) — qwen will have no model"
  fi
}

# ------------------------------------------------------------------ staging

STAGE=""
cleanup() { [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"; }
trap cleanup EXIT

build_stage() {
  section "Staging locally"

  STAGE=$(mktemp -d)

  # The existing deploy functions already write to $QWEN_CONFIG_DIR, so
  # pointing it at a staging dir reuses them verbatim — the remote gets the
  # same bytes the local install would produce, from one code path.
  QWEN_CONFIG_DIR="$STAGE"
  export QWEN_CONFIG_DIR
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/agents.sh"

  _deploy_qwen_md
  _deploy_qwen_hooks
  _deploy_qwen_settings_json
  _deploy_qwen_skills

  # Qwen-side policy: the trimmed tool menus and the session cap derived from
  # the server's max_model_len. Not cosmetic — Qwen's ceiling is a hard wall
  # past which vLLM refuses the request outright, so a remote install without
  # these is one long session away from failing. Same functions the local
  # install calls, pointed at the stage.
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/mcp.sh"
  _configure_qwen_settings ""
  if [[ -n "$VLLM_HOST" ]]; then
    _configure_qwen_cli_env "$VLLM_HOST"
  fi

  # extern ships as real directories, not the symlink the local install uses:
  # there is no clone on the far side to point at.
  if [[ -d "$REPO_ROOT/extern" ]]; then
    mkdir -p "$STAGE/extern"
    rsync -a --exclude '.git' "$REPO_ROOT/extern/" "$STAGE/extern/"
    ok "extern skill libraries copied ($(find "$STAGE/extern" -maxdepth 1 -mindepth 1 -type d | wc -l) libraries)"
  else
    warn "extern/ missing — run: git submodule update --init --recursive"
  fi

  # Every skill points at ~/.claude/extern, which does not exist on a
  # Claude-less host. Repoint them at the copy we are actually shipping.
  local rewritten=0
  if [[ -d "$STAGE/skills" ]]; then
    # [~] rather than a bare ~ so this reads as the literal pattern it is.
    rewritten=$(grep -rl '[~]/\.claude/extern' "$STAGE/skills" 2>/dev/null | wc -l)
    grep -rl '[~]/\.claude/extern' "$STAGE/skills" 2>/dev/null \
      | xargs -r sed -i 's|~/\.claude/extern|~/.qwen/extern|g'
  fi
  ok "$rewritten skill file(s) repointed to ~/.qwen/extern"

  # code-review-graph installs from source on the remote — ship the source.
  local crg_src="$REPO_ROOT/mcp-infra/code-review-graph"
  if [[ -d "$crg_src" ]]; then
    mkdir -p "$STAGE/.src"
    rsync -a --exclude '.git' "$crg_src/" "$STAGE/.src/code-review-graph/"
    ok "code-review-graph source staged"
  else
    warn "code-review-graph submodule missing — that MCP will be skipped"
  fi

  ok "stage ready: $(du -sh "$STAGE" | cut -f1)"
}

# ------------------------------------------------------------------ shipping

ship_stage() {
  section "Shipping to $HOST:~/.qwen/"

  # No --delete: the remote's ~/.qwen may hold its own settings and state that
  # this kit does not own. Stale skills are reported instead of silently
  # removed — deleting files on someone else's machine needs a human.
  rsync -az -e "ssh ${SSH_OPTS[*]}" "$STAGE/" "$HOST:.qwen/"
  ok "payload synced"
}

# ---------------------------------------------------------------- bootstrap

bootstrap_remote() {
  section "Bootstrapping on $HOST"

  local gitlab_token_value=""
  if [[ "$SEND_GITLAB_TOKEN" -eq 1 ]]; then
    gitlab_token_value=$(grep -E '^GITLAB_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
    [[ -n "$gitlab_token_value" ]] && warn "shipping GITLAB_TOKEN to $HOST as requested"
  fi

  # Everything below runs on the remote. Each optional step is guarded: one
  # missing package must not end the run before the config is written.
  ssh "${SSH_OPTS[@]}" "$HOST" \
      PROFILE="$PROFILE" \
      VLLM_HOST="$VLLM_HOST" \
      GITLAB_TOKEN_VALUE="$gitlab_token_value" \
      bash -s <<'REMOTE'
set -uo pipefail
QDIR="$HOME/.qwen"

echo "--- node/qwen CLI"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
node_major=$(command -v node >/dev/null && node --version | sed 's/v\([0-9]*\).*/\1/' || echo 0)
if [[ "$node_major" -lt 22 ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash >/dev/null 2>&1 || true
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
  nvm install 22 >/dev/null 2>&1 || echo "  ! node install failed"
fi
command -v node >/dev/null && echo "  node $(node --version)" || echo "  ! node unavailable"

npm install -g @qwen-code/qwen-code >/dev/null 2>&1 \
  && echo "  qwen $(qwen --version 2>/dev/null | head -1)" \
  || echo "  ! qwen CLI install failed"

echo "--- MCP servers"
npm install -g mcp-fetch-server >/dev/null 2>&1 \
  && echo "  fetch: ok" || echo "  ! fetch MCP install failed"

crg_bin=""
if [[ -d "$QDIR/.src/code-review-graph" ]]; then
  if ! command -v uv >/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if command -v uv >/dev/null; then
    uv tool install --force "$QDIR/.src/code-review-graph" >/dev/null 2>&1 \
      && crg_bin="$(command -v code-review-graph || true)"
  fi
fi
[[ -n "$crg_bin" ]] && echo "  code-review-graph: $crg_bin" || echo "  ! code-review-graph unavailable"

echo "--- settings.json"
python3 - "$QDIR/settings.json" <<PY
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

profile = os.environ.get("PROFILE", "edge")
vllm = os.environ.get("VLLM_HOST", "")
token = os.environ.get("GITLAB_TOKEN_VALUE", "")

servers = cfg.setdefault("mcpServers", {})

servers["fetch"] = {"command": "mcp-fetch-server"}

crg = "$crg_bin"
if crg:
    servers["code-review-graph"] = {"command": crg, "args": ["serve"]}
else:
    servers.pop("code-review-graph", None)

if profile == "workstation":
    servers["playwright"] = {
        "command": "npx",
        "args": ["@playwright/mcp@latest", "--headless", "--no-sandbox"],
    }
else:
    # A headless robot has no use for a browser stack.
    servers.pop("playwright", None)

# The staged config was generated on the source machine, so some entries name
# absolute paths from there (a mem-lite server, under another user's home).
# Anything pointing at a path that does not exist here would
# surface as a failed server on every session — drop it and say so.
#
# args matter as much as command: mem-lite runs as `node /home/<them>/...`,
# so checking only the command would keep a permanently broken entry.
for name, entry in list(servers.items()):
    if not isinstance(entry, dict):
        continue
    candidates = [entry.get("command", "")] + [
        a for a in entry.get("args", []) if isinstance(a, str)
    ]
    missing = next(
        (c for c in candidates if c.startswith("/") and not os.path.exists(c)), None
    )
    if missing:
        servers.pop(name)
        print("  dropped %s: %s does not exist on this host" % (name, missing))

if vllm:
    cfg.setdefault("model", {})
    env = cfg.setdefault("env", {})
    env["OPENAI_BASE_URL"] = vllm

if token:
    cfg.setdefault("env", {})["GITLAB_TOKEN"] = token

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("  mcpServers: " + ", ".join(sorted(servers)) or "  mcpServers: none")
PY

echo "--- verify"
rc=0
[[ -f "$QDIR/QWEN.md" ]]      && echo "  QWEN.md ok"      || { echo "  ! QWEN.md MISSING"; rc=1; }
[[ -d "$QDIR/skills" ]]       && echo "  skills: $(ls -1 "$QDIR/skills" | wc -l)" || { echo "  ! skills MISSING"; rc=1; }
[[ -d "$QDIR/hooks" ]]        && echo "  hooks: $(ls -1 "$QDIR/hooks" | wc -l)"   || { echo "  ! hooks MISSING"; rc=1; }
[[ -d "$QDIR/extern" ]]       && echo "  extern: $(ls -1 "$QDIR/extern" | wc -l) libraries" || { echo "  ! extern MISSING"; rc=1; }
python3 -c "import json;json.load(open('$QDIR/settings.json'))" 2>/dev/null \
  && echo "  settings.json parses" || { echo "  ! settings.json INVALID"; rc=1; }
if grep -rq '~/\.claude/extern' "$QDIR/skills" 2>/dev/null; then
  echo "  ! skills still point at ~/.claude/extern (no Claude here — they would load empty)"
  rc=1
fi
exit $rc
REMOTE
}

# ---------------------------------------------------------------------- main

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-kit — remote Qwen install"
echo "  Target   : $HOST"
echo "  Profile  : $PROFILE"
echo "  vLLM     : ${VLLM_HOST:-<none>}"
echo "  Token    : $([[ $SEND_GITLAB_TOKEN -eq 1 ]] && echo "GITLAB_TOKEN will be sent" || echo "not sent")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

preflight

if [[ "$DRY_RUN" -eq 1 ]]; then
  build_stage
  section "Dry run"
  info "would rsync $(du -sh "$STAGE" | cut -f1) to $HOST:~/.qwen/ and bootstrap there"
  find "$STAGE" -maxdepth 1 -mindepth 1 -printf '    %f\n' | sort
  echo ""
  ok "dry run complete — nothing was changed on $HOST"
  exit 0
fi

build_stage
ship_stage

RC=0
bootstrap_remote || RC=$?

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $RC -eq 0 ]]; then
  echo "  ✓ Remote Qwen install complete on $HOST"
  echo ""
  echo "  Start it there:  ssh $HOST -t qwen"
else
  echo "  ! Remote install finished WITH PROBLEMS (see verify above)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit $RC
