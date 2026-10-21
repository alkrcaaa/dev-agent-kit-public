---
name: advisor-workers
description: Offloads read-only work (large review, repo exploration, planning, second opinion) to local Qwen/Gemini workers via ask_worker. Use when a task is mostly reading and would burn your own context, or a second model's view is worth having. Not for writing code.
---

# Advisor Workers — read-only Qwen / Gemini
<!-- dev-agent-kit native skill -->

<!-- gate:begin -->
1. Workers **advise, never write.** They run in a throwaway copy of the project. You make
   every edit yourself.
2. **Check `status` before using an answer.** `VIOLATION` = a worker changed the original
   tree despite the sandbox (absolute-path write): stop, run `git status`/`git diff`, tell the
   user. `error`/`timeout` = no answer; do the work yourself.
3. **Verify, don't relay.** A worker's finding is a lead: open the cited `file:line` before
   you repeat it to the user or act on it. Small models invent line numbers.
   **Never ask a worker for numbers** (line no., file length, counts of filtered items): in
   testing both Qwen hosts read the file but got every one wrong. Ask for a verbatim quote or
   a list of matching lines (14/14 correct) and produce numbers yourself with `grep -n`/`wc -l`.
4. **Do not use for small asks** — a one-file question is cheaper to answer yourself than to
   brief, wait for and verify.
<!-- gate:end -->

## When it pays off

| Situation | Call |
|---|---|
| Review a large diff / many files (reading dominates) | `ask_worker(role="review")` on one worker (Gemini); two (Qwen + Gemini) only if it matters |
| "Where / how does X work" across an unfamiliar repo | `role="explore"` |
| Non-trivial change, want a plan before touching code | `role="plan"`, then judge it |
| Type-1 or contested call, want another model's view | `role="ask"` on Qwen *and* Gemini, compare; for a real deliberation see `llm-council` |

Gemini (`gemini`, pinned to gemini-3.8-flash-medium in workers.json; best measured reviewer; a real review takes minutes, so expect it to finish in the background); Qwen hosts are free and fast but miss more (see Gotchas).
Send the same review to one of each when it matters; agreement is signal, disagreement is
where to look yourself.

## Calling

```
list_workers()                                   # who is up, which model each serves
ask_worker(prompt, working_dir, worker="", role="review", timeout=300)
```

- `prompt`: name files and what to conclude. Workers have no memory of earlier calls and see
  only git-tracked + untracked-not-ignored files (submodule contents are not copied).
- `worker` empty = default from `workers.json`. `role` = any file in `personas/`.
- Run independent workers in parallel (several calls in one turn); results are text only.
- No approval needed: just tell the user which workers you used.

## Managing workers (you will be asked to)

All in `mcp-infra/local-model-mcp/` (the submodule, repo `alkrcaaa/local-llm-mcp-public`):
- `workers.json` (gitignored, re-read every call): host moved or model swapped → edit
  `base_url`; `model: ""` asks the server which id it serves. New worker = new entry.
  `kind: qwen` (OpenAI-compatible vLLM via Qwen CLI) or `kind: agy` (Gemini, subscription).
- `personas/*.md`: `_base.md` (read-only rules, code standards; overrides the CLIs' own
  QWEN.md/GEMINI.md, which tell workers to write files) + one file per role. Adding a role
  = adding a file. Text is inlined in the prompt, not referenced.
- After editing tool code, the MCP needs `/mcp` reconnect; config and personas do not.

## Gotchas (observed)

- Gemini timeouts are the norm, not the exception: 18 of 25 calls timed out at 300 s
  before 2026-10-07. Dropping `--mode plan` (a plan + walkthrough artifact per turn) made
  small asks ~3x faster, but a real diff review still hit 600 s the same day — root cause
  open. Give Gemini narrow, file-named asks; for a big review prefer a Qwen worker.
- `agy --mode plan` and `gemini --approval-mode plan` are **not** trustworthy read-only
  flags; the copy + before/after fingerprint is the real guard. Absolute-path writes are
  detected, not prevented.
- Plain `gemini` CLI has no valid key here; Gemini goes through `agy`.
- Measured 2026-10-01 on `crg-gate.py` (383 lines): `qwen-411` (qwen3.8) and `qwen-149`
  (qwen3.6) both returned the right `BUDGET` value but wrong line numbers and totals
  (116/358, 135/318 vs 126/383) and missed 1-2 of 3 prefix-filtered functions; verbatim
  "quote every `def ` line" was 14/14 on both. Every call also logs discarded writes to
  `.claude/plugin_claude_mem_lite*` — harmless noise.
- A GPU host can be busy with someone else's load: slow
  answers are not a bug.
