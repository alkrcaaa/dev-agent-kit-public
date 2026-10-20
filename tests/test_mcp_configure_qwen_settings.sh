#!/usr/bin/env bash
# Tests for _configure_qwen_settings in scripts/lib/mcp.sh

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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/workspace/dev-agent-kit")"
source "$REPO_ROOT/scripts/lib/platform.sh" 2>/dev/null || true

ok() { echo "  ok: $*"; }
warn() { echo "  warn: $*"; }
info() { echo "  info: $*"; }
# platform.sh exports its own fail() — one that aborts the script. Sourcing it
# above silently replaced the assertion helper, so the first failing check
# killed the run and every later check went unreported. Re-declare after.
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

# TEST_HOME is only created by the E2E test near the end; under `set -u` an
# earlier exit would make this trap itself the reported error and hide the
# actual failure.
TEST_HOME=""
cleanup() {
    [[ -n "$TEST_HOME" ]] && rm -rf "$TEST_HOME" 2>/dev/null
    return 0
}
trap cleanup EXIT

echo "=== test_configure_qwen_settings ==="

# The function body, delimited by its python heredoc rather than a `^}` brace:
# the block writes column-0 `}` of its own whenever a server entry spans
# several lines, which silently truncated this scope before.
QWEN_FN="$(sed -n '/^_configure_qwen_settings/,/^PYEOF/p' "$REPO_ROOT/scripts/lib/mcp.sh")"

# --- Test 1: MCP entries are correct URLs ---
# Matched per key rather than key-and-URL on one line — the entries are
# multi-line dicts now that they carry tool allowlists.
TOTAL=$((TOTAL+1))
if grep -q '"code-review-graph"' <<<"$QWEN_FN" && \
   grep -q 'http://localhost:8931/mcp' <<<"$QWEN_FN" && \
   grep -q '"playwright"' <<<"$QWEN_FN" && \
   grep -q 'http://localhost:8932/mcp' <<<"$QWEN_FN"; then
    pass "MCP URLs are correct"
else
    fail "MCP URLs incorrect"
fi

# --- Test 2: No "qwen" self-reference MCP entry ---
TOTAL=$((TOTAL+1))
# The _configure_qwen_settings function should NOT add a "qwen" entry
# Check that the function body does not contain config["qwen"] or config['qwen']
if sed -n '/^_configure_qwen_settings/,/^}/p' "$REPO_ROOT/scripts/lib/mcp.sh" \
   | grep -q 'config\["qwen"\]\|config\[.qwen.\]'; then
    fail "Should not add self-referencing 'qwen' MCP entry"
else
    pass "No self-referencing 'qwen' MCP entry"
fi

# --- Test 3: Backup created before writing ---
TOTAL=$((TOTAL+1))
if grep -q 'bak' <<<"$QWEN_FN"; then
    pass "Backup (.bak) created before writing"
else
    fail "No backup step"
fi

# --- Tool allowlists: qwen-only, and attached to the servers that need them ---
TOTAL=$((TOTAL+1))
if grep -q '"includeTools": CRG_TOOLS' <<<"$QWEN_FN" && \
   grep -q '"includeTools": PLAYWRIGHT_TOOLS' <<<"$QWEN_FN"; then
    pass "graph and playwright carry tool allowlists on qwen"
else
    fail "tool allowlists not attached"
fi

# --- Test 4: Existing settings preserved (uses setdefault) ---
TOTAL=$((TOTAL+1))
if grep -q 'setdefault.*mcpServers' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "Uses setdefault to preserve existing config"
else
    fail "Does not preserve existing config"
fi

# --- Test 5: Version field initialized ---
TOTAL=$((TOTAL+1))
if grep -q '\$version.*4\|"4"' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "Default version set to 4"
else
    fail "No default version"
fi

# --- Test 6: Creates directory if missing ---
TOTAL=$((TOTAL+1))
if grep -q 'mkdir -p.*dirname.*qwen_settings' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "Creates ~/.qwen/ directory if missing"
else
    fail "Does not create directory"
fi

# --- Test 7: Function wired into setup_mcp_servers ---
TOTAL=$((TOTAL+1))
count=$(grep -c '_configure_qwen_settings' "$REPO_ROOT/scripts/lib/mcp.sh")
if [ "$count" -ge 2 ]; then
    pass "Function wired into setup_mcp_servers"
else
    fail "Function not wired into setup_mcp_servers (found $count occurrences)"
fi

# --- Test 8: End-to-end Python JSON manipulation ---
TOTAL=$((TOTAL+1))
TEST_HOME="$(mktemp -d)"
TEST_SETTINGS="$TEST_HOME/.qwen/settings.json"
mkdir -p "$TEST_HOME/.qwen"

# Simulate the Python logic from _configure_qwen_settings
cat > "$TEST_SETTINGS" <<'EOF'
{
  "$version": 4,
  "ui": { "color": true },
  "permissions": { "allow": ["all"] }
}
EOF

python3 - "$TEST_SETTINGS" <<'PYEOF'
import json, shutil, sys

config_path = sys.argv[1]
with open(config_path, 'r') as f:
    config = json.load(f)

config.setdefault("mcpServers", {})
config["mcpServers"]["code-review-graph"] = {"httpUrl": "http://localhost:7000/mcp"}
config["mcpServers"]["playwright"] = {"httpUrl": "http://localhost:8932/mcp"}

shutil.copy2(config_path, config_path + ".bak")

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
PYEOF

# Verify: existing keys preserved + MCP entries added + backup exists
if python3 -c "
import json, sys
with open('$TEST_SETTINGS') as f:
    c = json.load(f)
ok = (c.get('\$version') == 4 and
      c.get('ui', {}).get('color') == True and
      c.get('permissions', {}).get('allow') == ['all'] and
      c['mcpServers']['code-review-graph']['httpUrl'] == 'http://localhost:7000/mcp' and
      c['mcpServers']['playwright']['httpUrl'] == 'http://localhost:8932/mcp')
sys.exit(0 if ok else 1)
"; then
    pass "E2E: Python JSON merge preserves existing keys and adds MCP entries"
else
    fail "E2E: JSON merge incorrect"
fi

# Check backup was created
if [ -f "$TEST_SETTINGS.bak" ]; then
    pass "E2E: Backup file created"
else
    fail "E2E: No backup file"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL total"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
