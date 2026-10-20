---
name: karpathy-guidelines
description: Simplicity and surgical-change discipline for any non-trivial implementation or refactor. Use BEFORE starting a large, ambiguous, or multi-file code change — keeps the diff minimal and the design boring.
---

# Karpathy Guidelines

<!-- gate:begin -->
**Four rules for a non-trivial change.**

1. **Think before coding.** State your assumptions out loud. If the request has two readings, present both instead of silently picking one. If a simpler approach exists, say so.
2. **Simplicity first.** The minimum code that solves the problem — no speculative features, no abstraction for a single call site, no configurability nobody asked for, no error handling for impossible states. If 200 lines could be 50, rewrite it.
3. **Surgical changes.** Touch only what the request requires. Don't "improve" adjacent code, comments, or formatting; match the existing style even where you'd do it differently. Remove imports/variables *your* change orphaned — mention pre-existing dead code instead of deleting it. Test: every changed line traces directly to the request.
4. **Goal-driven execution.** Turn the task into a verifiable goal before starting — "fix the bug" → "write a test that reproduces it, then make it pass". For multi-step work, state `step → verify:` pairs and loop until each check passes.
<!-- gate:end -->

## Depth

Read the full skill now and follow it:

```
~/.claude/extern/andrej-karpathy-skills/skills/karpathy-guidelines/SKILL.md
```

Tradeoff: these bias toward caution over speed. For trivial tasks, use judgment.
