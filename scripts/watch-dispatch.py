#!/usr/bin/env python3
"""
watch-dispatch.py - Local notification tool that monitors the `status:` field
of task files in dispatch/tasks/.

This is NOT a cross-process "wake-up" mechanism: it cannot trigger another
agent's session. It only prints a terminal notification so the user does not
miss the handoff moment — presenting the file to the other agent's session
is still the user's responsibility. See dispatch/README.md.

Usage:
  watch-dispatch.py                 Watch all files in dispatch/tasks/*.md
  watch-dispatch.py <file>          Watch only the given file
  watch-dispatch.py --timeout 600   Custom timeout instead of the default 1800s
"""
import argparse
import os
import re
import sys
import time

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TASKS_DIR = os.path.join(ROOT_DIR, "dispatch", "tasks")

STATUS_RE = re.compile(r"^status:\s*(\S+)\s*$", re.MULTILINE)


def read_status(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except OSError:
        return None
    match = STATUS_RE.search(content)
    return match.group(1) if match else None


def discover_files(explicit_file):
    if explicit_file:
        return [os.path.abspath(explicit_file)]
    if not os.path.isdir(TASKS_DIR):
        return []
    return sorted(
        os.path.join(TASKS_DIR, name)
        for name in os.listdir(TASKS_DIR)
        if name.endswith(".md")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", help="a single task file (optional)")
    parser.add_argument("--timeout", type=int, default=1800, help="seconds (default 1800)")
    parser.add_argument("--interval", type=int, default=2, help="polling interval, seconds")
    args = parser.parse_args()

    files = discover_files(args.file)
    if not files:
        print(f"[WATCHER] No files to watch ({TASKS_DIR})", file=sys.stderr)
        return 1

    print(f"[WATCHER STARTED] Watched files: {len(files)}")
    for f in files:
        print(f"  - {os.path.relpath(f, ROOT_DIR)}")
    sys.stdout.flush()

    initial_status = {f: read_status(f) for f in files}
    start_time = time.time()

    while time.time() - start_time < args.timeout:
        time.sleep(args.interval)
        for f in files:
            current = read_status(f)
            if current != initial_status[f]:
                print("\n" + "=" * 60)
                print(f"🔔 [NOTIFICATION] {os.path.relpath(f, ROOT_DIR)}")
                print(f"   status: {initial_status[f]} -> {current}")
                print("=" * 60 + "\n")
                sys.stdout.flush()
                return 0

    print(f"[WATCHER TIMEOUT] No status change detected for {args.timeout}s.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
