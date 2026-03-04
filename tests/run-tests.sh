#!/usr/bin/env bash
# Entry point for code-guardian tests — installs bats-core if needed, runs all tests.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_DIR="${TEST_DIR}/.bats"
BATS_BIN="${BATS_DIR}/bats-core/bin/bats"

# Install bats-core if not present
if [[ ! -x "$BATS_BIN" ]]; then
  echo "Installing bats-core..."
  mkdir -p "$BATS_DIR"
  git clone --depth 1 https://github.com/bats-core/bats-core.git "${BATS_DIR}/bats-core" 2>/dev/null
  echo "bats-core installed."
fi

echo ""
echo "Running code-guardian tests..."
echo ""

"$BATS_BIN" "${TEST_DIR}"/bats/*.bats
