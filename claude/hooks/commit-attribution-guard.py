#!/usr/bin/env python3
"""
commit-attribution-guard hook (PreToolUse, matcher: Bash).

The user has said "no Claude/Anthropic attribution in commits" repeatedly
(file memory + CLAUDE.md), yet the footers keep coming back because the
harness system prompt injects them per-session. An instruction cannot
reliably override another instruction — a deterministic block can
(lesson #91: hook > skill description > CLAUDE.md).

Blocks any `git commit` whose command text carries an attribution
pattern; stderr tells the model to strip the lines and retry. Everything
else — including commit messages that merely mention claude/ paths or
hook names — passes untouched.

Escape hatch: `export COMMIT_GUARD_OFF=1`. Fail-open on any error.
"""
import json
import os
import re
import sys

import agent_env

GIT_COMMIT_RE = re.compile(r"\bgit\b[^|;&]*\bcommit\b")
ATTRIBUTION_RES = (
    re.compile(r"co-authored-by", re.I),
    re.compile(r"generated with", re.I),
    re.compile(r"noreply@anthropic", re.I),
    re.compile(r"(?:claude|anthropic)\.com", re.I),
    re.compile("\U0001f916"),  # 🤖
)


def main():
    if os.environ.get("COMMIT_GUARD_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if agent_env.tool_name(data) != "Bash":
        sys.exit(0)
    cmd = agent_env.tool_input(data).get("command") or ""
    if not GIT_COMMIT_RE.search(cmd):
        sys.exit(0)

    hits = [r.pattern for r in ATTRIBUTION_RES if r.search(cmd)]
    if not hits:
        # A guard that has never had to block looks dead to consistency-check
        # I3; a row per commit (rare, unlike every Bash call) tells them apart.
        try:
            import hook_metrics
            hook_metrics.record("commit-attribution-guard", "pass", data.get("cwd"))
        except Exception:
            pass
        sys.exit(0)

    sys.stderr.write(
        "commit-attribution-guard: this commit contains Claude/Anthropic "
        "attribution (%s). The user's standing rule is NO attribution "
        "footers — no Co-Authored-By, no 'Generated with Claude Code', no "
        "robot emoji, no anthropic/claude.com links. Strip those lines and "
        "re-run the commit; the message content itself is otherwise fine."
        % ", ".join(hits)
    )
    try:
        import hook_metrics
        hook_metrics.record("commit-attribution-guard", "block",
                            data.get("cwd"), hits[0] if hits else None)
    except Exception:
        pass
    sys.exit(2)


if __name__ == "__main__":
    main()
