#!/usr/bin/env bash
# hook-stats.sh — audit how often the enforcement hooks ACTUALLY fired.
#
# agent-stats.sh measures the *result* of enforcement (structural ratio, skill
# invocations, tokens). This measures the *act*: how many times each gate
# blocked, which skill domain nudged, what the linter caught. Without it,
# tuning a hook is guesswork — the kit's own field lesson is that only
# measurable behavior settles an enforcement argument.
#
# Source: ~/.claude/hook-metrics.jsonl, appended by claude/hooks/hook_metrics.py
# (one line per decision; silent passes are never recorded).
#
# Usage:
#   bash scripts/hook-stats.sh                    # all hooks, all projects
#   bash scripts/hook-stats.sh miivii             # projects matching a substring
#   bash scripts/hook-stats.sh --since 7d         # last 7 days
#   bash scripts/hook-stats.sh miivii --since 24h
set -euo pipefail

METRICS="$HOME/.claude/hook-metrics.jsonl"
FILTER=""
CUTOFF=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      arg="$2"; shift 2
      if [[ "$arg" =~ ^([0-9]+)d$ ]]; then
        CUTOFF=$(($(date +%s) - BASH_REMATCH[1] * 86400))
      elif [[ "$arg" =~ ^([0-9]+)h$ ]]; then
        CUTOFF=$(($(date +%s) - BASH_REMATCH[1] * 3600))
      else
        CUTOFF=$(date -d "$arg" +%s) || { echo "Bad --since value: $arg (use 7d, 24h, or a date)" >&2; exit 1; }
      fi ;;
    *) FILTER="$1"; shift ;;
  esac
done

if [[ ! -f "$METRICS" ]]; then
  echo "No hook metrics yet ($METRICS)."
  echo "The file is created the first time a hook actually blocks or nudges."
  echo "If you expected data, check that hooks are deployed: bash deploy-agents.sh"
  exit 0
fi

# Include the rotated generation so a rotation mid-window doesn't silently
# halve the counts.
python3 - "$METRICS" "$CUTOFF" "$FILTER" <<'PY'
import json
import sys
import os
from collections import Counter, defaultdict

path, cutoff, filt = sys.argv[1], int(sys.argv[2]), sys.argv[3]

records = []
for p in (path + ".1", path):          # oldest first
    try:
        with open(p) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except Exception:
                    continue           # partial line from a crashed write
                if r.get("ts", 0) < cutoff:
                    continue
                # "-tmp" is almost always test_hooks.sh writing to the real
                # metrics file (see mem-lite #415: 68/83 vault-inject records
                # were test runs, not real sessions) rather than real work
                # done from a /tmp cwd. Exclude it by default; an explicit
                # filter for "-tmp" still opts back in for debugging tests.
                if (r.get("project") or "") == "-tmp" and filt != "-tmp":
                    continue
                if filt and filt not in (r.get("project") or ""):
                    continue
                records.append(r)
    except OSError:
        pass

if not records:
    print("No hook decisions recorded for that window/filter.")
    sys.exit(0)

by_hook = Counter(r.get("hook", "?") for r in records)
detail = defaultdict(Counter)
for r in records:
    if r.get("detail"):
        detail[r.get("hook", "?")][r["detail"]] += 1

span_lo = min(r.get("ts", 0) for r in records)
span_hi = max(r.get("ts", 0) for r in records)
days = max((span_hi - span_lo) / 86400.0, 1 / 24.0)

print("━━ hook decisions  (%d total, %s → %s)" % (
    len(records),
    __import__("datetime").date.fromtimestamp(span_lo),
    __import__("datetime").date.fromtimestamp(span_hi)))
print()
print("  %-26s%8s%10s" % ("hook", "fired", "per day"))
for hook, n in by_hook.most_common():
    print("  %-26s%8d%10.1f" % (hook, n, n / days))

# Detail breakdown: which skill domain, which linter, which guard pattern.
for hook in by_hook:
    if not detail[hook]:
        continue
    print()
    print("  %s — breakdown:" % hook)
    for d, n in detail[hook].most_common(10):
        print("      %-34s%6d" % (d[:34], n))

# Same hooks run under Claude Code and Qwen Code. Which host they fired on is
# the question "is the qwen side actually enforced, or only configured?" —
# unanswerable from a merged total. Records written before the agent field
# existed are all Claude's.
print()
print("━━ by agent")
by_agent = Counter(r.get("agent", "claude") for r in records)
agent_hook = defaultdict(Counter)
for r in records:
    agent_hook[r.get("agent", "claude")][r.get("hook", "?")] += 1
for agent, n in by_agent.most_common():
    print("  %-52s%5d" % (agent, n))
    for hook, hn in agent_hook[agent].most_common():
        print("      %-44s%5d" % (hook, hn))

print()
print("━━ by project")
by_proj = Counter(r.get("project", "?") for r in records)
proj_hook = defaultdict(Counter)
for r in records:
    proj_hook[r.get("project", "?")][r.get("hook", "?")] += 1
for proj, n in by_proj.most_common(15):
    print("  %-52s%5d" % (proj[:50], n))
    for hook, hn in proj_hook[proj].most_common():
        print("      %-44s%5d" % (hook, hn))

# The crg-gate block count is the tuning signal for BUDGET: a gate that never
# blocks is not enforcing, one that blocks constantly is mis-sized.
crg = by_hook.get("crg-gate", 0)
if crg:
    print()
    print("  note: crg-gate blocked %d time(s) — each block is one forced graph"
          " consult. Compare against the structural ratio in agent-stats.sh;"
          " if the ratio is still low, BUDGET in crg-gate.py is too high."
          % crg)
PY
