#!/usr/bin/env python3
"""
skill-nudge hook — one-line reminders for skills no file edit ever points at.

skill-gate fires on Edit/Write of domain files, which is why design-dna,
devops and friends get used. The skills below have no such decision point
(a push, a "scan this" request), so they sat at zero invocations. Each rule
here is a concrete trigger -> one line, injected as non-blocking context,
once per session per rule. Vague "use when appropriate" wording is read as
"never" (lesson #1090), so every trigger is spelled out in RULES.

Modes (argv[1]):
  prompt  UserPromptSubmit: keyword match on the user's prompt
  bash    PreToolUse Bash: command match (git push / gh pr create)

Wave 1 only: differential-review, static-analysis. Measure via hook-stats
(hook "skill-nudge", detail = rule) before adding conversational skills.

Escape hatch: SKILL_NUDGE_OFF=1. Fail-open on any error.
"""
import hashlib
import json
import os
import re
import sys
import tempfile

import agent_env

# (rule id, regex, message). Word-bounded on purpose: bare "tara" matched
# "taraman" (a config diff request), bare "asan" matched "arasana".
PROMPT_RULES = (
    (
        "static-analysis",
        re.compile(
            r"\b(semgrep|codeql|gitleaks|sast)\b|static analysis|statik analiz"
            r"|sızıntı|\bleaks?\b|açık kaynak|open[- ]?source"
            r"|güvenlik (açığı|taraması|tara)|zafiyet|vulnerab",
            re.IGNORECASE),
        "[skill-nudge] This looks like a scan/leak/vulnerability task: load the "
        "`static-analysis` skill first (semgrep for breadth, CodeQL for taint, "
        "triage every finding at file:line before reporting).",
    ),
)

BASH_RULES = (
    (
        "differential-review",
        re.compile(r"\bgit\s+push\b|\bgh\s+pr\s+(create|merge)\b"),
        "[skill-nudge] Before this push/PR: if the change touches hooks, auth, "
        "secrets, config defaults or goes to a public remote, run the "
        "`differential-review` skill on `git diff @{u}..` first (a deleted check "
        "is a finding until proven otherwise). Skip for docs/typo-only pushes.",
    ),
)


def _state_path(data):
    sid = data.get("session_id") or ("cwd:" + (data.get("cwd") or os.getcwd()))
    key = hashlib.sha1(sid.encode("utf-8", "replace")).hexdigest()[:16]
    return os.path.join(tempfile.gettempdir(), "skill-nudge-%s.json" % key)


def _sent(data):
    try:
        with open(_state_path(data)) as f:
            return set(json.load(f))
    except Exception:
        return set()


def _remember(data, sent):
    try:
        with open(_state_path(data), "w") as f:
            json.dump(sorted(sent), f)
    except Exception:
        pass


def main():
    if os.environ.get("SKILL_NUDGE_OFF"):
        return
    mode = sys.argv[1] if len(sys.argv) > 1 else "prompt"
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    if mode == "bash":
        if agent_env.tool_name(data) != "Bash":
            return
        text = agent_env.tool_input(data).get("command") or ""
        rules, event = BASH_RULES, "PreToolUse"
    else:
        text = data.get("prompt") or ""
        rules, event = PROMPT_RULES, "UserPromptSubmit"

    sent = _sent(data)
    hits = [(rid, msg) for rid, rx, msg in rules
            if rid not in sent and rx.search(text)]
    if not hits:
        return

    sent.update(rid for rid, _ in hits)
    _remember(data, sent)
    agent_env.emit_context(event, "\n".join(msg for _, msg in hits))
    try:
        import hook_metrics
        for rid, _ in hits:
            hook_metrics.record("skill-nudge", "nudge", data.get("cwd"), rid)
    except Exception:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
