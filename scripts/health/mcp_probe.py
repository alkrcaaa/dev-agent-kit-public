#!/usr/bin/env python3
"""mcp_probe.py — liveness probe for the MCP servers this kit installs.

Everything else in scripts/health/ checks that *files* say the right thing.
Nothing checked that a server actually answers, so a dead MCP looked identical
to a healthy one until an agent tried to call it mid-task. This speaks real
MCP to each configured server (initialize -> tools/list) and reports the tool
count it got back.

The tool count is not decoration. Qwen trims two servers via `includeTools`
(graph 30 -> 13, playwright 24 -> 14) because schemas ride in its 235k window
on every call, and until now that trim was only ever verified by grepping the
settings file. Probing the live server also catches an allowlist that has gone
stale — an `includeTools` entry naming a tool the server no longer exposes is
silently dropped by the client, so the file keeps looking correct.

Usage:
    mcp_probe.py [--host claude|qwen|both] [--timeout SECONDS]
    mcp_probe.py --list-expected      # name<TAB>scope, for doctor.sh

Exit status: 0 if no FAIL, 1 otherwise. stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

# ── Expected inventory ──────────────────────────────────────────────────────
# Scope decides how a missing server is judged. Without this a naive
# "configured vs documented" diff is pure noise: lsp, grafana and terraform are
# all absent from ~/.claude.json *by design*, and reporting them as failures
# every run is how a health check teaches you to ignore it.
#
#   global      — must be registered and answering; absence is a FAIL
#   conditional — only on hosts meeting a precondition (see PRECONDITIONS)
#   opt-in      — off unless deliberately enabled; probed if present
#   project     — lives in a repo's .mcp.json, never global; not probed here
EXPECTED = {
    "code-review-graph": "global",
    "playwright": "global",
    "fetch": "global",
    "mem-lite": "global",
    "local-model": "global",
    "GitLab": "opt-in",
    "lsp": "opt-in",
    "vault-search": "opt-in",
    "llm-council": "opt-in",
    "grafana": "project",
    "terraform": "project",
}

# A conditional server is only expected where its precondition holds.
PRECONDITIONS = {}

# Two globals are deliberately Claude-only, and demanding them on the Qwen side
# would be demanding a broken setup:
#   local-model — the offload server pointed at the vLLM host; registering it
#                 inside Qwen itself would let a Qwen session recurse into
#                 another one.
#   GitLab — authenticated by Claude Code's `/mcp` OAuth flow, which Qwen Code
#            has no equivalent for, so a Qwen-side entry could never authenticate.
CLAUDE_ONLY = {"local-model", "GitLab"}

CONFIGS = {
    "claude": Path.home() / ".claude.json",
    "qwen": Path.home() / ".qwen" / "settings.json",
}

PROTOCOL_VERSION = "2024-11-05"

# ── Output ──────────────────────────────────────────────────────────────────
_color = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
RED, GREEN, YELLOW, CYAN, BOLD, RESET = (
    ("\033[0;31m", "\033[0;32m", "\033[1;33m", "\033[0;36m", "\033[1m", "\033[0m")
    if _color
    else ("", "", "", "", "", "")
)

PASS = FAILED = WARNED = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  {GREEN}✓{RESET} {msg}")


def bad(msg: str) -> None:
    global FAILED
    FAILED += 1
    print(f"  {RED}✗{RESET} {msg}")


def warn(msg: str) -> None:
    global WARNED
    WARNED += 1
    print(f"  {YELLOW}!{RESET} {msg}")


def info(msg: str) -> None:
    print(f"  {CYAN}→{RESET} {msg}")


def section(msg: str) -> None:
    print(f"\n{BOLD}── {msg} ──{RESET}")


class ProbeError(Exception):
    """Server was found but could not be spoken to — counts as a failure."""


class Unverified(ProbeError):
    """Something answered, but not in a way we can read a tool list from.

    Same reasoning as `host_reachable` in scripts/lib/platform.sh: an HTTP
    status reply still proves a server is listening. The GitLab MCP sits behind
    OAuth and answers 404 until `/mcp` has authenticated the session, so
    treating any non-200 as death would make this check cry wolf on every run
    of a perfectly healthy setup. We have no evidence of breakage — warn.
    """


# ── stdio transport ─────────────────────────────────────────────────────────
def _requests() -> list[dict]:
    return [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "dev-agent-kit-probe", "version": "1"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]


def probe_stdio(spec: dict, timeout: float) -> list[str]:
    """Run the server as a subprocess and return the tool names it lists."""
    command = spec.get("command")
    if not command:
        raise ProbeError("no command in config")

    env = {**os.environ, **{k: str(v) for k, v in (spec.get("env") or {}).items()}}
    try:
        proc = subprocess.Popen(  # noqa: S603 — commands come from our own config
            [command, *spec.get("args", [])],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            cwd=spec.get("cwd") or None,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        raise ProbeError(f"command not found: {command}") from None
    except OSError as exc:
        raise ProbeError(f"cannot start: {exc}") from None

    # A server that never answers must not wedge the health check, so the read
    # happens on a daemon thread the main thread can walk away from.
    result: dict = {}

    def reader() -> None:
        try:
            for line in proc.stdout:  # type: ignore[union-attr]
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue  # some servers print banners before the protocol
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == 2:
                    result["reply"] = msg
                    return
        except (ValueError, OSError):
            pass  # pipe closed while we were reading

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    try:
        for req in _requests():
            proc.stdin.write(json.dumps(req) + "\n")  # type: ignore[union-attr]
            proc.stdin.flush()  # type: ignore[union-attr]
        thread.join(timeout)
    except (BrokenPipeError, OSError):
        raise ProbeError("server exited during handshake") from None
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    reply = result.get("reply")
    if reply is None:
        raise ProbeError(f"no tools/list reply within {timeout:g}s")
    if "error" in reply:
        raise ProbeError(f"server error: {reply['error'].get('message', reply['error'])}")
    return [t["name"] for t in reply.get("result", {}).get("tools", [])]


# ── HTTP transport ──────────────────────────────────────────────────────────
def _post(url: str, payload: dict, headers: dict, timeout: float):
    req = urllib.request.Request(  # noqa: S310 — URLs come from our own config
        url,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            **headers,
        },
        method="POST",
    )
    return urllib.request.urlopen(req, timeout=timeout)  # noqa: S310


def _decode(raw: bytes) -> dict | None:
    """Streamable HTTP answers as plain JSON or as an SSE frame."""
    text = raw.decode("utf-8", "replace").strip()
    if not text:
        return None
    if text.startswith("{"):
        return json.loads(text)
    for line in text.splitlines():
        if line.startswith("data:"):
            body = line[5:].strip()
            if body.startswith("{"):
                return json.loads(body)
    return None


def probe_http(url: str, extra_headers: dict, timeout: float) -> list[str]:
    init, _, listing = _requests()  # the initialized notification is stdio-only framing
    headers = dict(extra_headers)
    try:
        with _post(url, init, headers, timeout) as resp:
            session = resp.headers.get("mcp-session-id")
            if _decode(resp.read()) is None:
                raise ProbeError("initialize returned no JSON-RPC frame")
        if session:
            headers["Mcp-Session-Id"] = session
        with _post(url, listing, headers, timeout) as resp:
            reply = _decode(resp.read())
    except urllib.error.HTTPError as exc:
        raise Unverified(
            f"listening but returned HTTP {exc.code} — needs auth, or not streamable-HTTP"
        ) from None
    except urllib.error.URLError as exc:
        raise ProbeError(f"unreachable: {exc.reason}") from None
    except (TimeoutError, OSError) as exc:
        raise ProbeError(f"unreachable: {exc}") from None

    if reply is None:
        raise ProbeError("tools/list returned no JSON-RPC frame")
    if "error" in reply:
        raise ProbeError(f"server error: {reply['error'].get('message', reply['error'])}")
    return [t["name"] for t in reply.get("result", {}).get("tools", [])]


def probe(spec: dict, timeout: float) -> list[str]:
    url = spec.get("httpUrl") or (spec.get("url") if spec.get("type") == "http" else None)
    if url:
        return probe_http(url, spec.get("headers") or {}, timeout)
    return probe_stdio(spec, timeout)


# ── Reporting ───────────────────────────────────────────────────────────────
def load_servers(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text()).get("mcpServers", {}) or {}
    except (json.JSONDecodeError, OSError):
        return {}


def check_host(host: str, timeout: float) -> None:
    path = CONFIGS[host]
    section(f"MCP servers — {host} ({path})")

    if not path.is_file():
        warn(f"{path} not found — run: bash install.sh")
        return

    servers = load_servers(path)
    if not servers:
        warn(f"{path} declares no mcpServers")
        return

    for name in sorted(servers, key=str.lower):
        spec = servers[name]
        scope = EXPECTED.get(name)

        if scope is None:
            warn(f"{name}: registered but not in the expected inventory (update EXPECTED)")
            continue
        if scope == "project":
            info(f"{name}: project-scoped, unexpected in {path.name} — skipping probe")
            continue
        if host != "claude" and name in CLAUDE_ONLY:
            warn(f"{name}: registered on {host}, but it is Claude-only by design")
            continue

        try:
            tools = probe(spec, timeout)
        except Unverified as exc:
            warn(f"{name}: {exc}")
            continue
        except ProbeError as exc:
            met, why = PRECONDITIONS.get(name, (lambda: True, ""))
            if scope == "conditional" and not met():
                info(f"{name}: not expected here ({why})")
            elif scope == "opt-in":
                warn(f"{name}: opt-in server registered but not answering — {exc}")
            else:
                bad(f"{name}: {exc}")
            continue

        detail = f"{len(tools)} tools"
        allowed = spec.get("includeTools")
        if allowed:
            stale = sorted(set(allowed) - set(tools))
            detail += f", filtered → {len(allowed)}"
            if stale:
                # Silently dropped by the client — the settings file still
                # looks right, so only a live listing can catch this.
                warn(f"{name}: {detail}; includeTools names {len(stale)} tool(s) "
                     f"the server no longer exposes: {', '.join(stale)}")
                continue
        ok(f"{name}: {detail}")

    # Expected-but-absent, judged by scope.
    for name, scope in sorted(EXPECTED.items(), key=lambda kv: kv[0].lower()):
        if name in servers or scope == "project":
            continue
        if host != "claude" and name in CLAUDE_ONLY:
            info(f"{name}: Claude-only by design — not expected on {host}")
            continue
        if scope == "conditional":
            met, why = PRECONDITIONS.get(name, (lambda: True, ""))
            if met():
                bad(f"{name}: not registered in {path.name} — run: bash install.sh")
            else:
                info(f"{name}: absent, as expected on this host ({why})")
        elif scope == "opt-in":
            info(f"{name}: not registered (opt-in, off by default)")
        else:
            bad(f"{name}: not registered in {path.name} — run: bash install.sh")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", choices=["claude", "qwen", "both"], default="both")
    parser.add_argument("--timeout", type=float, default=20.0,
                        help="seconds to wait per server (default: 20)")
    parser.add_argument("--list-expected", action="store_true",
                        help="print 'name<TAB>scope' and exit — used by doctor.sh")
    args = parser.parse_args()

    if args.list_expected:
        for name, scope in EXPECTED.items():
            print(f"{name}\t{scope}")
        return 0

    hosts = ["claude", "qwen"] if args.host == "both" else [args.host]
    for host in hosts:
        # Probing a host we never installed would report a wall of failures for
        # a setup the user deliberately does not have.
        if args.host == "both" and not CONFIGS[host].is_file():
            section(f"MCP servers — {host}")
            info(f"{CONFIGS[host]} not present — skipping")
            continue
        check_host(host, args.timeout)

    print(f"\n  {BOLD}mcp-probe:{RESET} {GREEN}{PASS} ok{RESET}, "
          f"{RED}{FAILED} fail{RESET}, {YELLOW}{WARNED} warn{RESET}")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
