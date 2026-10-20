#!/usr/bin/env python3
"""
skill-gate hook.

Goal: make Claude actually load the matching domain skill before editing
domain files. Static CLAUDE.md guidance decays in long sessions, and skill
descriptions alone demonstrably fail to trigger mid-build (a full webui was
shipped without frontend-design ever firing). Like crg-gate, this fires at
the decision point instead of hoping.

Modes (argv[1]):

  gate  (PreToolUse on Edit/Write)
        Maps the target file to a skill domain (UI files -> design skills,
        ansible trees -> ansible skill, terraform/helm/k8s/grafana files ->
        devops skill). If no skill of that domain has been
        loaded this session, block ONCE with exit 2 — stderr tells Claude
        which skill to load. The warning is recorded, so the retry passes
        and it can never loop. One warning per domain per session.

  mark  (PostToolUse on Skill and Read)
        Records skill loads: a Skill tool invocation, or a Read of any
        SKILL.md, whose name/path matches a domain's markers.

The block message carries the domain's operative checklist inline, lifted from
the deployed wrapper between its <!-- gate:begin --> / <!-- gate:end --> markers
(single source: edit the SKILL.md, both the skill and this gate follow). The
"load the skill" instruction stays first and unchanged — the checklist is the
floor for a host that skips the load, not a replacement for reading the skill.
Measured on qwen 2026-08-09: a 27B model invokes the skill tool but does not
follow a pointer inside the result to a second file, so guidance that only
exists behind that pointer never lands. Claude follows the pointer; for it this
is purely additive.

Fail-open everywhere: any parse/IO error -> exit 0 (never obstruct work).
Escape hatch: `export SKILL_GATE_OFF=1`.
"""
import sys
import os
import re
import json
import hashlib
import tempfile

import agent_env

# Each domain matches via one or more (exts, path_re) rules — a file matches
# the domain if it matches ANY rule (path_re=None means ext alone suffices).
# NOTE — no generic "testing" domain on purpose. It was added here on
# 2026-08-09 and removed the same day: firing it revealed that the
# `testing-handbook` skill it pointed at is entirely fuzzing/sanitizer/
# coverage material (libFuzzer, AFL++, Atheris, ASan, Wycheproof), not
# unit/integration guidance. Gating every test-file edit would have sent
# every `test_foo.py` edit into fuzzing docs. No skill in this kit serves
# the generic "I am writing a unit test" case, so there is nothing worth
# blocking on. Re-add only alongside a skill that actually answers it.
DOMAINS = {
    "design": {
        "rules": [
            ((".html", ".htm", ".css", ".scss", ".sass", ".less",
              ".vue", ".svelte", ".jsx", ".tsx"), None),
        ],
        "skill": "design-dna",
        "markers": ("design", "frontend", "taste", "dataviz", "artifact"),
        "advice": (
            "load the `design-dna` skill first (creates/obeys the project's "
            "design/DESIGN-DNA.md identity), then `frontend-design` for craft. "
            "This is how UIs stop coming out AI-generic."
        ),
    },
    "ansible": {
        "rules": [
            ((".yml", ".yaml"), re.compile(
                r"(^|/)(roles|playbooks|group_vars|host_vars)/|ansible|playbook")),
        ],
        "skill": "ansible",
        "markers": ("ansible",),
        "advice": "load the `ansible` skill first (playbook patterns, idempotency, debugging).",
    },
    # Dependency manifests / lockfiles — the decision point where a new
    # transitive dependency (and its CVEs) actually enters the repo.
    "supply-chain": {
        "rules": [
            ((".txt",), re.compile(r"requirements[^/]*\.txt$")),
            ((".json",), re.compile(r"(^|/)package(-lock)?\.json$")),
            ((".toml",), re.compile(r"pyproject\.toml$|cargo\.toml$")),
            ((".mod",), re.compile(r"go\.mod$")),
            ((".lock",), None),
            ((".yaml", ".yml"), re.compile(r"(pnpm|npm)-lock\.ya?ml$")),
        ],
        "skill": "supply-chain-audit",
        "markers": ("supply-chain", "dependency", "sbom"),
        "advice": (
            "load the `supply-chain-audit` skill first — it covers vulnerable/"
            "malicious packages, transitive pulls, pinning and lockfile review."
        ),
    },
    # Security-sensitive code paths: auth, crypto, session, access control.
    "security": {
        "rules": [
            # Calibrated against the real workspace (2026-08-08), because the
            # obvious keyword list is a false-positive machine: bare `token`
            # matches every `tokenizer.py` (fatal in LLM repos) and bare
            # `session` matched this kit's own session-size-nudge.py. Both are
            # narrowed to forms that only occur in actual security code.
            ((".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".go", ".rb",
              ".php", ".java", ".cs", ".rs"),
             re.compile(
                 r"auth|login|signin|signup|passwd|password|credential"
                 r"|secret|crypto|cipher|hmac|permission|rbac|sso|oauth|jwt"
                 # token: only auth-flavoured, never `tokenizer`
                 r"|(?:access|refresh|api|bearer|csrf|id)[_-]?tokens?\b"
                 r"|tokens?[_-](?:store|manager|service|refresh|validation)"
                 # session: only session *management*, not any name containing it
                 r"|(?:^|/)sessions?[._]"
                 r"|session[_-](?:manager|store|middleware|cookie|handler|"
                 r"id|entries|state)")),
        ],
        "skill": "owasp-security",
        "markers": ("owasp", "security", "static-analysis", "differential-review"),
        "advice": (
            "load the `owasp-security` skill first (Top 10:2025, ASVS 5.0, "
            "LLM/Agentic Top 10) before touching auth/crypto/session code."
        ),
    },
    # Ordered after ansible: an ansible-tree yaml wins there; helm/k8s yaml
    # and terraform/grafana files land here.
    "devops": {
        "rules": [
            ((".tf", ".tfvars", ".hcl"), None),
            ((".yml", ".yaml"), re.compile(
                r"/(helm|charts|templates|manifests|k8s|kubernetes)/|values.*\.ya?ml$")),
            ((".json",), re.compile(r"/dashboards/|dashboard")),
            # Containers and pipelines — the checklist above devotes its two
            # longest sections to these, so the rules have to reach them.
            # ("",) is an always-true endswith: the regex alone decides, which
            # is what extensionless Dockerfile/Containerfile needs.
            (("",), re.compile(r"(^|/)(docker|container)file(\.[\w.-]+)?$")),
            ((".yml", ".yaml"), re.compile(
                r"(^|/)docker-compose[^/]*\.ya?ml$|(^|/)compose\.ya?ml$"
                r"|(^|/)\.gitlab-ci\.ya?ml$|/\.github/workflows/"
                r"|/\.circleci/|(^|/)azure-pipelines[^/]*\.ya?ml$")),
        ],
        "skill": "devops",
        "markers": ("devops", "terraform", "iac", "k8s", "gitops",
                    "monitoring", "ci-cd"),
        "advice": (
            "load the `devops` skill first — it routes to the matching topic "
            "(iac-terraform, k8s-troubleshooter, monitoring-observability, gitops)."
        ),
    },
    # MCP server source — the kit's own servers (local-model-mcp, mcp-infra/*).
    # Ordered last so an auth/crypto file inside one still routes to security.
    "mcp-server": {
        "rules": [
            ((".py", ".ts", ".js", ".mjs"), re.compile(
                r"(^|/)(local-model-mcp|mcp-infra/[^/]+|[^/]*-mcp(-server)?|mcp[-_]server[^/]*)/")),
        ],
        "skill": "mcp-builder",
        "markers": ("mcp-builder",),
        "advice": (
            "load the `mcp-builder` skill first (tool naming, schemas, output "
            "budget, actionable errors, side-effect annotations)."
        ),
    },
}


def _session_key(data):
    sid = data.get("session_id") or ""
    if not sid:
        sid = "cwd:" + (data.get("cwd") or os.getcwd())
    return hashlib.sha1(sid.encode("utf-8", "replace")).hexdigest()[:16]


def _state_path(data):
    return os.path.join(tempfile.gettempdir(), "skill-gate-%s.json" % _session_key(data))


def _load_state(data):
    try:
        with open(_state_path(data)) as f:
            s = json.load(f)
        return {"loaded": set(s.get("loaded", [])), "warned": set(s.get("warned", []))}
    except Exception:
        return {"loaded": set(), "warned": set()}


def _save_state(data, state):
    try:
        with open(_state_path(data), "w") as f:
            json.dump({"loaded": sorted(state["loaded"]),
                       "warned": sorted(state["warned"])}, f)
    except Exception:
        pass


GATE_BEGIN = "<!-- gate:begin -->"
GATE_END = "<!-- gate:end -->"


def _checklist(domain):
    """Operative core of the domain's skill, lifted from the deployed wrapper.

    The hook lives in <config>/hooks/ and the skills in <config>/skills/ on
    both hosts, so one relative lookup serves ~/.claude and ~/.qwen alike.
    Missing file or missing markers -> "" and the message degrades to the
    advice line alone (fail-open, same as everywhere else here).
    """
    name = DOMAINS[domain].get("skill")
    if not name:
        return ""
    path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "skills", name, "SKILL.md")
    try:
        with open(path, encoding="utf-8") as f:
            body = f.read()
        return body.split(GATE_BEGIN, 1)[1].split(GATE_END, 1)[0].strip()
    except Exception:
        return ""


def _domain_of_file(fp):
    low = fp.lower()
    for name, d in DOMAINS.items():
        for exts, path_re in d["rules"]:
            if not low.endswith(exts):
                continue
            if path_re is not None and not path_re.search(low):
                continue
            return name
    return None


def _domains_matching(text):
    low = text.lower()
    return {name for name, d in DOMAINS.items()
            if any(m in low for m in d["markers"])}


def _mark(data):
    tool = agent_env.tool_name(data)
    ti = agent_env.tool_input(data)
    if tool == "Skill":
        hit = _domains_matching(ti.get("skill") or "")
    elif tool == "Read":
        fp = ti.get("file_path") or ""
        if "SKILL.md" not in fp:
            sys.exit(0)
        hit = _domains_matching(fp)
    else:
        sys.exit(0)
    if hit:
        state = _load_state(data)
        state["loaded"] |= hit
        _save_state(data, state)
    sys.exit(0)


def main():
    if os.environ.get("SKILL_GATE_OFF"):
        sys.exit(0)

    mode = sys.argv[1] if len(sys.argv) > 1 else "gate"
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if mode == "mark":
        _mark(data)

    # --- gate mode (PreToolUse Edit/Write) ---
    # The matcher used to be the only thing keeping reads out of here. The
    # Antigravity wiring matches a union of every wire name (its matcher
    # semantics for "*" are unverified), so the tool check has to live in the
    # hook or a plain view_file of a playbook would fire the nudge.
    _tool = agent_env.tool_name(data)
    if _tool and _tool not in ("Edit", "Write", "NotebookEdit"):
        sys.exit(0)
    ti = agent_env.tool_input(data)
    fp = ti.get("file_path") or ""
    domain = _domain_of_file(fp)
    if domain is None:
        sys.exit(0)

    state = _load_state(data)
    if domain in state["loaded"] or domain in state["warned"]:
        sys.exit(0)

    state["warned"].add(domain)
    _save_state(data, state)
    msg = (
        "[skill-gate] You are editing a %s file (%s) without having loaded the "
        "matching skill this session: %s Then redo this edit."
        % (domain, os.path.basename(fp), DOMAINS[domain]["advice"])
    )
    checklist = _checklist(domain)
    if checklist:
        msg += (
            "\n\nWhichever you do, these apply to this edit — from the skill "
            "itself, not a substitute for loading it:\n\n%s" % checklist
        )
    print(msg, file=sys.stderr)
    try:
        import hook_metrics
        hook_metrics.record("skill-gate", "block", data.get("cwd"), domain)
    except Exception:
        pass
    sys.exit(2)


if __name__ == "__main__":
    main()
