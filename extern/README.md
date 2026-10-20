# Extern

Git submodules containing external skill libraries used by agents. 11 submodules, all actively used.

Skills are markdown files that agents load as context at task start — they provide specialized knowledge the base model doesn't apply by default.

MCP server submodules (not skill libraries) live under [`mcp-infra/`](../mcp-infra/) instead — e.g. `mcp-infra/local-model-mcp/`, `mcp-infra/code-review-graph/`.

## Submodules

| Directory | Used By | Purpose | License |
|-----------|---------|---------|---------|
| `andrej-karpathy-skills/` | All agents | 4 behavioral rules: Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution | — |
| `claude-code-owasp/` | ` @security` | OWASP Top 10:2025, LLM01-LLM10, ASI01-ASI10, ASVS 5.0, 20+ language security quirks | MIT |
| `devops-claude-skills/` | ` @ops` | K8s troubleshooting, Terraform patterns, AWS cost optimization, CI/CD, GitOps, monitoring | — |
| `open-design/` | ` @designer` | 90+ design patterns — dashboards, pitch decks, mobile screens, social carousels | Apache 2.0 |
| `skills/` | ` @general-purpose`, ` @tester` | Anthropic reference skills: frontend design, API examples, skill templates | per skill (`skills/*/LICENSE.txt`) |
| `trailofbits-skills/` | ` @security`, ` @reviewer`, ` @tester`, ` @general-purpose` | Security and QA plugins: static-analysis, supply-chain-risk-auditor, insecure-defaults, sharp-edges, differential-review, testing-handbook-skills, semgrep-rule-creator | CC BY-SA 4.0 |
| `drawio-skill/` | ` @general-purpose`, ` @designer` | Draw.io diagrams from natural language — architecture, UML, ER, network, ML/DL; 10,000+ shapes; auto-layout; code→diagram | MIT |
| `ansible-skills/` | ` @ops`, ` @general-purpose` | Ansible playbook writing, debugging, shell→playbook conversion | MIT |
| `taste-skill/` | ` @designer`, ` @general-purpose` | Anti-slop design: taste-skill (landing/portfolio, design-read + 3 dials), redesign-skill (audit + upgrade existing generic UIs), aesthetic variants (soft/minimalist/brutalist) | MIT |
| `skills-cli/` | ` @general-purpose` | `npx skills` — discovers and (with user go-ahead) installs third-party skills from the open agent-skills ecosystem for capabilities not already covered here | MIT |
| `obsidian-vault-bridge/` | hooks (obsidian-mirror, vault-inject, personal-capture) | vault-search MCP + two-way Obsidian vault sync, not an agent skill library | — |

## Skill → Agent Mapping

### @security
- `claude-code-owasp/` — primary vulnerability reference (OWASP, ASVS, CWE mapping)
- `trailofbits-skills/plugins/static-analysis/` — Semgrep patterns, code smell detection
- `trailofbits-skills/plugins/supply-chain-risk-auditor/` — dependency CVE checks
- `trailofbits-skills/plugins/insecure-defaults/` — config anti-patterns
- `trailofbits-skills/plugins/sharp-edges/` — dangerous API footguns
- `trailofbits-skills/plugins/semgrep-rule-creator/` — custom rules for project-specific patterns

### @reviewer
- `trailofbits-skills/plugins/differential-review/` — diff-focused review methodology

### @tester
- `trailofbits-skills/plugins/testing-handbook-skills/` — unit vs integration vs property-based, flakiness prevention

### @ops
- `devops-claude-skills/` — IaC, CI/CD, container, observability patterns

### @designer
- `open-design/skills/` — HTML/CSS design patterns and templates
- `skills/skills/frontend-design/` — production-quality frontend principles
- `taste-skill/skills/` — anti-slop landing/portfolio design + redesign audits
- `drawio-skill/skills/drawio-skill/SKILL.md` — draw.io XML diagrams, export to PNG/SVG/PDF
- `skills-cli/skills/find-skills/SKILL.md` — discover/install third-party skills

### All agents
- `andrej-karpathy-skills/` — behavioral guardrails loaded at every task start

## Installation

```bash
git submodule update --init --recursive
```

## License

Each submodule is distributed under its own license. See each subdirectory's `LICENSE` file.
