#!/usr/bin/env python3
"""
crg-autobuild hook (UserPromptSubmit).

Builds the code graph for the repo you are working in, so the graph-first
workflow has something to answer with on a fresh clone without anyone
remembering to run `code-review-graph build`.

Replaces a shell one-liner that carried three defects:

  1. SUBMODULES WERE INVISIBLE. code-review-graph builds from git-tracked
     files, and a superproject lists each submodule as a single gitlink, not
     its contents. The one-liner produced a graph of the superproject shell
     (10 files in one measured repo) and then never retried, because the
     graph.db it just wrote is the "already built" marker. Every umbrella
     repo in this fleet keeps its real code in submodules, so the graph was
     permanently blind exactly where the code is. Each submodule is its own
     git repo and gets its own graph; the MCP is multi-repo aware
     (list_repos_tool / cross_repo_search_tool) and joins them.

  2. THE MARKER WAS cwd-RELATIVE. Started in a subdirectory of an
     already-graphed repo, `[ ! -f .code-review-graph/graph.db ]` never found
     the marker at the repo root, so it launched a FULL rebuild on every
     single prompt, in the background, silently.

  3. It lived as duplicated inline shell in two settings files, so none of
     the above could be tested.

Never blocks: builds are detached and this hook returns immediately. A lock
file keeps a slow build from being started again by the next prompt.
Fail-open everywhere. Escape hatch: `export CRG_AUTOBUILD_OFF=1`.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time

# A build in flight leaves no graph.db until it finishes, so the marker alone
# would let each prompt start another one. Treat a lock younger than this as
# "still running".
LOCK_TTL_SECONDS = 1800

# Cap the builds started from one prompt. A superproject with many submodules
# should warm up over a few prompts rather than fork a dozen parsers at once.
MAX_BUILDS_PER_PROMPT = 3

BUILD_CMD = "code-review-graph"

# Path segments that mark vendored third-party code. Graphing it is pure cost:
# it is not edited, not reviewed, and it dwarfs the first-party tree.
VENDOR_DIRS = {"extern", "external", "third_party", "thirdparty", "vendor",
               "deps", "3rdparty"}


def _git(cwd, *args):
    try:
        r = subprocess.run(["git", "-C", cwd, *args],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return None


def _repo_root(cwd):
    return _git(cwd, "rev-parse", "--show-toplevel")


def _submodule_dirs(root):
    """Absolute paths of the repo's own checked-out submodules.

    Deliberately NOT --recursive. Measured on this fleet: the top level holds
    the first-party components, while the level below is where vendored
    third-party lands (picoquic, picotls, generated protobuf definitions) —
    2712 of one component's 2779 C/C++ files were vendored. Recursing spent
    the build budget graphing dependencies nobody edits and starved the code
    that matters. VENDOR_DIRS covers the same pattern when a vendored tree is
    a direct submodule instead of a nested one.
    """
    out = _git(root, "submodule", "status")
    if not out:
        return []
    dirs = []
    for line in out.splitlines():
        # "<sha> <path> (<describe>)" — a leading '-' means not checked out.
        if line.startswith("-"):
            continue
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        rel = parts[1]
        if any(seg in VENDOR_DIRS for seg in rel.split("/")):
            continue
        path = os.path.join(root, rel)
        # A checked-out submodule has .git as a file (gitlink) or a directory.
        if os.path.exists(os.path.join(path, ".git")):
            dirs.append(path)
    return dirs


def _lock_path(path):
    key = hashlib.sha1(path.encode("utf-8", "replace")).hexdigest()[:16]
    return os.path.join(tempfile.gettempdir(), "crg-autobuild-%s.lock" % key)


def _needs_build(path):
    if os.path.exists(os.path.join(path, ".code-review-graph", "graph.db")):
        return False
    lock = _lock_path(path)
    try:
        if time.time() - os.path.getmtime(lock) < LOCK_TTL_SECONDS:
            return False  # a build is already running for this repo
    except OSError:
        pass
    return True


def _start_build(path):
    try:
        with open(_lock_path(path), "w") as f:
            f.write(str(int(time.time())))
    except OSError:
        pass
    try:
        subprocess.Popen(
            [BUILD_CMD, "build"],
            cwd=path,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,   # survives this hook's exit
        )
        return True
    except Exception:
        return False


def main():
    if os.environ.get("CRG_AUTOBUILD_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}

    cwd = data.get("cwd") or os.getcwd()
    root = _repo_root(cwd)
    if not root:
        sys.exit(0)  # not a git repo -> nothing to graph

    # Root first: it is the one the model is most likely to ask about.
    targets = [root] + _submodule_dirs(root)

    started = []
    for path in targets:
        if len(started) >= MAX_BUILDS_PER_PROMPT:
            break
        if _needs_build(path) and _start_build(path):
            started.append(path)

    if started:
        try:
            import hook_metrics
            hook_metrics.record("crg-autobuild", "build", cwd,
                                "%d repo(s)" % len(started))
        except Exception:
            pass
    sys.exit(0)


if __name__ == "__main__":
    main()
