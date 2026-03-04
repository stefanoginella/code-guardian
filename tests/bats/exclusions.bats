#!/usr/bin/env bats
# Tests for user-configurable directory exclusions

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  cd "$BATS_TEST_TMPDIR"
  mkdir -p .claude
  # Initialize a git repo so common.sh utilities work
  git init -q .
}

teardown() {
  teardown_tmpdir
}

# Helper: source common.sh and print CG_EXCLUDE_DIRS
_get_exclude_dirs() {
  bash -c "
    set -euo pipefail
    export NO_COLOR=1
    source '${SCRIPTS_DIR}/lib/common.sh'
    printf '%s\n' \"\${CG_EXCLUDE_DIRS[@]}\"
  "
}

# Helper: source common.sh and call get_exclude_dirs_csv
_get_csv() {
  bash -c "
    set -euo pipefail
    export NO_COLOR=1
    source '${SCRIPTS_DIR}/lib/common.sh'
    get_exclude_dirs_csv
  "
}

# Helper: source common.sh and call write_exclude_paths_file, then cat it
_get_exclude_paths_file() {
  bash -c "
    set -euo pipefail
    export NO_COLOR=1
    source '${SCRIPTS_DIR}/lib/common.sh'
    f=\$(write_exclude_paths_file)
    cat \"\$f\"
    rm -f \"\$f\"
  "
}

@test "exclusions: user exclude entries appended to CG_EXCLUDE_DIRS" {
  cp "$FIXTURES_DIR/configs/with-exclude.json" .claude/code-guardian.config.json
  run _get_exclude_dirs
  [ "$status" -eq 0 ]
  # User entries should appear in output
  [[ "$output" == *"tests"* ]]
  [[ "$output" == *"__tests__"* ]]
  [[ "$output" == *"cypress"* ]]
}

@test "exclusions: hardcoded entries preserved with user config" {
  cp "$FIXTURES_DIR/configs/with-exclude.json" .claude/code-guardian.config.json
  run _get_exclude_dirs
  [ "$status" -eq 0 ]
  # Core hardcoded entries must still be present
  [[ "$output" == *".git"* ]]
  [[ "$output" == *"node_modules"* ]]
  [[ "$output" == *"dist"* ]]
  [[ "$output" == *".venv"* ]]
}

@test "exclusions: duplicates not added twice" {
  # node_modules is in hardcoded list — config adding it again should not duplicate
  echo '{"exclude": ["node_modules", "tests"]}' > .claude/code-guardian.config.json
  run _get_exclude_dirs
  [ "$status" -eq 0 ]
  # Count occurrences of node_modules — should be exactly 1
  local count
  count=$(echo "$output" | grep -c '^node_modules$')
  [ "$count" -eq 1 ]
}

@test "exclusions: get_exclude_dirs_csv includes user entries" {
  cp "$FIXTURES_DIR/configs/with-exclude.json" .claude/code-guardian.config.json
  run _get_csv
  [ "$status" -eq 0 ]
  [[ "$output" == *",tests,"* || "$output" == *",tests" ]]
  [[ "$output" == *"__tests__"* ]]
  [[ "$output" == *"cypress"* ]]
  # Also still has hardcoded
  [[ "$output" == *".git,"* || "$output" == ".git,"* ]]
}

@test "exclusions: write_exclude_paths_file includes user entries" {
  cp "$FIXTURES_DIR/configs/with-exclude.json" .claude/code-guardian.config.json
  run _get_exclude_paths_file
  [ "$status" -eq 0 ]
  # Each entry becomes a regex line like (^|/)tests/
  [[ "$output" == *"(^|/)tests/"* ]]
  [[ "$output" == *"(^|/)__tests__/"* ]]
  [[ "$output" == *"(^|/)cypress/"* ]]
  # Hardcoded still present
  [[ "$output" == *"(^|/).git/"* ]]
}

@test "exclusions: empty exclude array is no-op" {
  echo '{"scope": "codebase", "exclude": []}' > .claude/code-guardian.config.json
  run _get_exclude_dirs
  [ "$status" -eq 0 ]
  # Should have hardcoded entries but no extras
  [[ "$output" == *".git"* ]]
  [[ "$output" == *"node_modules"* ]]
}

@test "exclusions: missing config file is no-op" {
  # No config file at all
  run _get_exclude_dirs
  [ "$status" -eq 0 ]
  # Should still have the hardcoded list
  [[ "$output" == *".git"* ]]
  [[ "$output" == *"node_modules"* ]]
}

@test "exclusions: config without exclude key is no-op" {
  cp "$FIXTURES_DIR/configs/default.json" .claude/code-guardian.config.json
  run _get_exclude_dirs
  [ "$status" -eq 0 ]
  # Should have hardcoded entries only
  [[ "$output" == *".git"* ]]
  [[ "$output" == *"node_modules"* ]]
}
