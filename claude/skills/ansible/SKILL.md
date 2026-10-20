---
name: ansible
description: Ansible work — writing playbooks/roles/inventory, debugging failures (UNREACHABLE, MODULE FAILURE, undefined variables), converting shell scripts to playbooks, idempotency, vault, variable precedence. Use for ANY Ansible task before touching playbook code.
---

# Ansible Skills

<!-- gate:begin -->
**Baseline for every playbook, role, and task file.**

- **Modules, not shell.** `ansible.builtin.package/copy/template/service/file` instead of `command`/`shell`. When shell is genuinely unavoidable, give it `creates:`/`removes:` or a `changed_when:` so it stays idempotent.
- **Fully-qualified collection names** (`ansible.builtin.copy`, not `copy`).
- **Idempotency is the acceptance test:** a second run must report `changed=0`. If it can't, the task is wrong.
- **Name every task** — an unnamed task is unreadable in a failure log.
- **Handlers for restarts**, notified by the task that changed the config; never restart unconditionally.
- **Variable precedence** (low→high): role defaults → inventory vars → group_vars → host_vars → play vars → `-e` extra vars. Put overridable defaults in `defaults/main.yml`, never in `vars/`.
- **No secrets in plaintext** — ansible-vault or an external secret store.
- **`become:` only on the tasks that need it**, not blanket at play level.
- **Loops:** `loop:` with `label:` in `loop_control`, not the deprecated `with_*`.
- **Verify before reporting done:** `ansible-playbook --syntax-check`, then `--check --diff` against a real inventory when one exists. `ansible-lint` runs automatically on every playbook edit via the lint-on-edit hook — fix its findings immediately rather than moving on.
<!-- gate:end -->

## Depth

Pick the skill matching the task and read it now:

| Task | Path |
|------|------|
| Write/modify playbooks, roles, inventory | `~/.claude/extern/ansible-skills/skills/ansible-playbook/SKILL.md` |
| Debug failures (UNREACHABLE, module errors, undefined vars) | `~/.claude/extern/ansible-skills/skills/ansible-debug/SKILL.md` |
| Convert shell scripts to playbooks | `~/.claude/extern/ansible-skills/skills/ansible-convert/SKILL.md` |
| Guide a fresh Ansible setup | `~/.claude/extern/ansible-skills/skills/ansible-interactive/SKILL.md` |

Running against a real remote host? Pair with the `remote-ops` skill.
