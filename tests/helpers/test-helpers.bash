#!/usr/bin/env bash
# Shared test helpers for bats tests

# Resolve paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPTS_DIR="${PLUGIN_ROOT}/scripts"
FIXTURES_DIR="${TEST_DIR}/fixtures"

# Disable colors in test output
export NO_COLOR=1

# Create a temporary working directory for each test
setup_tmpdir() {
  BATS_TEST_TMPDIR="$(mktemp -d)"
}

teardown_tmpdir() {
  [[ -n "${BATS_TEST_TMPDIR:-}" ]] && rm -rf "$BATS_TEST_TMPDIR"
}

# Copy a fixture project to a temp dir and cd into it
use_fixture() {
  local fixture_name="$1"
  setup_tmpdir
  cp -R "${FIXTURES_DIR}/projects/${fixture_name}/." "$BATS_TEST_TMPDIR/"
  cd "$BATS_TEST_TMPDIR"
}

# Assert that stdout is valid JSON
assert_valid_json() {
  python3 -c "import json, sys; json.loads(sys.stdin.read())" <<<"$output"
}

# Assert that a JSON key equals an expected value
# Usage: assert_json_key ".languages" '["javascript"]'
assert_json_key() {
  local key="$1"
  local expected="$2"
  local actual
  actual=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
keys = sys.argv[1].lstrip('.').split('.')
val = data
for k in keys:
    val = val[k]
print(json.dumps(val))
" "$key" <<<"$output")
  [[ "$actual" == "$expected" ]] || {
    echo "Expected $key = $expected, got $actual" >&2
    return 1
  }
}

# Assert JSON array contains a value
# Usage: assert_json_array_contains ".languages" "javascript"
assert_json_array_contains() {
  local key="$1"
  local value="$2"
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
keys = sys.argv[1].lstrip('.').split('.')
val = data
for k in keys:
    val = val[k]
assert sys.argv[2] in val, f'{sys.argv[2]} not in {val}'
" "$key" "$value" <<<"$output"
}

# Assert JSON array does NOT contain a value
assert_json_array_not_contains() {
  local key="$1"
  local value="$2"
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
keys = sys.argv[1].lstrip('.').split('.')
val = data
for k in keys:
    val = val[k]
assert sys.argv[2] not in val, f'{sys.argv[2]} found in {val}'
" "$key" "$value" <<<"$output"
}

# Assert JSON boolean value
assert_json_bool() {
  local key="$1"
  local expected="$2" # "true" or "false"
  local actual
  actual=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
keys = sys.argv[1].lstrip('.').split('.')
val = data
for k in keys:
    val = val[k]
print(str(val).lower())
" "$key" <<<"$output")
  [[ "$actual" == "$expected" ]] || {
    echo "Expected $key = $expected, got $actual" >&2
    return 1
  }
}

# Assert JSON array length
assert_json_array_length() {
  local key="$1"
  local expected="$2"
  local actual
  actual=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
keys = sys.argv[1].lstrip('.').split('.')
val = data
for k in keys:
    val = val[k]
print(len(val))
" "$key" <<<"$output")
  [[ "$actual" == "$expected" ]] || {
    echo "Expected $key length = $expected, got $actual" >&2
    return 1
  }
}
