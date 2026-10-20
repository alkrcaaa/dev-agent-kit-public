#!/usr/bin/env bash
# Host-side driver for the fresh-machine install test.
#
#   bash tests/fresh-install/fresh-install-test.sh [log-path]
#
# Builds a clean Ubuntu image, clones this repo into it (working tree
# included), runs install.sh, and asserts the result. Takes ~15 minutes and
# needs network, so it is not wired into the per-push test battery — run it
# whenever install.sh or scripts/lib/ changes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$REPO_ROOT/tests/fresh-install"
IMAGE="dev-agent-kit-fresh"
LOG="${1:-/tmp/dak-fresh-install.log}"

if ! command -v docker &>/dev/null; then
    echo "docker not found — this test needs it to simulate a clean machine" >&2
    exit 2
fi
if ! docker info &>/dev/null; then
    echo "cannot reach the docker daemon (permissions? not running?)" >&2
    exit 2
fi

echo "building $IMAGE..."
docker build -q -f "$HERE/Dockerfile" -t "$IMAGE" "$HERE" >/dev/null

echo "running install in a clean container — ~15 min, streaming to $LOG"
rc=0
mounts=(-v "$REPO_ROOT":/src:ro)
# In a git worktree .git is a file naming the main repo's git dir by absolute
# path; mount that dir at the same path or the in-container clone fails.
if [[ -f "$REPO_ROOT/.git" ]]; then
    common="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)"
    mounts+=(-v "$common":"$common":ro)
fi
# Pass-through knobs: DAK_FRESH_TIMEOUT (install bound), and the installer's
# own DAK_SKIP_PLAYWRIGHT_BROWSER / DAK_SKIP_EMBEDDINGS / DAK_PLAYWRIGHT_TIMEOUT.
envs=()
for v in DAK_FRESH_TIMEOUT DAK_SKIP_PLAYWRIGHT_BROWSER DAK_SKIP_EMBEDDINGS DAK_PLAYWRIGHT_TIMEOUT; do
    [[ -n "${!v:-}" ]] && envs+=(-e "$v=${!v}")
done
docker run --rm "${mounts[@]}" "${envs[@]}" \
    "$IMAGE" bash /home/tester/run-in-container.sh >"$LOG" 2>&1 || rc=$?

echo ""
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | sed -n '/^### assertions/,$p'
echo ""
if [[ $rc -eq 0 ]]; then
    echo "fresh install OK — full log: $LOG"
else
    echo "fresh install FAILED (exit $rc) — full log: $LOG"
fi
exit "$rc"
