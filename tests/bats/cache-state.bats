#!/usr/bin/env bats
# Tests for scripts/cache-state.sh

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  cd "$BATS_TEST_TMPDIR"
  mkdir -p .claude
}

teardown() {
  teardown_tmpdir
}

_write_stack_file() {
  cat >"$BATS_TEST_TMPDIR/stack.json" <<'EOF'
{"languages":["javascript"],"frameworks":[],"packageManagers":["npm"],"docker":false,"dockerCompose":false,"ciSystems":[],"iacTools":[]}
EOF
}

_write_tools_file() {
  cat >"$BATS_TEST_TMPDIR/tools.json" <<'EOF'
{"available":["semgrep","gitleaks"],"unavailable":[],"docker":[]}
EOF
}

@test "cache-state: write then read returns valid JSON" {
  _write_stack_file
  _write_tools_file
  # Write
  run bash "$SCRIPTS_DIR/cache-state.sh" --write \
    --stack-file "$BATS_TEST_TMPDIR/stack.json" \
    --tools-file "$BATS_TEST_TMPDIR/tools.json"
  [ "$status" -eq 0 ]
  [ -f .claude/code-guardian-cache.json ]

  # Read (redirect stderr to avoid log messages in output)
  run bash -c "bash '$SCRIPTS_DIR/cache-state.sh' --read --max-age 3600 2>/dev/null"
  [ "$status" -eq 0 ]
  # Output should contain valid JSON with stack data
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'stack' in d, 'missing stack key'
assert 'tools' in d, 'missing tools key'
assert d['version'] == 1
" <<<"$output"
}

@test "cache-state: read with no cache file exits 1" {
  run bash "$SCRIPTS_DIR/cache-state.sh" --read
  [ "$status" -eq 1 ]
}

@test "cache-state: stale cache exits 2" {
  _write_stack_file
  _write_tools_file
  # Write cache
  bash "$SCRIPTS_DIR/cache-state.sh" --write \
    --stack-file "$BATS_TEST_TMPDIR/stack.json" \
    --tools-file "$BATS_TEST_TMPDIR/tools.json" 2>/dev/null

  # Read with max-age=0 → immediately stale
  run bash "$SCRIPTS_DIR/cache-state.sh" --read --max-age 0
  [ "$status" -eq 2 ]
}

@test "cache-state: check mode exits 0 for fresh cache" {
  _write_stack_file
  _write_tools_file
  bash "$SCRIPTS_DIR/cache-state.sh" --write \
    --stack-file "$BATS_TEST_TMPDIR/stack.json" \
    --tools-file "$BATS_TEST_TMPDIR/tools.json" 2>/dev/null

  run bash "$SCRIPTS_DIR/cache-state.sh" --check --max-age 3600
  [ "$status" -eq 0 ]
}

@test "cache-state: path mismatch exits 1" {
  _write_stack_file
  _write_tools_file
  bash "$SCRIPTS_DIR/cache-state.sh" --write \
    --stack-file "$BATS_TEST_TMPDIR/stack.json" \
    --tools-file "$BATS_TEST_TMPDIR/tools.json" 2>/dev/null

  # Move to a different directory → path mismatch
  local other_dir
  other_dir=$(mktemp -d)
  cp -R .claude "$other_dir/"
  cd "$other_dir"

  run bash "$SCRIPTS_DIR/cache-state.sh" --read --max-age 3600
  [ "$status" -eq 1 ]
  rm -rf "$other_dir"
}

@test "cache-state: write requires both stack-file and tools-file" {
  run bash "$SCRIPTS_DIR/cache-state.sh" --write --stack-file /tmp/nonexistent.json
  [ "$status" -ne 0 ]
}
