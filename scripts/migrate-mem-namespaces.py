#!/usr/bin/env python3
"""Merge stranded absolute-path project keys in the claude-mem-lite DB.

The bug: observations saved with an explicit absolute `project` (e.g.
"/home/user/workspace/dev-agent-kit") land in a namespace parallel to the
canonical one mem-lite infers from the cwd ("workspace--dev-agent-kit").
mem-lite's resolveProject() only canonicalises *short* names — an absolute
path contains no "--", falls through to the substring fallback, and matches
itself, so the orphan namespace is self-consistent and never merges.

Consequence: mem_search is global and still finds them, but mem_recent and the
session-start auto-injection are namespace-scoped — so a large slice of a
project's memory silently stops being loaded. Measured 2026-08-08: 51 of 282
observations stranded, including 18 of dev-agent-kit's 27.

This rewrites orphan keys to the canonical form. Dry-run by default.

Usage:
  python3 scripts/migrate-mem-namespaces.py            # show what would change
  python3 scripts/migrate-mem-namespaces.py --apply    # do it (backs up first)
"""
import os
import re
import shutil
import sqlite3
import sys
import time

DB = os.path.expanduser("~/.claude-mem-lite/claude-mem-lite.db")
HOME = os.path.expanduser("~")

# Tables carrying a `project` column that must move together, or a merged
# namespace would still read half its history from the old key.
CANDIDATE_TABLES = (
    "observations", "user_prompts", "session_summaries",
    "sdk_sessions", "events", "session_handoffs", "deferred_work",
)


def canonical(project):
    """Absolute path -> the key mem-lite's inferProject() would produce."""
    if not project or not project.startswith("/"):
        return None                      # already canonical (or a short name)
    rel = project[len(HOME):] if project.startswith(HOME) else project
    rel = rel.strip("/")
    if not rel:
        return None
    return re.sub(r"/+", "--", rel)


def tables_with_project(con):
    out = []
    for (name,) in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall():
        if name not in CANDIDATE_TABLES:
            continue
        cols = {r[1] for r in con.execute("PRAGMA table_info(%s)" % name)}
        if "project" in cols:
            out.append(name)
    return out


def main():
    apply = "--apply" in sys.argv
    if not os.path.exists(DB):
        print("No claude-mem-lite DB at %s — nothing to do." % DB)
        return 0

    con = sqlite3.connect(DB)
    targets = tables_with_project(con)
    if not targets:
        print("No project-scoped tables found.")
        return 0

    plan = []          # (table, old, new, rows)
    for t in targets:
        rows = con.execute(
            "SELECT project, COUNT(*) FROM %s GROUP BY project" % t).fetchall()
        for proj, n in rows:
            new = canonical(proj)
            if new and new != proj:
                plan.append((t, proj, new, n))

    if not plan:
        print("✓ No stranded namespaces — every project key is already canonical.")
        return 0

    print("Stranded namespaces to merge:\n")
    for t, old, new, n in sorted(plan, key=lambda r: -r[3]):
        print("  %-18s %-44s -> %-32s %4d row(s)" % (t, old[:44], new[:32], n))
    total = sum(r[3] for r in plan)
    print("\n  %d row(s) across %d table(s)." % (total, len({r[0] for r in plan})))

    if not apply:
        print("\nDry run. Re-run with --apply to migrate (a backup is taken first).")
        return 0

    backup = "%s.bak-%s" % (DB, time.strftime("%Y%m%d-%H%M%S"))
    # Use the online backup API: the DB has WAL sidecars, so a plain file copy
    # can miss committed pages still sitting in the -wal.
    with sqlite3.connect(backup) as bcon:
        con.backup(bcon)
    shutil.copystat(DB, backup)
    print("\n  backup -> %s" % backup)

    moved = 0
    with con:
        for t, old, new, _ in plan:
            cur = con.execute(
                "UPDATE %s SET project = ? WHERE project = ?" % t, (new, old))
            moved += cur.rowcount
    print("  ✓ migrated %d row(s)" % moved)

    left = [(t, p) for t in targets
            for (p,) in con.execute(
                "SELECT DISTINCT project FROM %s" % t).fetchall()
            if p and p.startswith("/")]
    if left:
        print("  ⚠ still absolute (outside $HOME, left alone): %s" % left)
    else:
        print("  ✓ no absolute-path project keys remain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
