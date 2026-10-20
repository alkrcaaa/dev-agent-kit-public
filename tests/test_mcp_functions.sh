#!/usr/bin/env bash
# Tests for pure logic in scripts/lib/mcp.sh
# Covers: _crg_works, _write_openai_env, _configure_claude_json

set -Eeuo pipefail

PASS=0; FAIL=0; TOTAL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
assert_file_contains() {
    local file="$1" pattern="$2" label="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label (expected '$pattern' in $file)"
    fi
}
assert_file_not_contains() {
    local file="$1" pattern="$2" label="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        fail "$label (unexpected '$pattern' in $file)"
    else
        pass "$label"
    fi
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/workspace/dev-agent-kit")"
source "$REPO_ROOT/scripts/lib/platform.sh" 2>/dev/null || true

ok() { echo "  ok: $*"; }
warn() { echo "  warn: $*"; }
info() { echo "  info: $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

TEST_DIR=""
cleanup() {
    [[ -n "$TEST_DIR" ]] && rm -rf "$TEST_DIR" 2>/dev/null
    return 0
}
trap cleanup EXIT

echo "=== test_mcp_functions ==="

TEST_DIR="$(mktemp -d)"
export HOME="$TEST_DIR"
export REPO_ROOT="$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/lib/mcp.sh"

# --- _crg_works ---

echo ""
echo "── _crg_works ──"

# Absent binary — strip code-review-graph from PATH
_clean_path="$(echo "$PATH" | tr ':' '\n' | grep -v 'code-review-graph' | paste -sd: || echo /usr/bin)"
# Use env to run in a clean PATH
if env PATH="/usr/bin" bash -c 'source '"$REPO_ROOT"'/scripts/lib/platform.sh 2>/dev/null; source '"$REPO_ROOT"'/scripts/lib/mcp.sh; _crg_works' 2>/dev/null; then
    fail "_crg_works fails when code-review-graph is absent"
    FAIL=$((FAIL + 1))
else
    pass "_crg_works fails when code-review-graph is absent"
    PASS=$((PASS + 1))
fi

# Present but broken
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/code-review-graph" <<'EOF'
#!/usr/bin/env bash
echo "broken" >&2
exit 1
EOF
chmod +x "$TEST_DIR/bin/code-review-graph"
if env PATH="$TEST_DIR/bin:/usr/bin" bash -c 'source '"$REPO_ROOT"'/scripts/lib/platform.sh 2>/dev/null; source '"$REPO_ROOT"'/scripts/lib/mcp.sh; _crg_works' 2>/dev/null; then
    fail "_crg_works fails when binary is present but broken"
    FAIL=$((FAIL + 1))
else
    pass "_crg_works fails when binary is present but broken"
    PASS=$((PASS + 1))
fi

# Healthy
cat > "$TEST_DIR/bin/code-review-graph" <<'EOF'
#!/usr/bin/env bash
echo "2.3.3"
exit 0
EOF
chmod +x "$TEST_DIR/bin/code-review-graph"
if env PATH="$TEST_DIR/bin:/usr/bin" bash -c 'source '"$REPO_ROOT"'/scripts/lib/platform.sh 2>/dev/null; source '"$REPO_ROOT"'/scripts/lib/mcp.sh; _crg_works' 2>/dev/null; then
    pass "_crg_works succeeds with healthy binary"
    PASS=$((PASS + 1))
else
    fail "_crg_works succeeds with healthy binary"
    FAIL=$((FAIL + 1))
fi

# --- _write_openai_env ---

echo ""
echo "── _write_openai_env ──"

# Fresh file
_write_openai_env "$TEST_DIR/openai.env" "http://localhost:8002/v1" "/models/qwen3.6"
assert_file_contains "$TEST_DIR/openai.env" "OPENAI_API_KEY=not-needed" "writes API key placeholder"
assert_file_contains "$TEST_DIR/openai.env" "OPENAI_BASE_URL=http://localhost:8002/v1" "writes base URL"
assert_file_contains "$TEST_DIR/openai.env" "OPENAI_MODEL=/models/qwen3.6" "writes model"

# Empty model — should not write OPENAI_MODEL line
_write_openai_env "$TEST_DIR/openai2.env" "http://localhost:8002/v1" ""
assert_file_contains "$TEST_DIR/openai2.env" "OPENAI_BASE_URL=http://localhost:8002/v1" "writes base URL without model"
assert_file_not_contains "$TEST_DIR/openai2.env" "OPENAI_MODEL=" "skips model line when empty"

# Update existing file — preserves non-managed lines
cat > "$TEST_DIR/openai3.env" <<'EOF'
# My custom comment
CUSTOM_VAR=hello
OPENAI_BASE_URL=http://old-host/v1
EOF
_write_openai_env "$TEST_DIR/openai3.env" "http://new-host/v1" "/models/new"
assert_file_contains "$TEST_DIR/openai3.env" "CUSTOM_VAR=hello" "preserves non-managed lines"
assert_file_contains "$TEST_DIR/openai3.env" "# My custom comment" "preserves comments"
assert_file_contains "$TEST_DIR/openai3.env" "OPENAI_BASE_URL=http://new-host/v1" "updates base URL"
assert_file_not_contains "$TEST_DIR/openai3.env" "http://old-host/v1" "removes old base URL"

# Exactly one OPENAI_BASE_URL after update
count=$(grep -c '^OPENAI_BASE_URL=' "$TEST_DIR/openai3.env" || true)
TOTAL=$((TOTAL + 1))
if [[ "$count" -eq 1 ]]; then
    pass "exactly one OPENAI_BASE_URL after rewrite"
else
    fail "expected 1 OPENAI_BASE_URL, got $count"
    FAIL=$((FAIL + 1))
fi

# --- _configure_claude_json ---

echo ""
echo "── _configure_claude_json ──"

# Create a fake mcp-fetch-server so the function detects it
mkdir -p "$TEST_DIR/bin"
echo '#!/usr/bin/env bash' > "$TEST_DIR/bin/mcp-fetch-server"
chmod +x "$TEST_DIR/bin/mcp-fetch-server"

# Create ~/.claude/claude.json with existing keys
mkdir -p "$TEST_DIR/.claude"
cat > "$TEST_DIR/.claude/claude.json" <<'EOF'
{
  "mcpServers": {
    "existing-server": {"command": "existing-cmd"}
  },
  "customSetting": "preserve-me"
}
EOF

# Run in subshell with isolated PATH so code-review-graph from system doesn't interfere
env PATH="$TEST_DIR/bin:/usr/bin:/usr/local/bin" HOME="$TEST_DIR" REPO_ROOT="$REPO_ROOT" bash -c '
  source '"$REPO_ROOT"'/scripts/lib/platform.sh 2>/dev/null || true
  ok() { echo "  ok: $*"; }
  warn() { echo "  warn: $*"; }
  info() { echo "  info: $*"; }
  fail() { echo "FAIL_FROM_LIB: $*" >&2; return 1; }
  source '"$REPO_ROOT"'/scripts/lib/mcp.sh
  _configure_claude_json "" ""
' 2>/dev/null

# Preserves existing mcpServers
assert_file_contains "$TEST_DIR/.claude/claude.json" "existing-server" "preserves existing MCP server entries"

# Preserves unrelated top-level keys
assert_file_contains "$TEST_DIR/.claude/claude.json" "customSetting" "preserves unrelated config keys"

# Adds playwright
assert_file_contains "$TEST_DIR/.claude/claude.json" "playwright" "adds playwright MCP server"

# Adds fetch (mcp-fetch-server is on PATH)
assert_file_contains "$TEST_DIR/.claude/claude.json" "fetch" "adds fetch MCP server when binary exists"

# Backup created
if [[ -f "$TEST_DIR/.claude/claude.json.bak" ]]; then
    pass "backup file created before writing"
else
    fail "no backup file created"
    FAIL=$((FAIL + 1))
fi

# Idempotency — run again and verify no duplication
env PATH="$TEST_DIR/bin:/usr/bin:/usr/local/bin" HOME="$TEST_DIR" REPO_ROOT="$REPO_ROOT" bash -c '
  source '"$REPO_ROOT"'/scripts/lib/platform.sh 2>/dev/null || true
  ok() { echo "  ok: $*"; }
  warn() { echo "  warn: $*"; }
  info() { echo "  info: $*"; }
  fail() { echo "FAIL_FROM_LIB: $*" >&2; return 1; }
  source '"$REPO_ROOT"'/scripts/lib/mcp.sh
  _configure_claude_json "" ""
' 2>/dev/null

# Count playwright entries — should be exactly 1
playwright_count=$(grep -c '"playwright"' "$TEST_DIR/.claude/claude.json" || true)
TOTAL=$((TOTAL + 1))
if [[ "$playwright_count" -eq 1 ]]; then
    pass "idempotent: playwright appears exactly once after second run"
else
    fail "idempotency: playwright appears $playwright_count times (expected 1)"
    FAIL=$((FAIL + 1))
fi

# Existing server still preserved after second run
assert_file_contains "$TEST_DIR/.claude/claude.json" "existing-server" "existing server preserved after second run"

# --- _council_shim_unit ---

echo ""
echo "── _council_shim_unit ──"

_council_shim_unit claude-code CLAUDE claude_code_shim.py /srv/council 172.17.0.1 > "$TEST_DIR/shim.service"
assert_file_contains "$TEST_DIR/shim.service" "EnvironmentFile=/srv/council/.env" "shim reads the secret from the council .env"
assert_file_contains "$TEST_DIR/shim.service" "Environment=CLAUDE_SHIM_HOST=172.17.0.1" "shim binds the docker gateway, not all interfaces"
assert_file_contains "$TEST_DIR/shim.service" "ExecStart=/usr/bin/env python3 /srv/council/infra/local-models/claude_code_shim.py" "shim ExecStart points at the council checkout"
assert_file_not_contains "$TEST_DIR/shim.service" "SHIM_SECRET=" "no secret value is written into the unit file"

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL total"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
