#!/usr/bin/env bats
# Tests for scripts/read-config.sh

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  cd "$BATS_TEST_TMPDIR"
  mkdir -p .claude
}

teardown() {
  teardown_tmpdir
}

@test "read-config: no config file returns empty" {
  run bash "$SCRIPTS_DIR/read-config.sh" --get scope
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "read-config: --get scope returns value" {
  cp "$FIXTURES_DIR/configs/default.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --get scope
  [ "$status" -eq 0 ]
  [ "$output" = "codebase" ]
}

@test "read-config: --get tools returns comma-separated list" {
  cp "$FIXTURES_DIR/configs/default.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --get tools
  [ "$status" -eq 0 ]
  [ "$output" = "semgrep,gitleaks" ]
}

@test "read-config: --get dockerFallback returns boolean" {
  cp "$FIXTURES_DIR/configs/docker-fallback.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --get dockerFallback
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "read-config: --dump returns full JSON" {
  cp "$FIXTURES_DIR/configs/default.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --dump
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['scope'] == 'codebase'
assert d['tools'] == ['semgrep', 'gitleaks']
" <<<"$output"
}

@test "read-config: --dump with no config returns empty object" {
  run bash "$SCRIPTS_DIR/read-config.sh" --dump
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "read-config: invalid JSON returns empty gracefully" {
  cp "$FIXTURES_DIR/configs/invalid.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --get scope
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "read-config: --get exclude returns comma-separated list" {
  cp "$FIXTURES_DIR/configs/with-exclude.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --get exclude
  [ "$status" -eq 0 ]
  [ "$output" = "tests,__tests__,cypress" ]
}

@test "read-config: empty config returns empty for any key" {
  cp "$FIXTURES_DIR/configs/empty.json" .claude/code-guardian.config.json
  run bash "$SCRIPTS_DIR/read-config.sh" --get scope
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
