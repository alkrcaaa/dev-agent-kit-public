#!/usr/bin/env python3
"""
lint-on-edit hook (PostToolUse on Edit/Write).

Runs the matching linter on the file Claude just edited and feeds findings
straight back to Claude via stderr + exit 2 — the tightest possible feedback
loop: the model sees its mistake the moment it makes it, not when the user
runs CI.

Linters (only if installed — missing linter = silent pass):
  .py          -> ruff check
  .sh/.bash    -> shellcheck
  .yml/.yaml   -> ansible-lint, ONLY in ansible repos (ansible.cfg at git
                  root, or file under playbooks/roles/tasks/handlers);
                  any other yaml -> yamllint syntax-only (relaxed,
                  no-warnings: syntax errors / duplicate keys, zero style
                  noise) — covers helm values and k8s manifests.
  .tf/.tfvars  -> tflint (provider-aware) if installed, else
                  terraform fmt -check -diff (canonical style only).
  dashboards/*.json -> built-in Grafana dashboard sanity check: valid
                  JSON, has a title, no duplicate panel ids.

De-dupe: only NEW findings are reported. Findings are normalized (digits
stripped, so line shifts don't count as new) and cached per file; each
block reports the delta against the cache, so a pre-existing issue the
model can't or shouldn't fix (deliberate E402 etc.) is shown exactly
once and never rides along in later blocks — field data showed one such
finding repeated in 17 block messages of a single session. A clean run
clears the cache so future regressions block again.

Fail-open everywhere: linter crash, timeout, parse error -> exit 0.
Output capped so a wall of findings can't flood the context.
Escape hatch: `export LINT_HOOK_OFF=1`.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

import agent_env
import tempfile

MAX_LINES = 25
TIMEOUT = 45  # ansible-lint cold start can take a while

ANSIBLE_DIR_HINTS = ("playbooks", "roles", "tasks", "handlers", "group_vars", "host_vars")


def _git_root(path):
    d = os.path.dirname(path)
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return None


def _is_ansible_yml(fp):
    root = _git_root(fp)
    if root and os.path.exists(os.path.join(root, "ansible.cfg")):
        return True
    parts = fp.split(os.sep)
    return any(h in parts for h in ANSIBLE_DIR_HINTS)


def _cmd_for(fp):
    low = fp.lower()
    if low.endswith(".py"):
        if shutil.which("ruff"):
            # concise = one line per finding -> per-finding de-dupe is exact
            return ["ruff", "check", "--quiet", "--output-format", "concise", fp]
    elif low.endswith((".sh", ".bash")):
        if shutil.which("shellcheck"):
            return ["shellcheck", "-S", "warning", "-f", "gcc", fp]
    elif low.endswith((".yml", ".yaml")):
        if _is_ansible_yml(fp):
            if shutil.which("ansible-lint"):
                return ["ansible-lint", "--offline", "-qq", "-p", "--nocolor", fp]
        elif shutil.which("yamllint"):
            # syntax-only: catches broken indentation / duplicate keys in helm
            # values and k8s manifests without any style nagging
            return ["yamllint", "--no-warnings", "-f", "parsable",
                    "-d", "{extends: relaxed}", fp]
    elif low.endswith((".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx")):
        if shutil.which("cppcheck"):
            # .h is treated as C++, not left to auto-detection: a C++ header
            # read as C yields a bogus "invalid C code [syntaxError]" that
            # buries the real findings. Measured over 180 sampled headers in
            # the C++/ROS2 repos — auto-detect produced 46 such false errors,
            # forced c++ produced none, and none appeared in a pure-C
            # firmware tree either.
            lang = "c" if low.endswith(".c") else "c++"
            return [
                "cppcheck",
                # No style/information: single-file analysis without the build
                # graph makes those mostly noise. warning/performance/
                # portability are the classes that are still sound per-file.
                "--enable=warning,performance,portability",
                "--inline-suppr",          # honour // cppcheck-suppress in code
                "--quiet",
                # Unavoidable without the full include path; not a code defect.
                "--suppress=missingInclude",
                "--suppress=missingIncludeSystem",
                "--error-exitcode=1",      # cppcheck exits 0 on findings otherwise
                "--language=" + lang,
                # One line per finding, like ruff --output-format concise, so
                # the per-finding de-dupe below stays exact. The default gcc
                # template echoes source lines and notes, which would turn a
                # single warning into five "findings".
                "--template={file}:{line}:{column}: {severity}: {message} [{id}]",
                "--template-location=",
                fp,
            ]
    elif low.endswith((".tf", ".tfvars")):
        if shutil.which("tflint"):
            return ["tflint", "--format", "compact",
                    "--chdir", os.path.dirname(fp) or ".",
                    "--filter", os.path.basename(fp)]
        if shutil.which("terraform"):
            return ["terraform", "fmt", "-check", "-diff", fp]
    return None


def _is_grafana_dashboard(fp):
    low = fp.lower()
    if not low.endswith(".json"):
        return False
    parts = low.split(os.sep)
    return "dashboards" in parts or "dashboard" in os.path.basename(low)


def _grafana_findings(fp):
    """Built-in sanity check for Grafana dashboard JSON (no external linter
    exists worth shipping). Returns a list of finding lines; [] = clean."""
    try:
        with open(fp) as f:
            doc = json.load(f)
    except ValueError as e:
        return ["%s: invalid JSON — %s" % (os.path.basename(fp), e)]
    except OSError:
        return []
    if not isinstance(doc, dict) or "panels" not in doc:
        return []  # some other json living near dashboards — validity was enough
    out = []
    if not str(doc.get("title") or "").strip():
        out.append("dashboard has no title — Grafana will list it as 'New dashboard'")
    ids = []

    def walk(panels):
        for p in panels or []:
            if isinstance(p, dict):
                if p.get("id") is not None:
                    ids.append(p["id"])
                walk(p.get("panels"))  # rows nest their panels

    walk(doc.get("panels"))
    dups = sorted({str(i) for i in ids if ids.count(i) > 1})
    if dups:
        out.append("duplicate panel id(s): %s — panels/links will collide"
                   % ", ".join(dups))
    return out


def _cache_path(fp):
    key = hashlib.sha1(fp.encode("utf-8", "replace")).hexdigest()[:16]
    return os.path.join(tempfile.gettempdir(), "lint-on-edit-%s.last" % key)


def _norm(line):
    # Digits stripped: a pre-existing finding that merely shifts lines after
    # an unrelated edit must not count as new.
    return re.sub(r"\d+", "", line)


def main():
    if os.environ.get("LINT_HOOK_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    # Self-filter instead of trusting the matcher: the Antigravity wiring
    # registers one group over a union of wire names (its "*" semantics are
    # unverified), so a read must not reach an edit-only hook.
    # Filter when the payload says what the tool was; do NOT refuse when it
    # does not. Refusing on a missing name is the same silent-shutdown failure
    # this whole change exists to remove -- the matcher has already scoped the
    # event, so an unnamed payload should still be handled.
    _tool = agent_env.tool_name(data)
    if _tool and _tool not in ("Edit", "Write", "NotebookEdit"):
        sys.exit(0)

    fp = agent_env.tool_input(data).get("file_path") or ""
    if not fp or not os.path.isfile(fp):
        sys.exit(0)

    cmd = _cmd_for(fp)
    if cmd is not None:
        tool = cmd[0]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
        except Exception:
            sys.exit(0)
        if r.returncode == 0:
            lines = []
        else:
            out = (r.stdout or "") + (r.stderr or "")
            lines = [ln for ln in out.splitlines() if ln.strip()]
    elif _is_grafana_dashboard(fp):
        tool = "grafana-check"
        try:
            lines = _grafana_findings(fp)
        except Exception:
            sys.exit(0)
    else:
        sys.exit(0)

    cache = _cache_path(fp)
    if not lines:
        try:
            os.remove(cache)  # clean run: future regressions must block again
        except OSError:
            pass
        sys.exit(0)

    try:
        with open(cache) as f:
            prev = set(f.read().splitlines())
    except OSError:
        prev = set()
    try:
        with open(cache, "w") as f:
            f.write("\n".join(_norm(ln) for ln in lines))
    except OSError:
        pass

    new = [ln for ln in lines if _norm(ln) not in prev]
    if not new:
        sys.exit(0)  # everything already reported — don't nag

    clipped = new[:MAX_LINES]
    if len(new) > MAX_LINES:
        clipped.append("... (%d more findings truncated)" % (len(new) - MAX_LINES))
    suppressed = len(lines) - len(new)
    if suppressed:
        clipped.append("(+%d previously reported finding(s) still present, omitted)"
                       % suppressed)

    try:
        import hook_metrics
        # detail = which linter fired; count = how many NEW findings it caught.
        hook_metrics.record("lint-on-edit", "findings", data.get("cwd"),
                            "%s:%d" % (tool, len(new)))
    except Exception:
        pass
    # Channel depends on the host: Claude surfaces PostToolUse stderr as a
    # tool error, Qwen silently discards it. agent_env picks the one that
    # actually reaches the model, then exits.
    agent_env.post_feedback(
        "[lint-on-edit] %s found NEW issues in the file you just wrote — fix them now:\n%s"
        % (tool, "\n".join(clipped))
    )


if __name__ == "__main__":
    main()
