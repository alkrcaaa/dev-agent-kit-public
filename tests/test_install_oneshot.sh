#!/usr/bin/env bash
# Tests for one-shot install guarantees:
#   persist_path_entry / ensure_local_bin_on_path / _npm_pkg_name (platform.sh)
#   _write_openai_env / _configure_qwen_cli_env wiring (mcp.sh)

set -euo pipefail

PASS=0; FAIL=0; TOTAL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
assert_eq() {
    local got="$1" want="$2" label="$3"
    TOTAL=$((TOTAL+1))
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label (got '$got', want '$want')"
    fi
}
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
source "$REPO_ROOT/scripts/lib/platform.sh"

TEST_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TEST_HOME" 2>/dev/null || true; }
trap cleanup EXIT

echo "=== test_install_oneshot ==="

# --- persist_path_entry: writes to the active shell's RC ---
(
    export HOME="$TEST_HOME" SHELL=/usr/bin/zsh
    persist_path_entry "$HOME/.local/bin" >/dev/null
)
assert_file_contains "$TEST_HOME/.zshrc" 'export PATH="$HOME/.local/bin:$PATH"' \
    "persist_path_entry writes \$HOME-relative export to .zshrc for zsh"

(
    export HOME="$TEST_HOME" SHELL=/bin/bash
    persist_path_entry "$HOME/.npm-global/bin" >/dev/null
)
assert_file_contains "$TEST_HOME/.bashrc" 'export PATH="$HOME/.npm-global/bin:$PATH"' \
    "persist_path_entry writes to .bashrc for bash"

(
    export HOME="$TEST_HOME" SHELL=/bin/fish
    persist_path_entry "$HOME/.local/bin" >/dev/null
)
assert_file_contains "$TEST_HOME/.profile" 'export PATH="$HOME/.local/bin:$PATH"' \
    "persist_path_entry falls back to .profile for other shells"

# --- persist_path_entry: idempotent ---
(
    export HOME="$TEST_HOME" SHELL=/usr/bin/zsh
    persist_path_entry "$HOME/.local/bin" >/dev/null
    persist_path_entry "$HOME/.local/bin" >/dev/null
)
count=$(grep -cF '.local/bin' "$TEST_HOME/.zshrc")
assert_eq "$count" "1" "persist_path_entry is idempotent (no duplicate lines)"

# --- persist_path_entry: respects an existing user-written spelling ---
echo 'export PATH=~/.cargo/bin:$PATH' > "$TEST_HOME/.zshrc2"
(
    export HOME="$TEST_HOME" SHELL=/usr/bin/zsh
    mv "$HOME/.zshrc2" "$HOME/.zshrc"
    persist_path_entry "$HOME/.cargo/bin" >/dev/null
)
count=$(grep -cF '.cargo/bin' "$TEST_HOME/.zshrc")
assert_eq "$count" "1" "persist_path_entry skips dirs already in RC (any spelling)"

# --- persist_path_entry: dirs outside \$HOME written literally ---
(
    export HOME="$TEST_HOME" SHELL=/usr/bin/zsh
    persist_path_entry "/opt/tools/bin" >/dev/null
)
assert_file_contains "$TEST_HOME/.zshrc" 'export PATH="/opt/tools/bin:$PATH"' \
    "persist_path_entry writes non-HOME dirs as absolute paths"

# --- ensure_local_bin_on_path: exports and persists when missing ---
(
    export HOME="$TEST_HOME" SHELL=/bin/bash
    rm -f "$HOME/.bashrc"
    export PATH="/usr/bin:/bin"
    ensure_local_bin_on_path >/dev/null
    [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || exit 1
    grep -qF '.local/bin' "$HOME/.bashrc" || exit 2
)
TOTAL=$((TOTAL+1))
case $? in
    0) pass "ensure_local_bin_on_path exports for session AND persists to RC" ;;
    1) fail "ensure_local_bin_on_path did not export PATH" ;;
    *) fail "ensure_local_bin_on_path did not persist to RC" ;;
esac

# --- _npm_pkg_name: scoped package must NOT collapse to empty (rm -rf guard) ---
assert_eq "$(_npm_pkg_name '@qwen-code/qwen-code')" "@qwen-code/qwen-code" \
    "_npm_pkg_name keeps scoped package intact"
assert_eq "$(_npm_pkg_name '@qwen-code/qwen-code@0.5.0')" "@qwen-code/qwen-code" \
    "_npm_pkg_name strips version from scoped package"
assert_eq "$(_npm_pkg_name 'pyright@1.1.0')" "pyright" \
    "_npm_pkg_name strips version from plain package"
assert_eq "$(_npm_pkg_name 'supergateway')" "supergateway" \
    "_npm_pkg_name passes plain package through"

# --- _write_openai_env: fresh file gets managed keys ---
source "$REPO_ROOT/scripts/lib/mcp.sh"

ENV_FILE="$TEST_HOME/qwen.env"
_write_openai_env "$ENV_FILE" "http://10.0.0.5:8002/v1" "/models/qwen3-27b"
assert_file_contains "$ENV_FILE" "OPENAI_API_KEY=not-needed" "_write_openai_env writes API key"
assert_file_contains "$ENV_FILE" "OPENAI_BASE_URL=http://10.0.0.5:8002/v1" "_write_openai_env writes base URL"
assert_file_contains "$ENV_FILE" "OPENAI_MODEL=/models/qwen3-27b" "_write_openai_env writes model"

# --- _write_openai_env: updates managed keys, preserves foreign lines ---
echo "QWEN_BASE_URL=http://10.0.0.5:8002/v1" >> "$ENV_FILE"
_write_openai_env "$ENV_FILE" "http://10.0.0.9:8002/v1" "/models/qwen4"
assert_file_contains "$ENV_FILE" "OPENAI_BASE_URL=http://10.0.0.9:8002/v1" \
    "_write_openai_env updates base URL on address change"
assert_file_contains "$ENV_FILE" "QWEN_BASE_URL=http://10.0.0.5:8002/v1" \
    "_write_openai_env preserves unmanaged lines"
count=$(grep -c '^OPENAI_BASE_URL=' "$ENV_FILE")
assert_eq "$count" "1" "_write_openai_env keeps exactly one OPENAI_BASE_URL"

# --- _configure_qwen_cli_env: offline server → env still written, model kept ---
(
    export HOME="$TEST_HOME" REPO_ROOT="$TEST_HOME/no-repo"
    mkdir -p "$HOME/.qwen"
    printf 'OPENAI_MODEL=/models/existing\n' > "$HOME/.qwen/.env"
    _configure_qwen_cli_env "http://127.0.0.1:1/v1" >/dev/null 2>&1 || true
)
assert_file_contains "$TEST_HOME/.qwen/.env" "OPENAI_BASE_URL=http://127.0.0.1:1/v1" \
    "_configure_qwen_cli_env writes base URL even when server is offline"
assert_file_contains "$TEST_HOME/.qwen/.env" "OPENAI_MODEL=/models/existing" \
    "_configure_qwen_cli_env keeps previously configured model when detection fails"
assert_file_contains "$TEST_HOME/.qwen/settings.json" '"selectedType": "openai"' \
    "_configure_qwen_cli_env pins auth type to openai"

# --- sampling params pinned even when the server is unreachable ---
# temperature/top_p do not depend on max_model_len, and leaving them unset is
# what produces malformed tool calls on Qwen3.6 — they must land regardless.
TOTAL=$((TOTAL+1))
if python3 - "$TEST_HOME/.qwen/settings.json" <<'PY'
import json, sys
sp = json.load(open(sys.argv[1]))["model"]["generationConfig"]["samplingParams"]
assert sp["temperature"] == 0.6, sp
assert sp["top_p"] == 0.95, sp
assert "max_tokens" not in sp, "max_tokens needs max_model_len; must not be guessed offline"
PY
then
    pass "samplingParams temperature/top_p pinned without a reachable server"
else
    fail "samplingParams not pinned when server is unreachable"
fi

# --- offline server → sessionTokenLimit NOT written (no stale/bogus cap) ---
TOTAL=$((TOTAL+1))
if grep -qF 'sessionTokenLimit' "$TEST_HOME/.qwen/settings.json"; then
    fail "sessionTokenLimit must not be written when server is unreachable"
else
    pass "sessionTokenLimit skipped when server is unreachable"
fi

# --- sessionTokenLimit derived from max_model_len when server responds ---
TOTAL=$((TOTAL+1))
if grep -qF 'max_model_len' "$REPO_ROOT/scripts/lib/mcp.sh" && \
   grep -qF 'sessionTokenLimit' "$REPO_ROOT/scripts/lib/mcp.sh"; then
    pass "sessionTokenLimit wired to server max_model_len in mcp.sh"
else
    fail "sessionTokenLimit not derived from max_model_len"
fi

# --- live server → limits and output budget derived from max_model_len ---
# A stub /v1/models is enough: the whole online branch (session cap, context
# window, max_tokens headroom) is arithmetic on max_model_len.
STUB_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 - "$STUB_PORT" <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"data": [{"id": "/models/stub", "max_model_len": 262144}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
STUB_PID=$!
for _ in $(seq 1 40); do
    curl -fsS --max-time 1 "http://127.0.0.1:$STUB_PORT/models" >/dev/null 2>&1 && break
    sleep 0.1
done
(
    export HOME="$TEST_HOME" REPO_ROOT="$TEST_HOME/no-repo"
    _configure_qwen_cli_env "http://127.0.0.1:$STUB_PORT" >/dev/null 2>&1 || true
)
kill "$STUB_PID" 2>/dev/null || true
wait "$STUB_PID" 2>/dev/null || true

TOTAL=$((TOTAL+1))
if python3 - "$TEST_HOME/.qwen/settings.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["model"]
limit, gen = m["sessionTokenLimit"], m["generationConfig"]
assert limit == 235929, limit
assert gen["contextWindowSize"] == 262144, gen
# prompt cap + output cap must fit inside the served window, or vLLM rejects
# the request outright once a session grows into its own reserve.
assert limit + gen["samplingParams"]["max_tokens"] <= 262144, gen
assert gen["samplingParams"]["max_tokens"] == 262144 - limit, gen
PY
then
    pass "live server: session cap, window and max_tokens all fit max_model_len"
else
    fail "live server: derived model limits do not fit max_model_len"
fi

# --- wiring: setup_mcp_servers calls _configure_qwen_cli_env ---
TOTAL=$((TOTAL+1))
count=$(grep -c '_configure_qwen_cli_env' "$REPO_ROOT/scripts/lib/mcp.sh")
if [ "$count" -ge 2 ]; then
    pass "Function wired into setup_mcp_servers"
else
    fail "Function not wired into setup_mcp_servers (found $count occurrences)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL total"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
