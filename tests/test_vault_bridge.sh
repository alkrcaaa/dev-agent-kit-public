#!/usr/bin/env bash
# Runs the obsidian-vault-bridge suite as part of the kit's own test run.
#
# The bridge ships 90 tests covering every vault hook, but run-all.sh globs
# tests/test_*.sh and the submodule's suite lives outside that glob -- so the
# entire vault layer was only ever tested by hand, which is the same as being
# tested when someone remembers. This wrapper puts it back in the run.

set -Eeuo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$KIT_ROOT/extern/obsidian-vault-bridge/hooks/test_hooks.sh"

echo "=== test_vault_bridge ==="

if [[ ! -f "$SUITE" ]]; then
  # An uninitialised submodule is not a failure of the kit.
  echo "  SKIP: bridge submodule not checked out"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

out="$(bash "$SUITE" 2>&1)" && rc=0 || rc=$?
echo "$out" | grep -E "FAIL" || true

# The bridge prints "N passed / M failed"; run-all.sh parses "N passed, M failed".
line="$(echo "$out" | grep -oE "[0-9]+ passed[ /,]+[0-9]+ failed" | tail -1)"
if [[ -z "$line" ]]; then
  echo "  FAIL: bridge suite produced no result line (rc=$rc)"
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

passed="$(echo "$line" | grep -oE "^[0-9]+")"
failed="$(echo "$line" | grep -oE "[0-9]+ failed" | grep -oE "^[0-9]+")"
echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 && $rc -eq 0 ]]
