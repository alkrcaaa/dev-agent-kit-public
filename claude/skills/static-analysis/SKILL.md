---
name: static-analysis
description: Run or configure static analysis (SAST) — semgrep, CodeQL, linters — to find bugs and vulnerabilities in a codebase. Use when asked to scan code, set up SAST tooling, or triage analyzer findings.
---

# Static Analysis (Trail of Bits)

<!-- gate:begin -->
**How to actually run a scan.**

- **Semgrep for breadth, fast** (installed and on PATH):
  ```
  semgrep scan --config=p/security-audit --config=p/secrets --sarif -o findings.sarif <path>
  ```
  Add `--baseline-commit <sha>` to scan only what changed. OSS mode cannot track data flow across files — say so rather than implying full coverage.
- **CodeQL when you need interprocedural taint tracking** (create a database, then run `security-extended`). Slower; reserve it for the questions semgrep can't answer.
- **Triage every finding before reporting it.** Open the source at `file:line` and decide true/false positive. An unreviewed analyzer dump is not a security review — it is noise with a severity column.
- **Report shape:** severity-grouped, each item `file:line` + why it is exploitable + the fix. Drop the ones you confirmed as false positives and say how many you dropped.
- **Zero findings is a result, not a failure** — but state what was scanned and what the ruleset does not cover.
<!-- gate:end -->

## Depth

Pick the tool matching the task and read its SKILL.md now:

| Tool | Path |
|------|------|
| Semgrep (fast pattern + taint scanning) | `~/.claude/extern/trailofbits-skills/plugins/static-analysis/skills/semgrep/SKILL.md` |
| CodeQL (deep taint / data-flow) | `~/.claude/extern/trailofbits-skills/plugins/static-analysis/skills/codeql/SKILL.md` |
| SARIF parsing / merging results | `~/.claude/extern/trailofbits-skills/plugins/static-analysis/skills/sarif-parsing/SKILL.md` |

(The plugin's top-level `README.md` is install metadata, not the skill.)

Writing custom rules: `~/.claude/extern/trailofbits-skills/plugins/semgrep-rule-creator/README.md`.
For interpreting what the findings mean, pair with `owasp-security`.
