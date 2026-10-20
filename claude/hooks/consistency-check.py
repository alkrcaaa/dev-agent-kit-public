#!/usr/bin/env python3
"""
consistency-check (SessionStart, and a manual entry point).

This kit already had six things that watch it -- agent-stats, qwen-stats,
hook-stats, doctor, healthcheck, mcp_probe -- and a mem_save still went
missing without any of them noticing. They all count what happened; none of
them asserts what should be true. A save made through the CLI instead of the
MCP tool fired no hook, so the counter that would have caught it simply never
incremented, and the layer looked healthy at 39 mirrors that day.

So this is not a seventh counter. Each check states an invariant and reports
only when it is broken. Healthy runs print nothing under --oneline (what the
SessionStart hook uses), which is the whole reason it can afford to run every
session: a layer with no consumer is ambient cost, and the only consumer that
is guaranteed to be read is the one that stays silent until it matters.

    consistency-check.py             full report, every invariant, ok or not
    consistency-check.py --oneline   silent when healthy; one line when not

Exit code is 1 on any violation so it can gate CI, but the hook wrapper
discards it: a broken invariant is news, never a blocked session.

Invariants that depend on the vault bridge are skipped when it is not
installed -- they are meaningless without it, and this kit runs without it.
"""
import json
import os
import re
import sqlite3
import sys
import time

HOME = os.path.expanduser("~")
MEM_DB = os.path.join(HOME, ".claude-mem-lite", "claude-mem-lite.db")
METRICS = os.path.join(HOME, ".claude", "hook-metrics.jsonl")
SETTINGS = [os.path.join(HOME, ".claude", "settings.json"),
            os.path.join(HOME, ".qwen", "settings.json")]

# I1's window matches the mirror's own reconcile window. Beyond it a row is
# deliberately not mirrored (see the bridge's D12), so reporting it would be
# reporting a decision as a fault.
MIRROR_DAYS = 7

# How far a compiled note may lag the newest raw record it is compiled from.
# Long enough that a repo worked on daily is not permanently "stale", short
# enough that a note nobody recompiled for a month is called out.
STALE_DAYS = 21

# Hooks the kit does not own. mem-lite ships its own launcher and scripts;
# they do not use this kit's metrics module, so "never recorded a metric" says
# nothing about them.
FOREIGN_HOOK_MARKERS = ("claude-mem-lite",)

# A path, not a bare word: mem-lite's launcher is invoked as
# `node .../hook-launcher.mjs hook.mjs session-start`, where `hook.mjs` is an
# argument naming a module the launcher resolves itself. Matching bare
# filenames reported five "missing" hooks that were never files.
SCRIPT_RE = re.compile(r"[^\s\"';|&]*/[^\s\"';|&]+\.(?:py|sh|mjs)")


def _bridge_hooks_dir():
    """The vault bridge's hooks dir next to this script, if it is installed."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(os.path.dirname(here), "extern", "obsidian-vault-bridge",
                        "hooks")
    return path if os.path.isdir(path) else None


def _vault_common():
    """The bridge's shared lookups, or None when the bridge is not installed.

    Imported rather than reimplemented: the project-key rules and the config
    file's location are the bridge's to define, and a second copy of them here
    would drift the moment either side changed -- which is exactly how a key
    resolved two ways makes a lookup fail in silence.
    """
    path = _bridge_hooks_dir()
    if not path:
        return None
    if path not in sys.path:
        sys.path.insert(0, path)
    try:
        import vault_common  # type: ignore[import-not-found]
        return vault_common
    except Exception:
        return None


def _wired_scripts():
    """(settings file, event, absolute script path) for every wired hook."""
    out = []
    for settings in SETTINGS:
        try:
            with open(settings, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        for event, groups in (data.get("hooks") or {}).items():
            for group in groups if isinstance(groups, list) else []:
                for hook in group.get("hooks") or []:
                    command = hook.get("command") or ""
                    for token in SCRIPT_RE.findall(command):
                        path = os.path.expandvars(os.path.expanduser(token))
                        out.append((settings, event, path))
    return out


def _recorded_hooks():
    """Every hook name that has ever written a metric."""
    names = set()
    for path in (METRICS, METRICS + ".1"):
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    try:
                        names.add(json.loads(line).get("hook"))
                    except ValueError:
                        continue
        except OSError:
            continue
    return names


def check_hook_files_exist():
    """I2: every hook wired in settings.json is on disk.

    A hook whose script is missing is not an error anyone sees: the wrappers
    are all `[ -f "$H" ] && ... || true`, so it degrades to nothing at all.
    That is not hypothetical here -- compile-nudge was wired and dead from the
    day it shipped, and the only reason anybody found out was going to look.
    """
    missing = []
    for settings, event, path in _wired_scripts():
        if not os.path.isfile(path):
            missing.append(f"{os.path.basename(settings)} [{event}] -> {path}")
    return sorted(set(missing))


def check_hooks_are_instrumented():
    """I3: every hook this kit owns reports what it decided.

    An uninstrumented hook cannot be told apart from a dead one -- hook-stats
    shows nothing for both. This is the check that makes the other counters
    trustworthy rather than a seventh counter beside them.
    """
    recorded = _recorded_hooks()
    silent = []
    for _, _, path in _wired_scripts():
        if any(marker in path for marker in FOREIGN_HOOK_MARKERS):
            continue
        if not os.path.isfile(path):
            continue  # I2 already owns this one
        name = os.path.splitext(os.path.basename(path))[0]
        if name not in recorded:
            silent.append(f"{name} ({path})")
    return sorted(set(silent))


def check_mem_namespaces():
    """I4: no project is keyed by an absolute path.

    mem_save with an explicit `project=/abs/path` opens a second namespace
    beside the canonical `workspace--<repo>`. Search still finds both, so
    nothing looks broken, while mem_recent and the session-start injection are
    namespace-scoped and quietly load half the project's memory. 51 of 282
    observations were stranded this way before anyone measured it.
    """
    try:
        con = sqlite3.connect(f"file:{MEM_DB}?mode=ro", uri=True, timeout=5)
        rows = con.execute(
            "SELECT project, COUNT(*) FROM observations WHERE project LIKE '/%' "
            "GROUP BY project ORDER BY 2 DESC"
        ).fetchall()
        con.close()
    except Exception:
        return []
    return [f"{project} ({count} records)" for project, count in rows]


def check_mirror_gap(vc):
    """I1: every recent mem-lite row has a copy in the vault.

    The failure this whole script exists because of. Checked against both the
    project's own folder and the catch-all, because a repo-less session is
    filed under the catch-all at capture time and its mem-lite key never
    learns that -- looking only at the key's own folder would report every
    correctly-folded row as missing.
    """
    mirror = vc.env_or_conf("MEM_OBSIDIAN_VAULT")
    if not mirror or not os.path.isdir(mirror):
        return []

    id_re = re.compile(r"\(#(\d+)\)")

    def ids_in(project):
        found = set()
        day_dir = os.path.join(mirror, project)
        try:
            names = os.listdir(day_dir)
        except OSError:
            return found
        for name in names:
            if not name.endswith(".md"):
                continue
            try:
                with open(os.path.join(day_dir, name), "r", encoding="utf-8",
                          errors="ignore") as f:
                    found.update(id_re.findall(f.read()))
            except OSError:
                continue
        return found

    since = time.strftime("%Y-%m-%dT%H:%M:%S",
                          time.gmtime(time.time() - MIRROR_DAYS * 86400))
    try:
        con = sqlite3.connect(f"file:{MEM_DB}?mode=ro", uri=True, timeout=5)
        rows = con.execute(
            "SELECT project, id FROM observations WHERE created_at > ? "
            "AND superseded_at IS NULL AND compressed_into IS NULL", (since,)
        ).fetchall()
        con.close()
    except Exception:
        return []

    catchall = ids_in(vc.CATCHALL_PROJECT)
    seen, gaps = {}, {}
    for project, obs_id in rows:
        if project not in seen:
            seen[project] = ids_in(project) | catchall
        if str(obs_id) not in seen[project]:
            gaps.setdefault(project, []).append(obs_id)
    return [f"{project}: {len(ids)} records missing from vault "
            f"(#{', #'.join(str(i) for i in sorted(ids)[:5])})"
            for project, ids in sorted(gaps.items())]


def check_stale_notes(vc):
    """I5: a compiled note is not far behind the records it compiles from.

    A note that stopped being recompiled keeps being injected every session,
    so it does not go quiet -- it goes wrong, and confidently. That is worse
    than a missing note, which at least announces itself.
    """
    vault = vc.vault_dir()
    mirror = vc.env_or_conf("MEM_OBSIDIAN_VAULT")
    if not vault or not mirror or not os.path.isdir(mirror):
        return []

    stale = []
    for project in sorted(os.listdir(mirror)):
        day_dir = os.path.join(mirror, project)
        if not os.path.isdir(day_dir):
            continue
        days = sorted(n[:-3] for n in os.listdir(day_dir) if n.endswith(".md"))
        if not days:
            continue
        newest = days[-1]
        _, head = vc.find_note(vault, f"mem_lite_project: {project}")
        if not head:
            continue  # a project with no note at all is vault-compile's report
        compiled = vc.frontmatter_field(head, "last_compiled")
        if not compiled:
            stale.append(f"{project}: note never compiled (raw record {newest})")
            continue
        try:
            lag = (time.mktime(time.strptime(newest, "%Y-%m-%d"))
                   - time.mktime(time.strptime(compiled, "%Y-%m-%d"))) / 86400
        except ValueError:
            continue
        if lag > STALE_DAYS:
            stale.append(f"{project}: note {compiled}, raw record {newest} "
                         f"({int(lag)} days behind)")
    return stale


def main():
    oneline = "--oneline" in sys.argv[1:]

    checks = [
        ("I2 wired hook script exists on disk", check_hook_files_exist, None),
        ("I3 wired hook produces metrics", check_hooks_are_instrumented, None),
        ("I4 no absolute-path namespace in mem-lite", check_mem_namespaces, None),
    ]
    vc = _vault_common()
    if vc:
        checks.insert(0, ("I1 last 7 days of records in vault", check_mirror_gap, vc))
        checks.append(("I5 compiled note is up to date", check_stale_notes, vc))

    results = []
    for label, fn, arg in checks:
        try:
            results.append((label, fn(arg) if arg else fn()))
        except Exception as exc:
            results.append((label, [f"kontrol edilemedi: {exc}"]))

    broken = [(label, items) for label, items in results if items]

    # I3 flagged this script on its first run, and it was right to: a checker
    # nobody can see is the same blind spot it exists to close.
    try:
        import hook_metrics
        hook_metrics.record("consistency-check",
                            "violation" if broken else "clean", None,
                            str(sum(len(items) for _, items in broken)))
    except Exception:
        pass

    if oneline:
        if broken:
            total = sum(len(items) for _, items in broken)
            names = ", ".join(label.split()[0] for label, _ in broken)
            print(f"[consistency] {total} violations ({names}) — "
                  f"details: python3 {os.path.abspath(sys.argv[0])}")
        sys.exit(0)

    for label, items in results:
        if not items:
            print(f"  OK    {label}")
            continue
        print(f"  VIOLATION {label}")
        for item in items:
            print(f"          - {item}")
    if not vc:
        print("  (vault bridge not installed — I1 and I5 skipped)")
    sys.exit(1 if broken else 0)


if __name__ == "__main__":
    main()
