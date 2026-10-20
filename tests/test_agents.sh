#!/usr/bin/env bash
# Test suite for scripts/lib/agents.sh
# Run: bash tests/test_agents.sh

set -Eeuo pipefail

PASS=0
FAIL=0
TEST_DIR=""

# setup() redirects REPO_ROOT and HOME at temp fixtures; the wrapper checks
# below inspect the real repo and the real skill library, so capture both here,
# before any test has run.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $*"
}

fail_test() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $*" >&2
}

setup() {
  TEST_DIR="$(mktemp -d)"
  export REPO_ROOT="$TEST_DIR/repo"
  export CLAUDE_CONFIG_DIR="$TEST_DIR/claude_config"
  export HOME="$TEST_DIR"

  mkdir -p "$REPO_ROOT/claude"
  mkdir -p "$REPO_ROOT/extern"
  mkdir -p "$CLAUDE_CONFIG_DIR"

  # Create CLAUDE.md
  cat > "$REPO_ROOT/claude/CLAUDE.md" <<'EOF'
# Claude Agent Setup
Orchestrator instructions
EOF

  # Create extern file
  echo "extern skill content" > "$REPO_ROOT/extern/skill.txt"

  # Source the helpers that agents.sh depends on
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
  ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
  fail()    { echo "FAIL_FROM_LIB: $*" >&2; return 1; }
  warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
  info()    { echo -e "  ${CYAN}→${RESET} $*"; }
  section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

  # Source the library (resolve path relative to this script's location)
  local _script_dir
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$_script_dir/../scripts/lib/agents.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

run_test() {
  local name="$1"
  local fn="$2"
  setup
  if eval "$fn"; then
    pass "$name"
  else
    fail_test "$name"
  fi
  teardown
}

# --- Tests ---

test_verify_templates_passes_with_claude_md() {
  _verify_templates >/dev/null 2>&1
}

test_deploy_claude_md_copies_file() {
  _deploy_claude_md >/dev/null 2>&1
  if [[ -f "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]]; then
    local content
    content=$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")
    [[ "$content" == *"Orchestrator instructions"* ]]
  else
    return 1
  fi
}

test_deploy_claude_md_backups_existing() {
  # Pre-populate existing CLAUDE.md
  echo "old content" > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
  _deploy_claude_md >/dev/null 2>&1

  local backup_count
  backup_count=$(find "$CLAUDE_CONFIG_DIR/backups" -name 'CLAUDE.md.backup.*' 2>/dev/null | wc -l)
  [[ "$backup_count" -ge 1 ]]
}

test_retire_agents_removes_kit_agents_keeps_user_agents() {
  mkdir -p "$CLAUDE_CONFIG_DIR/agents"
  echo "kit" > "$CLAUDE_CONFIG_DIR/agents/reviewer.md"
  echo "kit" > "$CLAUDE_CONFIG_DIR/agents/general-purpose.md"
  echo "mine" > "$CLAUDE_CONFIG_DIR/agents/my-agent.md"
  _retire_agents "$CLAUDE_CONFIG_DIR/agents" claude >/dev/null 2>&1

  [[ ! -f "$CLAUDE_CONFIG_DIR/agents/reviewer.md" ]] &&
    [[ ! -f "$CLAUDE_CONFIG_DIR/agents/general-purpose.md" ]] &&
    [[ -f "$CLAUDE_CONFIG_DIR/agents/my-agent.md" ]]
}

test_retire_agents_tolerates_missing_dir() {
  _retire_agents "$TEST_DIR/nope" claude >/dev/null 2>&1
}

test_deploy_extern_symlink() {
  _deploy_extern_symlink >/dev/null 2>&1
  [[ -L "$CLAUDE_CONFIG_DIR/extern" ]]
}

test_deploy_agents_full_flow() {
  deploy_agents >/dev/null 2>&1
  [[ -f "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]] &&
    [[ ! -e "$CLAUDE_CONFIG_DIR/agents" ]] &&
    [[ -L "$CLAUDE_CONFIG_DIR/extern" ]]
}

# --- Qwen parity: the same hooks/skills/settings must land on both agents ---

# Populates the fake repo with the sources the qwen deploy functions read.
_seed_shared_sources() {
  mkdir -p "$REPO_ROOT/claude/hooks" "$REPO_ROOT/claude/skills/demo" "$REPO_ROOT/qwen"
  echo "print('hook')" > "$REPO_ROOT/claude/hooks/demo-hook.py"
  echo "# Demo" > "$REPO_ROOT/claude/skills/demo/SKILL.md"
  cat > "$REPO_ROOT/qwen/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "read_file",
        "hooks": [{"type": "command", "command": "DAK_AGENT=qwen python3 demo"}]
      }
    ]
  }
}
EOF
}

test_deploy_qwen_hooks_copies_shared_sources() {
  _seed_shared_sources
  _deploy_qwen_hooks >/dev/null 2>&1
  [[ -f "$QWEN_CONFIG_DIR/hooks/demo-hook.py" ]] &&
    [[ -x "$QWEN_CONFIG_DIR/hooks/demo-hook.py" ]]
}

test_deploy_qwen_skills_copies_claude_skills() {
  _seed_shared_sources
  _deploy_qwen_skills >/dev/null 2>&1
  [[ -f "$QWEN_CONFIG_DIR/skills/demo/SKILL.md" ]]
}

test_deploy_qwen_settings_creates_when_absent() {
  _seed_shared_sources
  _deploy_qwen_settings_json >/dev/null 2>&1
  grep -q 'read_file' "$QWEN_CONFIG_DIR/settings.json"
}

# The live file also holds mcpServers/model/auth — a merge that clobbers those
# would silently unregister every MCP server on the qwen side.
test_deploy_qwen_settings_preserves_existing_keys() {
  _seed_shared_sources
  mkdir -p "$QWEN_CONFIG_DIR"
  cat > "$QWEN_CONFIG_DIR/settings.json" <<'EOF'
{
  "mcpServers": {"mem-lite": {"command": "node"}},
  "model": {"sessionTokenLimit": 12345},
  "hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "user-own-hook"}]}]}
}
EOF
  _deploy_qwen_settings_json >/dev/null 2>&1
  python3 - "$QWEN_CONFIG_DIR/settings.json" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
cmds = {h["command"]
        for entries in cfg["hooks"].values()
        for e in entries for h in e.get("hooks", [])}
assert cfg["mcpServers"]["mem-lite"]["command"] == "node", "mcpServers lost"
assert cfg["model"]["sessionTokenLimit"] == 12345, "model settings lost"
assert "user-own-hook" in cmds, "user's own hook lost"
assert any("DAK_AGENT=qwen" in c for c in cmds), "our hooks not merged in"
PYEOF
}

test_deploy_qwen_settings_merge_is_idempotent() {
  _seed_shared_sources
  _deploy_qwen_settings_json >/dev/null 2>&1
  _deploy_qwen_settings_json >/dev/null 2>&1
  [[ "$(grep -c 'DAK_AGENT=qwen' "$QWEN_CONFIG_DIR/settings.json")" -eq 1 ]]
}

# --- Claude settings merge ---
# The merge is additive, so retiring a kit hook needs an explicit removal; the
# user's own hooks must survive it.
test_deploy_settings_retires_kit_hooks_keeps_user_hooks() {
  mkdir -p "$REPO_ROOT/claude" "$CLAUDE_CONFIG_DIR"
  cp "$KIT_ROOT/claude/settings.json" "$REPO_ROOT/claude/settings.json"
  cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'EOF'
{
  "hooks": {"PreToolUse": [
    {"matcher": "Agent|Task", "hooks": [{"type": "command", "command": "python3 \"$HOME/.claude/hooks/qwen-consider.py\""}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "user-own-hook"}]}
  ]}
}
EOF
  _deploy_settings_json >/dev/null 2>&1
  _deploy_settings_json >/dev/null 2>&1
  python3 - "$CLAUDE_CONFIG_DIR/settings.json" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
cmds = [h["command"] for entries in cfg["hooks"].values()
        for e in entries for h in e.get("hooks", [])]
assert not any("qwen-consider" in c for c in cmds), "retired hook still wired"
assert "user-own-hook" in cmds, "user's own hook lost"
assert sum("commit-attribution-guard" in c for c in cmds) == 1, "kit hooks not merged once"
assert all(e.get("hooks") for entries in cfg["hooks"].values() for e in entries), "empty entry left"
PYEOF
}

# --- Skill wrappers: no pointer-only skills ---
# Measured on qwen 2026-08-09: the model invokes the skill tool but never
# follows a path inside the result to a second file, so a wrapper whose whole
# content is "read ~/.claude/extern/..." delivers nothing. Every wrapper that
# defers to extern material must carry its own operative core, and every path
# it names must exist — three wrappers pointed at plugin README install blurbs
# rather than the actual SKILL.md.
test_skill_wrappers_carry_operative_core() {
  # ~/.claude/extern is a symlink to the kit's extern/ (_deploy_extern_symlink),
  # so resolve pointers through the checkout: the check then holds in CI and on
  # machines where the kit is not installed.
  python3 - "$KIT_ROOT/claude/skills" "$KIT_ROOT" <<'PYEOF'
import os, re, sys
root, kit = sys.argv[1], sys.argv[2]
bad = []
for name in sorted(os.listdir(root)):
    p = os.path.join(root, name, "SKILL.md")
    if not os.path.isfile(p):
        continue
    body = open(p, encoding="utf-8").read()
    points_out = "~/.claude/extern" in body
    core = ""
    if "<!-- gate:begin -->" in body and "<!-- gate:end -->" in body:
        core = body.split("<!-- gate:begin -->", 1)[1].split("<!-- gate:end -->", 1)[0].strip()
    if points_out and len(core) < 300:
        bad.append("%s: defers to extern with no operative core" % name)
    for ref in re.findall(r"~/\.claude/extern/[^`)\s]*", body):
        rel = ref[len("~/.claude/"):]
        # A private submodule CI cannot clone leaves an empty directory; its
        # pointers are checked wherever it is checked out.
        sub = os.path.join(kit, *rel.split("/")[:2])
        if os.path.isdir(sub) and not os.listdir(sub):
            continue
        if not os.path.exists(os.path.join(kit, rel)):
            bad.append("%s: dangling pointer %s" % (name, ref))
assert not bad, "\n".join(bad)
PYEOF
}

# --- Qwen memory parity ---
# claude-mem-lite hard-codes Claude's tool vocabulary (pre-tool-recall.js gates
# on ['Edit','Write','NotebookEdit','Read']), so pointing its hooks straight at
# a qwen session silently recalls nothing. mem-bridge.py canonicalises the one
# field that differs; these tests pin both halves of that contract.
test_mem_bridge_canonicalises_qwen_tool_names() {
  python3 - "$KIT_ROOT/claude/hooks" <<'PYEOF'
import json, subprocess, sys
hooks = sys.argv[1]
payload = json.dumps({"session_id": "t", "tool_name": "edit",
                      "tool_input": {"file_path": "/tmp/x.py"}})
# The "child" just echoes back what it was handed on stdin.
child = ["python3", "-c", "import sys; sys.stdout.write(sys.stdin.read())"]
r = subprocess.run(["python3", hooks + "/mem-bridge.py"] + child,
                   input=payload, capture_output=True, text=True)
seen = json.loads(r.stdout)
assert seen["tool_name"] == "Edit", "wire name not canonicalised: %r" % seen["tool_name"]
assert seen["tool_input"]["file_path"] == "/tmp/x.py", "payload mangled"
PYEOF
}

# Memory is an enhancement: a broken/missing mem-lite must never block a tool
# call or take the session down.
# The checker runs on every SessionStart, so its silence when healthy is not a
# nicety -- it is what lets it run there at all. A version that prints a status
# line on a clean system is ambient cost on every session, which is the reason
# the last layer with no consumer got cut.
test_consistency_check_is_silent_when_healthy() {
  local home; home="$(mktemp -d)"
  local out
  out="$(HOME="$home" python3 "$KIT_ROOT/claude/hooks/consistency-check.py" --oneline 2>&1)"
  rm -rf "$home"
  [[ -z "$out" ]] || { echo "clean system printed: $out"; return 1; }
}

# ...and speaks when an invariant is broken. A hook wired to a script that is
# not on disk degrades to nothing at all: every wrapper is
# `[ -f "$H" ] && ... || true`, which is how compile-nudge shipped dead.
test_consistency_check_reports_a_missing_hook() {
  local home; home="$(mktemp -d)"
  mkdir -p "$home/.claude"
  cat > "$home/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command",
  "command":"python3 \"$HOME/.claude/hooks/not-a-real-hook.py\""}]}]}}
JSON
  local out rc
  out="$(HOME="$home" python3 "$KIT_ROOT/claude/hooks/consistency-check.py" --oneline 2>&1)"
  HOME="$home" python3 "$KIT_ROOT/claude/hooks/consistency-check.py" >/dev/null 2>&1; rc=$?
  rm -rf "$home"
  [[ "$out" == *"I2"* ]] || { echo "missing hook not reported: $out"; return 1; }
  [[ $rc -eq 1 ]] || { echo "full report exited $rc, expected 1"; return 1; }
}

test_mem_bridge_fails_open() {
  python3 - "$KIT_ROOT/claude/hooks" <<'PYEOF'
import subprocess, sys
hooks = sys.argv[1]
for case, argv, stdin in (
    ("missing child", ["definitely-not-a-real-binary-xyz"], '{"tool_name":"edit"}'),
    ("non-json stdin", ["true"], "not json at all"),
    ("no argv", [], '{"tool_name":"edit"}'),
    ("child exits 2", ["python3", "-c", "raise SystemExit(2)"], '{"tool_name":"edit"}'),
):
    r = subprocess.run(["python3", hooks + "/mem-bridge.py"] + argv,
                       input=stdin, capture_output=True, text=True)
    assert r.returncode == 0, "%s: exit %d (would block the tool)" % (case, r.returncode)
PYEOF
}

# Qwen fires SessionStart/Stop/UserPromptSubmit/PreToolUse/PostToolUse (verified
# empirically against a real `qwen -p` run). The memory hooks must be wired to
# all of them with WIRE tool names — a "Read" or "Edit" matcher here matches
# nothing and fails silently.
test_qwen_settings_wires_memory_with_wire_names() {
  python3 - "$KIT_ROOT/qwen/settings.json" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))["hooks"]
def cmds(event):
    return [h["command"] for e in cfg.get(event, []) for h in e.get("hooks", [])]

for event in ("SessionStart", "Stop", "UserPromptSubmit", "PreToolUse", "PostToolUse"):
    assert event in cfg, "qwen settings missing %s" % event
assert any("session-start" in c for c in cmds("SessionStart")), "no startup memory injection"
assert any("hook.mjs stop" in c for c in cmds("Stop")), "no session-end save"
assert any("user-prompt" in c for c in cmds("UserPromptSubmit")), "no per-prompt recall"

bridged = [(e.get("matcher", ""), h["command"])
           for ev in ("PreToolUse", "PostToolUse")
           for e in cfg[ev] for h in e.get("hooks", [])
           if "mem-bridge" in h["command"]]
assert bridged, "mem-lite hooks not bridged on qwen"
for matcher, _ in bridged:
    assert not any(c.isupper() for c in matcher), \
        "matcher %r uses Claude names — matches nothing on qwen" % matcher
assert any("pre-tool-recall" in c for _, c in bridged), "no pre-edit recall"
PYEOF
}

# --- Qwen tool surface ---
# A 27B picks worse from a longer menu, and every schema rides in the 235k
# window on every call. The allowlist must stay a subset of what the server
# offers AND a superset of what the kit's own guidance names, or the docs teach
# tools the model cannot see (the exact defect the stale LSP section had).
test_qwen_tool_allowlist_matches_documented_tools() {
  python3 - "$KIT_ROOT" <<'PYEOF'
import os, re, sys
root = sys.argv[1]
src = open(os.path.join(root, "scripts/lib/mcp.sh")).read()
m = re.search(r"CRG_TOOLS\s*=\s*\[(.*?)\]", src, re.S)
assert m, "CRG_TOOLS allowlist missing from mcp.sh"
allow = set(re.findall(r'"([^"]+)"', m.group(1)))
assert "get_minimal_context_tool" in allow, "the mandated first call is not allowlisted"

docs = []
for p in ("qwen/QWEN.md", "claude/CLAUDE.md"):
    docs.append(open(os.path.join(root, p), encoding="utf-8").read())
skills = os.path.join(root, "claude/skills")
for name in os.listdir(skills):
    f = os.path.join(skills, name, "SKILL.md")
    if os.path.isfile(f):
        docs.append(open(f, encoding="utf-8").read())

referenced = set()
for body in docs:
    referenced |= set(re.findall(r"\b[a-z_]+_tool\b", body))
missing = sorted(referenced - allow)
assert not missing, "guidance names tools qwen cannot see: %s" % missing
PYEOF
}

# --- Runner ---


# --- vault-compile timer ------------------------------------------------------

_stage_vault_timer_fixture() {
  # The gate reads the deployed tool through CLAUDE_CONFIG_DIR/extern, which is
  # a symlink to REPO_ROOT/extern in a real install.
  mkdir -p "$REPO_ROOT/extern/obsidian-vault-bridge/tools"
  : > "$REPO_ROOT/extern/obsidian-vault-bridge/tools/vault-compile.py"
  ln -sfn "$REPO_ROOT/extern" "$CLAUDE_CONFIG_DIR/extern"
}

test_vault_timer_writes_units() {
  setup
  _stage_vault_timer_fixture
  mkdir -p "$HOME/.config/dev-agent-kit"
  echo "VAULT_DIR=$TEST_DIR/vault" > "$HOME/.config/dev-agent-kit/vault.env"

  DAK_SKIP_SYSTEMD=1 VAULT_DIR="" _deploy_vault_timer >/dev/null

  local unit_dir="$HOME/.config/systemd/user"
  local svc="$unit_dir/vault-compile.service"
  local tmr="$unit_dir/vault-compile.timer"

  [[ -f "$svc" && -f "$tmr" ]] || { teardown; return 1; }
  grep -q -- "--all --apply" "$svc" || { teardown; return 1; }
  # A miss must be made up, or the note simply drifts another day.
  grep -q "^Persistent=true" "$tmr" || { teardown; return 1; }
  # PATH is the one thing the unit must carry: `claude` lives in ~/.local/bin.
  grep -q "^Environment=PATH=.*\.local/bin" "$svc" || { teardown; return 1; }
  # VAULT_DIR must NOT be baked in -- vault.env stays the single source of
  # truth, so a reinstall that moves the vault is picked up without re-writing
  # the unit.
  grep -q "^Environment=VAULT_DIR" "$svc" && { teardown; return 1; }
  # The dashboard follows the compile, and its failure must not fail the run.
  grep -q "^ExecStartPost=-/usr/bin/env python3 .*/vault-stats.py$" "$svc" || { teardown; return 1; }

  teardown
}

test_vault_timer_skipped_without_vault() {
  setup
  _stage_vault_timer_fixture
  # No vault.env, no VAULT_DIR: nothing to compile, so nothing to schedule.
  DAK_SKIP_SYSTEMD=1 VAULT_DIR="" _deploy_vault_timer >/dev/null

  [[ -e "$HOME/.config/systemd/user/vault-compile.timer" ]] && { teardown; return 1; }
  teardown
}


main() {
  echo "=== agents.sh tests ==="
  run_test "verify_templates passes with CLAUDE.md present" test_verify_templates_passes_with_claude_md
  run_test "deploy_claude_md copies file" test_deploy_claude_md_copies_file
  run_test "deploy_claude_md backs up existing" test_deploy_claude_md_backups_existing
  run_test "retire_agents removes kit agents, keeps user agents" test_retire_agents_removes_kit_agents_keeps_user_agents
  run_test "retire_agents tolerates a missing dir" test_retire_agents_tolerates_missing_dir
  run_test "deploy_extern creates symlink" test_deploy_extern_symlink
  run_test "deploy_agents full flow succeeds" test_deploy_agents_full_flow
  run_test "vault: timer units written when a vault is configured" test_vault_timer_writes_units
  run_test "vault: timer skipped when no vault is configured" test_vault_timer_skipped_without_vault
  run_test "qwen: hooks deploy from the shared claude/hooks source" test_deploy_qwen_hooks_copies_shared_sources
  run_test "qwen: skills deploy from the shared claude/skills source" test_deploy_qwen_skills_copies_claude_skills
  run_test "qwen: settings.json created when absent" test_deploy_qwen_settings_creates_when_absent
  run_test "qwen: settings merge preserves mcpServers/model/user hooks" test_deploy_qwen_settings_preserves_existing_keys
  run_test "qwen: settings merge is idempotent" test_deploy_qwen_settings_merge_is_idempotent
  run_test "claude: settings merge retires kit hooks, keeps user hooks" test_deploy_settings_retires_kit_hooks_keeps_user_hooks
  run_test "skills: no pointer-only wrappers, no dangling pointers" test_skill_wrappers_carry_operative_core
  run_test "qwen: mem-bridge canonicalises wire tool names" test_mem_bridge_canonicalises_qwen_tool_names
  run_test "qwen: mem-bridge fails open, never blocks a tool" test_mem_bridge_fails_open
  run_test "qwen: memory hooks wired on every fired event, wire names only" test_qwen_settings_wires_memory_with_wire_names
  run_test "qwen: graph tool allowlist covers everything the docs teach" test_qwen_tool_allowlist_matches_documented_tools
  run_test "consistency: silent on a healthy system" test_consistency_check_is_silent_when_healthy
  run_test "consistency: a wired-but-missing hook is reported" test_consistency_check_reports_a_missing_hook

  echo ""
  echo "Results: $PASS passed, $FAIL failed"

  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
