---
name: differential-review
description: Security-focused review of a diff, commit, or pull request — what changed and what new risk it introduces. Use when reviewing PRs, commits, or branch diffs (complements /code-review, which targets correctness).
---

# Differential Review (Trail of Bits)

<!-- gate:begin -->
**Review the change, not the file.**

1. **Triage by risk first.** Rank changed files: auth/crypto/session, value transfer, external calls and deserialization, then everything else. Spend the budget at the top of that list.
2. **Ask why the old code existed** before accepting its replacement — `git blame`/`git log -S` on the removed lines. A deleted check is a finding until proven otherwise; re-introduced vulnerabilities (regressions) are the highest-yield category in diff review.
3. **Blast radius:** count the callers of every changed function before calling a change local. Use `get_impact_radius_tool` / `query_graph_tool(pattern="callers_of")` rather than guessing.
4. **Coverage gap:** which changed lines have no test? `query_graph_tool(pattern="tests_for", node=...)`. Untested new auth logic is a reportable gap on its own.
5. **Think adversarially, concretely.** For each candidate issue name WHO the attacker is, what access they hold, and the exact request sequence. If you cannot write that sequence, downgrade it — do not pad the report.
6. **Report:** severity-grouped, each finding `file:line` + attack scenario + fix. Say explicitly what you did not review.

Stop-and-escalate triggers: an auth or ownership check removed/weakened, a new raw SQL/shell/`eval` sink, a crypto primitive or key-handling change, a new unauthenticated route, secrets appearing in the diff.
<!-- gate:end -->

## Depth

Read the full skill now and follow it (workflow phases 0–6, decision tree, adversarial modeling, report template):

```
~/.claude/extern/trailofbits-skills/plugins/differential-review/skills/differential-review/SKILL.md
```

Supporting files in the same directory as the task requires: `methodology.md` (phase detail),
`adversarial.md` (attacker model, exploitability), `reporting.md` (report structure),
`patterns.md` (regression/access-control/overflow patterns).
(The plugin's top-level `README.md` is install metadata, not the skill.)

Pair with the code-review-graph MCP: `detect_changes_tool` for the risk-scored diff,
`get_review_context_tool` for snippets, `get_impact_radius_tool` for blast radius.
