#!/usr/bin/env python3
"""
snapshot-size-nudge hook (PostToolUse, matcher: mcp__playwright__.*).

Field data (miivii, Jul 2026): single playwright results reached ~595KB
(~150k tokens) on pages with 2000+-line templates — four of them made up
over half of a 12MB mega-session, and each one is re-billed on every
subsequent API call. The webapp-testing skill has warned about snapshot
cost since Jul 4 and the 595KB results still happened on Jul 7 — proving
(again) that a skill description is not enough; the nudge has to land at
the decision point (lesson #91: hook > skill description > CLAUDE.md).

When a playwright tool result exceeds a size threshold, emit JSON on
BOTH channels (same pattern as session-size-nudge):

  systemMessage       -> rendered to the USER, so oversized snapshots
                         stop being invisible.
  additionalContext   -> injected for the model at the decision point:
                         switch to browser_find / targeted
                         browser_evaluate on this page.

Caps at 3 nudges per session — after that the model has been told.

Escape hatches: `export SNAPSHOT_NUDGE_OFF=1`, threshold via
`SNAPSHOT_NUDGE_KB` (default 100). Fail-open on any error.
"""
import hashlib
import json
import os
import sys
import tempfile

import agent_env

DEFAULT_THRESHOLD_KB = 100
MAX_NUDGES = 3


def main():
    if os.environ.get("SNAPSHOT_NUDGE_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    # Antigravity delivers MCP calls wrapped as call_mcp_tool(ToolName=...),
    # so the server prefix is gone by the time the name is unwrapped; accept
    # the bare playwright tool name too.
    tool = agent_env.raw_tool_name(data)
    if not (tool.startswith("mcp__playwright__") or tool.startswith("browser_")):
        sys.exit(0)

    try:
        threshold_kb = int(os.environ.get("SNAPSHOT_NUDGE_KB",
                                          DEFAULT_THRESHOLD_KB))
    except ValueError:
        threshold_kb = DEFAULT_THRESHOLD_KB

    try:
        kb = len(json.dumps(data.get("tool_response", ""),
                            default=str)) / 1024
    except Exception:
        sys.exit(0)
    if kb < threshold_kb:
        sys.exit(0)

    sid = data.get("session_id") or "unknown"
    key = hashlib.sha1(sid.encode("utf-8", "replace")).hexdigest()[:16]
    marker = os.path.join(tempfile.gettempdir(),
                          "snapshot-size-%s.count" % key)
    count = 0
    try:
        with open(marker) as f:
            count = int(f.read().strip() or 0)
    except (OSError, ValueError):
        pass
    if count >= MAX_NUDGES:
        sys.exit(0)
    try:
        with open(marker, "w") as f:
            f.write(str(count + 1))
    except OSError:
        sys.exit(0)

    short = tool.replace("mcp__playwright__", "")
    tokens_k = round(kb / 4)
    user_msg = (
        "📸 %s returned ~%dKB (~%dk tokens) — this page's snapshot is "
        "oversized and now re-bills on every call. Prefer browser_find / "
        "targeted browser_evaluate here." % (short, round(kb), tokens_k)
    )
    ctx = (
        "[snapshot] The last %s result was ~%dKB (~%dk tokens) and stays "
        "in context for the rest of the session. This page is too large "
        "for full snapshots: from now on use browser_find or a targeted "
        "browser_evaluate (a selector query costs ~50 tokens), and "
        "browser_take_screenshot for visual checks. Do not take another "
        "full snapshot of this page." % (short, round(kb), tokens_k)
    )

    try:
        import hook_metrics
        hook_metrics.record("snapshot-size-nudge", "nudge", data.get("cwd"),
                            "%dKB" % round(kb))
    except Exception:
        pass

    print(json.dumps({
        "systemMessage": user_msg,
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": ctx,
        },
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
