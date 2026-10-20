#!/usr/bin/env python3
"""
session-size-nudge hook (UserPromptSubmit).

The single biggest token cost in field data is mega-sessions: one
transcript reached 1955 API calls at ~362k context tokens per call —
every call re-bills the whole history. The user adopted a
fresh-session-per-task habit but needs the reminder at the decision
point, not in a doc.

When the transcript crosses a size threshold (2/4/8/16/32/64 MB), emit
JSON with BOTH channels — once per threshold, so it never nags twice at
the same level:

  systemMessage       -> rendered directly to the USER in the UI. Plain
                         stdout only reaches the model's context, which
                         is why the v1 nudge felt invisible.
  additionalContext   -> injected for the model, so it also steers the
                         session toward a wrap-up point.

From 8MB up the wording escalates: stop suggesting "when the task wraps
up" and recommend breaking off now. (Lowered from 16MB — field data showed
mega-sessions settling at 4.5-8.8MB, under the old threshold, so they never
got past the soft nudge.)

Two signals, whichever trips first:

  transcript MB      — cheap, always available, and the only signal that
                       catches a transcript bloated by huge tool results.
  context per call   — what actually gets re-billed. Measured over 52
                       sessions (2026-08-08): MB correlates at only r=0.81
                       and the bands overlap exactly where the decision is
                       made — sessions under 250k context span 0.1-7.9MB,
                       those over span 3.7-11.2MB. MB alone both cries wolf
                       (7.9MB at 119k/call) and misses the expensive case
                       (4.0MB at 382k/call, among the priciest runs in the
                       whole dataset, yet never reaching the 8MB escalation).

Context thresholds come from the same measurement: 101-500 call sessions
averaged 191k/call, 500+ call sessions averaged 347k/call, and those 13
mega-sessions carried 84% of all context tokens. 200k is the approach
warning; 300k means the expensive regime has already started.

Both hosts are covered. The transcript formats differ (Claude nests
message.usage, Qwen writes a flat usageMetadata.promptTokenCount) so
_record_context reads either. On Qwen the tokens are free — the wording
shifts from "re-bills" to the context window filling up, which is the
quality cost that actually applies to a local model.

Escape hatch: `export SESSION_NUDGE_OFF=1`. Fail-open on any error.
"""
import hashlib
import json
import os
import sys
import tempfile

import agent_env

THRESHOLDS_MB = (2, 4, 8, 16, 32, 64)
ESCALATE_MB = 8

# Context-per-call thresholds, in thousands of tokens. Claude's are absolute
# because its ceiling is money, not a wall: a 700k-per-call session bills a
# fortune but still runs. Qwen's ceiling IS a wall — past sessionTokenLimit the
# vLLM server starts refusing requests — and it sits at ~235k, below three of
# these four steps. Left absolute, the escalation would never once fire on the
# host where crossing the line actually breaks the session, so on Qwen the
# steps are derived from the configured limit instead. See _ctx_thresholds.
THRESHOLDS_CTX_K = (200, 300, 450, 700)
ESCALATE_CTX_K = 300

# Fractions of the host's own token limit, used on Qwen. 80% is the escalation
# point: far enough out that there is still room to checkpoint state to
# mem-lite and hand over before requests start failing.
_QWEN_FRACTIONS = (0.50, 0.65, 0.80, 0.90)
_QWEN_ESCALATE_FRACTION = 0.80

# Only consulted if the settings file names neither a session limit nor a
# window — a default vLLM qwen3 deployment.
_QWEN_FALLBACK_LIMIT = 262_144


def _qwen_token_limit():
    """The session's hard token ceiling, from Qwen's own settings."""
    path = os.path.join(os.path.expanduser("~"), ".qwen", "settings.json")
    try:
        with open(path) as f:
            model = json.load(f).get("model") or {}
    except Exception:
        return _QWEN_FALLBACK_LIMIT
    limit = model.get("sessionTokenLimit")
    if not limit:
        # No explicit session limit: the window itself is the wall.
        limit = (model.get("generationConfig") or {}).get("contextWindowSize")
    return limit or _QWEN_FALLBACK_LIMIT


def _ctx_thresholds():
    """(steps, escalate) in thousands of tokens, for whichever host this is.

    Only Qwen's local vLLM deployment has a hard token wall; Claude and
    Antigravity are both hosted APIs where the ceiling is cost, not a wall
    the host will start refusing requests at, so they share the absolute
    thresholds.
    """
    if agent_env.AGENT != "qwen":
        return THRESHOLDS_CTX_K, ESCALATE_CTX_K
    limit_k = _qwen_token_limit() / 1000.0
    steps = tuple(int(limit_k * f) for f in _QWEN_FRACTIONS)
    return steps, int(limit_k * _QWEN_ESCALATE_FRACTION)

# How much of the transcript tail to scan for the newest usage record. The
# file can exceed 10MB and this hook runs on every prompt, so it is never read
# whole; a single API call's record is far smaller than this window.
_TAIL_BYTES = 262_144


def _record_context(rec):
    """Context tokens for one transcript record, across both host formats.

    Claude:  message.usage.{input,cache_read_input,cache_creation_input}_tokens
    Qwen:    usageMetadata.promptTokenCount (one flat prompt-side figure)
    """
    usage = (rec.get("message") or {}).get("usage") or {}
    if usage:
        return (usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0))
    meta = rec.get("usageMetadata") or {}
    return meta.get("promptTokenCount", 0)


def _context_per_call(path):
    """Context tokens resent on the most recent API call, or None if unknown."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > _TAIL_BYTES:
                f.seek(size - _TAIL_BYTES)
                f.readline()          # discard the partial first line
            chunk = f.read()
    except OSError:
        return None

    for raw in reversed(chunk.splitlines()):
        if b'"usage"' not in raw and b'"usageMetadata"' not in raw:
            continue
        try:
            rec = json.loads(raw)
        except Exception:
            continue                  # truncated or partial line
        total = _record_context(rec)
        if total > 1000:              # skip tiny bookkeeping calls
            return total
    return None


def main():
    if os.environ.get("SESSION_NUDGE_OFF"):
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tp = data.get("transcript_path") or ""
    if not tp or not os.path.isfile(tp):
        sys.exit(0)
    try:
        mb = os.path.getsize(tp) / 1e6
    except OSError:
        sys.exit(0)

    mb_level = 0
    for t in THRESHOLDS_MB:
        if mb >= t:
            mb_level = t

    ctx_steps, ctx_escalate = _ctx_thresholds()
    ctx_tokens = _context_per_call(tp)
    ctx_k = round(ctx_tokens / 1000) if ctx_tokens else 0
    ctx_level = 0
    for t in ctx_steps:
        if ctx_k >= t:
            ctx_level = t

    if not mb_level and not ctx_level:
        sys.exit(0)

    escalate = mb_level >= ESCALATE_MB or ctx_level >= ctx_escalate

    sid = data.get("session_id") or tp
    key = hashlib.sha1(sid.encode("utf-8", "replace")).hexdigest()[:16]
    marker = os.path.join(tempfile.gettempdir(), "session-size-%s.notified" % key)

    # Highest level already announced on each axis, so crossing a new
    # threshold on EITHER one still nudges exactly once. A bare integer is
    # the v2 format (MB only) — read it as the MB level so an in-flight
    # session upgrading to this version does not re-nudge from zero.
    seen_mb = seen_ctx = 0
    try:
        with open(marker) as f:
            raw = f.read().strip()
        if raw.startswith("{"):
            prev = json.loads(raw)
            seen_mb = int(prev.get("mb", 0))
            seen_ctx = int(prev.get("ctx", 0))
        elif raw:
            seen_mb = int(raw)
    except (OSError, ValueError, TypeError):
        pass

    if mb_level <= seen_mb and ctx_level <= seen_ctx:
        sys.exit(0)  # already nudged at these levels

    try:
        with open(marker, "w") as f:
            json.dump({"mb": max(mb_level, seen_mb),
                       "ctx": max(ctx_level, seen_ctx)}, f)
    except OSError:
        sys.exit(0)

    # Lead with whichever signal actually tripped: the token figure is the
    # one the user can act on, MB is only a proxy for it.
    if ctx_k:
        size = "~%dk tokens per call (transcript ~%dMB)" % (ctx_k, round(mb))
    else:
        size = "a ~%dMB transcript" % round(mb)

    # Same measurement, different stake per host. On Claude and Antigravity
    # (both hosted APIs) the cost is money: every call re-bills the whole
    # transcript. On Qwen's local vLLM the tokens are free but the context
    # window is not — a session this size is crowding out the window and
    # degrading answer quality, which is what the user cares about there.
    is_qwen = agent_env.AGENT == "qwen"
    verb = "carries" if is_qwen else "re-bills"
    stake = ("into every call — the context window is filling up" if is_qwen
             else "on every single call")
    # The remedy is host-specific: Qwen can /compress and keep going; Claude
    # and Antigravity have no in-session recovery command to name. Naming the
    # wrong command here is the whole value of the nudge lost at the moment it
    # finally fires.
    remedy = "/compress, or /exit and start fresh" if is_qwen else "/exit and start fresh"

    if escalate:
        wall = (" Past ~%dk the vLLM server starts refusing requests."
                % (_qwen_token_limit() // 1000)) if is_qwen else ""
        user_msg = (
            "⚠️  This session %s %s %s.%s Break off now: "
            "%s (mem-lite carries the context over)."
            % (verb, size, stake, wall, remedy)
        )
        model_ctx = (
            "[session] This session %s %s — past healthy size.%s Steer to a "
            "stopping point: finish or checkpoint the current step, save state "
            "to mem-lite, and tell the user this is a good moment to %s and "
            "continue." % (verb, size, wall, remedy)
        )
    else:
        user_msg = (
            "💡 This session %s %s %s. When this task wraps "
            "up, start the next one in a fresh session (mem-lite carries the "
            "context over)." % (verb, size, stake)
        )  # non-escalated: the advice is the same on both hosts
        model_ctx = (
            "[session] This session %s %s %s. When the current "
            "task wraps up, suggest the user start a fresh session for the next "
            "one (mem-lite carries the context over)." % (verb, size, stake)
        )

    try:
        import hook_metrics
        hook_metrics.record("session-size-nudge", "nudge", data.get("cwd"),
                            "%dMB/%dk%s" % (round(mb), ctx_k,
                                            "!" if escalate else ""))
    except Exception:
        pass

    print(json.dumps({
        "systemMessage": user_msg,
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": model_ctx,
        },
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
