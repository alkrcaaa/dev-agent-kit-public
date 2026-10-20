---
name: remote-ops
description: Remote server/device work over SSH — docker exec into containers, builds inside containers, netplan/ethernet/VPN network changes, ROS2 commands on robots/Jetson devices. Use BEFORE any task touching a remote host, container internals, network config, or ROS2.
---

# Remote Ops — SSH, Docker, Network, ROS2
<!-- dev-agent-kit native skill -->

Core discipline: every command non-interactive, time-bounded, verified on the box.
A hung interactive prompt stalls the tool; a bad network change kills your own connection.

## SSH

- Always: `ssh -o BatchMode=yes -o ConnectTimeout=5 <host> '<cmd>'` — never a bare
  interactive `ssh <host>`, never commands that can prompt (`apt install` without `-y`).
- Orient first: `ssh <host> 'hostname && uname -a && uptime'` — confirm it's the right box
  before changing anything.
- Multi-step work: one quoted compound (`'cd /x && make && ls'`) or `ssh <host> bash -s <<EOF`.
- Long jobs (builds): `nohup <cmd> > /tmp/job.log 2>&1 &` then poll the log — don't hold
  the channel open; wrap quick commands in `timeout 30` as a habit.
- Files: `rsync -az` (resumable, deltas) over `scp`; `scp` only for single small files.
- Keep a record: the user wants SSH sessions recorded. Append every remote command and
  its output with `2>&1 | tee -a ~/ssh-logs/<host>-$(date +%F).log` (`mkdir -p ~/ssh-logs`
  once). When you hand the user an interactive session to run, wrap it:
  `asciinema rec ~/ssh-logs/<host>-$(date +%F-%H%M).cast -c 'ssh <host>'` (fall back to
  plain `ssh` and say so if `asciinema` is not installed).

## Docker

- NEVER `docker exec -it` — the TTY hangs the tool. Always:
  `docker exec <container> bash -lc '<cmd>'` (falls back to `sh -lc` on slim images).
- Discover before acting: `docker ps --format '{{.Names}}\t{{.Status}}'`,
  `docker logs --tail 100 <c>`, `docker inspect <c> --format '{{json .State}}'`.
- Build inside a container: `docker exec <c> bash -lc 'cd /ws && <build>'; echo exit=$?` —
  always capture the exit code, don't trust output alone.
- Files in/out: `docker cp`. Compose: `docker compose ps/logs/restart <svc>` —
  never `down`/`rm` without explicit user confirmation.

## Network config (netplan / eth / VPN) — HIGH RISK over SSH

- READ before touching: `ip -br a`, `ip route`, `cat /etc/netplan/*.yaml`, `resolvectl status`.
- Identify which interface carries YOUR session: `ip route get <client-ip>` — if the change
  touches that interface, warn the user and get confirmation first.
- Always back up: `cp /etc/netplan/x.yaml /etc/netplan/x.yaml.bak.$(date +%s)` before editing;
  validate with `netplan get` after.
- Prefer `netplan try --timeout 60` (auto-rollback if connectivity dies). From a
  non-interactive session it can't be confirmed — then use apply with a safety net:
  `nohup bash -c 'sleep 120 && cp <backup> <file> && netplan apply' & netplan apply`
  → verify → kill the rollback job. Never a bare `netplan apply` on your own uplink.
- VPN state: `wg show` / `systemctl status openvpn@<name>` / `ip route` for pushed routes.
- After any change verify BOTH directions: from the box out (`ping -c2 <gw>`,
  `resolvectl query <domain>`) and a fresh SSH connection in.

## ROS2

- Non-interactive shells don't source ROS. Prefix EVERY ros2/colcon command:
  `bash -lc 'source /opt/ros/<distro>/setup.bash && source install/setup.bash 2>/dev/null; <cmd>'`
- Streaming commands run forever — always bound them:
  `ros2 topic echo --once <topic>`, `timeout 5 ros2 topic hz <topic>`.
- Introspection order: `ros2 node list` → `ros2 topic list` → `ros2 topic info/echo --once` →
  `ros2 param list/get`. Nodes invisible to each other → check `ROS_DOMAIN_ID` and
  `RMW_IMPLEMENTATION` match across shells/devices before debugging anything else.
- Build: `colcon build --symlink-install --packages-select <pkg>`; on failure read
  `log/latest_build/<pkg>/stdout_stderr.log`, not just the summary.
- Jetson/embedded: before long builds check headroom — `tegrastats` one-shot or `free -h`,
  `df -h`; OOM mid-build wastes 20 minutes.

## Report format

Host + what changed + verification output (the actual command result, not "should work").
