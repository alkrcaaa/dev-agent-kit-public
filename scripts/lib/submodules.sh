#!/usr/bin/env bash
# sourced — not executed directly

init_submodules() {
  section "Submodules"
  # -e, not -d: in a git worktree .git is a file pointing at the real git
  # dir, and -d skipped every submodule there.
  if [[ ! -e "$REPO_ROOT/.git" ]]; then
    warn "Not a git repository — extern/ skills will be empty."
    warn "Clone with: git clone --recursive https://github.com/..."
    return
  fi
  info "git submodule update --init --recursive"
  # GIT_TERMINAL_PROMPT=0 (platform.sh) turns a credential prompt into a
  # failure and the bound turns a stalled clone into one, so the per-submodule
  # retry below names what is missing instead of the install hanging.
  if run_bounded 1200 git -C "$REPO_ROOT" submodule update --init --recursive; then
    ok "Submodules ready"
    _warn_empty_submodules
    return
  fi

  # git aborts the whole batch on the first unreachable remote, and under
  # `set -e` that took the entire install with it -- one optional
  # integration with a bad URL left a fresh machine with no agents, no
  # skills and no MCPs at all. Retry each submodule on its own so the
  # damage stops at the one that is actually broken, and say which.
  warn "Batch clone failed — retrying each submodule individually"
  local path
  local missing=()
  while read -r path; do
    run_bounded 600 git -C "$REPO_ROOT" submodule update --init --recursive -- "$path" >/dev/null 2>&1 \
      || missing+=("$path")
  done < <(git -C "$REPO_ROOT" config -f "$REPO_ROOT/.gitmodules" \
             --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

  if (( ${#missing[@]} == 0 )); then
    ok "Submodules ready"
    return
  fi
  warn "Unavailable — features needing these are skipped, install continues:"
  for path in "${missing[@]}"; do
    warn "  - $path"
  done
  _warn_empty_submodules
}

# Prints the .gitmodules paths that are missing or empty on disk, one per line.
_empty_submodules() {
  [[ -f "$REPO_ROOT/.gitmodules" ]] || return 0
  local path
  while read -r path; do
    [[ -n "$(ls -A "$REPO_ROOT/$path" 2>/dev/null)" ]] || echo "$path"
  done < <(git -C "$REPO_ROOT" config -f "$REPO_ROOT/.gitmodules" \
             --get-regexp '^submodule\..*\.path$' | awk '{print $2}')
}

# Hooks into submodules are wired as `[ -f "$H" ] && ... || true` (the vault
# hooks: obsidian-mirror, vault-inject, the capture hooks), so an empty
# submodule turns them off without a word. Name every empty one, loudly.
_warn_empty_submodules() {
  local path empty=()
  while read -r path; do
    [[ -n "$path" ]] && empty+=("$path")
  done < <(_empty_submodules)
  (( ${#empty[@]} == 0 )) && return 0
  warn "EMPTY SUBMODULE(S) — anything wired to them silently does nothing:"
  for path in "${empty[@]}"; do
    warn "    $path"
  done
  warn "  fix: git -C $REPO_ROOT submodule update --init --recursive, then re-run install.sh"
}
