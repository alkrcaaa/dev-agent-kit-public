#!/usr/bin/env bash
# sourced — not executed directly

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

_verify_templates() {
  section "Template Verification"

  local src_file="$REPO_ROOT/claude/CLAUDE.md"
  [[ -f "$src_file" ]] || fail "CLAUDE.md template not found: $src_file"
  ok "claude/CLAUDE.md"
}

_deploy_claude_md() {
  local dst="$CLAUDE_CONFIG_DIR/CLAUDE.md"
  local src="$REPO_ROOT/claude/CLAUDE.md"

  mkdir -p "$CLAUDE_CONFIG_DIR"

  if [[ -f "$dst" ]]; then
    local backup_dir="$CLAUDE_CONFIG_DIR/backups"
    local backup_path
    backup_path="$backup_dir/CLAUDE.md.backup.$(date +%s)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_path"
    info "Backup: $backup_path"
  fi

  cp "$src" "$dst"
  ok "claude/CLAUDE.md -> $dst"
}

# The kit's own subagents were removed (Claude/Qwen/Antigravity; Codex keeps
# its own). Drop the copies older installs left behind — by name only, so a
# user's own agent files in the same directory are never touched.
_KIT_AGENTS=(designer general-purpose ops reviewer security tester)

_retire_agents() {
  local dst_dir="$1" label="$2" name removed=0
  for name in "${_KIT_AGENTS[@]}"; do
    [[ -f "$dst_dir/$name.md" ]] || continue
    rm -f "$dst_dir/$name.md" && removed=$((removed + 1))
  done
  [[ $removed -gt 0 ]] && ok "removed $removed retired $label agent(s) from $dst_dir"
  return 0
}

_deploy_extern_symlink() {
  local extern_src="$REPO_ROOT/extern"
  local extern_dst="$CLAUDE_CONFIG_DIR/extern"

  [[ -d "$extern_src" ]] || { warn "extern/ not found, skipping symlink"; return; }

  ln -sfn "$extern_src" "$extern_dst"
  ok "extern skills -> $extern_dst"
}

# The delegate CLI was removed; drop the symlink older installs still carry.
_retire_delegate() {
  local dst="$HOME/.local/bin/delegate"
  # Only our own symlink: an unrelated ~/.local/bin/delegate is left alone.
  if [[ -L "$dst" && "$(readlink "$dst")" == */team/delegate.py ]]; then
    rm -f "$dst" && ok "removed retired delegate symlink"
  fi
  return 0
}

QWEN_CONFIG_DIR="${QWEN_CONFIG_DIR:-$HOME/.qwen}"

_deploy_qwen_md() {
  local dst="$QWEN_CONFIG_DIR/QWEN.md"
  local src="$REPO_ROOT/qwen/QWEN.md"

  [[ -f "$src" ]] || { warn "QWEN.md template not found: $src"; return; }
  mkdir -p "$QWEN_CONFIG_DIR"

  if [[ -f "$dst" ]]; then
    local backup_dir="$QWEN_CONFIG_DIR/backups"
    local backup_path
    backup_path="$backup_dir/QWEN.md.backup.$(date +%s)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_path"
    info "Backup: $backup_path"
  fi

  cp "$src" "$dst"
  ok "qwen/QWEN.md -> $dst"
}

_deploy_qwen_hooks() {
  # Same hook sources as Claude — agent_env.py adapts tool names and output
  # channels at runtime, so there is exactly one copy to maintain. Only the
  # wiring (qwen/settings.json) differs, because Qwen's hook matchers match
  # its own wire tool names and nothing else.
  local src="$REPO_ROOT/claude/hooks"
  local dst="$QWEN_CONFIG_DIR/hooks"

  [[ -d "$src" ]] || { warn "claude/hooks/ not found, skipping qwen hooks"; return; }

  mkdir -p "$dst"
  cp "$src"/*.py "$dst"/ 2>/dev/null || true
  chmod +x "$dst"/*.py 2>/dev/null || true
  ok "hook scripts -> $dst"
}

_deploy_qwen_settings_json() {
  local src="$REPO_ROOT/qwen/settings.json"
  local dst="$QWEN_CONFIG_DIR/settings.json"

  [[ -f "$src" ]] || { warn "qwen/settings.json not found, skipping"; return; }

  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    ok "qwen/settings.json -> $dst (created)"
    return
  fi

  # Merge hooks only — the live file also holds mcpServers, auth, model and
  # UI settings that must survive untouched.
  python3 - "$src" "$dst" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    src = json.load(f)
with open(sys.argv[2]) as f:
    dst = json.load(f)

for event, entries in src.get("hooks", {}).items():
    dst_hooks = dst.setdefault("hooks", {}).setdefault(event, [])
    existing = {h["command"] for e in dst_hooks for h in e.get("hooks", [])}
    for entry in entries:
        new_cmds = {h["command"] for h in entry.get("hooks", [])}
        if not new_cmds.issubset(existing):
            dst_hooks.append(entry)

with open(sys.argv[2], "w") as f:
    json.dump(dst, f, indent=2)
    f.write("\n")
PYEOF

  ok "qwen/settings.json hooks merged -> $dst"
}

_deploy_qwen_skills() {
  # Qwen Code discovers SKILL.md skills in ~/.qwen/skills, the same layout
  # Claude uses — so the kit's skills deploy verbatim to both.
  local src_dir="$REPO_ROOT/claude/skills"
  local dst_dir="$QWEN_CONFIG_DIR/skills"

  [[ -d "$src_dir" ]] || { warn "claude/skills/ not found, skipping qwen skills"; return; }
  mkdir -p "$dst_dir"

  local legacy_skills=("mcp")  # renamed → mcp-builder

  for deployed in "$dst_dir"/*/; do
    [[ -d "$deployed" ]] || continue
    local base
    base=$(basename "$deployed")
    [[ -d "$src_dir/$base" ]] && continue

    local is_legacy=0
    for legacy in "${legacy_skills[@]}"; do
      [[ "$base" == "$legacy" ]] && { is_legacy=1; break; }
    done

    if [[ $is_legacy -eq 1 ]] || grep -q '\.claude/extern\|dev-agent-kit' "$deployed/SKILL.md" 2>/dev/null; then
      rm -rf "$deployed"
      warn "Removed stale qwen skill: $base"
    fi
  done

  local count=0
  for d in "$src_dir"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    local base
    base=$(basename "$d")
    mkdir -p "$dst_dir/$base"
    cp "$d"/* "$dst_dir/$base/"
    count=$((count + 1))
  done

  ok "$count skill(s) deployed to $dst_dir"
}

_deploy_qwen_extern_symlink() {
  local extern_src="$REPO_ROOT/extern"
  local extern_dst="$QWEN_CONFIG_DIR/extern"

  [[ -d "$extern_src" ]] || { warn "extern/ not found, skipping qwen symlink"; return; }

  ln -sfn "$extern_src" "$extern_dst"
  ok "extern skills -> $extern_dst"
}

ANTIGRAVITY_CONFIG_DIR="${ANTIGRAVITY_CONFIG_DIR:-$HOME/.gemini/config}"

ANTIGRAVITY_HOME_DIR="${ANTIGRAVITY_HOME_DIR:-$HOME/.gemini}"

# GEMINI.md is the global-rules half of Antigravity's CLAUDE.md equivalent
# (Identity/Core Principles/Delegation/Qwen/Project Memory/MCP Inventory) —
# antigravity/AGENTS.md below is the leaner per-task checklist half. Until
# 2026-09-05 GEMINI.md only existed hand-authored at $ANTIGRAVITY_HOME_DIR,
# with no repo source and no deploy step, unlike claude/CLAUDE.md's
# _deploy_claude_md — so edits had no version history and wouldn't survive a
# fresh install. Mirrors _deploy_claude_md exactly.
_deploy_gemini_md() {
  local dst="$ANTIGRAVITY_HOME_DIR/GEMINI.md"
  local src="$REPO_ROOT/antigravity/GEMINI.md"

  [[ -f "$src" ]] || { warn "antigravity/GEMINI.md not found, skipping"; return; }
  mkdir -p "$ANTIGRAVITY_HOME_DIR"

  if [[ -f "$dst" ]]; then
    local backup_dir="$ANTIGRAVITY_HOME_DIR/backups"
    local backup_path
    backup_path="$backup_dir/GEMINI.md.backup.$(date +%s)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_path"
    info "Backup: $backup_path"
  fi

  cp "$src" "$dst"
  ok "antigravity/GEMINI.md -> $dst"
}

_deploy_antigravity_agents_md() {
  local dst="$ANTIGRAVITY_CONFIG_DIR/AGENTS.md"
  local src="$REPO_ROOT/antigravity/AGENTS.md"

  [[ -f "$src" ]] || { warn "antigravity/AGENTS.md not found, skipping"; return; }
  mkdir -p "$ANTIGRAVITY_CONFIG_DIR"

  if [[ -f "$dst" ]]; then
    local backup_dir="$ANTIGRAVITY_CONFIG_DIR/backups"
    local backup_path
    backup_path="$backup_dir/AGENTS.md.backup.$(date +%s)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_path"
    info "Backup: $backup_path"
  fi

  cp "$src" "$dst"
  ok "antigravity/AGENTS.md -> $dst"
}

_deploy_antigravity_hooks() {
  # Same hook sources as Claude/Qwen — agent_env.py adapts tool names and
  # output channels at runtime (Antigravity's native wire names, e.g.
  # view_file/write_to_file/run_command, are distinct from Qwen's Gemini-CLI
  # names — see agent_env.py's module docstring). Only the wiring
  # (antigravity/hooks.json) differs.
  local src="$REPO_ROOT/claude/hooks"
  local dst="$ANTIGRAVITY_CONFIG_DIR/hooks"

  [[ -d "$src" ]] || { warn "claude/hooks/ not found, skipping antigravity hooks"; return; }

  mkdir -p "$dst"
  cp "$src"/*.py "$dst"/ 2>/dev/null || true
  chmod +x "$dst"/*.py 2>/dev/null || true
  ok "hook scripts -> $dst"
}

_deploy_antigravity_hooks_json() {
  local dst="$ANTIGRAVITY_CONFIG_DIR/hooks.json"
  local src="$REPO_ROOT/antigravity/hooks.json"

  [[ -f "$src" ]] || { warn "antigravity/hooks.json not found, skipping"; return; }
  mkdir -p "$ANTIGRAVITY_CONFIG_DIR"

  # Overwrite, not merge — same first-cut simplicity as
  # _configure_antigravity_mcp: no live Antigravity install has hand-edited
  # this file yet. Add a merge (like _deploy_qwen_settings_json) once one does.
  cp "$src" "$dst"
  ok "antigravity/hooks.json -> $dst"
}

_deploy_antigravity_skills() {
  # Antigravity discovers SKILL.md skills the same way Claude/Qwen do, per
  # antigravity.google/docs (global: ~/.gemini/config/skills/) — so the kit's
  # skills deploy verbatim.
  local src_dir="$REPO_ROOT/claude/skills"
  local dst_dir="$ANTIGRAVITY_CONFIG_DIR/skills"

  [[ -d "$src_dir" ]] || { warn "claude/skills/ not found, skipping antigravity skills"; return; }
  mkdir -p "$dst_dir"

  local legacy_skills=("mcp")  # renamed → mcp-builder

  for deployed in "$dst_dir"/*/; do
    [[ -d "$deployed" ]] || continue
    local base
    base=$(basename "$deployed")
    [[ -d "$src_dir/$base" ]] && continue

    local is_legacy=0
    for legacy in "${legacy_skills[@]}"; do
      [[ "$base" == "$legacy" ]] && { is_legacy=1; break; }
    done

    if [[ $is_legacy -eq 1 ]] || grep -q '\.claude/extern\|dev-agent-kit' "$deployed/SKILL.md" 2>/dev/null; then
      rm -rf "$deployed"
      warn "Removed stale antigravity skill: $base"
    fi
  done

  local count=0
  for d in "$src_dir"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    local base
    base=$(basename "$d")
    mkdir -p "$dst_dir/$base"
    cp "$d"/* "$dst_dir/$base/"
    count=$((count + 1))
  done

  ok "$count skill(s) deployed to $dst_dir"
}

_deploy_antigravity_extern_symlink() {
  local extern_src="$REPO_ROOT/extern"
  local extern_dst="$ANTIGRAVITY_CONFIG_DIR/extern"

  [[ -d "$extern_src" ]] || { warn "extern/ not found, skipping antigravity symlink"; return; }

  ln -sfn "$extern_src" "$extern_dst"
  ok "extern skills -> $extern_dst"
}

_deploy_skills() {
  local src_dir="$REPO_ROOT/claude/skills"
  local dst_dir="$CLAUDE_CONFIG_DIR/skills"

  [[ -d "$src_dir" ]] || { warn "claude/skills/ not found, skipping"; return; }
  mkdir -p "$dst_dir"

  # Skills we deployed under an older name. These predate the marker below, so
  # they survive the stale sweep — and a leftover one can shadow a BUILT-IN
  # slash command (a stale "mcp" skill hijacked /mcp). Purge them by name.
  local legacy_skills=("mcp")  # renamed → mcp-builder

  # Remove stale skills that no longer exist in source. Only ones we own:
  # kit wrappers reference ~/.claude/extern, native kit skills carry a
  # "dev-agent-kit" marker — user-made skills have neither.
  for deployed in "$dst_dir"/*/; do
    [[ -d "$deployed" ]] || continue
    local base
    base=$(basename "$deployed")
    [[ -d "$src_dir/$base" ]] && continue

    local is_legacy=0
    for legacy in "${legacy_skills[@]}"; do
      [[ "$base" == "$legacy" ]] && { is_legacy=1; break; }
    done

    if [[ $is_legacy -eq 1 ]] || grep -q '\.claude/extern\|dev-agent-kit' "$deployed/SKILL.md" 2>/dev/null; then
      rm -rf "$deployed"
      warn "Removed stale skill: $base"
    fi
  done

  local count=0
  for d in "$src_dir"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    local base
    base=$(basename "$d")
    mkdir -p "$dst_dir/$base"
    cp "$d"/* "$dst_dir/$base/"
    count=$((count + 1))
  done

  ok "$count skill(s) deployed to $dst_dir"
}

_deploy_hooks_scripts() {
  local src="$REPO_ROOT/claude/hooks"
  local dst="$CLAUDE_CONFIG_DIR/hooks"

  [[ -d "$src" ]] || return 0

  mkdir -p "$dst"
  cp "$src"/* "$dst"/ 2>/dev/null || true
  chmod +x "$dst"/*.py "$dst"/*.sh 2>/dev/null || true
  ok "hook scripts -> $dst"
}

# The bridge hooks are wired into every host whether or not a vault is set,
# and with no VAULT_DIR / MEM_OBSIDIAN_VAULT they exit quietly -- so a machine
# without them looks installed and simply never writes a note. Loud, not
# fatal: running without a vault is a legitimate choice. Prints nothing when
# the bridge is absent (that has its own warning in init_submodules).
_warn_vault_unset() {
  [[ -f "$REPO_ROOT/extern/obsidian-vault-bridge/hooks/obsidian-mirror.py" ]] || return 0
  local unset_vars=()
  [[ -n "${VAULT_DIR:-}" ]] || unset_vars+=(VAULT_DIR)
  [[ -n "${MEM_OBSIDIAN_VAULT:-}" ]] || unset_vars+=(MEM_OBSIDIAN_VAULT)
  (( ${#unset_vars[@]} == 0 )) && return 0
  warn "VAULT NOT CONFIGURED: ${unset_vars[*]} unset — obsidian-vault-bridge hooks are installed but OFF"
  warn "  (obsidian-mirror writes nothing, vault-inject injects nothing). Add to $REPO_ROOT/.env:"
  local v
  for v in "${unset_vars[@]}"; do
    case "$v" in
      VAULT_DIR)          warn "    VAULT_DIR=/path/to/your/vault" ;;
      MEM_OBSIDIAN_VAULT) warn "    MEM_OBSIDIAN_VAULT=/path/to/your/vault/_mem-log" ;;
    esac
  done
  warn "  then re-run: bash install.sh"
}

_deploy_vault_config() {
  # The bridge's hooks are gated on VAULT_DIR / QWEN_BASE_URL, but a hook only
  # sees what the shell that launched the agent exported. Exporting them in a
  # shell rc reaches sessions started from that shell and nothing else -- and a
  # gated hook that never fires looks exactly like one that is switched off.
  # compile-nudge shipped that way and did nothing for weeks. Persist whatever
  # the installing shell has so resolution stops depending on the launcher.
  local conf_dir="$HOME/.config/dev-agent-kit"
  local conf="$conf_dir/vault.env"

  _warn_vault_unset

  [[ -n "${VAULT_DIR:-}" || -n "${QWEN_BASE_URL:-}" || -n "${MEM_OBSIDIAN_VAULT:-}" ]] || return 0

  mkdir -p "$conf_dir"
  {
    echo "# Written by dev-agent-kit install. Read by extern/obsidian-vault-bridge"
    echo "# hooks when the variable is absent from the agent process env."
    [[ -n "${VAULT_DIR:-}" ]] && echo "VAULT_DIR=$VAULT_DIR"
    [[ -n "${QWEN_BASE_URL:-}" ]] && echo "QWEN_BASE_URL=$QWEN_BASE_URL"
    # obsidian-mirror was left out of this file and kept reading the process
    # env alone, so the one thing switching it on was a hand-written export in
    # a shell rc -- the same launcher dependency the rest of this function
    # exists to remove. It stays opt-in; it just stops being opt-in *per shell*.
    [[ -n "${MEM_OBSIDIAN_VAULT:-}" ]] && echo "MEM_OBSIDIAN_VAULT=$MEM_OBSIDIAN_VAULT"
  } > "$conf"
  ok "vault config -> $conf"
}

_deploy_vault_timer() {
  # D3 says compile runs outside a session -- but "outside a session" still
  # needs something to pull the trigger. Without this the compiler only runs
  # when it is invoked by hand, which is the exact failure mode it was built
  # to fix: a note is compiled once and drifts from its repo from that day on.
  # compile-nudge fired three times and was actioned zero times; a louder
  # reminder does not fix this class, a scheduler does.
  local tool="$CLAUDE_CONFIG_DIR/extern/obsidian-vault-bridge/tools/vault-compile.py"
  local stats="$CLAUDE_CONFIG_DIR/extern/obsidian-vault-bridge/tools/vault-stats.py"
  local unit_dir="$HOME/.config/systemd/user"

  [[ -f "$tool" ]] || return 0
  # Same gate as the config above: no vault configured, nothing to compile.
  [[ -n "${VAULT_DIR:-}" || -f "$HOME/.config/dev-agent-kit/vault.env" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || {
    warn "systemd not available, skipping vault-compile timer"; return 0; }
  # systemctl --user talks to the caller's real session manager, which does not
  # follow a relocated HOME. Tests need to exercise unit *writing* without
  # touching the live timer, so activation is opt-out.
  local activate=1
  [[ -n "${DAK_SKIP_SYSTEMD:-}" ]] && activate=0

  mkdir -p "$unit_dir"

  # No Environment=VAULT_DIR here on purpose. A systemd unit starts with a
  # near-empty env, so the resolution has to come from vault.env -- which is
  # what _deploy_vault_config exists to persist. Baking the path into the unit
  # would fork a second source of truth that reinstalls would not refresh.
  # PATH is the exception: `claude` lives in ~/.local/bin and the unit would
  # not find it otherwise.
  cat > "$unit_dir/vault-compile.service" <<EOF
[Unit]
Description=Compile claude-mem-lite history into vault notes
Documentation=file://$CLAUDE_CONFIG_DIR/extern/obsidian-vault-bridge/DECISIONS.md

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/env python3 $tool --all --apply
# Regenerate the vault dashboard from what the compile just wrote. The leading
# "-" keeps a dashboard failure from marking the compile itself as failed.
# Output: ~/.local/share/dev-agent-kit/vault-stats.html (outside the vault).
ExecStartPost=-/usr/bin/env python3 $stats
# Each note gets its own --timeout; this is the ceiling for the whole sweep.
TimeoutStartSec=3600
Nice=10
EOF

  cat > "$unit_dir/vault-compile.timer" <<'EOF'
[Unit]
Description=Daily vault compile

[Timer]
OnCalendar=*-*-* 04:00:00
# A workstation is usually off at 04:00. Without this the run is simply lost
# and the note drifts another day; with it, the miss is made up after boot.
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

  if [[ $activate -eq 0 ]]; then
    ok "vault-compile units -> $unit_dir (activation skipped)"
    return 0
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  # Two machines compiling into one git-synced vault race on the same notes and
  # pay for the claude -p calls twice. VAULT_COMPILE_TIMER=0 in .env marks this
  # machine as a reader: the timer is turned off, not just left alone.
  if [[ "${VAULT_COMPILE_TIMER:-1}" == "0" ]]; then
    systemctl --user disable --now vault-compile.timer >/dev/null 2>&1 || true
    ok "vault-compile timer off on this machine (VAULT_COMPILE_TIMER=0)"
    return 0
  fi
  if systemctl --user enable --now vault-compile.timer >/dev/null 2>&1; then
    ok "vault-compile timer -> daily 04:00 (systemctl --user list-timers)"
  else
    warn "vault-compile units written but not enabled (no user systemd session?)"
  fi

  # A user timer does not run while the user is logged out. Linger is the
  # difference between "daily" and "daily, if I happen to be logged in".
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    if loginctl enable-linger "$USER" >/dev/null 2>&1; then
      ok "linger enabled (timer runs while logged out)"
    else
      warn "linger is off -- run: sudo loginctl enable-linger $USER"
    fi
  fi
}

_deploy_settings_json() {
  local src="$REPO_ROOT/claude/settings.json"
  local dst="$CLAUDE_CONFIG_DIR/settings.json"

  [[ -f "$src" ]] || { warn "claude/settings.json not found, skipping"; return; }

  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    ok "claude/settings.json -> $dst (created)"
    return
  fi

  python3 - "$src" "$dst" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    src = json.load(f)
with open(sys.argv[2]) as f:
    dst = json.load(f)

# Kit hooks unwired from the template. The merge below is additive, so a hook
# dropped from claude/settings.json would otherwise stay live in every existing
# install. qwen-consider: nudges toward the Qwen offload, which the removed
# delegate CLI backed (see claude/README.md).
RETIRED = ("/.claude/hooks/qwen-consider.py",)
for event in list(dst.get("hooks", {})):
    kept = []
    for entry in dst["hooks"][event]:
        hooks = [h for h in entry.get("hooks", [])
                 if not any(r in h.get("command", "") for r in RETIRED)]
        if hooks:
            kept.append(dict(entry, hooks=hooks))
    dst["hooks"][event] = kept

for event, entries in src.get("hooks", {}).items():
    dst_hooks = dst.setdefault("hooks", {}).setdefault(event, [])
    existing = {h["command"] for e in dst_hooks for h in e.get("hooks", [])}
    for entry in entries:
        new_cmds = {h["command"] for h in entry.get("hooks", [])}
        if not new_cmds.issubset(existing):
            dst_hooks.append(entry)

# Additive only: never drop a rule the user added by hand (except retired kit rules).
allow = dst.setdefault("permissions", {}).setdefault("allow", [])
allow[:] = [r for r in allow if r != "Bash(delegate:*)"]
for rule in src.get("permissions", {}).get("allow", []):
    if rule not in allow:
        allow.append(rule)

with open(sys.argv[2], "w") as f:
    json.dump(dst, f, indent=2)
    f.write("\n")
PYEOF

  ok "claude/settings.json hooks merged -> $dst"
}

CODEX_CONFIG_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"

_deploy_codex_agents_md() {
  local dst="$CODEX_CONFIG_DIR/AGENTS.md"
  local src="$REPO_ROOT/codex/AGENTS.md"

  [[ -f "$src" ]] || { warn "codex/AGENTS.md not found, skipping"; return; }
  mkdir -p "$CODEX_CONFIG_DIR"

  if [[ -f "$dst" ]]; then
    local backup_dir="$CODEX_CONFIG_DIR/backups"
    local backup_path
    backup_path="$backup_dir/AGENTS.md.backup.$(date +%s)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_path"
    info "Backup: $backup_path"
  fi

  cp "$src" "$dst"
  ok "codex/AGENTS.md -> $dst"
}

_deploy_codex_config() {
  local src="$REPO_ROOT/codex/config.toml"
  local dst="$CODEX_CONFIG_DIR/config.toml"

  [[ -f "$src" ]] || { warn "codex/config.toml not found, skipping"; return; }
  mkdir -p "$CODEX_CONFIG_DIR"

  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    ok "codex/config.toml -> $dst (created)"
    return
  fi

  python3 - "$src" "$dst" <<'PYEOF'
import sys, re

def parse_sections(text):
    """Return list of (header, lines) — header='' for top-level keys."""
    sections = []
    current_header = ''
    current_lines = []
    for line in text.splitlines(keepends=True):
        m = re.match(r'^\[([^\]]+)\]', line)
        if m:
            sections.append((current_header, current_lines))
            current_header = m.group(1)
            current_lines = [line]
        else:
            current_lines.append(line)
    sections.append((current_header, current_lines))
    return sections

with open(sys.argv[1]) as f:
    src_text = f.read()
with open(sys.argv[2]) as f:
    dst_text = f.read()

src_sections = {h: lines for h, lines in parse_sections(src_text)}
dst_sections = parse_sections(dst_text)
dst_headers = {h for h, _ in dst_sections}

result = list(dst_sections)
for header, lines in src_sections.items():
    if header and header not in dst_headers:
        result.append((header, lines))

with open(sys.argv[2], 'w') as f:
    for _, lines in result:
        f.writelines(lines)
        if lines and not lines[-1].endswith('\n'):
            f.write('\n')
PYEOF

  ok "codex/config.toml sections merged -> $dst"
}

_deploy_codex_agents() {
  local src_dir="$REPO_ROOT/codex/agents"
  local dst_dir="$CODEX_CONFIG_DIR/agents"

  [[ -d "$src_dir" ]] || { warn "codex/agents/ not found, skipping"; return; }
  mkdir -p "$dst_dir"

  for deployed in "$dst_dir"/*.toml; do
    [[ -f "$deployed" ]] || continue
    local base; base=$(basename "$deployed")
    if [[ ! -f "$src_dir/$base" ]]; then
      rm "$deployed"
      warn "Removed stale codex agent: $base"
    fi
  done

  local count=0
  for f in "$src_dir"/*.toml; do
    [[ -f "$f" ]] || continue
    cp "$f" "$dst_dir/"
    count=$((count + 1))
  done

  ok "$count codex agent(s) deployed to $dst_dir"
}

_deploy_codex_extern_symlink() {
  local extern_src="$REPO_ROOT/extern"
  local extern_dst="$CODEX_CONFIG_DIR/extern"

  [[ -d "$extern_src" ]] || { warn "extern/ not found, skipping codex symlink"; return; }

  ln -sfn "$extern_src" "$extern_dst"
  ok "extern skills -> $extern_dst"
}

deploy_agents() {
  section "Agent Deployment"
  _verify_templates
  _deploy_claude_md
  _deploy_hooks_scripts
  _deploy_settings_json
  _deploy_vault_config
  _deploy_vault_timer
  _retire_agents "$CLAUDE_CONFIG_DIR/agents" claude
  _deploy_skills
  _deploy_extern_symlink
  _retire_delegate

  _deploy_qwen_md
  _retire_agents "$QWEN_CONFIG_DIR/agents" qwen
  _deploy_qwen_hooks
  _deploy_qwen_settings_json
  _deploy_qwen_skills
  _deploy_qwen_extern_symlink

  mkdir -p "$CODEX_CONFIG_DIR/agents"
  _deploy_codex_agents_md
  _deploy_codex_config
  _deploy_codex_agents
  _deploy_codex_extern_symlink

  _deploy_gemini_md
  _deploy_antigravity_agents_md
  _retire_agents "$ANTIGRAVITY_CONFIG_DIR/agents" antigravity
  _deploy_antigravity_hooks
  _deploy_antigravity_hooks_json
  _deploy_antigravity_skills
  _deploy_antigravity_extern_symlink
}
