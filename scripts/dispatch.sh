#!/usr/bin/env bash
# dispatch.sh - Manage agent-to-agent task files in dispatch/tasks/.
# See dispatch/README.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_DIR="$ROOT_DIR/dispatch"
TASKS_DIR="$DISPATCH_DIR/tasks"
ARCHIVE_DIR="$DISPATCH_DIR/archive"

usage() {
  cat <<'EOF'
Usage:
  dispatch.sh new <to> <title...>   Create a new task file (dispatch/tasks/)
  dispatch.sh list                  List open tasks and their statuses
  dispatch.sh done <file>           Move task to dispatch/archive/
EOF
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

cmd_new() {
  local to="${1:?to is required (e.g., claude, gemini, qwen)}"
  shift
  local title="${*:?title is required}"
  local date slug file
  date="$(date +%F)"
  slug="$(slugify "$title")"
  file="$TASKS_DIR/${date}-${slug}.md"

  if [[ -e "$file" ]]; then
    echo "Already exists: $file" >&2
    exit 1
  fi

  mkdir -p "$TASKS_DIR"
  cat > "$file" <<EOF
---
from: unknown
to: ${to}
status: pending_${to}
created: ${date}
updated: ${date}
---

## Task/Specification

${title}

## Response/Findings

_(to be filled by: ${to})_

## Review/Next Step

_(next agent fills in if needed)_
EOF
  echo "$file"
}

cmd_list() {
  shopt -s nullglob
  local files=("$TASKS_DIR"/*.md)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No open tasks."
    return 0
  fi
  for f in "${files[@]}"; do
    local status updated
    status="$(sed -n 's/^status: *//p' "$f" | head -1)"
    updated="$(sed -n 's/^updated: *//p' "$f" | head -1)"
    printf '%-14s %-24s %s\n' "$status" "$updated" "$(basename "$f")"
  done
}

cmd_done() {
  local input="${1:?file name is required}"
  local file="$input"
  [[ -e "$file" ]] || file="$TASKS_DIR/$input"
  [[ -e "$file" ]] || { echo "Not found: $input" >&2; exit 1; }

  mkdir -p "$ARCHIVE_DIR"
  local tmp
  tmp="$(mktemp)"
  sed -E "s/^status: .*/status: done/" "$file" > "$tmp"
  mv "$tmp" "$ARCHIVE_DIR/$(basename "$file")"
  rm -f "$file"
  echo "Archived: $ARCHIVE_DIR/$(basename "$file")"
}

main() {
  local sub="${1:-}"
  case "$sub" in
    new) shift; cmd_new "$@" ;;
    list) cmd_list ;;
    done) shift; cmd_done "$@" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
