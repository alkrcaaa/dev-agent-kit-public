#!/usr/bin/env python3
"""stats-page — one static monitoring page for the kit: where tokens go, what the agents do, what the hooks did.

Collects from what is already on disk (nothing new is recorded):
  ~/.claude/projects/*/*.jsonl   per-call usage + tool_use  -> tokens, tools, sessions (Claude)
  ~/.qwen/projects/*/chats/*.jsonl  usageMetadata           -> tokens (Qwen)
  ~/.claude/hook-metrics.jsonl   hook decisions             -> gates, nudges
and embeds it as JSON in one HTML file. Filtering (day range, agent, project) and
the "what am I doing wrong" rules run in the browser, so no server and no rebuild
to slice the data. The vault dashboard (vault-stats.py) is appended below.

    python3 scripts/stats-page.py                 # -> ~/.local/share/dev-agent-kit/stats.html
    python3 scripts/stats-page.py --days 90 --open

Read-only. The page lives outside the repo and the vault on purpose.
"""
import argparse
import glob
import html
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "dev-agent-kit")
DEFAULT_OUT = os.path.join(DATA, "stats.html")
METRICS = os.path.join(HOME, ".claude", "hook-metrics.jsonl")
VAULT_STATS = os.path.join(ROOT, "extern", "obsidian-vault-bridge", "tools", "vault-stats.py")

CATS = (("manual", ("Read", "Grep", "Glob")), ("edit", ("Edit", "Write", "NotebookEdit")),
        ("bash", ("Bash",)), ("skill", ("Skill",)), ("agent", ("Agent", "Task")))


def project_name(dirname):
    n = dirname.strip("-")
    home = os.path.expanduser("~").strip("/").replace("/", "-")
    for pre in (f"{home}-workspace-", f"{home}-"):
        if n.startswith(pre):
            return n[len(pre):] or "~"
    return "~" if n == home else n


def local_day(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")
    except (ValueError, AttributeError):
        return None


def tool_cat(name):
    if name.startswith("mcp__code-review-graph__") or name == "LSP":
        return "graph"
    if name == "mcp__local-model__ask_worker":
        return "worker"
    if name.startswith("mcp__"):
        return "mcp"
    for cat, names in CATS:
        if name in names:
            return cat
    return "other"


def collect_claude(cutoff_ts, cutoff_day):
    """One row per (session, day): usage is taken once per message id, tools unioned across its content blocks."""
    rows = []
    for path in glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl")):
        if os.path.getmtime(path) < cutoff_ts:
            continue
        proj = project_name(os.path.basename(os.path.dirname(path)))
        sid = os.path.basename(path)[:-6][:8]
        msgs, seen_tools = {}, set()
        try:
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if '"usage"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    m = d.get("message") or {}
                    u = m.get("usage")
                    if not u or d.get("type") != "assistant":
                        continue
                    mid = m.get("id") or d.get("uuid")
                    e = msgs.setdefault(mid, {"tools": Counter()})
                    e["u"], e["day"], e["model"] = u, local_day(d.get("timestamp")), m.get("model", "")
                    for c in m.get("content") or []:
                        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("id") not in seen_tools:
                            seen_tools.add(c.get("id"))
                            e["tools"][tool_cat(c.get("name", ""))] += 1
        except OSError:
            continue
        per_day = {}
        for e in msgs.values():
            if not e["day"] or e["day"] < cutoff_day or e["model"] == "<synthetic>":
                continue
            r = per_day.setdefault(e["day"], {"d": e["day"], "s": sid, "p": proj, "a": "claude", "calls": 0,
                                              "in": 0, "cc": 0, "cr": 0, "out": 0, "t": Counter(), "m": e["model"]})
            u = e["u"]
            r["calls"] += 1
            r["in"] += u.get("input_tokens", 0)
            r["cc"] += u.get("cache_creation_input_tokens", 0)
            r["cr"] += u.get("cache_read_input_tokens", 0)
            r["out"] += u.get("output_tokens", 0)
            r["t"].update(e["tools"])
        rows += [{**r, "t": dict(r["t"])} for r in per_day.values()]
    return rows


def collect_qwen(cutoff_ts, cutoff_day):
    rows = []
    for path in glob.glob(os.path.join(HOME, ".qwen", "projects", "*", "chats", "*.jsonl")):
        if os.path.getmtime(path) < cutoff_ts:
            continue
        proj = project_name(path.split(os.sep)[-3])
        sid = os.path.basename(path)[:-6][:8]
        per_day = {}
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                if '"usageMetadata"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                u, day = d.get("usageMetadata"), local_day(d.get("timestamp"))
                if not u or not day or day < cutoff_day:
                    continue
                r = per_day.setdefault(day, {"d": day, "s": sid, "p": proj, "a": "qwen", "calls": 0, "in": 0,
                                             "cc": 0, "cr": 0, "out": 0, "t": {}, "m": "qwen"})
                cached = u.get("cachedContentTokenCount", 0)
                r["calls"] += 1
                r["in"] += max(u.get("promptTokenCount", 0) - cached, 0)
                r["cr"] += cached
                r["out"] += u.get("candidatesTokenCount", 0) + u.get("thoughtsTokenCount", 0)
        rows += list(per_day.values())
    return rows


AG_CATS = {"manual": ("view_file", "list_dir", "grep_search", "read_url", "execute_url"),
           "edit": ("write_to_file", "replace_file_content", "multi_replace_file_content"),
           "bash": ("run_command",)}


def collect_antigravity(cutoff_ts, cutoff_day):
    """Approximate, as in agent-stats.sh: tool names counted in undocumented protobuf blobs, no tokens, no project.
    The day is the db mtime, so a conversation spanning days lands on its last one."""
    rows = []
    for conv_dir in ("antigravity-ide", "antigravity-cli"):
        for db in glob.glob(os.path.join(HOME, ".gemini", conv_dir, "conversations", "*.db")):
            mtime = os.path.getmtime(db)
            day = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
            if mtime < cutoff_ts or day < cutoff_day:
                continue
            try:
                conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=1)
                blob = b"".join(r[0] for r in conn.execute("select step_payload from steps") if r[0])
                conn.close()
            except sqlite3.Error:
                continue
            t = {cat: sum(blob.count(n.encode()) for n in names) for cat, names in AG_CATS.items()}
            mcp = Counter(m.decode() for m in re.findall(rb"mcp\(([A-Za-z0-9_/-]+)\)", blob))
            t["graph"] = sum(n for k, n in mcp.items() if k.startswith("code-review-graph/"))
            t["mcp"] = sum(mcp.values()) - t["graph"]
            rows.append({"d": day, "s": os.path.basename(db)[:8], "p": "(antigravity)", "a": "antigravity",
                         "calls": sum(t.values()), "in": 0, "cc": 0, "cr": 0, "out": 0,
                         "t": {k: v for k, v in t.items() if v}, "m": "antigravity"})
    return rows


def collect_hooks(cutoff_ts):
    agg = Counter()
    for p in (METRICS + ".1", METRICS):
        try:
            with open(p, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    # "-tmp" = test_hooks.sh writing to the real file (same exclusion as hook-stats.sh)
                    if r.get("ts", 0) < cutoff_ts or (r.get("project") or "") == "-tmp":
                        continue
                    day = datetime.fromtimestamp(r["ts"]).strftime("%Y-%m-%d")
                    agg[(day, r.get("hook", "?"), r.get("agent", "claude"), project_name(r.get("project") or "?"))] += 1
        except OSError:
            pass
    return [{"d": d, "h": h, "a": a, "p": p, "n": n} for (d, h, a, p), n in agg.items()]


def vault_fragment():
    with tempfile.NamedTemporaryFile(suffix=".html", delete=False) as t:
        tmp = t.name
    try:
        subprocess.run([sys.executable, VAULT_STATS, "--fragment", "--out", tmp], check=True,
                       capture_output=True, text=True, timeout=120)
        with open(tmp, encoding="utf-8") as f:
            return f.read()
    except (OSError, subprocess.SubprocessError):
        return ""
    finally:
        os.unlink(tmp)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--days", type=int, default=60, help="history window embedded in the page")
    ap.add_argument("--open", action="store_true", help="xdg-open the result")
    a = ap.parse_args()

    now = datetime.now()
    cutoff = now - timedelta(days=a.days)
    cday = cutoff.strftime("%Y-%m-%d")
    data = {"generated": now.strftime("%Y-%m-%d %H:%M"), "days": a.days,
            "sessions": collect_claude(cutoff.timestamp(), cday) + collect_qwen(cutoff.timestamp(), cday)
            + collect_antigravity(cutoff.timestamp(), cday),
            "hooks": collect_hooks(cutoff.timestamp())}
    with open(os.path.join(ROOT, "scripts", "stats-page.html"), encoding="utf-8") as f:
        page = f.read()
    vault = vault_fragment()
    vault_doc = ('<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="dark"></head><body>'
                 + vault + "</body></html>") if vault else ""
    page = page.replace("__DATA__", json.dumps(data).replace("</", "<\\/"))
    page = page.replace("__VAULT__", html.escape(vault_doc, quote=True))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(page)
    print(a.out, "(%d session-days, %d hook rows)" % (len(data["sessions"]), len(data["hooks"])))
    if a.open:
        subprocess.Popen(["xdg-open", a.out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
