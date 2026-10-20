#!/usr/bin/env python3
"""
code-review-graph gate hook.

Goal: make Claude actually consult the code graph instead of defaulting to
manual Read/Grep. Static CLAUDE.md guidance is loaded once and decays; this
fires at the decision point.

Host-portable: deployed to both Claude Code and Qwen Code. agent_env maps
Qwen's wire tool names (read_file/grep_search/run_shell_command) onto the
canonical ones compared below.

Modes (passed as argv[1]):

  gate  (PreToolUse on Read/Grep/Bash)
        Budget model: every graph consult grants BUDGET manual code
        reads/searches. Each Read/Grep/bash-cat of code decrements it.
        At zero the gate closes again and the next manual read is blocked
        with exit code 2 — stderr steers Claude back to the graph. A block
        auto-refills the budget, so it fires at most once per cycle and
        can never loop even if the MCP is down. This re-arming is the fix
        for long-session decay: a one-shot gate opens once and the model
        drifts back to bulk-reading; a budget keeps pressure on all session.
        Covers Read and Grep tools, and Bash commands that read or search
        code files (cat/head/tail/sed/awk/grep/rg) — otherwise Bash is a
        trivial bypass.

  mark  (PostToolUse on any mcp__code-review-graph__* tool)
        Graph was consulted -> refills the manual-read budget.

  remind (UserPromptSubmit)
        If the repo has a built graph, print a one-line reminder to stdout
        (injected as context). Fresh every prompt — counters guidance decay
        in long sessions. ~40 tokens.

Fail-open everywhere: any parse/IO error -> exit 0 (never obstruct work).
Only ever acts in repos that actually have a graph, and never on
docs/config files (.md/.json/.yaml/...).

Coverage-aware: the gate only defends file types the graph actually indexes
(read from nodes.file_path). In an infra repo whose graph covers just the
python/bash helpers, greps and reads over .tf/.yaml/.json pass freely —
steering the model to a graph that can't answer is worse than no gate.
Unknown coverage (unreadable/legacy DB) falls back to gating everything.
"""
import sys
import os
import re
import json
import functools
import hashlib
import subprocess
import tempfile

import agent_env

CODE_EXT = (
    ".py", ".pyi", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
    ".cpp", ".cc", ".cxx", ".c", ".h", ".hpp", ".hh", ".go", ".rs",
    ".java", ".rb", ".php", ".cs", ".swift", ".kt", ".kts", ".scala",
    ".m", ".mm", ".sh", ".bash", ".zsh", ".lua", ".dart", ".ex", ".exs",
    ".pl", ".r", ".jl", ".vue", ".svelte",
)

_EXT_UNION = "|".join(e.lstrip(".") for e in CODE_EXT)
# Tokens that really are file extensions. _exts_in_text would otherwise read any
# dotted word (`user.name`, `v1.0`) as one, and an "aimed at non-indexed types"
# verdict on a bogus ext waved code searches through. Unknown -> dropped -> gated.
_KNOWN_EXT = {e.lstrip(".") for e in CODE_EXT} | {
    "tf", "tfvars", "hcl", "yaml", "yml", "json", "jsonl", "md", "rst", "txt",
    "toml", "ini", "cfg", "conf", "env", "xml", "html", "css", "scss", "csv",
    "lock", "j2", "sql", "log", "service", "proto", "graphql", "mk",
}
# Where a command may start: line start, pipeline/list separators, newline,
# `$(` / backtick substitution.
_CMD_START = r"(?:^\s*|[|;&\n(`]\s*)"
# A reading command whose args mention a code file: `cat foo.py`, `head -50 x.sh`
_BASH_READ_RE = re.compile(
    _CMD_START + r"(?:cat|head|tail|sed|awk|less|more)\b[^|;&]*\.(?:%s)\b" % _EXT_UNION
)
# A search command — only gated when clearly aimed at code (code ext or recursive,
# incl. bundled flags: -rn, -rl, -ri, -nr). Judged on its own stage, up to the next
# separator: in `bash x.sh | grep foo` the `.sh` belongs to another stage. A piped
# grep still counts when its own stage reads files (`true | grep -rn foo .`).
_BASH_GREP_RE = re.compile(_CMD_START + r"(?:grep|rg|egrep|fgrep|ack|ag)\b[^|;&\n]*")
# rg/ag/ack recurse by default, so no -r is needed. Not after a pipe: `x | rg y`
# filters stdin rather than reading files.
_BASH_RECURSIVE_RE = re.compile(r"(?:^\s*|[;&\n(`]\s*)(?:rg|ag|ack)\b")
_BASH_GREP_CODE_RE = re.compile(r"\.(?:%s)\b|\s-[a-zA-Z]*[rR][a-zA-Z]*\b|--include" % _EXT_UNION)
# Bulk-read sweeps that never name an extension: `find ... -exec cat {}` and
# `... | xargs (sh -c) cat/grep/...` — the exact pattern the budget exists for.
_BASH_SWEEP_RE = re.compile(
    r"\bfind\b[^|;&]*-exec\s+[^|;&]*\b(?:cat|head|tail|sed|awk|grep)\b"
    r"|\|\s*xargs\b[^|&]*\b(?:cat|head|tail|sed|awk|grep)\b"
)


def _session_key(data):
    sid = data.get("session_id") or ""
    if not sid:
        # fall back to cwd so the gate is still per-repo, not global
        sid = "cwd:" + (data.get("cwd") or os.getcwd())
    return hashlib.sha1(sid.encode("utf-8", "replace")).hexdigest()[:16]


# Manual code reads/searches allowed per graph consult before the gate re-arms.
#
# This constant sets the ceiling on the structural ratio the gate can produce.
# Field measurement (agent-stats, 2026-08): the model has ~no intrinsic graph
# habit — essentially every graph consult is one this gate forced. So the ratio
# converges on 1 consult per BUDGET reads, i.e. a ceiling of 1/(1+BUDGET):
#
#   BUDGET=12 -> 7.7% ceiling (observed 9% in miivii — the gate was the whole
#                signal, and the 10-30% target band was arithmetically
#                unreachable at this setting)
#   BUDGET=5  -> 16.7% ceiling, lands mid-band
#   BUDGET=4  -> 20% ceiling
#   BUDGET=3  -> 25% ceiling
#
# Re-measured 2026-09-22 (agent-stats, 7d): at BUDGET=5 the heaviest repos
# (repo-a 9%, repo-b 11%) sat BELOW the 16.7% ceiling, not
# at it -- the gate wasn't even the binding constraint there, so headroom was
# being left on the table. Dropped to 3 to raise the ceiling; re-measure
# after a week before going lower still.
#
# Don't raise this without re-reading that arithmetic: the target band and this
# number are the same knob.
BUDGET = 3


def _metric(action, cwd=None, detail=None):
    """Record a decision for scripts/hook-stats.sh. Deferred import so a
    missing/partial deploy can never break the gate."""
    try:
        import hook_metrics
        hook_metrics.record("crg-gate", action, cwd, detail)
    except Exception:
        pass


def _marker_path(data):
    return os.path.join(tempfile.gettempdir(), "crg-gate-%s.open" % _session_key(data))


def _read_budget(data):
    """Return (budget, ever_seen). Missing file = fresh session."""
    try:
        with open(_marker_path(data)) as f:
            raw = f.read().strip()
        return (int(raw) if raw else 0), True
    except FileNotFoundError:
        return 0, False
    except Exception:
        return BUDGET, True  # unreadable -> fail-open

def _write_budget(data, n):
    # tmp + rename: a concurrent hook must never read the file mid-truncate
    # (empty -> budget 0 -> a spurious block).
    try:
        path = _marker_path(data)
        tmp = "%s.%d" % (path, os.getpid())
        with open(tmp, "w") as f:
            f.write(str(n))
        os.replace(tmp, path)
    except Exception:
        pass


@functools.lru_cache(maxsize=None)
def _git_root(cwd):
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return cwd


def _graph_db(data):
    cwd = data.get("cwd") or os.getcwd()
    path = os.path.join(_git_root(cwd), ".code-review-graph", "graph.db")
    return path if os.path.exists(path) else None


def _graph_files(db):
    """File paths indexed in the graph, or None if unknown."""
    try:
        import sqlite3
        conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=1)
        rows = conn.execute("SELECT DISTINCT file_path FROM nodes").fetchall()
        conn.close()
        return {fp for (fp,) in rows if fp} or None
    except Exception:
        return None


def _graph_exts(db, files=None):
    """File extensions actually indexed in the graph, or None if unknown.

    None (unreadable/legacy DB) means: gate everything, as before."""
    files = files if files is not None else _graph_files(db)
    if not files:
        return None
    exts = {os.path.splitext(fp)[1].lower() for fp in files}
    exts.discard("")
    return exts or None


def _in_graph(path, files, root):
    """Whether a file is one the graph indexed (stored absolute or repo-relative).

    A submodule or a file the parser skipped has an indexed extension but no
    node, so the graph cannot answer for it -- gating it only costs a call."""
    full = os.path.realpath(path)
    return any(os.path.realpath(fp if os.path.isabs(fp) else os.path.join(root, fp)) == full
               for fp in files)


def _exts_in_text(text):
    """Every .ext token mentioned in a glob/command, normalized to '.ext'."""
    exts = {"." + m.lower() for m in re.findall(r"\.(\w+)\b", text)}
    for group in re.findall(r"\.\{([^}]+)\}", text):  # *.{ts,tsx}
        exts |= {"." + p.strip().lower() for p in group.split(",") if p.strip()}
    return {e for e in exts if e[1:] in _KNOWN_EXT}


_RG_TYPE_EXTS = {
    "python": {".py", ".pyi"}, "rust": {".rs"}, "ruby": {".rb"},
    "typescript": {".ts", ".tsx"}, "javascript": {".js", ".jsx", ".mjs", ".cjs"},
    "kotlin": {".kt", ".kts"}, "csharp": {".cs"}, "cpp": {".cpp", ".cc", ".cxx", ".hpp", ".hh"},
    "markdown": {".md"}, "yaml": {".yaml", ".yml"}, "sh": {".sh", ".bash", ".zsh"},
}


def _grep_target_exts(ti):
    """Extensions a Grep call is scoped to, if determinable."""
    exts = set()
    for key in ("glob", "path"):
        val = ti.get(key) or ""
        exts |= _exts_in_text(val)
    t = (ti.get("type") or "").strip().lower()
    if t:
        # ripgrep type names are not extensions: rust -> .rs, not .rust
        exts |= _RG_TYPE_EXTS.get(t) or {"." + t}
    return exts


def _bash_reads_code(command):
    if _BASH_READ_RE.search(command):
        return True
    if any(_BASH_GREP_CODE_RE.search(m.group(0)) for m in _BASH_GREP_RE.finditer(command)):
        return True
    if _BASH_RECURSIVE_RE.search(command):
        return True
    if _BASH_SWEEP_RE.search(command):
        return True
    return False


def _remind(data):
    db = _graph_db(data)
    if db is None:
        sys.exit(0)
    stats = ""
    try:
        import sqlite3
        conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=1)
        n = conn.execute("SELECT count(*) FROM nodes").fetchone()[0]
        conn.close()
        stats = " (%d nodes)" % n
    except Exception:
        pass
    exts = _graph_exts(db)
    coverage = ""
    if exts:
        coverage = (
            " Graph indexes %s only — other file types (config/IaC/docs) are "
            "not in it; read/grep those directly." % ", ".join(sorted(exts))
        )
    # JSON rather than bare stdout: Claude injects both, Qwen only the former.
    agent_env.emit_context(
        "UserPromptSubmit",
        "[crg] Code graph ready%s. Graph-before-grep: start code tasks with "
        "get_minimal_context_tool; use semantic_search_nodes_tool / query_graph_tool "
        "instead of manual grep/read.%s" % (stats, coverage),
    )
    sys.exit(0)


def _is_graph_tool(name):
    """True for a code-review-graph MCP call, under either host's naming.

    Claude/Qwen: the fully-qualified mcp__code-review-graph__<tool>.
    Antigravity: call_mcp_tool unwrapped to the bare server-side name, which
    for this server always ends in _tool (get_minimal_context_tool,
    query_graph_tool, ...) -- no other MCP server in the kit names tools that
    way, so the suffix is a safe discriminator for the bare form.
    """
    if not name or name == "call_mcp_tool":
        return False  # the bare wrapper: an MCP call whose target we cannot see
    if name.startswith("mcp__"):
        return name.startswith("mcp__code-review-graph__")
    return name.endswith("_tool")


def main():
    # Escape hatch: `export CRG_HOOKS_OFF=1` disables the gate (and freshness) entirely.
    if os.environ.get("CRG_HOOKS_OFF"):
        sys.exit(0)

    mode = sys.argv[1] if len(sys.argv) > 1 else "gate"
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if mode == "mark":
        # On Claude the matcher (mcp__code-review-graph__.*) is the whole
        # filter. Antigravity delivers every MCP call as call_mcp_tool, so a
        # matcher wide enough to catch a graph consult there also catches every
        # other MCP tool -- and marking on those would refill the budget
        # without anyone having looked at the graph, i.e. silently disable the
        # gate. Check the tool itself instead of trusting the matcher.
        if not _is_graph_tool(agent_env.raw_tool_name(data)):
            sys.exit(0)
        _write_budget(data, BUDGET)
        sys.exit(0)

    if mode == "remind":
        _remind(data)

    # --- gate mode ---
    db = _graph_db(data)
    if db is None:
        sys.exit(0)  # no graph here -> nothing to enforce
    graph_files = _graph_files(db)
    graph_exts = _graph_exts(db, graph_files)

    tool = agent_env.tool_name(data)
    ti = agent_env.tool_input(data)

    if tool == "Read":
        fp = (ti.get("file_path") or "").lower()
        if not fp.endswith(CODE_EXT):
            sys.exit(0)  # docs/config -> never gate
        if graph_exts is not None and os.path.splitext(fp)[1] not in graph_exts:
            sys.exit(0)  # code type the graph doesn't index -> can't help
        raw = ti.get("file_path") or ""
        cwd = data.get("cwd") or os.getcwd()
        root = os.path.realpath(_git_root(cwd))
        if os.path.isabs(raw):
            if not (os.path.realpath(raw) + os.sep).startswith(root + os.sep):
                sys.exit(0)  # outside this repo -> not in its graph
        if graph_files and not _in_graph(os.path.join(cwd, raw), graph_files, root):
            sys.exit(0)  # submodule / unparsed file -> the graph can't answer for it
        via = "reading code files"
    elif tool == "Grep":
        target = _grep_target_exts(ti)
        if graph_exts is not None and target and not (target & graph_exts):
            sys.exit(0)  # search scoped entirely to non-indexed types
        via = "grepping a graphed repo"
    elif tool == "Bash":
        cmd = ti.get("command") or ""
        if not _bash_reads_code(cmd):
            sys.exit(0)
        # Quoted strings are search patterns (`grep 'schema.sql'`), not targets --
        # except quoted globs (`--include='*.tf'`), which do scope the search.
        mentioned = _exts_in_text(re.sub(
            r"'[^'*{]*'|\"[^\"*{]*\"", " ", cmd))
        if graph_exts is not None and mentioned and not (mentioned & graph_exts):
            sys.exit(0)  # explicitly aimed at non-indexed file types
        via = "reading/searching code via bash"
    else:
        sys.exit(0)

    budget, seen = _read_budget(data)
    if budget > 0:
        _write_budget(data, budget - 1)
        sys.exit(0)

    # Budget exhausted (or fresh session): block once, refill so we never loop.
    _write_budget(data, BUDGET)

    if not seen:
        msg = (
            "[code-review-graph gate] This repo has a built code graph and you have "
            "not consulted it yet this session. Before %s, "
            "call get_minimal_context_tool(task=\"<what you're doing>\") FIRST — it returns "
            "full structural context (key entities, callers, risk, flows) in ~100 tokens. "
            "Then use semantic_search_nodes_tool / query_graph_tool / lsp_* for navigation." % via
        )
    else:
        msg = (
            "[code-review-graph gate] You have made %d manual code reads/searches since "
            "last consulting the graph — you are drifting into bulk-reading. Re-orient "
            "before %s: semantic_search_nodes_tool to locate, query_graph_tool "
            "(callers_of/callees_of/tests_for) to navigate, get_review_context_tool for "
            "token-efficient snippets. Targeted reads of files the graph pointed you to "
            "are fine; sweeping the repo file-by-file is not. If the sweep is the job "
            "(review, \"where/how does X work\", log triage), hand it to ask_worker "
            "(advisor-workers skill) and verify its findings instead." % (BUDGET, via)
        )
    if graph_exts is not None:
        msg += (
            " (Graph indexes %s only — reads/greps scoped to other file types, "
            "e.g. Grep with glob='*.tf', pass this gate freely.)"
            % ", ".join(sorted(graph_exts))
        )
    print(msg, file=sys.stderr)
    _metric("block", data.get("cwd"), "rearm" if seen else "fresh")
    sys.exit(2)


if __name__ == "__main__":
    main()
