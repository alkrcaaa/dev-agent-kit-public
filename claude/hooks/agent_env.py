#!/usr/bin/env python3
"""Host-agent adaptation layer for the enforcement hooks.

The same hook scripts are deployed to Claude Code (~/.claude/hooks), Qwen
Code (~/.qwen/hooks) and Google Antigravity (~/.gemini/config/hooks). All
three carry Claude's hook contract — same event names, same snake_case
payload keys (session_id, cwd, tool_input, transcript_path) and the same
tool_input parameter names (file_path, command, pattern, glob, skill). Two
things do differ per host:

1. TOOL NAMES are host-specific wire names, established by running real
   sessions against an isolated HOME rather than by reading a minified
   bundle:
     Qwen (Gemini-CLI wire names): read_file, grep_search, run_shell_command,
       edit, write_file, skill, agent.
     Antigravity (its own native tool surface — NOT the same family as
       Gemini-CLI's, confirmed against antigravity.google/docs/ide/hooks/):
       view_file, write_to_file, replace_file_content,
       multi_replace_file_content, find_by_name, run_command. Only
       grep_search is shared with Qwen's vocabulary.
   Hook *matchers* in the deployed settings/hooks JSON match only the wire
   names for that host — a "Read" or "Edit|Write" matcher matches nothing and
   fails silently (no error, the hook simply never runs). Regex alternation
   over wire names ("edit|write_file") does work. canonical() maps a
   payload's tool_name back to Claude's vocabulary so each hook keeps exactly
   one set of comparisons regardless of which host sent it.

2. OUTPUT CHANNELS differ on the non-blocking paths:
     UserPromptSubmit — plain stdout is NOT injected into qwen's (or,
                        presumably, Antigravity's) context;
                        hookSpecificOutput.additionalContext is. JSON is
                        honoured by both hosts, so hooks always emit JSON.
     PostToolUse      — exit 2 + stderr is NOT surfaced to the qwen model.
                        The hook runs, the message is dropped on the floor.
                        additionalContext is delivered verbatim. Antigravity's
                        PostToolUse channel behavior is unverified — post_feedback()
                        treats any non-"claude" AGENT the same as Qwen until
                        confirmed otherwise against a live Antigravity session.
   PreToolUse exit 2 blocks the call and surfaces stderr on BOTH hosts, so
   the gates (crg-gate, skill-gate, bash-edit-guard, commit-attribution-guard)
   need no channel adaptation — only the name mapping.

AGENT is declared by the deployed settings/hooks JSON (DAK_AGENT=qwen or
DAK_AGENT=antigravity); anything else, including unset, means Claude.
"""
import json
import os
import sys

AGENT = os.environ.get("DAK_AGENT", "claude")

# Wire name -> the name the hooks compare against (Claude's). Claude's own
# names are absent on purpose: canonical() passes anything unmapped straight
# through, which also keeps mcp__server__tool names intact (identical on both
# hosts, so the MCP matchers port as-is).
_WIRE_TO_CANONICAL = {
    "read_file": "Read",
    "grep_search": "Grep",
    "search_file_content": "Grep",  # legacy qwen name
    "glob": "Glob",
    "list_directory": "LS",
    "run_shell_command": "Bash",
    "edit": "Edit",
    "replace": "Edit",  # legacy qwen name
    "write_file": "Write",
    "notebook_edit": "NotebookEdit",
    "skill": "Skill",
    "agent": "Agent",
    "task": "Agent",
    "web_fetch": "WebFetch",
    "web_search": "WebSearch",
    "todo_write": "TodoWrite",
    # Antigravity's native tool surface — distinct from Qwen's Gemini-CLI
    # names (see module docstring). grep_search is already covered above.
    "view_file": "Read",
    "write_to_file": "Write",
    "replace_file_content": "Edit",
    "multi_replace_file_content": "Edit",
    "find_by_name": "Glob",
    "list_dir": "LS",
    "run_command": "Bash",
    "read_url_content": "WebFetch",
    "search_web": "WebSearch",
}


def canonical(name):
    """Map a host tool name to the kit's canonical (Claude) vocabulary."""
    if not name:
        return ""
    # "Task" is Claude's legacy name for the subagent tool; fold it in too so
    # hooks only ever test for "Agent".
    if name == "Task":
        return "Agent"
    return _WIRE_TO_CANONICAL.get(name, name)


def _raw_tool(data):
    """(wire tool name, argument dict) from a hook payload, whatever its shape.

    Claude and Qwen both send flat snake_case keys (tool_name / tool_input).
    Antigravity's payload shape is NOT guaranteed to match: its own hooks
    surface nests the call under "toolCall" and wraps every MCP call as
    call_mcp_tool(ToolName=..., Arguments={...}) -- obsidian-mirror already
    had to special-case both by hand. A hook that reads data["tool_name"]
    directly gets "" on such a payload and returns silently, which is
    indistinguishable from "the gate saw nothing to block": measured
    2026-09-12, the Antigravity host recorded 541 hook decisions of which
    ZERO came from crg-gate / skill-gate / bash-edit-guard / lint-on-edit /
    crg-update, while the same week it made 7579 reads and 2823 edits.
    Reading every known shape here keeps that failure out of every hook.
    """
    name = data.get("tool_name") or data.get("toolName") or ""
    args = data.get("tool_input") or data.get("toolInput") or {}
    if not name or not args:
        call = data.get("toolCall") or data.get("tool_call") or {}
        if isinstance(call, dict):
            name = name or call.get("name") or call.get("ToolName") or ""
            if not args:
                nested = (call.get("args") or call.get("arguments")
                          or call.get("Arguments") or call.get("tool_input"))
                if isinstance(nested, dict):
                    args = nested
    if not isinstance(args, dict):
        args = {}
    # Antigravity wraps MCP calls; the tool the model actually asked for (and
    # the arguments the gates care about) are one level in.
    if name == "call_mcp_tool":
        inner = args.get("Arguments") or args.get("arguments")
        name = args.get("ToolName") or args.get("tool_name") or name
        if isinstance(inner, dict):
            args = inner
    return name, args


def tool_name(data):
    """Canonical tool name from a hook payload."""
    return canonical(_raw_tool(data)[0])


def tool_input(data):
    """Tool argument dict from a hook payload, host shape absorbed."""
    raw = _raw_tool(data)[1]
    args = dict(raw) if isinstance(raw, dict) else {}
    # Canonicalise common argument keys across hosts:
    # Antigravity uses AbsolutePath/TargetFile/path -> file_path
    if "file_path" not in args:
        fp = args.get("AbsolutePath") or args.get("TargetFile") or args.get("path")
        if fp:
            args["file_path"] = fp
    # Antigravity uses CommandLine -> command
    if "command" not in args:
        cmd = args.get("CommandLine")
        if cmd:
            args["command"] = cmd
    return args


def raw_tool_name(data):
    """Wire tool name, unwrapped but NOT canonicalised.

    For the few hooks that key off an MCP server prefix (mcp__playwright__...)
    rather than the canonical vocabulary.
    """
    return _raw_tool(data)[0]


def emit_context(event, context, system_message=None):
    """Inject context for the model on a non-blocking event.

    Always JSON: plain stdout reaches the model on Claude but not on Qwen.
    """
    out = {
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext": context,
        }
    }
    if system_message:
        out["systemMessage"] = system_message
    print(json.dumps(out))


def post_feedback(message, system_message=None):
    """Deliver PostToolUse feedback and exit, using whichever channel lands.

    Claude renders exit-2 stderr as a tool error the model must react to —
    the strongest available signal, so it stays. Qwen drops it silently,
    so there the same text goes through additionalContext instead.
    """
    if AGENT == "claude":
        print(message, file=sys.stderr)
        sys.exit(2)
    emit_context("PostToolUse", message, system_message)
    sys.exit(0)
