#!/usr/bin/env python3
"""Run a claude-mem-lite hook against a Qwen Code payload.

claude-mem-lite ships Claude's tool vocabulary hard-coded — pre-tool-recall.js
gates on ['Edit', 'Write', 'NotebookEdit', 'Read'] and branches on
toolName === 'Read'. Qwen sends the Gemini-CLI wire names (edit, write_file,
read_file), so pointing the mem-lite hooks straight at a qwen session makes
them record 'pre-recall:unknown-tool' errors instead of recalling anything.

Rather than fork a third-party script per host, this bridge rewrites the one
field that differs and delegates:

    mem-bridge.py node /path/hook-launcher.mjs scripts/pre-tool-recall.js

stdin JSON -> tool_name canonicalised -> child's stdin. The child's stdout is
passed through verbatim, because mem-lite already emits the JSON
additionalContext envelope that both hosts honour.

Fail-open, always. Memory is an enhancement; a missing node, a crashed
launcher, or malformed JSON must never break the session or block a tool, so
every failure path exits 0 and stays silent. Exit codes from the child are
deliberately NOT propagated: no mem-lite hook blocks, and an accidental exit 2
on PreToolUse would deny the tool call.
"""
import json
import subprocess
import sys

import agent_env


def main():
    if len(sys.argv) < 2:
        sys.exit(0)

    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        name, args = agent_env._raw_tool(data)
        if name:
            data["tool_name"] = agent_env.canonical(name)
            # A host that nests the call (Antigravity's toolCall/call_mcp_tool)
            # leaves mem-lite's child hook with no tool_input to recall on;
            # flatten it onto the payload the child expects.
            if args and not data.get("tool_input"):
                data["tool_input"] = args
            # Record the rewrite, not the pass-through. This bridge existed
            # for a while doing nothing at all -- mem-lite recalled on Claude's
            # names, Qwen sent Gemini-CLI's, and the mismatch surfaced as
            # silence rather than an error. A rewrite is the one event that
            # proves the bridge is earning its place, so its absence from the
            # metrics is itself the finding.
            if data["tool_name"] != name:
                try:
                    import hook_metrics
                    hook_metrics.record("mem-bridge", "canonicalise", None, name)
                except Exception:
                    pass
        payload = json.dumps(data)
    except Exception:
        # Not JSON we understand — hand the original through untouched rather
        # than dropping the event.
        payload = raw

    try:
        proc = subprocess.run(
            sys.argv[1:],
            input=payload,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception:
        sys.exit(0)

    if proc.stdout:
        sys.stdout.write(proc.stdout)
    sys.exit(0)


if __name__ == "__main__":
    main()
