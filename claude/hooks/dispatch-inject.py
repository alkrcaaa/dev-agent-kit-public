#!/usr/bin/env python3
"""
SessionStart hook: surface pending dispatch/tasks/*.md addressed to this host.

dispatch/ is repo-local (see dispatch/README.md), not deployed anywhere — this
hook is global (deployed to ~/.claude/hooks/) and simply no-ops in any repo
that doesn't have a dispatch/tasks/ directory.
"""
import os
import re
import subprocess

import agent_env

STATUS_RE = re.compile(r"^status:\s*(\S+)\s*$", re.MULTILINE)
TO_RE = re.compile(r"^to:\s*(\S+)\s*$", re.MULTILINE)


def repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return None


def pending_for(agent, tasks_dir):
    pending = []
    for name in sorted(os.listdir(tasks_dir)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(tasks_dir, name)
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
        except OSError:
            continue
        status_m = STATUS_RE.search(content)
        to_m = TO_RE.search(content)
        if not status_m or not to_m:
            continue
        if to_m.group(1) == agent and status_m.group(1) == "pending_%s" % agent:
            pending.append(name)
    return pending


def main():
    root = repo_root()
    if not root:
        return
    tasks_dir = os.path.join(root, "dispatch", "tasks")
    if not os.path.isdir(tasks_dir):
        return

    pending = pending_for(agent_env.AGENT, tasks_dir)
    if not pending:
        return

    lines = "\n".join("  - dispatch/tasks/%s" % n for n in pending)
    context = (
        "[dispatch] %d pending task(s) assigned to you (%s):\n%s\n"
        "If relevant, read the file, fill in the relevant section, and update "
        "the status/to fields in the frontmatter. See dispatch/README.md."
        % (len(pending), agent_env.AGENT, lines)
    )
    agent_env.emit_context("SessionStart", context)

    try:
        import hook_metrics
        hook_metrics.record("dispatch-inject", "surface", root, "%d pending" % len(pending))
    except Exception:
        pass


if __name__ == "__main__":
    main()
