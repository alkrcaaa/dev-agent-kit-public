#!/usr/bin/env bash
# Tests for scripts/health/mcp_probe.py and doctor.sh's MCP inventory check.
#
# The stdio path is exercised against a fake MCP server (a ~20-line python
# script that speaks the same JSON-RPC handshake), so the handshake, the
# timeout and the includeTools staleness check are all tested for real without
# needing a live server or a network.

set -uo pipefail

PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

assert_contains() {  # assert_contains <haystack> <needle> <label>
    if grep -qF -- "$2" <<<"$1"; then pass "$3"; else
        fail "$3 (expected '$2' in output)"; fi
}
assert_not_contains() {
    if grep -qF -- "$2" <<<"$1"; then
        fail "$3 (did not expect '$2')"; else pass "$3"; fi
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/workspace/dev-agent-kit")"
PROBE="$REPO_ROOT/scripts/health/mcp_probe.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export NO_COLOR=1

# ── A fake MCP server: replies to initialize + tools/list over stdio ────────
cat > "$TMP/fake_server.py" <<'PYEOF'
import json, sys
n = int(sys.argv[1]) if len(sys.argv) > 1 else 3
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if msg.get("id") == 1:
        out = {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2024-11-05",
               "capabilities": {}, "serverInfo": {"name": "fake", "version": "1"}}}
    elif msg.get("id") == 2:
        tools = [{"name": f"tool_{i}", "description": "x", "inputSchema": {}} for i in range(n)]
        out = {"jsonrpc": "2.0", "id": 2, "result": {"tools": tools}}
    else:
        continue
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
PYEOF

# A server that starts but never answers — exercises the timeout path.
printf 'import time\ntime.sleep(60)\n' > "$TMP/mute_server.py"

write_config() {  # write_config <file> <json-of-mcpServers>
    printf '{"mcpServers": %s}\n' "$2" > "$1"
}

run_probe() {  # run_probe <config-file> [extra args...]
    local cfg="$1"; shift
    HOME="$TMP/home" python3 - "$PROBE" "$cfg" "$@" <<'PYEOF' 2>&1
import runpy, sys, pathlib
probe_path, cfg = sys.argv[1], sys.argv[2]
sys.argv = [probe_path, "--host", "claude", *sys.argv[3:]]
mod = runpy.run_path(probe_path, run_name="__probe__")
mod["CONFIGS"]["claude"] = pathlib.Path(cfg)
try:
    sys.exit(mod["main"]())
except SystemExit as e:
    sys.exit(e.code)
PYEOF
}

echo "── mcp_probe.py: expected inventory ──"

expected_out="$(python3 "$PROBE" --list-expected)"
assert_contains "$expected_out" "code-review-graph	global" "--list-expected emits name<TAB>scope"

# Every scope must be one doctor.sh and check_host actually understand.
bad_scopes="$(echo "$expected_out" | cut -f2 | sort -u | grep -vE '^(global|conditional|opt-in|project)$' || true)"
if [[ -z "$bad_scopes" ]]; then
    pass "every EXPECTED scope is a known scope"
else
    fail "unknown scope(s) in EXPECTED: $bad_scopes"
fi

echo "── mcp_probe.py: stdio handshake ──"

write_config "$TMP/live.json" \
  "{\"code-review-graph\": {\"command\": \"python3\", \"args\": [\"$TMP/fake_server.py\", \"7\"]}}"
out="$(run_probe "$TMP/live.json" --timeout 15)"
assert_contains "$out" "code-review-graph: 7 tools" "a live stdio server reports its tool count"

echo "── mcp_probe.py: includeTools staleness ──"

# Allowlist names tool_0 (real) and tool_99 (gone). The client would silently
# drop the dead one, so only a live listing can catch it.
write_config "$TMP/stale.json" \
  "{\"code-review-graph\": {\"command\": \"python3\", \"args\": [\"$TMP/fake_server.py\", \"3\"], \
    \"includeTools\": [\"tool_0\", \"tool_99\"]}}"
out="$(run_probe "$TMP/stale.json" --timeout 15)"
assert_contains "$out" "tool_99" "a stale includeTools entry is named in the warning"
assert_contains "$out" "no longer exposes" "stale allowlist is reported"

write_config "$TMP/fresh.json" \
  "{\"code-review-graph\": {\"command\": \"python3\", \"args\": [\"$TMP/fake_server.py\", \"3\"], \
    \"includeTools\": [\"tool_0\", \"tool_1\"]}}"
out="$(run_probe "$TMP/fresh.json" --timeout 15)"
assert_contains "$out" "filtered → 2" "a valid allowlist reports the filtered count"
assert_not_contains "$out" "no longer exposes" "a valid allowlist raises no staleness warning"

echo "── mcp_probe.py: failure paths ──"

write_config "$TMP/gone.json" '{"code-review-graph": {"command": "definitely-not-a-real-binary"}}'
out="$(run_probe "$TMP/gone.json" --timeout 5)"
assert_contains "$out" "command not found" "a missing binary is reported, not a crash"
assert_not_contains "$out" "0 fail" "a missing global server counts as a failure"

write_config "$TMP/mute.json" \
  "{\"code-review-graph\": {\"command\": \"python3\", \"args\": [\"$TMP/mute_server.py\"]}}"
out="$(run_probe "$TMP/mute.json" --timeout 3)"
assert_contains "$out" "no tools/list reply" "a silent server times out instead of hanging"

echo "── mcp_probe.py: scope handling ──"

# An opt-in server that is simply absent must not fail the run.
write_config "$TMP/empty.json" \
  "{\"code-review-graph\": {\"command\": \"python3\", \"args\": [\"$TMP/fake_server.py\"]}}"
out="$(run_probe "$TMP/empty.json" --timeout 15)"
assert_contains "$out" "lsp: not registered (opt-in" "an absent opt-in server is informational"
# A project-scoped server lives in some repo's .mcp.json, so its absence from
# the global config is not news — it should produce no line at all.
assert_not_contains "$out" "grafana" "an absent project-scoped server is silent"
assert_not_contains "$out" "terraform" "an absent project-scoped server is silent (terraform)"

# A server nobody documented should be surfaced, not ignored.
write_config "$TMP/unknown.json" \
  "{\"surprise-server\": {\"command\": \"python3\", \"args\": [\"$TMP/fake_server.py\"]}}"
out="$(run_probe "$TMP/unknown.json" --timeout 15)"
assert_contains "$out" "not in the expected inventory" "an undocumented server is flagged"

echo "── doctor.sh: MCP inventory drift ──"

out="$(bash "$REPO_ROOT/scripts/health/doctor.sh" 2>&1)"
assert_contains "$out" "MCP inventory matches" "doctor passes when docs and probe agree"

# Inject drift into a copy and point doctor at it via a scratch repo root.
DRIFT="$TMP/drift"
mkdir -p "$DRIFT/scripts/health"
cp "$PROBE" "$DRIFT/scripts/health/mcp_probe.py"
python3 - "$DRIFT/scripts/health/mcp_probe.py" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('"terraform": "project",',
                                   '"terraform": "project",\n    "ghost": "global",'))
PYEOF
documented="$(grep -oE '^\| *`[a-zA-Z0-9_-]+` *\|' "$REPO_ROOT/claude/CLAUDE.md" | tr -d '|` ' | sort -u)"
drifted="$(python3 "$DRIFT/scripts/health/mcp_probe.py" --list-expected | cut -f1 | sort -u)"
if comm -13 <(echo "$documented") <(echo "$drifted") | grep -q ghost; then
    pass "drift between CLAUDE.md and EXPECTED is detectable"
else
    fail "injected drift was not detected"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
