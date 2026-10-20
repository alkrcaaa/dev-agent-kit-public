#!/usr/bin/env bash
# Exercises scripts/remote-qwen-install.sh against a throwaway SSH container
# standing in for the remote host.
#
#   bash tests/remote-install/remote-install-test.sh [log-path]
#
# ~10 minutes, needs Docker and network. Keys, container and image are all
# created and torn down here — nothing touches your ssh config or agent.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO_ROOT/tests/remote-install"
IMAGE="dev-agent-kit-remote-target"
CONTAINER="dak-remote-target"
LOG="${1:-/tmp/dak-remote-install.log}"

PASS=0
FAIL=0
check() {
    local label="$1"; shift
    if "$@"; then
        echo "  PASS: $label"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"; FAIL=$((FAIL + 1))
    fi
}

WORK=""
cleanup() {
    docker rm -f "$CONTAINER" &>/dev/null || true
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

command -v docker &>/dev/null || { echo "docker not found" >&2; exit 2; }
docker info &>/dev/null || { echo "cannot reach the docker daemon" >&2; exit 2; }

WORK=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/id" -C dak-remote-test

echo "building $IMAGE..."
docker build -q -f "$HERE/Dockerfile" -t "$IMAGE" "$HERE" >/dev/null || exit 2

docker rm -f "$CONTAINER" &>/dev/null || true
docker run -d --name "$CONTAINER" -p 0:22 "$IMAGE" >/dev/null
PORT=$(docker port "$CONTAINER" 22 | head -1 | sed 's/.*://')
# -i, or docker does not forward stdin and the key silently never arrives.
docker exec -i -u root "$CONTAINER" bash -c \
    "cat > /home/nvidia/.ssh/authorized_keys && chown nvidia:nvidia /home/nvidia/.ssh/authorized_keys && chmod 600 /home/nvidia/.ssh/authorized_keys" \
    < "$WORK/id.pub"

# Wait for sshd rather than sleeping a guessed interval.
for _ in $(seq 1 30); do
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=2 -i "$WORK/id" -p "$PORT" nvidia@127.0.0.1 true 2>/dev/null && break
    sleep 1
done

if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -i "$WORK/id" -p "$PORT" nvidia@127.0.0.1 true 2>/dev/null; then
    echo "cannot reach the test container over SSH — harness problem, not an installer result" >&2
    exit 2
fi

# The installer shells out to plain `ssh`, so the key and port have to arrive
# through the environment it inherits.
export GIT_SSH_COMMAND="ssh -i $WORK/id -p $PORT"
cat > "$WORK/ssh" <<EOF
#!/usr/bin/env bash
exec /usr/bin/ssh -i "$WORK/id" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "\$@"
EOF
chmod +x "$WORK/ssh"
export PATH="$WORK:$PATH"

echo "running remote installer — streaming to $LOG"
bash "$REPO_ROOT/scripts/remote-qwen-install.sh" \
    --host nvidia@127.0.0.1 --profile edge >"$LOG" 2>&1
installer_rc=$?

remote() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$WORK/id" -p "$PORT" nvidia@127.0.0.1 "$@"; }

# ssh re-splits its command words, which shreds any quoting inside them. Send
# the script over stdin instead so it arrives exactly as written.
remote_sh() { remote bash -s <<<"$1"; }

echo ""
echo "### assertions"
check "installer exits 0" test "$installer_rc" -eq 0
check "QWEN.md shipped"   remote_sh '[ -f ~/.qwen/QWEN.md ]'
check "skills shipped"    remote_sh '[ -n "$(ls -A ~/.qwen/skills 2>/dev/null)" ]'
check "hooks shipped"     remote_sh '[ -n "$(ls -A ~/.qwen/hooks 2>/dev/null)" ]'
check "extern shipped as real dirs, not a dangling symlink" \
    remote_sh '[ -d ~/.qwen/extern ] && [ ! -L ~/.qwen/extern ] && [ -n "$(ls -A ~/.qwen/extern)" ]'
check "settings.json parses" \
    remote_sh 'python3 -c "import json,os;json.load(open(os.path.expanduser(\"~/.qwen/settings.json\")))"'
# The Qwen-side ceiling policy has to survive the trip, or a long session on
# the remote walks into the vLLM wall instead of being warned.
check "session cap present in remote settings.json" \
    remote_sh 'grep -q sessionTokenLimit ~/.qwen/settings.json'
# A plain `! remote grep ...` would also succeed when SSH itself fails, turning
# an unreachable host into a green result. grep says 1 for "ran, found
# nothing"; ssh transport failure is 255. Only 1 counts as absent.
remote_grep_absent() {
    local rc=0
    remote_sh "$1" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 1 ]]
}

# The failure this whole rewrite exists to prevent: on a Claude-less host a
# skill pointing at ~/.claude/extern loads and arrives empty.
check "no skill still points at the Claude-only extern path" \
    remote_grep_absent 'grep -rq "[~]/.claude/extern" ~/.qwen/skills'
check "GITLAB_TOKEN not shipped by default" \
    remote_grep_absent 'grep -q GITLAB_TOKEN ~/.qwen/settings.json'
# Every registered server must actually be runnable here. An entry naming a
# path from the source machine loads and fails on every single session.
check "no MCP entry points at a path missing on this host" \
    remote_sh 'python3 - <<'"'"'PY'"'"'
import json, os, sys
cfg = json.load(open(os.path.expanduser("~/.qwen/settings.json")))
bad = []
for name, e in cfg.get("mcpServers", {}).items():
    if not isinstance(e, dict):
        continue
    for c in [e.get("command", "")] + [a for a in e.get("args", []) if isinstance(a, str)]:
        if c.startswith("/") and not os.path.exists(c):
            bad.append((name, c))
for name, c in bad:
    print("stale: %s -> %s" % (name, c))
sys.exit(1 if bad else 0)
PY'

echo ""
echo "### Results: $PASS passed, $FAIL failed — full log: $LOG"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
