#!/usr/bin/env python3
"""checkpoint.py -- measure kit cost and vault read/write balance.

Usage:
    python3 scripts/checkpoint.py            # last 7 days
    python3 scripts/checkpoint.py --days 14

Sections:
  1. Kit share -- API calls spent working ON dev-agent-kit versus all work.
     Healthy means falling: the tool is supposed to converge, not burn at a
     constant rate.
  2. Vault read/write balance -- how often a session actually pulled vault
     knowledge (vault_search / vault_read calls) against how much the capture
     hooks wrote. vault-inject is reported apart: it fires on every session
     start whether or not anything uses it, so it is exposure, not reading.

A write side that dwarfs the read side is the signal to switch a capture hook
off rather than to add another dedup pass to it.

  3. Vault quality -- whether reads returned anything, whether a prompt that
     refers to past work was followed by a read, a per-project funnel
     (narrative writes -> card injections -> reads) to spot writes nothing
     consumes, how far compiled notes lag behind their captures, and what the
     nightly compile costs (its `claude -p` runs land in
     -tmp-vault-compile-* and are kept out of the kit-share denominator).
  4. Session health -- calls per session and context per call, since every
     call re-bills the transcript; plus mem_save and skill use per session,
     and what launches the one-shot background `claude -p` runs.
  5. Skill and MCP use -- calls per skill and per server, and the installed
     ones that were never called (candidates for removal).

Antigravity is counted from its step transcripts (the IDE/CLI .db files are
undocumented protobuf); its calls have no project, so they are reported as a
host total next to Claude's per-project split.
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import statistics
import time
from collections import Counter
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
KIT_MARKERS = ("dev-agent-kit", "obsidian-vault-bridge", "llm-council")
VAULT_TOOLS = ("vault_search", "vault_read", "vault_list")
CAPTURE_HOOKS = ("personal-capture", "concept-capture", "project-narrative", "obsidian-mirror")
COMPILE_MARKER = "-tmp-vault-compile-"
PAST_REF = re.compile(r"hatırlıyor|ne demiştik|ne konuşmuştuk|geçen (sefer|hafta|oturum)|"
                      r"önceki oturum|daha önce (ne|nasıl|karar)|remember when|last time we",
                      re.I)
EMPTY_RESULT = re.compile(r'"results"\s*:\s*\[\s*\]|no (results|matches)|not found', re.I)
LONG_SESSION = 500
ONESHOT_CALLS = 2


def _ts(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0


def _is_kit(project):
    return any(m in project for m in KIT_MARKERS)


def _user_text(msg):
    content = msg.get("content")
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in content or []
                    if isinstance(b, dict) and b.get("type") == "text")


def _result_text(block):
    content = block.get("content")
    return content if isinstance(content, str) else json.dumps(content or "")


def claude(cutoff):
    """One pass over Claude transcripts; a top-level .jsonl is one session."""
    calls, vault_reads = Counter(), Counter()
    read_outcome = Counter()      # hit / empty / error
    past_refs = followed = 0      # past-work prompts, and those followed by a vault read
    compile_calls = compile_ctx = 0
    skills, servers = Counter(), Counter()
    sessions = []                 # (calls, context tokens, mem_saves, skills, first prompt)
    for path in glob.glob(f"{HOME}/.claude/projects/*/*.jsonl"):
        if os.path.getmtime(path) < cutoff:
            continue
        project = os.path.basename(os.path.dirname(path))
        is_compile = project.startswith(COMPILE_MARKER)
        seen, vault_ids = set(), {}
        s_calls = s_ctx = s_saves = s_skills = 0
        s_first = ""
        pending_ref = False
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if _ts(rec.get("timestamp")) < cutoff:
                    continue
                msg = rec.get("message") or {}
                if rec.get("type") == "user":
                    if not s_first:
                        s_first = " ".join(_user_text(msg).split())[:60]
                    if not is_compile and PAST_REF.search(_user_text(msg)):
                        past_refs += 1
                        pending_ref = True
                    for block in msg.get("content") or []:
                        if (isinstance(block, dict) and block.get("type") == "tool_result"
                                and block.get("tool_use_id") in vault_ids):
                            if block.get("is_error"):
                                read_outcome["error"] += 1
                            elif EMPTY_RESULT.search(_result_text(block)[:2000]):
                                read_outcome["empty"] += 1
                            else:
                                read_outcome["hit"] += 1
                    continue
                if rec.get("type") != "assistant":
                    continue
                if msg.get("id") and msg["id"] not in seen:
                    seen.add(msg["id"])
                    usage = msg.get("usage") or {}
                    ctx = sum(usage.get(k, 0) for k in ("input_tokens", "cache_read_input_tokens",
                                                        "cache_creation_input_tokens"))
                    if is_compile:
                        compile_calls += 1
                        compile_ctx += ctx
                        continue
                    calls[project] += 1
                    s_calls += 1
                    s_ctx += ctx
                if is_compile:
                    continue
                for block in msg.get("content") or []:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    name = block.get("name", "")
                    if name.startswith("mcp__"):
                        servers[name.split("__")[1]] += 1
                    if name.endswith(VAULT_TOOLS):
                        vault_reads[project] += 1
                        vault_ids[block.get("id")] = name
                        if pending_ref:
                            followed += 1
                            pending_ref = False
                    elif name.endswith("mem_save") or (
                            name == "Bash" and " save " in str(block.get("input", {}).get("command", ""))
                            and "mem-lite" in str(block.get("input", {}).get("command", ""))):
                        s_saves += 1
                    elif name == "Skill":
                        s_skills += 1
                        skills[str(block.get("input", {}).get("skill"))] += 1
        if s_calls:
            sessions.append((s_calls, s_ctx, s_saves, s_skills, s_first))
    return {
        "calls": calls, "vault_reads": vault_reads, "read_outcome": read_outcome,
        "past_refs": past_refs, "followed": followed, "sessions": sessions,
        "compile_calls": compile_calls, "compile_ctx": compile_ctx,
        "skills": skills, "servers": servers,
    }


def installed():
    """Kit skills (repo source) and globally registered Claude MCP servers."""
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "claude", "skills")
    kit_skills = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
    try:
        with open(f"{HOME}/.claude.json", encoding="utf-8") as f:
            mcp = sorted(json.load(f).get("mcpServers", {}))
    except (OSError, ValueError):
        mcp = []
    return kit_skills, mcp


def antigravity(cutoff):
    calls = reads = 0
    for path in glob.glob(f"{HOME}/.gemini/antigravity-*/brain/*/.system_generated/logs/transcript.jsonl"):
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("type") != "PLANNER_RESPONSE" or _ts(rec.get("created_at")) < cutoff:
                    continue
                calls += 1
                for tc in rec.get("tool_calls") or []:
                    args = json.dumps(tc.get("args", {}))
                    if tc.get("name") == "call_mcp_tool" and any(t in args for t in VAULT_TOOLS):
                        reads += 1
    return calls, reads


def hook_metrics(cutoff):
    writes, injects = Counter(), 0
    narrative, injected = Counter(), Counter()    # per key / per Claude project dir
    compile_runs, compile_chars = Counter(), 0    # by outcome; model-call in+out
    path = f"{HOME}/.claude/hook-metrics.jsonl"
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="ignore") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("ts", 0) < cutoff:
                    continue
                hook, action = d.get("hook"), d.get("action")
                project = d.get("project") or ""
                if hook in CAPTURE_HOOKS and action in ("capture", "mirror"):
                    writes[hook] += 1
                    if hook == "project-narrative":
                        narrative[project] += 1
                elif hook == "vault-inject" and action == "inject":
                    injects += 1
                    injected[project] += 1
                elif hook == "vault-compile":
                    compile_runs[action] += 1
                    if action == "model-call":
                        compile_chars += sum(int(n) for n in re.findall(r"(\d+)(?:in|out)\b",
                                                                        str(d.get("detail"))))
    return {
        "writes": writes, "injects": injects, "narrative": narrative, "injected": injected,
        "compile_runs": compile_runs, "compile_chars": compile_chars,
    }


def stale_notes():
    """I5 from consistency-check with a 1-day threshold instead of 21, so the
    lag is visible before it becomes a violation. Imported, not copied: the
    note lookup and key rules belong to the bridge. The deployed copy, since it
    finds the bridge at ~/.claude/extern, which the repo copy has no sibling of."""
    path = f"{HOME}/.claude/hooks/consistency-check.py"
    try:
        spec = importlib.util.spec_from_file_location("consistency_check", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.STALE_DAYS = 1
        vc = mod._vault_common()
        return mod.check_stale_notes(vc) if vc else None
    except Exception:
        return None


def _dir_of(key):
    """mem-lite key `parent--repo` -> the Claude project dir suffix `-parent-repo`."""
    return "-" + key.replace("--", "-")


def _per_key(counter, key):
    return sum(v for d, v in counter.items() if d.endswith(_dir_of(key)))


def main():
    ap = argparse.ArgumentParser(description="Kit share and vault read/write balance.")
    ap.add_argument("--days", type=int, default=7)
    days = ap.parse_args().days
    cutoff = time.time() - days * 86400
    since = datetime.fromtimestamp(cutoff, timezone.utc).strftime("%Y-%m-%d")

    c = claude(cutoff)
    calls, claude_reads = c["calls"], c["vault_reads"]
    agy_calls, agy_reads = antigravity(cutoff)
    hm = hook_metrics(cutoff)
    writes, injects = hm["writes"], hm["injects"]

    total = sum(calls.values())
    kit = sum(v for p, v in calls.items() if _is_kit(p))
    print(f"checkpoint — last {days} days (since {since})\n")
    print("1. Kit share (Claude API calls)")
    print(f"   dev-agent-kit + vault-bridge + llm-council : {kit:>6}")
    print(f"   all projects                               : {total:>6}")
    print(f"   kit share                                  : {kit / total:.0%}" if total else "   (no calls)")
    print(f"   weekly rate                                : {kit * 7 / days:>6.0f}")
    print(f"   antigravity calls (all projects)           : {agy_calls:>6}")
    for p, v in calls.most_common(5):
        print(f"     {v:>6}  {p}")

    reads = sum(claude_reads.values()) + agy_reads
    wrote = sum(writes.values())
    print("\n2. Vault read/write balance")
    print(f"   reads  (vault_search/read/list calls)       : {reads:>6}  "
          f"(claude {sum(claude_reads.values())}, antigravity {agy_reads})")
    for p, v in claude_reads.most_common(5):
        print(f"     {v:>6}  {p}")
    print(f"   writes (capture hooks)                     : {wrote:>6}")
    for h, v in writes.most_common():
        print(f"     {v:>6}  {h}")
    print(f"   exposure (vault-inject card injections)    : {injects:>6}")
    if wrote:
        print(f"   reads per write                            : {reads / wrote:.2f}")

    out = c["read_outcome"]
    print("\n3. Vault quality (Claude)")
    print(f"   read outcomes                              : "
          f"hit {out['hit']}, empty {out['empty']}, error {out['error']}")
    print(f"   past-work prompts / followed by a read     : {c['past_refs']:>6} / {c['followed']}")
    print("   per-project funnel (narrative writes -> card injections -> reads):")
    for key, n in hm["narrative"].most_common(8):
        inj, rd = _per_key(hm["injected"], key), _per_key(claude_reads, key)
        flag = "   <- written, never shown" if not inj and not rd else ""
        print(f"     {n:>4} -> {inj:>4} -> {rd:>3}  {key}{flag}")
    stale = stale_notes()
    if stale is None:
        print("   notes behind their captures                : (vault bridge not configured)")
    else:
        print(f"   notes behind their captures (>1 day)       : {len(stale):>6}")
        for line in stale:
            print(f"            {line}")
    runs = hm["compile_runs"]
    print("   nightly compile runs                       : "
          + (", ".join(f"{a} {n}" for a, n in runs.most_common()) or "     0"))
    print(f"   nightly compile model I/O                  : {hm['compile_chars'] / 4000:>5.0f}k tokens"
          f" (chars/4; logged from 2026-10-20)")
    if c["compile_calls"]:
        print(f"   legacy compile transcripts                 : {c['compile_calls']:>6} calls, "
              f"{c['compile_ctx'] / 1e6:.1f}M context tokens")

    # Background `claude -p` runs (enrichment, capture) are 1-2 call sessions;
    # left in, they drag the median to 1 and hide what interactive work costs.
    oneshot = [s for s in c["sessions"] if s[0] <= ONESHOT_CALLS]
    sessions = [s for s in c["sessions"] if s[0] > ONESHOT_CALLS]
    if sessions:
        per = sorted(s[0] for s in sessions)
        ctx = sum(s[1] for s in sessions) / max(sum(per), 1)
        print("\n4. Session health (Claude)")
        print(f"   one-shot background runs (<={ONESHOT_CALLS} calls)     : {len(oneshot):>6}"
              f"  ({sum(s[1] for s in oneshot) / 1e6:.1f}M context tokens)")
        print(f"   interactive sessions                       : {len(sessions):>6}")
        print(f"   calls per session  median / p90 / max      : {statistics.median(per):>6.0f}"
              f" / {per[int(len(per) * 0.9)]} / {per[-1]}")
        print(f"   sessions over {LONG_SESSION} calls                    : "
              f"{sum(n > LONG_SESSION for n in per):>6}")
        print(f"   context tokens per call                    : {ctx / 1000:>5.0f}k")
        print(f"   sessions with a mem_save / with a skill    : "
              f"{sum(s[2] > 0 for s in sessions):>6} / {sum(s[3] > 0 for s in sessions)}")
        # Which job launches the one-shot runs: grouped by their opening prompt.
        sources = Counter(s[4][:40] for s in oneshot)
        if sources:
            print("   one-shot runs by opening prompt:")
            for text, n in sources.most_common(3):
                print(f"     {n:>6}  {text or '(no text)'}")

    # Every skill description and MCP tool list is paid for in every session;
    # one that is never called is pure cost. Top-level transcripts only, so
    # subagent calls are not in these counts.
    kit_skills, mcp = installed()
    skills, servers = c["skills"], c["servers"]
    print("\n5. Skill and MCP use (Claude)")
    print("   skills  : " + (", ".join(f"{k} {v}" for k, v in skills.most_common()) or "none"))
    print("   servers : " + (", ".join(f"{k} {v}" for k, v in servers.most_common()) or "none"))
    print("   kit skills never invoked     : " + (", ".join(s for s in kit_skills if not skills[s]) or "-"))
    print("   global MCP servers never used: " + (", ".join(s for s in mcp if not servers[s]) or "-"))


if __name__ == "__main__":
    main()
