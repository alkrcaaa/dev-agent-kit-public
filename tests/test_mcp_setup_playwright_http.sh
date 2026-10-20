#!/usr/bin/env bash
# Tests for _setup_playwright_http in scripts/lib/mcp.sh

set -euo pipefail

PASS=0; FAIL=0; TOTAL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
assert_exit_zero() { if [ $? -eq 0 ]; then pass "$*"; else fail "$*"; fi; }
assert_exit_nonzero() { if [ $? -ne 0 ]; then pass "$*"; else fail "$*"; fi; }
assert_file_contains() {
    local file="$1" pattern="$2" label="$3"
    TOTAL=$((TOTAL+1))
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (expected '$pattern' in $file)"
    fi
}
assert_file_exists() {
    local file="$1" label="$2"
    TOTAL=$((TOTAL+1))
    if [ -f "$file" ]; then
        pass "$label"
    else
        fail "$label ($file not found)"
    fi
}

# Source helpers
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/workspace/dev-agent-kit")"
source "$REPO_ROOT/scripts/lib/platform.sh" 2>/dev/null || true

# Minimal stubs if platform.sh didn't provide them
ok()      { echo "  ok: $*"; }
warn()    { echo "  warn: $*"; }
info()    { echo "  info: $*"; }

cleanup() {
    rm -rf "$TEST_HOME" "$TEST_LOG" "$TEST_SERVICE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== test_mcp_setup_playwright_http ==="

# --- Test 1: Port already in use → early return ---
TOTAL=$((TOTAL+1))
TEST_HOME="$(mktemp -d)"
TEST_LOG="$TEST_HOME/.qwen/playwright-mcp.log"
TEST_SERVICE_FILE="$TEST_HOME/.config/systemd/user/playwright-mcp.service"

# The port check lives in platform.sh (port_in_use); mcp.sh calls it.
if grep -q 'port_in_use "$port"' "$REPO_ROOT/scripts/lib/mcp.sh" && \
   grep -q 'ss -tlnp' "$REPO_ROOT/scripts/lib/platform.sh"; then
    pass "Port-in-use check present (mcp.sh → platform.sh:port_in_use)"
else
    fail "Port-in-use check missing"
fi

# port_in_use must degrade gracefully where ss is absent (macOS)
TOTAL=$((TOTAL+1))
if grep -q 'lsof -i' "$REPO_ROOT/scripts/lib/platform.sh" && \
   grep -q 'netstat -an' "$REPO_ROOT/scripts/lib/platform.sh"; then
    pass "port_in_use has lsof/netstat fallbacks"
else
    fail "port_in_use missing non-ss fallback"
fi

# --- Test 2: systemd service file content ---
TOTAL=$((TOTAL+1))
# The daemon is launched through a wrapper (~/.local/bin/playwright-mcp-start) so
# nvm/npm-global PATH is set up before npx runs; ExecStart points at the wrapper.
if grep -q 'playwright-mcp.service' "$REPO_ROOT/scripts/lib/mcp.sh" && \
   grep -q 'ExecStart=${wrapper}' "$REPO_ROOT/scripts/lib/mcp.sh" && \
   grep -q 'exec npx @playwright/mcp@latest --port 8932 --headless' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "systemd ExecStart points at the wrapper, wrapper execs playwright-mcp"
else
    fail "systemd ExecStart incorrect"
fi

# Wrapper must source nvm — without it systemd's minimal PATH has no npx
TOTAL=$((TOTAL+1))
if grep -q 'source "$NVM_DIR/nvm.sh"' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "wrapper sources nvm before exec"
else
    fail "wrapper does not set up nvm PATH"
fi

# --- Test 3: Service has restart policy ---
TOTAL=$((TOTAL+1))
if grep -q 'Restart=on-failure' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "Service has Restart=on-failure"
else
    fail "Missing Restart policy"
fi

# --- Test 4: nohup fallback exists ---
TOTAL=$((TOTAL+1))
if grep -q 'nohup "$wrapper"' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "nohup fallback present"
else
    fail "nohup fallback missing"
fi

# --- Test 5: Log file path ---
TOTAL=$((TOTAL+1))
if grep -q '\$HOME/.qwen/playwright-mcp.log' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "Log file path is ~/.qwen/playwright-mcp.log"
else
    fail "Log file path incorrect"
fi

# --- Test 6: systemctl --user daemon-reload ---
TOTAL=$((TOTAL+1))
if grep -q 'systemctl --user daemon-reload' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "systemd daemon-reload present"
else
    fail "Missing daemon-reload"
fi

# --- Test 7: WantedBy=default.target ---
TOTAL=$((TOTAL+1))
if grep -q 'WantedBy=default.target' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "Service has WantedBy=default.target"
else
    fail "Missing WantedBy"
fi

TOTAL=$((TOTAL+1))
# Verify the function is called in setup_mcp_servers
count=$(grep -c '_setup_playwright_http' "$REPO_ROOT/scripts/lib/mcp.sh")
if [ "$count" -ge 2 ]; then
    pass "Function wired into setup_mcp_servers"
else
    fail "Function not wired into setup_mcp_servers (found $count occurrences)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL total"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
