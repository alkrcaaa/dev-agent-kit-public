#!/usr/bin/env bash
# shellcheck disable=SC2088  # literal ~/ is intentional: grep patterns match
#                             tilde paths INSIDE skill files; the rest are
#                             display strings, never expanded as paths.
# doctor.sh — repo self-consistency check (docs vs reality drift)
#
# Catches the class of bug found by hand on 2026-07-09: 8 submodules existed
# while README/QWEN.md claimed 6-7. Every check compares a machine-readable
# source of truth (.gitmodules, directory listings, settings.json) against
# what the docs claim. Run locally or in CI; exits non-zero on any FAIL.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/platform.sh"

FAILS=0
check() {  # check <ok|fail> <message>
  if [[ "$1" == ok ]]; then ok "$2"; else
    echo -e "  ${RED}✗${RESET} $2"; FAILS=$((FAILS + 1)); fi
}

# ── 1. Submodule counts: .gitmodules vs doc claims ─────────────────────────
section "Submodule counts"
EXTERN_SUBS=$(git -C "$REPO_ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
              | awk '{print $2}' | grep -c '^extern/')
# Submodules under extern/ that are infra (hooks/MCP), not agent skill
# libraries — "N skill libraries" claims count against EXTERN_SUBS minus
# these, "N git submodules"/"N submodules" claims count against the raw total.
NON_SKILL_SUBS=1  # obsidian-vault-bridge
SKILL_SUBS=$((EXTERN_SUBS - NON_SKILL_SUBS))

for doc in README.md extern/README.md; do
  # "git submodules"/"submodules" claims count everything under extern/;
  # "skill libraries" claims exclude infra-only submodules (see above).
  total_claims=$(grep -hoE '[0-9]+ (git submodules|submodules)' "$REPO_ROOT/$doc" \
           | grep -oE '^[0-9]+' | sort -u || true)
  skill_claims=$(grep -hoE '[0-9]+ skill libraries' "$REPO_ROOT/$doc" \
           | grep -oE '^[0-9]+' | sort -u || true)
  if [[ -z "$total_claims$skill_claims" ]]; then
    info "$doc: no submodule-count claim (ok)"
    continue
  fi
  bad_total=$(echo "$total_claims" | grep -vx "$EXTERN_SUBS" || true)
  bad_skill=$(echo "$skill_claims" | grep -vx "$SKILL_SUBS" || true)
  if [[ -z "$bad_total" && -z "$bad_skill" ]]; then
    check ok "$doc submodule-count claims match (total=$EXTERN_SUBS, skill libraries=$SKILL_SUBS)"
  else
    check fail "$doc claims total=[$(echo "$total_claims" | tr ' ' ',')] skill=[$(echo "$skill_claims" | tr ' ' ',')] but .gitmodules has $EXTERN_SUBS extern submodules ($SKILL_SUBS skill libraries)"
  fi
done

# ── 2. Every extern submodule appears in the doc table ─────────────────────
section "Submodule tables"
while read -r sub; do
  base=$(basename "$sub")
  if grep -q "$base" "$REPO_ROOT/extern/README.md"; then
    check ok "extern/README.md lists $base"
  else
    check fail "extern/README.md missing submodule $base"
  fi
done < <(git -C "$REPO_ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
         | awk '{print $2}' | grep '^extern/')

# ── 3. Native skills: SKILL.md present, name matches dir ───────────────────
section "Skills (claude/skills/)"
for d in "$REPO_ROOT"/claude/skills/*/; do
  s="$d/SKILL.md"; base=$(basename "$d")
  if [[ ! -f "$s" ]]; then check fail "$base: SKILL.md missing"; continue; fi
  name=$(awk -F': *' '/^name:/{print $2; exit}' "$s")
  if [[ "$name" == "$base" ]]; then
    check ok "$base: SKILL.md name matches"
  else
    check fail "$base: SKILL.md says name '$name'"
  fi
done

# ── 3b. Every native skill is routed in qwen/QWEN.md's skill table ─────────
# Claude's routing is dynamic (the Skill tool lists live descriptions), but
# Qwen's is a hardcoded table — nothing re-derives it, so a skill added
# without a matching row silently never gets suggested to Qwen. Caught by
# hand once already (scrollcraft shipped without a qwen/QWEN.md row).
section "Qwen skill routing"
for d in "$REPO_ROOT"/claude/skills/*/; do
  base=$(basename "$d")
  if grep -q "\`$base\`" "$REPO_ROOT/qwen/QWEN.md"; then
    check ok "qwen/QWEN.md routes $base"
  else
    check fail "qwen/QWEN.md has no routing row for $base"
  fi
done

# A private submodule (the vault bridge) is an empty directory in a CI run
# without its token. Its pointers are checked wherever it is checked out.
_not_checked_out() { [[ -d "$1" && -z "$(ls -A "$1")" ]]; }

# ── 4. Wrapper skill targets exist (…/extern/<path> resolves in repo) ──────
section "Skill wrapper targets"
while IFS=: read -r f line; do
  # extract the ~/.claude/extern/... path and re-root it into the repo
  p=$(echo "$line" | grep -oE '~/(\.claude|\.qwen)/extern/[^ `)]+' | head -1)
  [[ -z "$p" ]] && continue
  rel=${p#*extern/}
  if _not_checked_out "$REPO_ROOT/extern/${rel%%/*}"; then
    info "$(basename "$(dirname "$f")") -> extern/$rel: submodule not checked out, skipped"
  elif [[ -e "$REPO_ROOT/extern/$rel" ]]; then
    check ok "$(basename "$(dirname "$f")") -> extern/$rel"
  else
    check fail "$(basename "$(dirname "$f")") points to missing extern/$rel"
  fi
done < <(grep -n 'extern/' "$REPO_ROOT"/claude/skills/*/SKILL.md | grep '~/')

# ── 6. Hooks referenced in settings.json exist where they're sourced from ──
# Most hooks live in claude/hooks/; the vault-sync hooks are optional and
# come from the extern/obsidian-vault-bridge submodule instead (guarded by
# `[ -f "$H" ] && ... || true` in settings.json, so a missing submodule
# degrades gracefully rather than failing) — check each against its own
# actual source dir, not a single hardcoded one.
section "Hook scripts"
while read -r ref; do
  h="${ref##*/}"
  if [[ "$ref" == extern/obsidian-vault-bridge/hooks/* ]]; then
    src_dir="$REPO_ROOT/extern/obsidian-vault-bridge/hooks"
  else
    src_dir="$REPO_ROOT/claude/hooks"
  fi
  if [[ "$ref" == extern/* ]] && _not_checked_out "$REPO_ROOT/extern/obsidian-vault-bridge"; then
    info "hooks/$h: obsidian-vault-bridge not checked out, skipped"
  elif [[ -f "$src_dir/$h" ]]; then
    check ok "hooks/$h exists ($(basename "$src_dir")/)"
  else
    check fail "settings.json references missing $ref"
  fi
done < <(grep -oE '(extern/obsidian-vault-bridge/hooks|hooks)/[a-z0-9_-]+\.py' "$REPO_ROOT/claude/settings.json" | sort -u)

# ── 7. Deployed drift (only if this machine is installed) ──────────────────
section "Deployment drift"
if [[ -d "$HOME/.claude/skills" ]]; then
  for d in "$REPO_ROOT"/claude/skills/*/; do
    base=$(basename "$d")
    if [[ -f "$HOME/.claude/skills/$base/SKILL.md" ]]; then
      check ok "~/.claude/skills/$base deployed"
    else
      check fail "~/.claude/skills/$base NOT deployed (run: bash deploy-agents.sh)"
    fi
  done
  if [[ "$(readlink -f "$HOME/.claude/extern" 2>/dev/null)" == "$(readlink -f "$REPO_ROOT/extern")" ]]; then
    check ok "~/.claude/extern symlink -> repo extern/"
  else
    check fail "~/.claude/extern does not point at $REPO_ROOT/extern"
  fi
else
  info "~/.claude not present — skipping deployment checks (CI mode)"
fi

# ── 8. MCP inventory: CLAUDE.md table vs the probe's expected set ──────────
# Same drift class as the submodule counts above, one layer over: the inventory
# table in claude/CLAUDE.md is what both agents are told exists, and
# mcp_probe.py's EXPECTED map is what the health check demands. If a server is
# added to one and not the other, the docs promise a tool nobody verifies, or
# the probe fails for something the docs never claimed. This is a static
# comparison only — liveness is healthcheck.sh's job, not doctor's.
section "MCP inventory (claude/CLAUDE.md vs mcp_probe.py)"

INVENTORY_DOC="$REPO_ROOT/claude/CLAUDE.md"
PROBE="$REPO_ROOT/scripts/health/mcp_probe.py"

if [[ ! -f "$PROBE" ]]; then
  check fail "scripts/health/mcp_probe.py missing — MCP inventory unverifiable"
else
  # shellcheck disable=SC2016  # the backticks are markdown table syntax to
  #                              match literally, not command substitution
  documented=$(grep -oE '^\| *`[a-zA-Z0-9_-]+` *\|' "$INVENTORY_DOC" \
               | tr -d '|` ' | sort -u)
  expected=$(python3 "$PROBE" --list-expected | cut -f1 | sort -u)

  missing_in_probe=$(comm -23 <(echo "$documented") <(echo "$expected"))
  missing_in_doc=$(comm -13 <(echo "$documented") <(echo "$expected"))

  if [[ -z "$missing_in_probe" && -z "$missing_in_doc" ]]; then
    check ok "MCP inventory matches ($(echo "$expected" | wc -l) servers)"
  fi
  for m in $missing_in_probe; do
    check fail "CLAUDE.md documents '$m' but mcp_probe.py EXPECTED does not list it"
  done
  for m in $missing_in_doc; do
    check fail "mcp_probe.py expects '$m' but CLAUDE.md inventory table omits it"
  done
fi

# ── Result ──────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILS -eq 0 ]]; then
  ok "doctor: all checks passed"
else
  echo -e "  ${RED}✗${RESET} doctor: $FAILS check(s) failed" >&2
  exit 1
fi
