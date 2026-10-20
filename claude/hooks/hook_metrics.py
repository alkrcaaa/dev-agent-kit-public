#!/usr/bin/env python3
"""Aggregate fire-count telemetry for the enforcement hooks.

Why this exists: agent-stats.sh can measure the *result* of enforcement
(structural ratio, skill invocations) but never the *act* — how often a gate
actually blocked, how often lint caught something, which domain nudged. The
hooks kept only per-session state in /tmp, so the question "is this hook
earning its keep?" was unanswerable and tuning was guesswork. Field lesson
from this kit: you cannot tune a layer you do not measure.

One JSONL line per decision, appended to ~/.claude/hook-metrics.jsonl.
Read back by `scripts/hook-stats.sh`. Both hosts (Claude Code and Qwen Code)
write to the same file and are told apart by the "agent" field, so one report
covers the whole enforcement layer instead of two half-views.

Design constraints, in order:
  1. Never obstruct work — every failure path is swallowed (fail-open).
  2. Cheap — one short append per *decision*, not per invocation. Hooks that
     pass silently (the overwhelming majority) write nothing.
  3. No new PII — records the same project slug agent-stats already groups by,
     never file contents or command text.
"""
import os
import re
import json
import time

PATH = os.path.join(os.path.expanduser("~"), ".claude", "hook-metrics.jsonl")

# Test runs must never land in the production ledger. They used to: the suite
# fires every hook for real, ~50 synthetic block/nudge decisions per run, and
# they were indistinguishable from live enforcement afterwards -- 74% of the
# ledger (5025 of 6812 rows) turned out to be test output, which is why
# commit-attribution-guard read as 513 blocks when it had really fired twice.
# The suite exports this variable; nothing else sets it.
_ENV_OVERRIDE = "DAK_METRICS_FILE"


def _target():
    return os.environ.get(_ENV_OVERRIDE) or PATH

# Rotate at ~2MB (roughly 20k decisions). One generation is kept: enough to
# span a tuning cycle, bounded enough to never become a disk problem.
_MAX_BYTES = 2_000_000


def project_slug(cwd):
    """Match the ~/.claude/projects dir naming so stats join on one key."""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd or "")


def _rotate_if_large(path):
    try:
        if os.path.getsize(path) > _MAX_BYTES:
            os.replace(path, path + ".1")
    except OSError:
        pass


def record(hook, action, cwd=None, detail=None):
    """Append one decision record. Any error is swallowed by design.

    hook:   which hook fired, e.g. "crg-gate"
    action: what it decided, e.g. "block" / "nudge" / "findings"
    detail: optional low-cardinality qualifier, e.g. a domain or linter name
    """
    try:
        path = _target()
        _rotate_if_large(path)
        rec = {
            "ts": int(time.time()),
            "hook": hook,
            "action": action,
            "agent": os.environ.get("DAK_AGENT", "claude"),
            "project": project_slug(cwd or os.getcwd()),
        }
        if detail:
            rec["detail"] = str(detail)[:80]
        line = json.dumps(rec, separators=(",", ":")) + "\n"
        # Single write in append mode: short lines are atomic enough that
        # concurrent hooks never interleave in practice.
        with open(path, "a") as f:
            f.write(line)
    except Exception:
        pass
