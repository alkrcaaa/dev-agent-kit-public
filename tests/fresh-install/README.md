# Fresh-machine install test

Answers one question the other test suites structurally cannot: **does
`install.sh` work on a machine that is not this one?**

```bash
bash tests/fresh-install/fresh-install-test.sh
```

~15 minutes, needs Docker and network. Works from a git worktree too.
`DAK_SKIP_PLAYWRIGHT_BROWSER=1` / `DAK_SKIP_EMBEDDINGS=1` are passed through
to the installer for a faster run on a slow link. Not part of the per-push battery — run
it after touching `install.sh` or anything under `scripts/lib/`.

## Why it exists

The other suites source the library functions and check their behaviour. They
all passed while a from-scratch install was, in fact, broken in three separate
ways — because the development machine had accumulated state that the
installer never actually creates.

The sharpest example: Claude Code reads `~/.claude.json`, while every writer
in this kit targets `~/.claude/claude.json`. On the original host those are one
file, via a symlink made by hand in May 2026 and long forgotten. On a fresh
machine they are two files, so every MCP the installer registered was invisible
to Claude Code — and `verify_install` inspected the same unread file and
reported `✓ Installation complete!`. A green install, a green test suite, and
nothing working. Only a machine with no history could show that.

## What it does

`Dockerfile` builds a stock `ubuntu:24.04` with only what a new box plus a
human's first five minutes would have: `git`, `curl`, `sudo`, `python3`. No
`~/.claude`, no `.env`, no nvm/npm/pipx/uv, no symlinks. `unzip` is absent on
purpose — its absence is what first exposed the `tflint` step aborting the
whole install.

`run-in-container.sh` clones the repo from a read-only bind mount, replays any
**uncommitted** changes on top (a plain clone carries committed `HEAD` only,
which quietly tests the previous version), runs `install.sh`, then asserts:

- `install.sh` finishes inside `DAK_FRESH_TIMEOUT` (default 2700s), with
  stdin on `/dev/null` — a hidden prompt or stalled download fails this
  instead of hanging the test
- `install.sh` exits 0
- Claude, Qwen and Antigravity each have >0 hooks registered, and the
  verification step printed its per-host hook count
- the `obsidian-vault-bridge` submodule cloned (the mirror hook script
  resolves through `~/.claude/extern`) and no submodule was left empty
- with no `.env` and no vault, the install printed `VAULT NOT CONFIGURED`
  and wrote no `vault.env`
- `~/.claude.json` and `~/.claude/claude.json` resolve to the same file
- `code-review-graph`, `playwright`, `fetch` and `mem-lite` are registered
  **in the file Claude Code reads**, not the one the installer wrote to
- agents and skills are deployed
- the `extern` symlink resolves and is non-empty

Host-conditional servers (`qwen`, `GitLab`) are not asserted: whether
they register depends on what the container can reach from the network it
happens to be on.

## Reading a failure

The driver prints the assertion block and points at the full log. Work
backwards from the first `FAIL` — and check the install log for a step that
died rather than warned, since a single unguarded optional dependency can end
the run before MCP setup, agent deployment and verification ever happen.
