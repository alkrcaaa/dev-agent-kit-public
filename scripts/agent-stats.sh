#!/usr/bin/env bash
# agent-stats.sh — audit ACTUAL tool usage from Claude Code transcripts.
#
# Counts real tool_use invocations (not tool-list definitions, which appear
# once per API request in the transcript) per project, so you can verify the
# graph/skills/LSP mechanisms are actually being used over manual Read/Bash.
#
# Usage:
#   bash scripts/agent-stats.sh                        # all projects, all time
#   bash scripts/agent-stats.sh miivii                 # projects matching a substring
#   bash scripts/agent-stats.sh miivii --since 7d      # only sessions active in the last 7 days
#   bash scripts/agent-stats.sh --since 2026-07-03     # or since a date
#
# --since filters by transcript mtime. Without it, years of history dominate
# the averages and bury any recent behavior change you are trying to measure.
#
# Antigravity coverage is approximate, unlike the Claude section above: its
# conversations live in ~/.gemini/antigravity-ide/conversations/*.db (IDE) and
# ~/.gemini/antigravity-cli/conversations/*.db (agy CLI) as undocumented
# protobuf blobs (no .proto schema shipped), not plain JSONL, and aren't
# partitioned by project directory the way Claude's/Qwen's are. Both dirs
# share the same steps.step_payload schema. Tool calls are recovered by
# scanning the blob for known tool-name substrings (view_file, run_command,
# ...) rather than parsing a message structure -- good enough to see relative
# usage, not an exact count. Token/context usage isn't exposed in cleartext
# anywhere in the format, so it's reported as N/A.
set -euo pipefail

PROJECTS_DIR="$HOME/.claude/projects"
QWEN_PROJECTS_DIR="$HOME/.qwen/projects"
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

count() { # count <file> <tool-name-regex>
  grep -oc "\"type\":\"tool_use\",\"id\":\"[^\"]*\",\"name\":\"$2\"" "$1" 2>/dev/null || true
}

sum() { # sum newline-separated numbers (grep -c prints one per file)
  awk '{s+=$1} END {print s+0}'
}

tokens() { # tokens <dir> <cutoff-epoch> -> "api_calls context_total cache_read output"
  python3 - "$@" <<'PYEOF'
import json, sys, glob, os

cutoff = int(sys.argv[2])
n = ctx = cr = out = 0
for path in glob.glob(sys.argv[1] + "/*.jsonl"):
    if cutoff and os.path.getmtime(path) < cutoff:
        continue
    with open(path, errors="replace") as fp:
        for line in fp:
            if '"usage"' not in line:
                continue
            try:
                u = (json.loads(line).get("message") or {}).get("usage")
            except Exception:
                continue
            if not u:
                continue
            n += 1
            ctx += (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                    + u.get("cache_creation_input_tokens", 0))
            cr += u.get("cache_read_input_tokens", 0)
            out += u.get("output_tokens", 0)
print(n, ctx, cr, out)
PYEOF
}

qwen_count() { # qwen_count <file> <tool-name-regex>
  grep -oc "\"functionCall\":{\"id\":\"[^\"]*\",\"name\":\"$2\"" "$1" 2>/dev/null || true
}

qwen_tokens() { # qwen_tokens <project-dir> <cutoff-epoch> -> "api_calls context_total cache_read output"
  python3 - "$@" <<'PYEOF'
import json, sys, glob, os

cutoff = int(sys.argv[2])
n = ctx = cr = out = 0
for path in glob.glob(sys.argv[1] + "/chats/*.jsonl"):
    if cutoff and os.path.getmtime(path) < cutoff:
        continue
    with open(path, errors="replace") as fp:
        for line in fp:
            if '"usageMetadata"' not in line:
                continue
            try:
                u = json.loads(line).get("usageMetadata")
            except Exception:
                continue
            if not u:
                continue
            n += 1
            ctx += u.get("promptTokenCount", 0)
            cr += u.get("cachedContentTokenCount", 0)
            out += u.get("candidatesTokenCount", 0) + u.get("thoughtsTokenCount", 0)
print(n, ctx, cr, out)
PYEOF
}

antigravity_stats() { # antigravity_stats <cutoff-epoch>
  python3 - "$@" <<'PYEOF'
import collections
import glob
import os
import re
import sqlite3
import sys

cutoff = int(sys.argv[1])
conv_dirs = [os.path.expanduser("~/.gemini/antigravity-ide/conversations"),
             os.path.expanduser("~/.gemini/antigravity-cli/conversations")]
TOOLS = ["view_file", "list_dir", "grep_search", "read_url", "execute_url",
         "write_to_file", "replace_file_content", "multi_replace_file_content",
         "run_command"]

counts = collections.Counter()
mcp = collections.Counter()
sessions = 0
for conv_dir in conv_dirs:
    for db in glob.glob(os.path.join(conv_dir, "*.db")):
        if cutoff and os.path.getmtime(db) < cutoff:
            continue
        try:
            conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=1)
            blob = b"".join(r[0] for r in conn.execute("select step_payload from steps") if r[0])
            conn.close()
        except Exception:
            continue
        sessions += 1
        for name in TOOLS:
            counts[name] += blob.count(name.encode())
        for m in re.findall(rb"mcp\(([A-Za-z0-9_/-]+)\)", blob):
            mcp[m.decode()] += 1

if sessions == 0:
    print("NONE")
    sys.exit(0)

graph_n = sum(n for k, n in mcp.items() if k.startswith("code-review-graph/"))
other_mcp_n = sum(mcp.values()) - graph_n
manual = counts["view_file"] + counts["list_dir"] + counts["grep_search"] + counts["read_url"] + counts["execute_url"]
edit = counts["write_to_file"] + counts["replace_file_content"] + counts["multi_replace_file_content"]
print("SESSIONS %d" % sessions)
print("MANUAL %d" % manual)
print("BASH %d" % counts["run_command"])
print("EDIT %d" % edit)
print("GRAPH %d" % graph_n)
print("OTHER_MCP %d" % other_mcp_n)
PYEOF
}

found=0
for dir in "$PROJECTS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  name=$(basename "$dir")
  [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || continue

  jsonls=()
  for f in "$dir"*.jsonl; do
    [[ -f "$f" ]] || continue
    [[ $CUTOFF -eq 0 || $(stat -c %Y "$f") -ge $CUTOFF ]] || continue
    jsonls+=("$f")
  done
  [[ ${#jsonls[@]} -gt 0 ]] || continue
  found=1

  read_n=0 bash_n=0 grep_n=0 glob_n=0 edit_n=0 skill_n=0 graph_n=0 lsp_n=0 extern_n=0 mcp_all_n=0
  vault_search_n=0 vault_read_n=0 vault_list_n=0
  for f in "${jsonls[@]}"; do
    read_n=$((read_n + $(count "$f" "Read")))
    bash_n=$((bash_n + $(count "$f" "Bash")))
    grep_n=$((grep_n + $(count "$f" "Grep")))
    glob_n=$((glob_n + $(count "$f" "Glob")))
    edit_n=$((edit_n + $(count "$f" "Edit") + $(count "$f" "Write")))
    skill_n=$((skill_n + $(count "$f" "Skill")))
    graph_n=$((graph_n + $(count "$f" "mcp__code-review-graph__[a-z_]*")))
    lsp_n=$((lsp_n + $(count "$f" "mcp__lsp__[a-z_]*")))
    mcp_all_n=$((mcp_all_n + $(count "$f" "mcp__[A-Za-z0-9-]*__[A-Za-z0-9_]*")))
    vault_search_n=$((vault_search_n + $(count "$f" "mcp__vault-search__vault_search")))
    vault_read_n=$((vault_read_n + $(count "$f" "mcp__vault-search__vault_read")))
    vault_list_n=$((vault_list_n + $(count "$f" "mcp__vault-search__vault_list")))
    extern_n=$((extern_n + $(grep -oc '"file_path":"[^"]*extern/[^"]*"' "$f" 2>/dev/null || true)))
  done
  mcp_other_n=$((mcp_all_n - graph_n - lsp_n))

  manual=$((read_n + grep_n + glob_n))
  structural=$((graph_n + lsp_n))

  echo "━━ $name"
  printf "  %-28s %6d\n" "Read/Grep/Glob (manual)" "$manual"
  printf "  %-28s %6d\n" "Bash" "$bash_n"
  printf "  %-28s %6d\n" "Edit/Write" "$edit_n"
  printf "  %-28s %6d\n" "code-review-graph calls" "$graph_n"
  printf "  %-28s %6d\n" "LSP calls" "$lsp_n"
  printf "  %-28s %6d\n" "other MCP calls" "$mcp_other_n"
  printf "  %-28s %6d\n" "Skill invocations" "$skill_n"
  # vault-search broken out of "other MCP": the point of the vault is to answer
  # from a compiled note instead of re-reading a repo, and that only shows up
  # as a saving if search/read are what get called. A vault_list-heavy split
  # means listings, not answers -- it returns paths, never content.
  vault_n=$((vault_search_n + vault_read_n + vault_list_n))
  if [[ $vault_n -gt 0 ]]; then
    printf "  %-28s %6d  (search %d / read %d / list %d)\n" \
      "vault-search calls" "$vault_n" "$vault_search_n" "$vault_read_n" "$vault_list_n"
  fi
  printf "  %-28s %6d\n" "extern skill file reads" "$extern_n"
  if [[ $((manual + structural)) -gt 0 ]]; then
    pct=$((100 * structural / (manual + structural)))
    printf "  %-28s %5d%%  (graph+lsp vs manual reads)\n" "structural ratio" "$pct"
  fi

  read -r api_n ctx_total cache_read out_total <<<"$(tokens "$dir" "$CUTOFF")"
  if [[ $api_n -gt 0 ]]; then
    printf "  %-28s %6d\n" "API calls" "$api_n"
    printf "  %-28s %6dk  (avg %dk/call, %d%% cached)\n" "context tokens" \
      $((ctx_total / 1000)) $((ctx_total / api_n / 1000)) $((100 * cache_read / ctx_total))
    printf "  %-28s %6dk\n" "output tokens" $((out_total / 1000))
  fi
  echo ""

  # Qwen uses the same sanitized-cwd directory naming as Claude, so join on
  # basename to report the same project's Qwen usage right after Claude's.
  qwen_dir="$QWEN_PROJECTS_DIR/$name/chats"
  if [[ -d "$qwen_dir" ]]; then
    qjsonls=()
    for f in "$qwen_dir"/*.jsonl; do
      [[ -f "$f" ]] || continue
      [[ $CUTOFF -eq 0 || $(stat -c %Y "$f") -ge $CUTOFF ]] || continue
      qjsonls+=("$f")
    done
    if [[ ${#qjsonls[@]} -gt 0 ]]; then
      qread_n=0 qbash_n=0 qgrep_n=0 qglob_n=0 qedit_n=0 qskill_n=0 qgraph_n=0 qmcp_all_n=0
      for f in "${qjsonls[@]}"; do
        qread_n=$((qread_n + $(qwen_count "$f" "read_file")))
        qbash_n=$((qbash_n + $(qwen_count "$f" "run_shell_command")))
        qgrep_n=$((qgrep_n + $(qwen_count "$f" "grep_search") + $(qwen_count "$f" "search_file_content")))
        qglob_n=$((qglob_n + $(qwen_count "$f" "glob")))
        qedit_n=$((qedit_n + $(qwen_count "$f" "edit") + $(qwen_count "$f" "replace") + $(qwen_count "$f" "write_file")))
        qskill_n=$((qskill_n + $(qwen_count "$f" "skill")))
        qgraph_n=$((qgraph_n + $(qwen_count "$f" "mcp__code-review-graph__[a-z_]*")))
        qmcp_all_n=$((qmcp_all_n + $(qwen_count "$f" "mcp__[A-Za-z0-9-]*__[A-Za-z0-9_]*")))
      done
      qmcp_other_n=$((qmcp_all_n - qgraph_n))
      qmanual=$((qread_n + qgrep_n + qglob_n))

      echo "━━ $name (qwen)"
      printf "  %-28s %6d\n" "Read/Grep/Glob (manual)" "$qmanual"
      printf "  %-28s %6d\n" "Bash" "$qbash_n"
      printf "  %-28s %6d\n" "Edit/Write" "$qedit_n"
      printf "  %-28s %6d\n" "code-review-graph calls" "$qgraph_n"
      printf "  %-28s %6d\n" "other MCP calls" "$qmcp_other_n"
      printf "  %-28s %6d\n" "Skill invocations" "$qskill_n"
      if [[ $((qmanual + qgraph_n)) -gt 0 ]]; then
        pct=$((100 * qgraph_n / (qmanual + qgraph_n)))
        printf "  %-28s %5d%%  (graph vs manual reads)\n" "structural ratio" "$pct"
      fi

      read -r qapi_n qctx_total qcache_read qout_total <<<"$(qwen_tokens "$QWEN_PROJECTS_DIR/$name" "$CUTOFF")"
      if [[ $qapi_n -gt 0 ]]; then
        printf "  %-28s %6d\n" "API calls" "$qapi_n"
        printf "  %-28s %6dk  (avg %dk/call, %d%% cached)\n" "context tokens" \
          $((qctx_total / 1000)) $((qctx_total / qapi_n / 1000)) \
          $((qctx_total > 0 ? 100 * qcache_read / qctx_total : 0))
        printf "  %-28s %6dk\n" "output tokens" $((qout_total / 1000))
      fi
      echo ""
    fi
  fi
done

if [[ $found -eq 0 ]]; then
  echo "No transcripts found under $PROJECTS_DIR${FILTER:+ matching '$FILTER'}"
fi

if [[ -z "$FILTER" || "$FILTER" == *antigravity* ]]; then
  ag_out="$(antigravity_stats "$CUTOFF")"
  if [[ "$ag_out" != "NONE" ]]; then
    declare -A ag
    while read -r key val; do ag["$key"]="$val"; done <<<"$ag_out"
    echo "━━ antigravity (all projects — not partitioned by cwd; approximate, see header)"
    printf "  %-28s %6d\n" "sessions scanned" "${ag[SESSIONS]}"
    printf "  %-28s %6d\n" "Read/list/grep (manual)" "${ag[MANUAL]}"
    printf "  %-28s %6d\n" "run_command" "${ag[BASH]}"
    printf "  %-28s %6d\n" "Edit/Write" "${ag[EDIT]}"
    printf "  %-28s %6d\n" "code-review-graph calls" "${ag[GRAPH]}"
    printf "  %-28s %6d\n" "other MCP calls" "${ag[OTHER_MCP]}"
    manual_ag=${ag[MANUAL]}; graph_ag=${ag[GRAPH]}
    if [[ $((manual_ag + graph_ag)) -gt 0 ]]; then
      pct=$((100 * graph_ag / (manual_ag + graph_ag)))
      printf "  %-28s %5d%%  (graph vs manual reads)\n" "structural ratio" "$pct"
    fi
    printf "  %-28s %6s\n" "context tokens" "N/A (format doesn't expose usage)"
  fi
fi
