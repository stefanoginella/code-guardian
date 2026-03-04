#!/usr/bin/env bats
# Tests for scripts/lib/common.sh

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  # Source common.sh in a subshell-friendly way
  export NO_COLOR=1
}

teardown() {
  teardown_tmpdir
}

@test "emit_finding: produces valid JSON with all 8 fields" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && emit_finding 'semgrep' 'high' 'xss-rule' 'XSS vulnerability' 'app.js' '42' 'false' 'sast'"
  [ "$status" -eq 0 ]
  # Verify it's valid JSON with all required fields
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['tool'] == 'semgrep', f'tool: {d[\"tool\"]}'
assert d['severity'] == 'high'
assert d['rule'] == 'xss-rule'
assert d['message'] == 'XSS vulnerability'
assert d['file'] == 'app.js'
assert d['line'] == 42
assert d['autoFixable'] == False
assert d['category'] == 'sast'
" <<<"$output"
}

@test "emit_finding: escapes double quotes in message" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && emit_finding 'test' 'low' 'rule1' 'message with \"quotes\" inside' 'test.js' '1' 'false' 'sast'"
  [ "$status" -eq 0 ]
  # Must be valid JSON even with quotes in message
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert '\"' in d['message'], 'Quotes not preserved in message'
" <<<"$output"
}

@test "emit_finding: escapes newlines in message" {
  run bash -c "
source '$SCRIPTS_DIR/lib/common.sh'
msg=\"line1
line2\"
emit_finding 'test' 'low' 'rule1' \"\$msg\" 'test.js' '1' 'false' 'sast'
"
  [ "$status" -eq 0 ]
  python3 -c "import json, sys; json.loads(sys.stdin.read())" <<<"$output"
}

@test "create_summary: correct severity counts from sample findings" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && create_summary '$FIXTURES_DIR/findings/sample.jsonl' 'test-tool'"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['tool'] == 'test-tool', f'tool: {d[\"tool\"]}'
assert d['summary']['high'] == 2, f'high: {d[\"summary\"][\"high\"]}'
assert d['summary']['medium'] == 2, f'medium: {d[\"summary\"][\"medium\"]}'
assert d['summary']['low'] == 1, f'low: {d[\"summary\"][\"low\"]}'
" <<<"$output"
}

@test "create_summary: handles empty findings file" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && create_summary '$FIXTURES_DIR/findings/empty.jsonl' 'empty-tool'"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['tool'] == 'empty-tool'
assert d['summary']['high'] == 0
assert d['summary']['medium'] == 0
assert d['summary']['low'] == 0
" <<<"$output"
}

@test "create_summary: handles nonexistent file" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && create_summary '/nonexistent/file.jsonl' 'no-tool'"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['summary']['high'] == 0
assert d['summary']['medium'] == 0
" <<<"$output"
}

@test "join_by: comma-joins multiple elements" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && join_by ',' 'a' 'b' 'c'"
  [ "$status" -eq 0 ]
  [ "$output" = "a,b,c" ]
}

@test "join_by: single element" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && join_by ',' 'only'"
  [ "$status" -eq 0 ]
  [ "$output" = "only" ]
}

@test "join_by: empty arguments" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && join_by ','"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "get_exclude_dirs_csv: produces comma-separated list" {
  run bash -c "source '$SCRIPTS_DIR/lib/common.sh' && get_exclude_dirs_csv"
  [ "$status" -eq 0 ]
  # Should contain known directories
  [[ "$output" == *".git"* ]]
  [[ "$output" == *"node_modules"* ]]
  [[ "$output" == *"vendor"* ]]
  # Should be comma-separated (no spaces)
  [[ "$output" != *" "* ]]
}
