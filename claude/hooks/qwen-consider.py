#!/usr/bin/env python3
"""
qwen-consider hook (PreToolUse, matcher: Agent|Task).

Field data (agent-stats, Jul 2026): Claude spawns its own subagents for
heavy work but almost never weighs the free local qwen offload first —
the CLAUDE.md "Qwen — Optional Offload" section is not at the decision
point, so it never fires (lesson #91). This soft-gate is: the FIRST
subagent dispatch per session is blocked once with a dispatch checklist;
re-running the same call passes, as does every later dispatch.

The checklist deliberately does NOT push hard refactors to qwen — the
offload-ceiling finding showed the 27B model fails there and the
retry+takeover loop costs more than doing it with Claude.

Escape hatch: `export QWEN_CONSIDER_OFF=1`. Fail-open on any error.
"""
import hashlib
import json
import os
import sys
import tempfile

import agent_env


def main():
    if os.environ.get("QWEN_CONSIDER_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if agent_env.tool_name(data) != "Agent":
        sys.exit(0)

    sid = data.get("session_id") or "unknown"
    key = hashlib.sha1(sid.encode("utf-8", "replace")).hexdigest()[:16]
    marker = os.path.join(tempfile.gettempdir(), "qwen-consider-%s.seen" % key)
    if os.path.exists(marker):
        sys.exit(0)
    try:
        open(marker, "w").close()
    except OSError:
        sys.exit(0)

    sys.stderr.write(
        "qwen-consider (one-time per session): before spawning a Claude "
        "subagent, weigh the free local offload. Send to "
        "mcp__qwen__qwen_execute instead when the task is bulk/mechanical: "
        "boilerplate or test scaffolds, repetitive multi-file edits from an "
        "exact spec, docs/config generation, or a parallel second "
        "implementation. KEEP the Claude subagent when the task needs deep "
        "reasoning: hard refactors, ambiguous design, security audits, "
        "debugging — qwen's 27B ceiling makes those a retry+takeover loss. "
        "If the Claude subagent is the right call, re-run the exact same "
        "Agent call now — it will pass."
    )
    try:
        import hook_metrics
        hook_metrics.record("qwen-consider", "nudge", data.get("cwd"))
    except Exception:
        pass
    sys.exit(2)


if __name__ == "__main__":
    main()
