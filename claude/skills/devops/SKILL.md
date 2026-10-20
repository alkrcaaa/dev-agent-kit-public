---
name: devops
description: Infrastructure and operations work — Kubernetes troubleshooting, CI/CD pipelines, Terraform/IaC, GitOps, AWS cost, monitoring/observability, Docker, Ansible, deployment scripts. Use for ANY infra, pipeline, or deployment task.
---

# DevOps Skills

<!-- gate:begin -->
**Baseline for anything that ships or runs infrastructure.**

Containers (Dockerfile / compose)
- Pinned base image (`python:3.12-slim`, not `latest`), non-root `USER`, no secrets baked into layers.
- One `HEALTHCHECK` that hits a real readiness endpoint — and the compose service must declare its own healthcheck/`depends_on: condition: service_healthy` if anything waits on it.
- Named volume for every path that must survive a container replacement (databases, uploads); a bind to a container-local path is data loss on redeploy.
- Secrets via env/secret store at runtime. A literal `change-me-in-production` default in a committed compose file is a finding — make it required and let startup fail without it.
- `.dockerignore` so `.venv/`, `.git/`, local DB files never enter the build context.
- **Build it before claiming it works** (`docker build .`, `docker compose config`). If the tool is unavailable, verify that first (`command -v docker`) and say so explicitly — never assume it is missing.

Pipelines
- Stage order fast→slow: lint → unit → integration → build → e2e → deploy, with approval gates before anything that touches production.
- Cache dependencies; pin action/image versions by tag or digest; least-privilege credentials (prefer OIDC over long-lived keys).

Terraform / K8s
- `terraform fmt` → `validate` → `plan` and read the plan before any apply; remote state with locking.
- K8s: every container sets resource requests/limits, liveness/readiness probes, and a non-root securityContext.

Shell entrypoints
- `#!/usr/bin/env bash`, `set -euo pipefail`, quote every expansion, `exec` the final process so signals reach PID 1. Run `shellcheck` on it — verify the tool's absence before excusing it.
<!-- gate:end -->

## Depth

Pick the topic matching the task and read its SKILL.md now:

| Topic | Path |
|-------|------|
| Kubernetes debugging | `~/.claude/extern/devops-claude-skills/k8s-troubleshooter/skills/SKILL.md` |
| CI/CD pipelines | `~/.claude/extern/devops-claude-skills/ci-cd/skills/SKILL.md` |
| Terraform / IaC | `~/.claude/extern/devops-claude-skills/iac-terraform/skills/SKILL.md` |
| GitOps workflows | `~/.claude/extern/devops-claude-skills/gitops-workflows/skills/SKILL.md` |
| AWS cost optimization | `~/.claude/extern/devops-claude-skills/aws-cost-optimization/skills/SKILL.md` |
| Monitoring / observability | `~/.claude/extern/devops-claude-skills/monitoring-observability/skills/SKILL.md` |

For dependency/supply-chain risk in CI, also see the `supply-chain-audit` skill.
For Ansible specifically, use the `ansible` skill. For work on a remote host or inside a
container over SSH, use `remote-ops`.
