#!/usr/bin/env bash
# qwen-stats.sh — audit ACTUAL tool usage from Qwen Code session transcripts.
#
# Companion to agent-stats.sh (Claude side). Parses ~/.qwen/projects/*/chats/
# JSONL sessions: functionCall parts for tool distribution (incl. mem-lite /
# code-review-graph MCP usage), ui_telemetry api_response events for token
# counts, and chat_compression events for context-limit pressure.
#
# Usage:
#   bash scripts/qwen-stats.sh                        # all projects, all time
#   bash scripts/qwen-stats.sh myproj                 # projects matching a substring
#   bash scripts/qwen-stats.sh myproj --since 7d      # only sessions active in the last 7 days
#   bash scripts/qwen-stats.sh --since 2026-07-03     # or since a date
set -euo pipefail

PROJECTS_DIR="$HOME/.qwen/projects"
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

python3 - "$PROJECTS_DIR" "$FILTER" "$CUTOFF" <<'PYEOF'
import glob, json, os, sys
from collections import Counter

projects_dir, flt, cutoff = sys.argv[1], sys.argv[2], int(sys.argv[3])

MANUAL = {"read_file", "list_directory", "glob", "grep_search", "read_many_files"}
EDITS = {"edit", "write_file", "replace"}

found = False
for proj in sorted(glob.glob(projects_dir + "/*/")):
    name = os.path.basename(proj.rstrip("/"))
    if flt and flt not in name:
        continue
    files = [f for f in glob.glob(proj + "chats/*.jsonl")
             if not cutoff or os.path.getmtime(f) >= cutoff]
    if not files:
        continue

    tools = Counter()
    prompts = api_n = api_err = 0
    ctx = cached = out = 0
    compressions = 0
    for path in files:
        with open(path, errors="replace") as fp:
            for line in fp:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                t = e.get("type")
                if t == "assistant":
                    for p in (e.get("message") or {}).get("parts") or []:
                        if isinstance(p, dict) and "functionCall" in p:
                            tools[p["functionCall"].get("name", "?")] += 1
                elif t == "user":
                    prompts += 1
                elif t == "system":
                    sub = e.get("subtype")
                    if sub == "chat_compression":
                        compressions += 1
                    elif sub == "ui_telemetry":
                        u = (e.get("systemPayload") or {}).get("uiEvent") or {}
                        ev = u.get("event.name", "")
                        if ev.endswith("api_response"):
                            api_n += 1
                            ctx += u.get("input_token_count", 0) or 0
                            cached += u.get("cached_content_token_count", 0) or 0
                            out += u.get("output_token_count", 0) or 0
                        elif ev.endswith("api_error"):
                            api_err += 1

    if not (tools or prompts or api_n):
        continue
    found = True

    manual = sum(n for t, n in tools.items() if t in MANUAL)
    shell = tools.get("run_shell_command", 0)
    edits = sum(n for t, n in tools.items() if t in EDITS)
    graph = sum(n for t, n in tools.items() if t.startswith("mcp__code-review-graph__"))
    lsp = sum(n for t, n in tools.items() if t.startswith("mcp__lsp__"))
    mem = sum(n for t, n in tools.items() if t.startswith("mcp__mem-lite__") or t.startswith("mem_"))
    other_mcp = sum(n for t, n in tools.items()
                    if t.startswith("mcp__") and not t.startswith(
                        ("mcp__code-review-graph__", "mcp__lsp__", "mcp__mem-lite__")))
    agents = tools.get("agent", 0) + tools.get("task", 0)

    print(f"━━ {name}")
    print(f"  {'sessions':<28} {len(files):6d}")
    print(f"  {'user prompts':<28} {prompts:6d}")
    print(f"  {'manual reads (file/grep)':<28} {manual:6d}")
    print(f"  {'shell commands':<28} {shell:6d}")
    print(f"  {'edits (edit/write)':<28} {edits:6d}")
    print(f"  {'code-review-graph calls':<28} {graph:6d}")
    print(f"  {'LSP calls':<28} {lsp:6d}")
    print(f"  {'mem-lite calls':<28} {mem:6d}")
    print(f"  {'other MCP calls':<28} {other_mcp:6d}")
    print(f"  {'subagent dispatches':<28} {agents:6d}")
    if manual + graph + lsp:
        pct = 100 * (graph + lsp) // (manual + graph + lsp)
        print(f"  {'structural ratio':<28} {pct:5d}%  (graph+lsp vs manual reads)")
    if api_n:
        print(f"  {'API calls / errors':<28} {api_n:6d} / {api_err}")
        pct_cached = 100 * cached // ctx if ctx else 0
        print(f"  {'context tokens':<28} {ctx // 1000:6d}k  (avg {ctx // api_n // 1000}k/call, {pct_cached}% cached)")
        print(f"  {'output tokens':<28} {out // 1000:6d}k")
    print(f"  {'compressions (ctx pressure)':<28} {compressions:6d}")
    print()

if not found:
    where = projects_dir + (f" matching '{flt}'" if flt else "")
    print(f"No qwen sessions found under {where}")
PYEOF
