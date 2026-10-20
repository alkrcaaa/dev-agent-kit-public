#!/usr/bin/env bash
# Runs inside the fresh-machine container: clone, install, then assert the
# things a passing install.sh cannot tell you about itself.
#
# Deliberately not `set -e` — every assertion below must run even after an
# earlier one fails, so one broken install yields the full picture.
set -uo pipefail

SRC=/src
CLONE="$HOME/dev-agent-kit"

PASS=0
FAIL=0
check() {
    local label="$1"; shift
    if "$@"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        FAIL=$((FAIL + 1))
    fi
}

echo "### fresh-machine install test"
echo "### user=$(whoami) HOME=$HOME"

# The bind mount is owned by another uid — a harness artifact, not something a
# real clone-from-remote would hit.
git config --global --add safe.directory '*'
if ! git clone "$SRC" "$CLONE" 2>&1 | tail -2; then
    echo "### clone failed — aborting"
    exit 90
fi
cd "$CLONE" || exit 91

# A clone carries committed HEAD only. Replay the source tree's uncommitted
# work on top, or this silently tests the previous version of the installer.
if ! git -C "$SRC" diff HEAD --binary > /tmp/wip.patch; then
    echo "### could not read source diff — aborting"
    exit 92
fi
if [[ -s /tmp/wip.patch ]]; then
    git apply /tmp/wip.patch || { echo "### applying uncommitted changes failed"; exit 93; }
    echo "### testing HEAD $(git rev-parse --short HEAD) + $(wc -l < /tmp/wip.patch) lines of uncommitted work"
else
    echo "### testing HEAD $(git rev-parse --short HEAD) (clean tree)"
fi

if [[ -f .env ]]; then
    echo "### unexpected: .env present in a fresh clone — it should be gitignored"
fi

# A hang is the failure this bound exists to catch: an install that waits on
# a prompt or a stalled download never exits on its own. stdin is /dev/null,
# as on a machine where nobody is watching the terminal.
BOUND="${DAK_FRESH_TIMEOUT:-2700}"
LOG="$HOME/install.log"
echo "### === install.sh: start $(date +%H:%M:%S) (bound ${BOUND}s) ==="
start=$(date +%s)
timeout -k 30 "$BOUND" bash install.sh </dev/null 2>&1 | tee "$LOG"
install_rc=${PIPESTATUS[0]}
elapsed=$(( $(date +%s) - start ))
echo "### === install.sh: exit $install_rc at $(date +%H:%M:%S) after ${elapsed}s ==="
log_has() { sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -qE "$1"; }

# Hook commands registered in one host config (Claude/Qwen: top-level
# "hooks"; Antigravity: the whole hooks.json).
hook_count() {
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print(0); sys.exit(0)
root = cfg.get("hooks", {}) if sys.argv[2] == "hooks" else cfg
n = 0
def walk(x):
    global n
    if isinstance(x, dict):
        n += isinstance(x.get("command"), str)
        for v in x.values(): walk(v)
    elif isinstance(x, list):
        for v in x: walk(v)
walk(root)
print(n)
PYEOF
}

echo ""
echo "### assertions"

check "install.sh finished within ${BOUND}s (no hang)" test "$install_rc" -ne 124 -a "$install_rc" -ne 137
check "install.sh exits 0" test "$install_rc" -eq 0

# Every host gets its hooks, whatever else failed along the way.
check "Claude hooks registered (~/.claude/settings.json)" \
    test "$(hook_count "$HOME/.claude/settings.json" hooks)" -gt 0
check "Qwen hooks registered (~/.qwen/settings.json)" \
    test "$(hook_count "$HOME/.qwen/settings.json" hooks)" -gt 0
check "Antigravity hooks registered (~/.gemini/config/hooks.json)" \
    test "$(hook_count "$HOME/.gemini/config/hooks.json" root)" -gt 0
check "verify printed a per-host hook count" \
    log_has 'Claude hooks: [0-9]+ registered'

# The vault hooks are wired as `[ -f "$H" ] || true`: an empty bridge
# submodule would switch them off without a word.
check "obsidian-mirror hook script resolves through ~/.claude/extern" \
    test -f "$HOME/.claude/extern/obsidian-vault-bridge/hooks/obsidian-mirror.py"
check "no EMPTY SUBMODULE warning" bash -c "! grep -q 'EMPTY SUBMODULE' '$LOG'"

# No .env, no vault: the install must say so instead of leaving the vault
# hooks silently off.
check "vault warning printed (VAULT NOT CONFIGURED)" \
    log_has 'VAULT NOT CONFIGURED'
check "vault.env not written without vault variables" \
    test ! -e "$HOME/.config/dev-agent-kit/vault.env"

# The split that a same-machine test can never catch: Claude Code reads
# ~/.claude.json, this kit writes ~/.claude/claude.json. If they are not one
# file, every MCP registered above is invisible to Claude Code.
check "HOME/.claude.json and HOME/.claude/claude.json are one file" \
    test "$(readlink -f "$HOME/.claude.json" 2>/dev/null)" = "$(readlink -f "$HOME/.claude/claude.json" 2>/dev/null)"

# Read through the path Claude Code itself uses, not the one we wrote to.
for mcp in code-review-graph playwright fetch mem-lite; do
    check "MCP '$mcp' registered in the file Claude Code reads" \
        python3 -c "import json,sys;sys.exit(0 if '$mcp' in json.load(open('$HOME/.claude.json')).get('mcpServers',{}) else 1)"
done

# The other half of registration: an opt-in server must stay out when its
# env var is unset. A fresh machine has no .env, and a server that can only
# answer "not configured" still costs every session its tool schemas.
check "MCP 'vault-search' NOT registered without VAULT_DIR" \
    python3 -c "import json,sys;sys.exit(1 if 'vault-search' in json.load(open('$HOME/.claude.json')).get('mcpServers',{}) else 0)"

check "skills deployed" test -n "$(ls -A "$HOME/.claude/skills" 2>/dev/null)"

# The extern symlink points into the cloned repo; a dangling link silently
# empties every skill that reads from it.
check "extern symlink resolves" test -d "$HOME/.claude/extern"
check "extern symlink has content" test -n "$(ls -A "$HOME/.claude/extern" 2>/dev/null)"

echo ""
echo "### Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
