#!/usr/bin/env bash
# Run all top-level test_*.sh files and print a consolidated summary.
# Usage: bash tests/run-all.sh [--with-containers]

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WITH_CONTAINERS=0
for arg in "$@"; do
  [[ "$arg" == "--with-containers" ]] && WITH_CONTAINERS=1
done

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0
FAILED_SUITES=()

# Discover test files
shopt -s nullglob
TEST_FILES=("$TESTS_DIR"/test_*.sh)
shopt -u nullglob

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo -e "${RED}No test files found in $TESTS_DIR${RESET}"
  exit 1
fi

# Filter out container suites unless --with-containers
if [[ $WITH_CONTAINERS -eq 0 ]]; then
  FILTERED=()
  for f in "${TEST_FILES[@]}"; do
    bname="$(basename "$f")"
    # Skip tests inside subdirectories (fresh-install, remote-install)
    # Our glob is maxdepth 1 so this shouldn't happen, but be safe
    case "$bname" in
      *) FILTERED+=("$f") ;;
    esac
  done
  TEST_FILES=("${FILTERED[@]}")
fi

echo -e "${BOLD}=== dev-agent-kit test suite ===${RESET}"
echo ""

for test_file in "${TEST_FILES[@]}"; do
  bname="$(basename "$test_file")"
  echo -e "${BOLD}── $bname ──${RESET}"

  # Run the test and capture output + exit code
  set +e
  output="$(bash "$test_file" 2>&1)" && rc=0 || rc=$?
  set -e

  echo "$output"

  # Parse the Results line from output
  # Formats seen:
  #   "Results: N passed, M failed"
  #   "Results: N passed, M failed out of K total"
  results_line="$(echo "$output" | grep -E '^\s*Results:' | tail -1 || true)"

  if [[ -n "$results_line" ]]; then
    pass_count="$(echo "$results_line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)"
    fail_count="$(echo "$results_line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)"
  else
    # No Results line — infer from exit code
    if [[ $rc -eq 0 ]]; then
      pass_count=0
      fail_count=0
    else
      pass_count=0
      fail_count=1
    fi
  fi

  TOTAL_PASS=$((TOTAL_PASS + pass_count))
  TOTAL_FAIL=$((TOTAL_FAIL + fail_count))
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  if [[ $rc -ne 0 ]]; then
    FAILED_SUITES+=("$bname")
    echo -e "${RED}  → FAILED (exit $rc)${RESET}"
  else
    echo -e "${GREEN}  → PASSED${RESET}"
  fi
  echo ""
done

echo -e "${BOLD}=== Summary ===${RESET}"
echo "Suites: $TOTAL_TESTS run"
echo -e "Results: ${GREEN}$TOTAL_PASS passed${RESET}, ${RED}$TOTAL_FAIL failed${RESET}"

if [[ ${#FAILED_SUITES[@]} -gt 0 ]]; then
  echo -e "${RED}Failed suites:${RESET}"
  for s in "${FAILED_SUITES[@]}"; do
    echo "  - $s"
  done
  exit 1
fi

exit 0
