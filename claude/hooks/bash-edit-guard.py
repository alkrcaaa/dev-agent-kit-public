#!/usr/bin/env python3
"""
bash-edit-guard hook (PreToolUse on Bash).

Blocks in-place edits of CODE files via bash — sed -i / perl -i /
awk -i inplace / shell redirects / tee. Editing through bash bypasses the
Edit/Write tools, which means lint-on-edit never fires and the change lands
unreviewed and unlinted. The block message steers to Edit (replace_all for
bulk renames) or Write.

Deliberately NOT blocked: reading (cat/sed -n — priced by crg-gate's budget),
cp/mv (deploy scripts legitimately copy code), and writes to non-code files
(.md/.json/.yaml/logs — normal shell business).

Escape hatch: LINT_HOOK_OFF=1 (this guard exists to protect the lint channel).
Fail-open on any parse error.
"""
import sys
import os
import re

import agent_env
import json

CODE_EXT = (
    "py", "pyi", "js", "jsx", "ts", "tsx", "mjs", "cjs",
    "cpp", "cc", "cxx", "c", "h", "hpp", "hh", "go", "rs",
    "java", "rb", "php", "cs", "swift", "kt", "kts", "scala",
    "m", "mm", "sh", "bash", "zsh", "lua", "dart", "ex", "exs",
    "pl", "r", "jl", "vue", "svelte",
)
_EXT = "|".join(CODE_EXT)

_CODE_FILE_RE = re.compile(r"\.(?:%s)\b" % _EXT)
# In-place text-transform editors at COMMAND position (segment start, after
# a pipe/;/&/(, or as an xargs target) — not inside quoted strings, where
# "sed -i" may just be prose. Flags must be a contiguous cluster after the
# command name, so `sed -n 'script' ... --include` can't match at a distance.
_INPLACE_RE = re.compile(
    r"(?:^|[|;&(]\s*|\bxargs\s+(?:-\S+\s+)*)"
    r"(?:sed\s+(?:-[a-zA-Z]+\s+)*(?:-[a-zA-Z]*i\b|-i\.\w+|--in-place)"
    r"|perl\s+(?:-\S+\s+)*-[a-zA-Z]*i"
    r"|g?awk\s+(?:-\S+\s+)*-i\s*inplace)"
)
# Redirect or tee targeting a code file: `> app.py`, `>> lib/util.sh`,
# `tee app/main.py`. Catches heredoc writes (`cat > x.py <<EOF`) too.
_REDIRECT_RE = re.compile(
    r"(?:>{1,2}|\btee\b(?:\s+-a)?)\s*['\"]?[^|;&\s'\"]*\.(?:%s)\b" % _EXT
)


_QUOTED_RE = re.compile(r"'[^']*'|\"[^\"]*\"")


def _blocks(command):
    # Match against the command with quoted strings emptied: prose in commit
    # messages / echo strings ("use sed -i on x.py") must not trigger. Real
    # edits keep their sed -i / > x.py tokens outside quotes.
    stripped = _QUOTED_RE.sub("''", command)
    for seg in re.split(r"[|;&]", stripped):
        seg = seg.strip()
        # ext may sit in an earlier segment (`find *.py | xargs sed -i`) or
        # inside quotes ('*.py'), so the check runs on the full raw command.
        if _INPLACE_RE.search(seg) and _CODE_FILE_RE.search(command):
            return "in-place edit (%s)" % seg[:60]
        if _REDIRECT_RE.search(seg):
            return "shell redirect/tee into a code file (%s)" % seg[:60]
    return None


def main():
    if os.environ.get("LINT_HOOK_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if agent_env.tool_name(data) != "Bash":
        sys.exit(0)
    command = agent_env.tool_input(data).get("command") or ""
    hit = _blocks(command)
    if not hit:
        sys.exit(0)
    print(
        "[bash-edit-guard] Blocked: %s. Editing code through bash bypasses the "
        "Edit/Write tools AND the lint-on-edit hook — the change would land "
        "unlinted. Use Edit (replace_all: true for bulk renames) or Write "
        "instead; they trigger linting automatically." % hit,
        file=sys.stderr,
    )
    try:
        import hook_metrics
        # Category only — `hit` embeds the offending command, and a blocked
        # `sed -i s/<secret>/.../` would otherwise write it to disk.
        hook_metrics.record("bash-edit-guard", "block", data.get("cwd"),
                            hit.split(" (")[0])
    except Exception:
        pass
    sys.exit(2)


if __name__ == "__main__":
    main()
