#!/usr/bin/env bash
# Test suite for claude/hooks/crg-gate.py and claude/hooks/bash-edit-guard.py
# Run: bash tests/test_hooks.sh
#
# These regexes are load-bearing (they block/allow live tool calls) and have
# already needed two false-positive fixes — any change to them must keep this
# matrix green.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The suite fires every hook for real, so every run appended ~50 synthetic
# block/nudge decisions to the user's live ~/.claude/hook-metrics.jsonl and
# hook-stats.sh reported them as enforcement. Redirect the whole run -- the
# export is inherited by every hook subprocess and by the in-process probes.
DAK_METRICS_FILE="$(mktemp -t dak-metrics-XXXXXX.jsonl)"
export DAK_METRICS_FILE
trap 'rm -f "$DAK_METRICS_FILE" "$DAK_METRICS_FILE.1"' EXIT

python3 - "$REPO_ROOT" <<'PYEOF'
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = sys.argv[1]
HOOKS = os.path.join(REPO, "claude/hooks")
GATE = os.path.join(HOOKS, "crg-gate.py")
GUARD = os.path.join(HOOKS, "bash-edit-guard.py")

# Hooks import their siblings (agent_env, hook_metrics) as plain modules —
# free when they run as scripts (script dir is sys.path[0]), but importlib
# loading here needs the directory put on the path explicitly.
sys.path.insert(0, HOOKS)

passed = failed = 0

def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
        print("  PASS: %s" % name)
    else:
        failed += 1
        print("  FAIL: %s" % name)

def run_hook(hook, mode, payload):
    args = ["python3", hook] + ([mode] if mode else [])
    env = dict(os.environ)
    env.pop("CRG_HOOKS_OFF", None)
    env.pop("LINT_HOOK_OFF", None)
    env.pop("SKILL_GATE_OFF", None)
    r = subprocess.run(args, input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    return r.returncode, r.stderr

# Load crg-gate as a module so tests read BUDGET from the source of truth
# instead of hardcoding it (the constant is a tuning knob and does move).
spec = importlib.util.spec_from_file_location("crg", GATE)
assert spec is not None and spec.loader is not None
crg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crg)

# ---- crg-gate: budget lifecycle in an isolated fake repo ----
with tempfile.TemporaryDirectory() as tmp:
    os.makedirs(os.path.join(tmp, ".code-review-graph"))
    open(os.path.join(tmp, ".code-review-graph", "graph.db"), "w").close()
    sid = "test-hooks-%d" % os.getpid()

    def gate(tool="Read", fp="app/main.py", cmd=None):
        ti = {"command": cmd} if cmd else {"file_path": fp}
        return run_hook(GATE, "gate", {
            "session_id": sid, "cwd": tmp, "tool_name": tool, "tool_input": ti})

    def mark():
        return run_hook(GATE, "mark", {"session_id": sid, "cwd": tmp,
                                       "tool_name": "mcp__code-review-graph__x",
                                       "tool_input": {}})

    rc, err = gate()
    check("gate: fresh session blocks first code read", rc == 2 and "not consulted" in err)
    check("gate: block refills budget (%d reads pass)" % crg.BUDGET,
          all(gate()[0] == 0 for _ in range(crg.BUDGET)))
    rc, err = gate()
    check("gate: read #%d re-arms with bulk-reading message" % (crg.BUDGET + 1),
          rc == 2 and "bulk-reading" in err)
    mark()
    check("gate: graph consult (mark) refills budget", gate()[0] == 0)

    import hashlib
    marker = os.path.join(tempfile.gettempdir(), "crg-gate-%s.open"
                          % hashlib.sha1(sid.encode()).hexdigest()[:16])
    open(marker, "w").write("0")
    check("gate: non-code file never gated at zero budget",
          gate(fp="README.md")[0] == 0)
    check("gate: bash cat of code gated at zero budget",
          gate(tool="Bash", cmd="cat app/main.py")[0] == 2)
    open(marker, "w").write("0")
    check("gate: non-read bash free at zero budget",
          gate(tool="Bash", cmd="git status")[0] == 0)
    open(marker, "w").write("garbage")
    check("gate: corrupt marker fails open", gate()[0] == 0)
    os.remove(marker)

# ---- crg-gate: bash read/sweep classification (pure function) ----
counted = [
    "find roles/x -type f | xargs -I{} sh -c 'echo ===={}====; cat {}'",
    "find . -type f -exec cat {} \\;",
    "find app -name '*.py' | xargs grep -l 'host_group'",
    "cat app/main.py",
    "grep -rn pattern --include='*.py' .",
    "grep -rn foo src/",
    "grep -nr foo .",
    "grep -rl foo .",
    "grep -ri foo .",
    "cd src\ncat main.py",
    "rg 'def execute'",
    "x=$(cat src/main.py | wc -l)",
    "echo `cat src/main.py`",
    "bash scripts/run.sh; grep -rn foo .",
    "cd src && grep foo main.py",
    "true | grep -rn foo .",
    "echo | grep foo src/main.py",
]
free = [
    "find . -iname 'docker_pull.yml'",
    "git diff --name-only | xargs ls -la",
    "pgrep -fa uvicorn",
    "grep -n --color foo notes.txt",
    "grep -v foo",
    "docker ps | rg web",
    "find . -type f | wc -l",
    # grep after a pipe filters the previous command's output, not files
    "bash scripts/hook-stats.sh --since 7d | grep -iE 'crg|skill'",
    "git diff scripts/lib/mcp.sh | grep '^[-+]'",
]
check("gate: sweep/read commands count against budget",
      all(crg._bash_reads_code(c) for c in counted))
check("gate: listing/non-read commands stay free",
      not any(crg._bash_reads_code(c) for c in free))

# ---- crg-gate: coverage-aware gating (real graph db, py/sh indexed only) ----
import sqlite3
with tempfile.TemporaryDirectory() as tmp:
    gdir = os.path.join(tmp, ".code-review-graph")
    os.makedirs(gdir)
    conn = sqlite3.connect(os.path.join(gdir, "graph.db"))
    conn.execute("CREATE TABLE nodes (id INTEGER PRIMARY KEY, file_path TEXT)")
    conn.executemany("INSERT INTO nodes (file_path) VALUES (?)",
                     [("scripts/collector.py",), ("scripts/run.sh",)])
    conn.commit()
    conn.close()
    sid = "cov-test-%d" % os.getpid()
    import hashlib
    marker = os.path.join(tempfile.gettempdir(), "crg-gate-%s.open"
                          % hashlib.sha1(sid.encode()).hexdigest()[:16])

    def cgate(tool, ti):
        return run_hook(GATE, "gate", {
            "session_id": sid, "cwd": tmp, "tool_name": tool, "tool_input": ti})

    open(marker, "w").write("0")  # budget exhausted -> gate is armed
    check("coverage: Read of non-indexed .tf passes at zero budget",
          cgate("Read", {"file_path": "modules/x/main.tf"})[0] == 0)
    check("coverage: Grep scoped to *.tf passes at zero budget",
          cgate("Grep", {"pattern": "enable_", "glob": "*.tf"})[0] == 0)
    check("coverage: bash grep --include='*.tf' passes at zero budget",
          cgate("Bash", {"command": "grep -rn foo --include='*.tf' modules/"})[0] == 0)
    check("coverage: bash grep for a quoted 'x.sql' pattern is still gated",
          cgate("Bash", {"command": "grep -rn 'schema.sql' src/"})[0] == 2)
    open(marker, "w").write("0")  # a block refills the budget; re-arm
    check("coverage: bash with leading whitespace is still gated",
          cgate("Bash", {"command": "  cat scripts/collector.py"})[0] == 2)
    open(marker, "w").write("0")
    rc, err = cgate("Read", {"file_path": "scripts/collector.py"})
    check("coverage: Read of indexed .py still gated", rc == 2)
    check("coverage: block message names the indexed exts",
          ".py" in err and ".sh" in err)
    open(marker, "w").write("0")
    check("coverage: Grep scoped to indexed *.py still gated",
          cgate("Grep", {"pattern": "x", "glob": "**/*.py"})[0] == 2)
    open(marker, "w").write("0")
    check("coverage: unscoped Grep still gated (may hit indexed code)",
          cgate("Grep", {"pattern": "x"})[0] == 2)
    open(marker, "w").write("0")
    check("coverage: dotted identifier is not a file ext (grep -r 'user.name')",
          cgate("Bash", {"command": "grep -r 'user.name' src/"})[0] == 2)
    open(marker, "w").write("0")
    check("coverage: absolute Read of code outside the repo is not gated",
          cgate("Read", {"file_path": "/tmp/scratch-elsewhere/test.py"})[0] == 0)
    open(marker, "w").write("0")
    check("coverage: absolute Read of indexed code inside the repo is gated",
          cgate("Read", {"file_path": os.path.join(tmp, "scripts", "collector.py")})[0] == 2)
    open(marker, "w").write("0")
    check("coverage: Read of an indexed ext the graph has no node for (submodule) passes",
          cgate("Read", {"file_path": "mcp-infra/server/advisors.py"})[0] == 0)
    check("coverage: absolute Read of an unindexed file inside the repo passes",
          cgate("Read", {"file_path": os.path.join(tmp, "extern", "x", "hook.py")})[0] == 0)
    crg._write_budget({"session_id": sid}, 3)
    check("gate: budget write is atomic (value readable, no tmp left behind)",
          open(marker).read() == "3"
          and not [f for f in os.listdir(tempfile.gettempdir())
                   if f.startswith(os.path.basename(marker) + ".")])

    r = subprocess.run(["python3", GATE, "remind"],
                       input=json.dumps({"session_id": sid, "cwd": tmp}),
                       capture_output=True, text=True)
    check("coverage: remind states graph coverage",
          "indexes" in r.stdout and ".py" in r.stdout)
    os.remove(marker)

# ---- bash-edit-guard: block/allow matrix ----
def guard(cmd):
    return run_hook(GUARD, None, {"tool_name": "Bash",
                                  "tool_input": {"command": cmd}})[0]

block = [
    "sed -i 's/a/b/g' app/main.py",
    "sed -i.bak 's/x/y/' lib/util.sh",
    "sed --in-place 's/x/y/' a.py",
    "perl -pi -e 's/a/b/' main.cpp",
    "awk -i inplace '{print}' x.py",
    "cd app && sed -i 's/a/b/' main.py",
    "find . -name '*.py' | xargs sed -i 's/a/b/'",
    "echo 'import os' > app/new.py",
    "grep -h pat a.py b.py >> merged.py",
    "some_cmd | tee app/main.py",
]
allow = [
    "sed -n '10,20p' app/main.py",
    "sed 's/a/b/' app/main.py | head",
    "cat app/main.py",
    "sed -i 's/a/b/' notes.md",
    "echo done > /tmp/out.log",
    "make 2>&1 | tee build.log",
    "cp claude/hooks/crg-gate.py ~/.claude/hooks/",
    "git commit -m 'fix: sed -i usage in deploy.py was broken'",
    'git commit -m "guard blocks (sed -i, perl -i | xargs grep) on x.py"',
    'echo "use sed -i on x.py" && ls',
    "grep -rn 'pattern' --include='*.py' .",
    "ruff check app/main.py",
]
for c in block:
    check("guard blocks: %s" % c[:58], guard(c) == 2)
for c in allow:
    check("guard allows: %s" % c[:58], guard(c) == 0)

# ---- lint-on-edit: de-dupe lifecycle (needs ruff on PATH) ----
LINT = os.path.join(REPO, "claude/hooks/lint-on-edit.py")
import shutil as _shutil
if _shutil.which("ruff"):
    import hashlib
    bad = os.path.join(tempfile.gettempdir(), "lint_dedupe_case_%d.py" % os.getpid())
    cache = os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last"
                         % hashlib.sha1(bad.encode()).hexdigest()[:16])

    def lint():
        return run_hook(LINT, None, {"tool_name": "Edit",
                                     "tool_input": {"file_path": bad}})

    with open(bad, "w") as f:
        f.write("import sys\nimport os\nX = 1\n")
    check("lint: first edit with findings blocks", lint()[0] == 2)
    check("lint: identical findings stay silent", lint()[0] == 0)
    with open(bad, "a") as f:
        f.write("import json\n")
    rc, err = lint()
    check("lint: new finding blocks again", rc == 2)
    check("lint: block reports ONLY the new finding",
          "json" in err and "`sys`" not in err and "previously reported" in err)
    with open(bad, "w") as f:
        f.write("X = 1\n")
    check("lint: clean run passes and clears cache", lint()[0] == 0)
    with open(bad, "w") as f:
        f.write("import sys\nX = 1\n")
    check("lint: regression after clean run blocks", lint()[0] == 2)
    os.remove(bad)
    if os.path.exists(cache):
        os.remove(cache)
else:
    print("  SKIP: lint de-dupe cases (ruff not installed)")

# ---- lint-on-edit: grafana dashboard sanity (built-in, no linter needed) ----
import hashlib as _hg
gdash = os.path.join(tempfile.gettempdir(), "dashboards")
os.makedirs(gdash, exist_ok=True)
dfp = os.path.join(gdash, "case_%d.json" % os.getpid())
dcache = os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last"
                      % _hg.sha1(dfp.encode()).hexdigest()[:16])

def dlint():
    return run_hook(LINT, None, {"tool_name": "Write",
                                 "tool_input": {"file_path": dfp}})

with open(dfp, "w") as f:
    json.dump({"title": "T", "panels": [{"id": 1}, {"id": 1}]}, f)
rc, err = dlint()
check("grafana: duplicate panel ids block", rc == 2 and "duplicate panel id" in err)
with open(dfp, "w") as f:
    json.dump({"title": "T", "panels": [{"id": 1}, {"id": 2, "panels": [{"id": 3}]}]}, f)
check("grafana: valid dashboard passes", dlint()[0] == 0)
with open(dfp, "w") as f:
    f.write("{broken json")
rc, err = dlint()
check("grafana: invalid JSON blocks", rc == 2 and "invalid JSON" in err)
with open(dfp, "w") as f:
    json.dump({"panels": [{"id": 1}]}, f)
rc, err = dlint()
check("grafana: missing title blocks", rc == 2 and "no title" in err)
os.remove(dfp)
if os.path.exists(dcache):
    os.remove(dcache)
other = os.path.join(tempfile.gettempdir(), "plain_%d.json" % os.getpid())
with open(other, "w") as f:
    f.write("{broken")
check("grafana: json outside dashboards dir ignored",
      run_hook(LINT, None, {"tool_name": "Write",
                            "tool_input": {"file_path": other}})[0] == 0)
os.remove(other)

# ---- lint-on-edit: terraform fmt fallback ----
if _shutil.which("terraform") and not _shutil.which("tflint"):
    tfp = os.path.join(tempfile.gettempdir(), "case_%d.tf" % os.getpid())
    tcache = os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last"
                          % _hg.sha1(tfp.encode()).hexdigest()[:16])
    with open(tfp, "w") as f:
        f.write('variable "x" {\n  type= string\n}\n')
    rc, err = run_hook(LINT, None, {"tool_name": "Edit",
                                    "tool_input": {"file_path": tfp}})
    check("terraform: unformatted .tf blocks via fmt -check", rc == 2)
    with open(tfp, "w") as f:
        f.write('variable "x" {\n  type = string\n}\n')
    check("terraform: formatted .tf passes",
          run_hook(LINT, None, {"tool_name": "Edit",
                                "tool_input": {"file_path": tfp}})[0] == 0)
    os.remove(tfp)
    if os.path.exists(tcache):
        os.remove(tcache)
else:
    print("  SKIP: terraform fmt cases (terraform missing or tflint present)")

# ---- skill-gate: devops domain (tf / helm-values / dashboards) ----
SKILLG = os.path.join(REPO, "claude/hooks/skill-gate.py")

def sgate(fp, session):
    return run_hook(SKILLG, "gate", {"session_id": session, "tool_name": "Edit",
                                     "tool_input": {"file_path": fp}})

def smark(skill, session):
    return run_hook(SKILLG, "mark", {"session_id": session, "tool_name": "Skill",
                                     "tool_input": {"skill": skill}})

s1 = "skillgate-test-%d-a" % os.getpid()
rc, err = sgate("modules/k3s-monitoring/main.tf", s1)
check("skill-gate: first .tf edit nudges devops skill",
      rc == 2 and "devops" in err)
check("skill-gate: retry passes (one warning per domain)",
      sgate("modules/k3s-monitoring/variables.tf", s1)[0] == 0)

s2 = "skillgate-test-%d-b" % os.getpid()
check("skill-gate: helm values yaml nudges devops",
      sgate("modules/minio/values-dev.yaml", s2)[0] == 2)
s3 = "skillgate-test-%d-c" % os.getpid()
check("skill-gate: grafana dashboard json nudges devops",
      sgate("modules/k3s-monitoring/dashboards/autonomy.json", s3)[0] == 2)
check("skill-gate: ansible-tree yaml still routes to ansible domain",
      "ansible" in sgate("/repo/roles/common/tasks/main.yml", s3)[1])
s4 = "skillgate-test-%d-d" % os.getpid()
smark("devops", s4)
check("skill-gate: after loading devops skill, .tf edit passes",
      sgate("environments/dev/main.tf", s4)[0] == 0)
check("skill-gate: random json untouched",
      sgate("config/settings.json", s4)[0] == 0)
s4b = "skillgate-test-%d-d2" % os.getpid()
_rc, _err = sgate("infra/Dockerfile", s4b)
check("skill-gate: Dockerfile edit nudges devops with the container checklist",
      _rc == 2 and "devops" in _err and "HEALTHCHECK" in _err)
s4c = "skillgate-test-%d-d3" % os.getpid()
check("skill-gate: CI pipeline edit nudges devops",
      sgate("/repo/.github/workflows/deploy.yml", s4c)[0] == 2)

# ---- skill-gate: domains added to reach the never-invoked skills ----
# supply-chain-audit / testing-handbook / owasp-security had zero invocations
# across the whole fleet because no decision point ever pointed at them.
s5 = "skillgate-test-%d-e" % os.getpid()
check("skill-gate: lockfile edit nudges supply-chain-audit",
      "supply-chain-audit" in sgate("web/package-lock.json", s5)[1])
s6 = "skillgate-test-%d-f" % os.getpid()
check("skill-gate: plain test file is NOT gated (no skill serves that case)",
      sgate("/repo/tests/test_api.py", s6)[0] == 0)
s7 = "skillgate-test-%d-g" % os.getpid()
check("skill-gate: auth path edit nudges owasp-security",
      "owasp-security" in sgate("/repo/api/auth/session.py", s7)[1])
s8 = "skillgate-test-%d-h" % os.getpid()
smark("supply-chain-audit", s8)
check("skill-gate: loading supply-chain-audit satisfies the domain",
      sgate("requirements.txt", s8)[0] == 0)

# Routing table: first-match ordering must stay stable as domains are added.
_spec = importlib.util.spec_from_file_location("sg", SKILLG)
assert _spec is not None and _spec.loader is not None
_sg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_sg)
_routes = [
    ("web/Button.tsx", "design"),
    ("pyproject.toml", "supply-chain"),
    ("svc/go.mod", "supply-chain"),
    ("web/package-lock.json", "supply-chain"),
    ("src/jwt_utils.go", "security"),
    ("app/routes/auth.py", "security"),
    ("strix/runtime/session_manager.py", "security"),
    ("roles/x/tasks/main.yml", "ansible"),  # relative path, no leading slash
    ("infra/main.tf", "devops"),
    # Containers and pipelines: the devops checklist's two longest sections
    # aimed at files the rules originally never matched.
    ("Dockerfile", "devops"),
    ("infra/Dockerfile.prod", "devops"),
    ("build/Containerfile", "devops"),
    ("docker-compose.yml", "devops"),
    ("deploy/docker-compose.prod.yaml", "devops"),
    ("compose.yaml", "devops"),
    (".gitlab-ci.yml", "devops"),
    ("repo/.github/workflows/ci.yml", "devops"),
    ("repo/.circleci/config.yml", "devops"),
    ("azure-pipelines.yml", "devops"),
    # ...without swallowing neighbours that merely sit near them
    ("docs/dockerfile-guide.md", None),
    ("src/compose_message.py", None),
    ("app/config.yml", None),
    ("src/utils.py", None),
    ("README.md", None),
    # Calibrated false positives: the naive keyword list matched all of these.
    ("claude/hooks/session-size-nudge.py", None),
    ("fzf/src/tokenizer.go", None),
    ("llm/token_counter.py", None),
    ("repo/tests/test_api.py", None),       # no skill serves generic unit tests
]
check("skill-gate: domain routing table is stable",
      all(_sg._domain_of_file(fp) == exp for fp, exp in _routes))
# mcp-builder had no decision point; MCP server source now routes to it.
check("skill-gate: MCP server source routes to mcp-server (not security)",
      _sg._domain_of_file("mcp-infra/llm-council-mcp/backend/main.py") == "mcp-server"
      and _sg._domain_of_file("extern/local-model-mcp/server.py") == "mcp-server"
      and _sg._domain_of_file("mcp-infra/llm-council-mcp/backend/auth.py") == "security"
      and _sg._domain_of_file("scripts/deploy.py") is None)

# ---- skill-nudge: wave-1 reminders for skills with no edit-time trigger ----
NUDGE = os.path.join(REPO, "claude/hooks/skill-nudge.py")

def _nudge(mode, payload):
    # skill-nudge speaks JSON on stdout (non-blocking context), unlike
    # skill-gate's stderr+exit 2, so run_hook's stderr view is not enough.
    r = subprocess.run(["python3", NUDGE, mode], input=json.dumps(payload),
                       capture_output=True, text=True)
    return r.returncode, r.stdout

def nprompt(text, session):
    return _nudge("prompt", {"session_id": session, "prompt": text})

def nbash(cmd, session):
    return _nudge("bash", {"session_id": session, "tool_name": "Bash",
                           "tool_input": {"command": cmd}})

n1 = "skillnudge-test-%d-a" % os.getpid()
_rc, _out = nprompt("repoyu açık kaynak yapmadan önce sızıntı taraması yap", n1)
check("skill-nudge: leak/open-source prompt injects static-analysis",
      _rc == 0 and "static-analysis" in _out and "UserPromptSubmit" in _out)
check("skill-nudge: same rule is silent the second time (once per session)",
      nprompt("semgrep çalıştır", n1) == (0, ""))
check("skill-nudge: ordinary Turkish prompts do not match",
      all(nprompt(p, "skillnudge-test-%d-b" % os.getpid()) == (0, "") for p in (
          "config değişikliklerini taraman lazım",
          "bir bak arasana vaultda",
          "commit et pushla",
          "nasıl istersen sen karar ver")))
n2 = "skillnudge-test-%d-c" % os.getpid()
_rc, _out = nbash("git push origin main", n2)
check("skill-nudge: git push injects differential-review",
      _rc == 0 and "differential-review" in _out and "PreToolUse" in _out)
check("skill-nudge: gh pr create also matches, but only once",
      nbash("gh pr create --fill", n2) == (0, ""))
check("skill-nudge: git status / git commit do not match",
      all(nbash(c, "skillnudge-test-%d-d" % os.getpid()) == (0, "")
          for c in ("git status", "git commit -m x", "echo git pushed")))
check("skill-nudge: garbage stdin fails open",
      subprocess.run(["python3", NUDGE, "prompt"], input="not json",
                     capture_output=True, text=True).returncode == 0)

# ---- skill-gate: the operative checklist rides along with the block ----
# Qwen (27B) invokes the skill tool but does not follow a pointer inside the
# result to a second file, so a wrapper that only points is guidance that never
# lands. Every gated domain must therefore carry its own marked checklist, and
# the block message must deliver it at the decision point.
check("skill-gate: every gated domain names a skill",
      all("skill" in d for d in _sg.DOMAINS.values()))
check("skill-gate: every gated domain resolves a non-empty checklist",
      all(len(_sg._checklist(name)) > 300 for name in _sg.DOMAINS))
s9 = "skillgate-test-%d-i" % os.getpid()
_rc, _err = sgate("/repo/api/auth/session.py", s9)
check("skill-gate: block carries the checklist inline",
      _rc == 2 and "scrypt" in _err and "Deny by default" in _err)
check("skill-gate: 'load the skill' instruction still comes first",
      _err.index("owasp-security") < _err.index("Non-negotiables"))
# Fail-open: a wrapper without markers must degrade to the advice line, never
# crash the edit.
_missing = dict(_sg.DOMAINS["security"], skill="no-such-skill-xyz")
_orig = _sg.DOMAINS["security"]
_sg.DOMAINS["security"] = _missing
check("skill-gate: missing wrapper degrades to empty checklist",
      _sg._checklist("security") == "")
_sg.DOMAINS["security"] = _orig

# ---- hook_metrics: decision telemetry ----
# Hooks are only tunable if their firing is measurable; these guard the write
# path (and the promise that no command text lands in the metrics file).
with tempfile.TemporaryDirectory() as mhome:
    menv = dict(os.environ, HOME=mhome,
                PYTHONPATH=os.path.join(REPO, "claude/hooks"))
    # This block asserts the default, HOME-derived path, so it drops the
    # suite-wide redirect; HOME is already a temp dir, so it stays isolated.
    menv.pop("DAK_METRICS_FILE", None)
    os.makedirs(os.path.join(mhome, ".claude"))
    mpath = os.path.join(mhome, ".claude", "hook-metrics.jsonl")

    def mrun(script, mode, payload):
        args = [sys.executable, script] + ([mode] if mode else [])
        subprocess.run(args, input=json.dumps(payload),
                       capture_output=True, text=True, env=menv)

    ms = "metrics-test-%d" % os.getpid()
    mrun(SKILLG, "gate", {"session_id": ms, "cwd": "/home/u/workspace/demo",
                          "tool_name": "Edit",
                          "tool_input": {"file_path": "/repo/web/package-lock.json"}})
    mrun(os.path.join(REPO, "claude/hooks/bash-edit-guard.py"), None,
         {"session_id": ms, "cwd": "/home/u/workspace/demo", "tool_name": "Bash",
          "tool_input": {"command": "sed -i s/HUNTER2/x/ app.py"}})

    recs = [json.loads(x) for x in open(mpath) if x.strip()]
    check("hook_metrics: decisions are recorded", len(recs) == 2)
    check("hook_metrics: records hook/action/project",
          all({"hook", "action", "project", "ts"} <= set(r) for r in recs))
    check("hook_metrics: project slug matches agent-stats naming",
          all(r["project"] == "-home-u-workspace-demo" for r in recs))
    check("hook_metrics: skill-gate records the domain",
          any(r["hook"] == "skill-gate" and r.get("detail") == "supply-chain"
              for r in recs))
    check("hook_metrics: no command text (secrets) reaches the metrics file",
          "HUNTER2" not in open(mpath).read())

    m = os.path.join(tempfile.gettempdir(), "skill-gate-%s.json"
                     % __import__("hashlib").sha1(ms.encode()).hexdigest()[:16])
    if os.path.exists(m):
        os.remove(m)

# hook_metrics must never raise, whatever it is handed.
_mspec = importlib.util.spec_from_file_location(
    "hm", os.path.join(REPO, "claude/hooks/hook_metrics.py"))
assert _mspec is not None and _mspec.loader is not None
_hm = importlib.util.module_from_spec(_mspec)
_mspec.loader.exec_module(_hm)
check("hook_metrics: slug matches agent-stats project dir naming",
      _hm.project_slug("/home/user/workspace/dev-agent-kit")
      == "-home-user-workspace-dev-agent-kit")
try:
    _hm.record(None, None, None, None)  # type: ignore[arg-type]
    _ok = True
except Exception:
    _ok = False
check("hook_metrics: never raises on bad input (fail-open)", _ok)

# The counters are only evidence if the suite that exercises them stays out of
# the ledger they write to. This asserts the redirect, not the file's content.
_live = os.path.join(os.path.expanduser("~"), ".claude", "hook-metrics.jsonl")
check("hook_metrics: the suite writes to the redirect, not the live ledger",
      _hm._target() == os.environ.get("DAK_METRICS_FILE")
      and _hm._target() != _live)
_before = os.path.getsize(_live) if os.path.exists(_live) else 0
_hm.record("test-probe", "write", "/home/u/workspace/demo")
_after = os.path.getsize(_live) if os.path.exists(_live) else 0
check("hook_metrics: a recorded decision leaves the live ledger untouched",
      _before == _after
      and "test-probe" in open(os.environ["DAK_METRICS_FILE"]).read())

import hashlib as _hs
for s in (s1, s2, s3, s4, s5, s6, s7, s8):
    m = os.path.join(tempfile.gettempdir(), "skill-gate-%s.json"
                     % _hs.sha1(s.encode()).hexdigest()[:16])
    if os.path.exists(m):
        os.remove(m)

# ---- session-size-nudge: threshold lifecycle ----
NUDGE = os.path.join(REPO, "claude/hooks/session-size-nudge.py")
with tempfile.TemporaryDirectory() as tmp:
    fake = os.path.join(tmp, "transcript.jsonl")
    sid = "nudge-test-%d" % os.getpid()

    def nudge(size_mb):
        with open(fake, "wb") as f:
            f.truncate(int(size_mb * 1e6))
        r = subprocess.run(["python3", NUDGE], input=json.dumps(
            {"session_id": sid, "transcript_path": fake}),
            capture_output=True, text=True)
        return r.returncode, r.stdout

    rc, out = nudge(1)
    check("nudge: small transcript stays silent", rc == 0 and not out.strip())
    rc, out = nudge(3)
    j = json.loads(out) if out.strip() else {}
    check("nudge: crossing 2MB emits user-visible systemMessage",
          "systemMessage" in j)
    check("nudge: additionalContext carries the model-side nudge",
          "[session]" in j.get("hookSpecificOutput", {}).get("additionalContext", ""))
    check("nudge: pre-escalation tone suggests wrapping up",
          "wraps up" in j.get("systemMessage", ""))
    rc, out = nudge(3.5)
    check("nudge: same level does not repeat", not out.strip())
    rc, out = nudge(9)
    j = json.loads(out) if out.strip() else {}
    check("nudge: 8MB+ escalates to break-off-now",
          "Break off now" in j.get("systemMessage", ""))
    rc, out = nudge(17)
    check("nudge: next threshold (16MB) still escalates", "[session]" in out)

    import hashlib as _h
    m = os.path.join(tempfile.gettempdir(), "session-size-%s.notified"
                     % _h.sha1(sid.encode()).hexdigest()[:16])
    if os.path.exists(m):
        os.remove(m)

# ---- session-size-nudge: context-per-call axis ----
# Transcript MB tracks re-billed context at only r=0.81, and the bands overlap
# across 3.7-7.9MB — exactly where the break-off call gets made. The two cases
# below are the measured failures of the MB-only version.
import hashlib as _h2


def _nudge_marker(s):
    return os.path.join(tempfile.gettempdir(), "session-size-%s.notified"
                        % _h2.sha1(s.encode()).hexdigest()[:16])


with tempfile.TemporaryDirectory() as tmp:
    def write_transcript(path, mb, ctx_tokens):
        pad = json.dumps({"filler": "x" * 900}) + "\n"
        rec = json.dumps({"message": {"usage": {
            "input_tokens": 100,
            "cache_read_input_tokens": ctx_tokens - 100,
            "cache_creation_input_tokens": 0}}}) + "\n"
        with open(path, "w") as f:
            f.write(pad * max(0, int(mb * 1e6 / len(pad))))
            f.write(rec)

    def ctx_nudge(s, mb, ctx_tokens):
        p = os.path.join(tmp, "t-%s.jsonl" % s)
        write_transcript(p, mb, ctx_tokens)
        r = subprocess.run(["python3", NUDGE], input=json.dumps(
            {"session_id": s, "transcript_path": p}),
            capture_output=True, text=True)
        return json.loads(r.stdout) if r.stdout.strip() else {}

    s_a = "nudgectx-a-%d" % os.getpid()
    j = ctx_nudge(s_a, 4.0, 382_000)
    check("nudge: 4MB/382k escalates (the case MB-only missed)",
          "Break off now" in j.get("systemMessage", ""))
    check("nudge: message reports tokens per call, not just MB",
          "382k tokens per call" in j.get("systemMessage", ""))

    s_b = "nudgectx-b-%d" % os.getpid()
    j = ctx_nudge(s_b, 7.9, 119_000)
    check("nudge: 7.9MB/119k stays soft (the case MB-only cried wolf on)",
          "wraps up" in j.get("systemMessage", "")
          and "Break off now" not in j.get("systemMessage", ""))

    s_c = "nudgectx-c-%d" % os.getpid()
    check("nudge: healthy session (1MB/90k) stays silent",
          not ctx_nudge(s_c, 1.0, 90_000))

    s_d = "nudgectx-d-%d" % os.getpid()
    check("nudge: context threshold fires once",
          bool(ctx_nudge(s_d, 4.0, 382_000)))
    check("nudge: same context level does not repeat",
          not ctx_nudge(s_d, 4.0, 382_000))
    check("nudge: growing into a higher context band nudges again",
          bool(ctx_nudge(s_d, 4.0, 720_000)))

    # A session already running under the v2 (bare-int MB) marker must not
    # re-nudge from zero when the hook is upgraded mid-flight.
    s_e = "nudgectx-e-%d" % os.getpid()
    with open(_nudge_marker(s_e), "w") as f:
        f.write("4")
    check("nudge: v2 bare-int marker is honoured after upgrade",
          not ctx_nudge(s_e, 4.0, 120_000))

    spec_n = importlib.util.spec_from_file_location("ssn", NUDGE)
    assert spec_n is not None and spec_n.loader is not None
    ssn = importlib.util.module_from_spec(spec_n)
    spec_n.loader.exec_module(ssn)
    big = os.path.join(tmp, "big.jsonl")
    write_transcript(big, 3.0, 456_000)
    check("nudge: tail read finds newest usage in a multi-MB transcript",
          ssn._context_per_call(big) == 456_000)
    empty = os.path.join(tmp, "empty.jsonl")
    open(empty, "w").write('{"no":"usage"}\n')
    check("nudge: transcript without usage records yields None",
          ssn._context_per_call(empty) is None)

    # Host-derived context thresholds. Claude's ceiling is money and its steps
    # are absolute; Qwen's ceiling is a wall (the vLLM server refuses requests
    # past sessionTokenLimit, ~235k) which sits BELOW three of Claude's four
    # steps — left absolute, the escalation could never fire on the one host
    # where crossing the line ends the session.
    claude_steps, claude_esc = ssn._ctx_thresholds()
    check("nudge: claude keeps the absolute measured steps",
          claude_steps == (200, 300, 450, 700) and claude_esc == 300)

    qwen_home = os.path.join(tmp, "qwenhome")
    os.makedirs(os.path.join(qwen_home, ".qwen"))
    with open(os.path.join(qwen_home, ".qwen", "settings.json"), "w") as f:
        json.dump({"model": {"sessionTokenLimit": 235929,
                             "generationConfig": {"contextWindowSize": 262144}}}, f)

    def qwen_ssn(home):
        env = dict(os.environ, DAK_AGENT="qwen", HOME=home)
        # python3 -c puts cwd on sys.path, not the script's directory, so the
        # hook's `import agent_env` would fail without this.
        code = ("import importlib.util,json,sys;"
                "sys.path.insert(0,%r);" % os.path.dirname(NUDGE) + (
                "s=importlib.util.spec_from_file_location('ssn',%r);"
                "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                "print(json.dumps(m._ctx_thresholds()))" % NUDGE))
        r = subprocess.run(["python3", "-c", code], capture_output=True,
                           text=True, env=env)
        return json.loads(r.stdout)

    q_steps, q_esc = qwen_ssn(qwen_home)
    check("nudge: qwen derives its steps from sessionTokenLimit",
          all(s < 236 for s in q_steps) and q_steps == sorted(q_steps))
    check("nudge: qwen escalates with headroom left before the wall",
          0 < q_esc < 236 and q_esc >= q_steps[0])

    # No sessionTokenLimit -> the window itself is the wall.
    win_home = os.path.join(tmp, "winhome")
    os.makedirs(os.path.join(win_home, ".qwen"))
    with open(os.path.join(win_home, ".qwen", "settings.json"), "w") as f:
        json.dump({"model": {"generationConfig": {"contextWindowSize": 131072}}}, f)
    w_steps, _ = qwen_ssn(win_home)
    check("nudge: falls back to contextWindowSize when no session limit is set",
          all(s < 131 for s in w_steps))

    # Unreadable settings must not take the hook down with them.
    bare_home = os.path.join(tmp, "barehome")
    os.makedirs(bare_home)
    b_steps, _ = qwen_ssn(bare_home)
    check("nudge: missing qwen settings falls back instead of raising",
          len(b_steps) == 4 and b_steps[0] > 0)

    # Antigravity is a hosted API like Claude (cost ceiling, no local vLLM
    # wall) — it must share Claude's absolute steps, not fall into the
    # qwen-derived branch just because AGENT != "claude".
    def antigravity_ssn(home):
        env = dict(os.environ, DAK_AGENT="antigravity", HOME=home)
        code = ("import importlib.util,json,sys;"
                "sys.path.insert(0,%r);" % os.path.dirname(NUDGE) + (
                "s=importlib.util.spec_from_file_location('ssn',%r);"
                "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                "print(json.dumps(m._ctx_thresholds()))" % NUDGE))
        r = subprocess.run(["python3", "-c", code], capture_output=True,
                           text=True, env=env)
        return json.loads(r.stdout)

    ag_steps, ag_esc = antigravity_ssn(bare_home)
    check("nudge: antigravity keeps Claude's absolute steps, not qwen's wall",
          tuple(ag_steps) == (200, 300, 450, 700) and ag_esc == 300)

    s_ag = "nudgectx-antigravity-%d" % os.getpid()
    p_ag = os.path.join(tmp, "t-ag.jsonl")
    write_transcript(p_ag, 4.0, 250_000)
    env_ag = dict(os.environ, DAK_AGENT="antigravity")
    r_ag = subprocess.run(["python3", NUDGE], input=json.dumps(
        {"session_id": s_ag, "transcript_path": p_ag}),
        capture_output=True, text=True, env=env_ag)
    j_ag = json.loads(r_ag.stdout) if r_ag.stdout.strip() else {}
    check("nudge: antigravity wording is cost-based (re-bills), no vLLM wall text",
          "re-bills" in j_ag.get("systemMessage", "")
          and "vLLM" not in j_ag.get("systemMessage", ""))
    if os.path.exists(_nudge_marker(s_ag)):
        os.remove(_nudge_marker(s_ag))

    for s in (s_a, s_b, s_c, s_d, s_e):
        if os.path.exists(_nudge_marker(s)):
            os.remove(_nudge_marker(s))

# ---- snapshot-size-nudge: oversized playwright result lifecycle ----
SNAP = os.path.join(REPO, "claude/hooks/snapshot-size-nudge.py")
sid = "snap-test-%d" % os.getpid()

def snap(tool, size_kb, session=None):
    payload = {"session_id": session or sid, "tool_name": tool,
               "tool_response": {"content": [{"type": "text",
                                              "text": "x" * (size_kb * 1024)}]}}
    r = subprocess.run(["python3", SNAP], input=json.dumps(payload),
                       capture_output=True, text=True)
    return r.returncode, r.stdout

rc, out = snap("mcp__playwright__browser_snapshot", 50)
check("snap: result under threshold stays silent", rc == 0 and not out.strip())
rc, out = snap("mcp__playwright__browser_snapshot", 600)
j = json.loads(out) if out.strip() else {}
check("snap: oversized snapshot emits user-visible systemMessage",
      "browser_snapshot" in j.get("systemMessage", ""))
check("snap: additionalContext steers to browser_find/evaluate",
      "browser_find" in j.get("hookSpecificOutput", {}).get("additionalContext", ""))
rc, out = snap("mcp__playwright__browser_navigate", 300)
check("snap: navigate results are covered too", "[snapshot]" in out)
snap("mcp__playwright__browser_snapshot", 600)
rc, out = snap("mcp__playwright__browser_snapshot", 600)
check("snap: caps at 3 nudges per session", not out.strip())
rc, out = snap("Read", 600, session=sid + "-other")
check("snap: non-playwright tools ignored", rc == 0 and not out.strip())

import hashlib as _h2
for s in (sid, sid + "-other"):
    m = os.path.join(tempfile.gettempdir(), "snapshot-size-%s.count"
                     % _h2.sha1(s.encode()).hexdigest()[:16])
    if os.path.exists(m):
        os.remove(m)

# ---- commit-attribution-guard: block/allow matrix ----
CGUARD = os.path.join(REPO, "claude/hooks/commit-attribution-guard.py")

def commit_guard(cmd):
    env = dict(os.environ)
    env.pop("COMMIT_GUARD_OFF", None)
    r = subprocess.run(["python3", CGUARD],
                       input=json.dumps({"tool_name": "Bash",
                                         "tool_input": {"command": cmd}}),
                       capture_output=True, text=True, env=env)
    return r.returncode

cblock = [
    'git commit -m "fix: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"',
    'git commit -m "feat: y\n\n\U0001f916 Generated with [Claude Code](https://claude.com/claude-code)"',
    'git commit --amend -m "z\n\nco-authored-by: someone"',
    'git add -A && git commit -m "w\n\nGenerated with AI"',
]
callow = [
    'git commit -m "feat: snapshot-size-nudge hook warns at decision point"',
    'git commit -m "fix: claude/settings.json merge order"',
    'git commit -m "docs: update QWEN.md dispatch rules"',
    'git log --oneline -5',
    'echo "Co-Authored-By: Claude" > /tmp/note.txt',
]
for c in cblock:
    check("commit-guard blocks: %s" % c[:55].replace("\n", " "), commit_guard(c) == 2)
for c in callow:
    check("commit-guard allows: %s" % c[:55].replace("\n", " "), commit_guard(c) == 0)

# ---- qwen-consider: one-time soft gate per session ----
QCONS = os.path.join(REPO, "claude/hooks/qwen-consider.py")
sid = "qwen-consider-test-%d" % os.getpid()

def consider(tool="Agent", session=None):
    env = dict(os.environ)
    env.pop("QWEN_CONSIDER_OFF", None)
    r = subprocess.run(["python3", QCONS],
                       input=json.dumps({"session_id": session or sid,
                                         "tool_name": tool,
                                         "tool_input": {"prompt": "x"}}),
                       capture_output=True, text=True, env=env)
    return r.returncode, r.stderr

rc, err = consider()
check("qwen-consider: first subagent dispatch soft-blocks with checklist",
      rc == 2 and "qwen_execute" in err and "hard refactor" in err.lower())
rc, err = consider()
check("qwen-consider: re-run passes (one-time only)", rc == 0)
rc, err = consider(tool="Read", session=sid + "-other")
check("qwen-consider: non-agent tools ignored", rc == 0)

for s in (sid, sid + "-other"):
    m = os.path.join(tempfile.gettempdir(), "qwen-consider-%s.seen"
                     % _h2.sha1(s.encode()).hexdigest()[:16])
    if os.path.exists(m):
        os.remove(m)

# ---- agent_env: the Claude/Qwen adaptation layer ----
# Qwen Code carries Claude's hook contract but with Gemini-CLI wire tool names
# and different delivery rules for the non-blocking channels. Both facts were
# established by running real `qwen -p` sessions, and both are load-bearing:
# get the name mapping wrong and every gate silently stops firing on Qwen.
import agent_env  # noqa: E402  (path set up above)

for wire, want in (("read_file", "Read"), ("grep_search", "Grep"),
                   ("run_shell_command", "Bash"), ("edit", "Edit"),
                   ("write_file", "Write"), ("skill", "Skill"),
                   ("agent", "Agent"), ("replace", "Edit"),
                   ("search_file_content", "Grep")):
    check("agent_env: %s -> %s" % (wire, want),
          agent_env.canonical(wire) == want)

for claude_name in ("Read", "Grep", "Bash", "Edit", "Write", "Skill"):
    check("agent_env: Claude name %s passes through" % claude_name,
          agent_env.canonical(claude_name) == claude_name)

check("agent_env: Claude's legacy Task folds into Agent",
      agent_env.canonical("Task") == "Agent")
check("agent_env: MCP tool names are untouched (matchers port as-is)",
      agent_env.canonical("mcp__code-review-graph__query_graph_tool")
      == "mcp__code-review-graph__query_graph_tool")
check("agent_env: unknown names pass through unchanged",
      agent_env.canonical("some_future_tool") == "some_future_tool")
check("agent_env: tool_name reads the payload",
      agent_env.tool_name({"tool_name": "read_file"}) == "Read")

# ---- payload SHAPE, not just tool names ----
# Antigravity does not guarantee Claude's flat snake_case payload: its own
# hooks surface nests the call under toolCall, and every MCP call arrives
# wrapped as call_mcp_tool(ToolName=..., Arguments={...}). A hook reading
# data["tool_name"] directly gets "" there and returns silently -- which is
# exactly how the enforcement half of the kit came to do nothing on agy for a
# week while the capture half kept reporting (measured 2026-09-12: 541
# Antigravity hook decisions, ZERO from any gate, against 7579 reads and 2823
# edits). These four checks are the regression fence for that.
_nested = {"toolCall": {"name": "run_command", "args": {"command": "ls"}}}
check("agent_env: nested toolCall yields the tool name",
      agent_env.tool_name(_nested) == "Bash")
check("agent_env: nested toolCall yields the arguments",
      agent_env.tool_input(_nested).get("command") == "ls")

_wrapped = {"tool_name": "call_mcp_tool",
            "tool_input": {"ToolName": "get_minimal_context_tool",
                           "Arguments": {"task": "t"}}}
check("agent_env: call_mcp_tool unwraps to the real tool",
      agent_env.raw_tool_name(_wrapped) == "get_minimal_context_tool")
check("agent_env: call_mcp_tool unwraps the real arguments",
      agent_env.tool_input(_wrapped).get("task") == "t")

# crg-gate "mark" refills the budget, so what reaches it decides whether the
# gate has teeth at all. On Antigravity the matcher cannot single out the
# graph server (everything is call_mcp_tool), so the hook must check the tool
# itself -- otherwise any MCP call would satisfy the gate and it would be
# permanently, invisibly open.
check("crg-gate: a graph tool marks (fully-qualified name)",
      crg._is_graph_tool("mcp__code-review-graph__query_graph_tool"))
check("crg-gate: a graph tool marks (Antigravity's unwrapped name)",
      crg._is_graph_tool("get_minimal_context_tool"))
check("crg-gate: an unrelated MCP tool does NOT mark",
      not crg._is_graph_tool("browser_take_screenshot"))
check("crg-gate: the wrapper itself does NOT mark",
      not crg._is_graph_tool("call_mcp_tool"))

# The gates must fire on a Qwen payload with no code change of their own.
def qwen_gate(hook, mode, payload):
    args = ["python3", hook] + ([mode] if mode else [])
    env = dict(os.environ)
    env["DAK_AGENT"] = "qwen"
    for k in ("CRG_HOOKS_OFF", "LINT_HOOK_OFF", "SKILL_GATE_OFF"):
        env.pop(k, None)
    r = subprocess.run(args, input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    return r.returncode, r.stdout, r.stderr

rc, _, err = qwen_gate(GUARD, None, {
    "tool_name": "run_shell_command",
    "tool_input": {"command": "sed -i 's/a/b/' app.py"}})
check("qwen payload: bash-edit-guard blocks run_shell_command",
      rc == 2 and "bash-edit-guard" in err)

rc, _, err = qwen_gate(os.path.join(HOOKS, "commit-attribution-guard.py"), None, {
    "tool_name": "run_shell_command",
    "tool_input": {"command": 'git commit -m "x\n\nCo-Authored-By: Claude"'}})
check("qwen payload: commit-attribution-guard blocks run_shell_command",
      rc == 2 and "attribution" in err)

with tempfile.TemporaryDirectory() as tmp:
    os.makedirs(os.path.join(tmp, ".code-review-graph"))
    open(os.path.join(tmp, ".code-review-graph", "graph.db"), "w").close()
    qsid = "agent-env-test-%d" % os.getpid()
    rc, _, err = qwen_gate(GATE, "gate", {
        "session_id": qsid, "cwd": tmp,
        "tool_name": "read_file", "tool_input": {"file_path": "app/main.py"}})
    check("qwen payload: crg-gate blocks read_file", rc == 2)

    # remind must go out as JSON: plain stdout is dropped by Qwen.
    rc, out, _ = qwen_gate(GATE, "remind", {"cwd": tmp})
    try:
        remind = json.loads(out)
    except Exception:
        remind = {}
    hso = remind.get("hookSpecificOutput", {})
    check("crg-gate remind emits JSON additionalContext",
          hso.get("hookEventName") == "UserPromptSubmit"
          and "[crg]" in (hso.get("additionalContext") or ""))

    m = os.path.join(tempfile.gettempdir(),
                     "crg-gate-%s.open" % _h2.sha1(qsid.encode()).hexdigest()[:16])
    if os.path.exists(m):
        os.remove(m)

# lint-on-edit's feedback channel: exit-2 stderr on Claude (rendered as a tool
# error), additionalContext on Qwen (which discards PostToolUse stderr).
LINT = os.path.join(HOOKS, "lint-on-edit.py")
with tempfile.TemporaryDirectory() as tmp:
    bad = os.path.join(tmp, "bad_lint_probe.py")
    with open(bad, "w") as f:
        f.write("import os\n")

    def lint(agent):
        env = dict(os.environ)
        env.pop("LINT_HOOK_OFF", None)
        env["DAK_AGENT"] = agent
        r = subprocess.run(["python3", LINT],
                           input=json.dumps({"tool_input": {"file_path": bad}}),
                           capture_output=True, text=True, env=env)
        return r.returncode, r.stdout, r.stderr

    cache = os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last"
                         % _h2.sha1(bad.encode()).hexdigest()[:16])
    rc, out, err = lint("claude")
    if os.path.exists(cache):
        os.remove(cache)  # findings are reported once per file; reset between runs
    have_ruff = rc != 0 or "lint-on-edit" in err
    if have_ruff:
        check("lint-on-edit: Claude gets exit-2 stderr",
              rc == 2 and "lint-on-edit" in err)
        rc, out, err = lint("qwen")
        try:
            payload = json.loads(out)
        except Exception:
            payload = {}
        ctx = payload.get("hookSpecificOutput", {}).get("additionalContext", "")
        check("lint-on-edit: Qwen gets additionalContext, exit 0",
              rc == 0 and "lint-on-edit" in ctx and "F401" in ctx)
    else:
        print("  SKIP: lint-on-edit channel tests (ruff not installed)")
    if os.path.exists(cache):
        os.remove(cache)

# ---- lint-on-edit: the C/C++ branch ----
# The fleet's largest repos are C/C++/ROS2 and had no lint coverage at all.
# The two settings that make single-file cppcheck usable are load-bearing:
# forced language (auto-detect reads C++ headers as C and reports a bogus
# syntaxError) and the one-line template (the default echoes source and notes,
# so one warning would arrive as five "findings" and blow the output cap).
import shutil as _shutil  # noqa: E402

if not _shutil.which("cppcheck"):
    print("  SKIP: cppcheck branch tests (cppcheck not installed)")
else:
    _lint_spec = importlib.util.spec_from_file_location("lint", LINT)
    assert _lint_spec is not None and _lint_spec.loader is not None
    _lint = importlib.util.module_from_spec(_lint_spec)
    _lint_spec.loader.exec_module(_lint)

    for ext, want_lang in ((".cpp", "c++"), (".hpp", "c++"), (".h", "c++"),
                           (".cc", "c++"), (".c", "c")):
        cmd = _lint._cmd_for("/tmp/probe" + ext) or []
        check("lint-on-edit: %s -> cppcheck --language=%s" % (ext, want_lang),
              cmd[:1] == ["cppcheck"] and ("--language=" + want_lang) in cmd)

    cmd = _lint._cmd_for("/tmp/probe.cpp") or []
    check("lint-on-edit: cppcheck exits nonzero on findings",
          "--error-exitcode=1" in cmd)
    check("lint-on-edit: cppcheck emits one line per finding",
          any(c.startswith("--template={file}") for c in cmd)
          and "--template-location=" in cmd)

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "leaky.cpp")
        with open(src, "w") as f:
            f.write("int f() {\n    int *p = new int[4];\n    p[0] = 1;\n"
                    "    return p[0];\n}\n")
        rc, out, err = qwen_gate(LINT, None, {"tool_input": {"file_path": src}})
        try:
            ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
        except Exception:
            ctx = ""
        check("lint-on-edit: real C++ defect is reported",
              rc == 0 and "memleak" in ctx)
        # One finding must stay one line — the de-dupe keys on whole lines.
        body = [ln for ln in ctx.splitlines() if ln.startswith(src)]
        check("lint-on-edit: no source echo / note lines in the output",
              len(body) == 1)
        cache = os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last"
                             % _h2.sha1(src.encode()).hexdigest()[:16])
        if os.path.exists(cache):
            os.remove(cache)

        # A C++ header must not be misread as C.
        hdr = os.path.join(tmp, "types.h")
        with open(hdr, "w") as f:
            f.write("namespace probe {\nclass T { public: int x; };\n}\n")
        rc, out, err = qwen_gate(LINT, None, {"tool_input": {"file_path": hdr}})
        check("lint-on-edit: C++ header is not reported as invalid C",
              "syntaxError" not in (out + err))
        cache = os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last"
                             % _h2.sha1(hdr.encode()).hexdigest()[:16])
        if os.path.exists(cache):
            os.remove(cache)

# ---- crg-autobuild: submodule-aware graph bootstrap ----
# The one-liner this replaces graphed only the superproject shell and never
# retried, leaving every umbrella repo in this fleet permanently blind.
AUTOBUILD = os.path.join(HOOKS, "crg-autobuild.py")
_ab_spec = importlib.util.spec_from_file_location("ab", AUTOBUILD)
assert _ab_spec is not None and _ab_spec.loader is not None
_ab = importlib.util.module_from_spec(_ab_spec)
_ab_spec.loader.exec_module(_ab)


def _git_init(path):
    os.makedirs(path, exist_ok=True)
    for args in (["init", "-q"],
                 ["config", "user.email", "t@t"],
                 ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", path] + args, capture_output=True)


with tempfile.TemporaryDirectory() as tmp:
    tmp = os.path.realpath(tmp)          # macOS /var -> /private/var
    root = os.path.join(tmp, "super")
    _git_init(root)
    with open(os.path.join(root, "a.py"), "w") as f:
        f.write("x = 1\n")
    subprocess.run(["git", "-C", root, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", root, "commit", "-qm", "i"], capture_output=True)

    # One first-party submodule and one vendored one below it — the shape the
    # real umbrella repos have.
    def _make_sub(name):
        origin = os.path.join(tmp, "origins", name)
        _git_init(origin)
        with open(os.path.join(origin, "b.py"), "w") as f:
            f.write("y = 2\n")
        subprocess.run(["git", "-C", origin, "add", "-A"], capture_output=True)
        subprocess.run(["git", "-C", origin, "commit", "-qm", "i"],
                       capture_output=True)
        return origin

    def _add_sub(super_repo, origin, rel):
        subprocess.run(["git", "-C", super_repo,
                        "-c", "protocol.file.allow=always",
                        "submodule", "add", "-q", origin, rel],
                       capture_output=True)
        subprocess.run(["git", "-C", super_repo, "commit", "-qm", "sub"],
                       capture_output=True)

    _add_sub(root, _make_sub("component"), "src/component")
    _add_sub(os.path.join(root, "src", "component"), _make_sub("libdep"),
             "extern/libdep")

    subs = _ab._submodule_dirs(root)
    check("crg-autobuild: finds the repo's own submodule",
          any(s.endswith("src/component") for s in subs))
    check("crg-autobuild: skips vendored (extern/) submodules",
          not any("extern" in s for s in subs))

    check("crg-autobuild: resolves the git root from a subdirectory",
          _ab._repo_root(os.path.join(root, "src")) == root)

    # The cwd-relative marker bug: from a subdirectory the old check missed an
    # existing graph and rebuilt on every prompt.
    os.makedirs(os.path.join(root, ".code-review-graph"))
    open(os.path.join(root, ".code-review-graph", "graph.db"), "w").close()
    check("crg-autobuild: an existing root graph is not rebuilt",
          _ab._needs_build(root) is False)

    lock = _ab._lock_path(root + "-fresh")
    with open(lock, "w") as f:
        f.write("1")
    check("crg-autobuild: a build already in flight is not started twice",
          _ab._needs_build(root + "-fresh") is False)
    os.remove(lock)

    check("crg-autobuild: outside a git repo it does nothing",
          _ab._repo_root(tempfile.gettempdir()) in (None, "")
          or not os.path.exists(os.path.join(
              _ab._repo_root(tempfile.gettempdir()) or "/nonexistent",
              ".git")))

# ---- Antigravity wiring: deploying a hook is not the same as wiring it ----
# The scripts deploy to ~/.gemini/config/hooks/ regardless of whether any
# event ever calls them, so a script can sit there looking installed and never
# run. Two things are asserted here because both have already gone wrong:
# an unsupported event name (Antigravity accepts only these five; SessionEnd
# was configured for weeks and is not one of them), and a command pointing at
# a hook file that does not exist.
_ANTI_EVENTS = {"PreToolUse", "PostToolUse", "PreInvocation",
                "PostInvocation", "Stop"}
with open(os.path.join(REPO, "antigravity/hooks.json")) as f:
    _anti = json.load(f)["dev-agent-kit"]

_bad_events = [e for e in _anti if e != "enabled" and e not in _ANTI_EVENTS]
check("antigravity/hooks.json: no unsupported event names (%s)"
      % (", ".join(_bad_events) or "none"), not _bad_events)

_cmds = []
for _ev, _groups in _anti.items():
    if _ev == "enabled":
        continue
    for _g in _groups:
        for _h in (_g.get("hooks", [_g]) if isinstance(_g, dict) else []):
            _cmds.append(_h.get("command", ""))

_missing = []
# The bridge is a private submodule: CI without its token has an empty
# directory there, and that is not a missing hook.
_BRIDGE = os.path.join(REPO, "extern/obsidian-vault-bridge/hooks")
_bridge_out = not os.path.isdir(_BRIDGE)
for _c in _cmds:
    if _bridge_out and "obsidian-vault-bridge" in _c:
        continue
    for _m in re.findall(r"hooks/([A-Za-z0-9_-]+\.py)", _c):
        if not os.path.exists(os.path.join(HOOKS, _m)) and not os.path.exists(
                os.path.join(_BRIDGE, _m)):
            _missing.append(_m)
check("antigravity/hooks.json: every referenced hook script exists (%s)"
      % (", ".join(sorted(set(_missing))) or "all found"), not _missing)

# The gates have to be reachable on the tool calls agy actually makes. Their
# matcher must therefore cover Antigravity's own wire names, not Claude's.
_pre = " ".join(json.dumps(_g) for _g in _anti.get("PreToolUse", []))
for _wire in ("view_file", "run_command", "write_to_file",
              "replace_file_content", "grep_search", "call_mcp_tool"):
    check("antigravity PreToolUse: %s is matched somewhere" % _wire,
          _wire in _pre)
for _gate in ("crg-gate.py", "bash-edit-guard.py", "skill-gate.py",
              "commit-attribution-guard.py"):
    check("antigravity PreToolUse: %s is wired" % _gate, _gate in _pre)

# ---- mem-save-guard: the key a record is saved under decides its note ----
# A blocking hook that ends in `|| true` blocks nothing: the shell turns its
# exit 2 into 0. The guard's missing-file case is the one that must exit 0,
# so it is spelled `[ -f "$H" ] || exit 0` and the python exit code survives.
def _guard_cmds(groups, matcher_has):
    out = []
    for _g in groups:
        if matcher_has in _g.get("matcher", ""):
            out += [_h["command"] for _h in _g.get("hooks", [])
                    if "mem-save-guard.py" in _h.get("command", "")]
    return out

for _host, _path, _key, _match, _agent in (
        ("claude", "claude/settings.json", None, "mcp__mem-lite__mem_save", ""),
        ("qwen", "qwen/settings.json", None, "mcp__mem-lite__mem_save", "DAK_AGENT=qwen "),
        ("antigravity", "antigravity/hooks.json", "dev-agent-kit", "call_mcp_tool",
         "DAK_AGENT=antigravity ")):
    with open(os.path.join(REPO, _path)) as f:
        _cfg = json.load(f)
    _hooks = _cfg[_key] if _key else _cfg["hooks"]
    _g = _guard_cmds(_hooks.get("PreToolUse", []), _match)
    check("%s: mem-save-guard runs PreToolUse on mem_save" % _host, len(_g) == 1)
    check("%s: mem-save-guard's block is not swallowed by || true" % _host,
          bool(_g) and "|| true" not in _g[0] and "|| exit 0" in _g[0])
    check("%s: mem-save-guard knows which agent it guards" % _host,
          bool(_g) and (_agent in _g[0] if _agent else "DAK_AGENT" not in _g[0]))

print()
print("Results: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PYEOF
