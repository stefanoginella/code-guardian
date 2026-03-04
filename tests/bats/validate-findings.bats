#!/usr/bin/env bats
# Tests for scripts/validate-findings.sh

setup() {
  load '../helpers/test-helpers'
}

@test "validate-findings: valid sample passes" {
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$FIXTURES_DIR/findings/sample.jsonl"
  [ "$status" -eq 0 ]
}

@test "validate-findings: valid AI review passes with --strict" {
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$FIXTURES_DIR/findings/ai-review.jsonl" --strict
  [ "$status" -eq 0 ]
}

@test "validate-findings: empty file passes" {
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$FIXTURES_DIR/findings/empty.jsonl"
  [ "$status" -eq 0 ]
}

@test "validate-findings: malformed JSONL fails" {
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$FIXTURES_DIR/findings/malformed.jsonl"
  [ "$status" -eq 1 ]
}

@test "validate-findings: AI regression fixtures pass strict validation" {
  for f in "$FIXTURES_DIR"/ai-review/expected-*.jsonl; do
    run bash "$SCRIPTS_DIR/validate-findings.sh" "$f" --strict
    [ "$status" -eq 0 ] || {
      echo "Failed on: $f" >&2
      return 1
    }
  done
}

@test "validate-findings: CLI findings fail strict mode" {
  # sample.jsonl has tool=semgrep, which should fail strict (requires tool=ai-review)
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$FIXTURES_DIR/findings/sample.jsonl" --strict
  [ "$status" -eq 1 ]
}

@test "validate-findings: missing required fields detected" {
  local tmpfile
  tmpfile=$(mktemp)
  echo '{"tool":"test","severity":"high"}' >"$tmpfile"
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$tmpfile"
  [ "$status" -eq 1 ]
  rm -f "$tmpfile"
}

@test "validate-findings: invalid severity detected" {
  local tmpfile
  tmpfile=$(mktemp)
  echo '{"tool":"test","severity":"critical","rule":"r","message":"m","file":"f","line":1,"autoFixable":false,"category":"sast"}' >"$tmpfile"
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$tmpfile"
  [ "$status" -eq 1 ]
  rm -f "$tmpfile"
}

@test "validate-findings: strict mode rejects wrong AI rule" {
  local tmpfile
  tmpfile=$(mktemp)
  echo '{"tool":"ai-review","severity":"high","rule":"wrong-rule","message":"test","file":"f.js","line":1,"autoFixable":false,"category":"ai-review"}' >"$tmpfile"
  run bash "$SCRIPTS_DIR/validate-findings.sh" "$tmpfile" --strict
  [ "$status" -eq 1 ]
  rm -f "$tmpfile"
}
