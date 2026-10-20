#!/usr/bin/env python3
"""
PostToolUse(Edit|Write) hook: keep the code-review-graph fresh.

The auto-build hook only builds the graph once (when graph.db is absent); it
never updates. After edits the graph goes stale, which erodes trust and pushes
the model back to manual reading. This runs an INCREMENTAL `code-review-graph
update` (only changed files) in the background after each edit.

Coalesced by a lock dir so rapid edits don't pile up or collide on the SQLite
graph: while one update runs, further edits skip (the running update picks up
their changes). Stale locks (crashed update) are stolen after LOCK_STALE secs.

Fail-open everywhere: only acts where a graph already exists; any error -> exit 0.
Never blocks the tool (detaches the update and returns immediately).
"""
import sys
import os
import json
import time
import shutil
import subprocess

import agent_env

LOCK_STALE = 180  # seconds — steal a lock older than this (crashed update)


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


def _shquote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main():
    # Escape hatch: `export CRG_HOOKS_OFF=1` disables freshness (and the gate) entirely.
    if os.environ.get("CRG_HOOKS_OFF"):
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

    cwd = data.get("cwd") or os.getcwd()
    root = _git_root(cwd)
    if not os.path.exists(os.path.join(root, ".code-review-graph", "graph.db")):
        sys.exit(0)  # no graph here -> nothing to refresh
    if not shutil.which("code-review-graph"):
        sys.exit(0)

    lock = os.path.join(root, ".code-review-graph", ".update.lock")

    # steal a stale lock (previous update crashed)
    try:
        if os.path.isdir(lock) and (time.time() - os.path.getmtime(lock)) > LOCK_STALE:
            os.rmdir(lock)
    except Exception:
        pass

    # acquire lock atomically; if held, an update is already running -> coalesce
    try:
        os.mkdir(lock)
    except FileExistsError:
        sys.exit(0)
    except Exception:
        sys.exit(0)

    # detach the update; release the lock when it finishes
    try:
        subprocess.Popen(
            ["sh", "-c",
             "code-review-graph update >/dev/null 2>&1; rmdir " + _shquote(lock) + " 2>/dev/null || true"],
            cwd=root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        try:
            os.rmdir(lock)
        except Exception:
            pass
        sys.exit(0)

    # An uninstrumented hook and a dead one look identical from the outside --
    # hook-stats reports nothing for both -- so this one was wired for months
    # with no way to tell whether the graph was being refreshed at all. Only
    # the launch is recorded: the update itself is detached by design, and
    # claiming its outcome here would be reporting a result nobody waited for.
    try:
        import hook_metrics
        hook_metrics.record("crg-update", "update", root)
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
