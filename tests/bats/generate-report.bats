#!/usr/bin/env bats
# Tests for scripts/generate-report.sh

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  cd "$BATS_TEST_TMPDIR"
  mkdir -p .code-guardian/scan-reports
}

teardown() {
  teardown_tmpdir
}

_run_report() {
  local findings_file="$1"
  local total="${2:-0}" high="${3:-0}" medium="${4:-0}" low="${5:-0}"
  bash "$SCRIPTS_DIR/generate-report.sh" \
    --findings-file "$findings_file" \
    --scope "codebase" \
    --scanners-run "semgrep,gitleaks,trivy" \
    --skipped-scanners "" \
    --scope-skipped-scanners "" \
    --failed-scanners "" \
    --summaries-json '[{"tool":"semgrep","summary":{"high":'"$high"',"medium":'"$medium"',"low":'"$low"',"info":0}}]' \
    --total "$total" --high "$high" --medium "$medium" --low "$low" \
    --timestamp "20240101_120000" \
    --base-ref "" \
    --report-file "$BATS_TEST_TMPDIR/test-report.md"
}

@test "generate-report: produces markdown with severity table" {
  local report_file
  report_file=$(_run_report "$FIXTURES_DIR/findings/sample.jsonl" 5 2 2 1)
  [ -f "$report_file" ]

  # Check for severity table
  grep -q "| Severity | Count |" "$report_file"
  grep -q "| High     | 2 |" "$report_file"
  grep -q "| Medium   | 2 |" "$report_file"
  grep -q "| Low      | 1 |" "$report_file"
}

@test "generate-report: findings have checkboxes" {
  local report_file
  report_file=$(_run_report "$FIXTURES_DIR/findings/sample.jsonl" 5 2 2 1)
  [ -f "$report_file" ]

  # Check for checkbox items
  grep -q '\- \[ \] \*\*#' "$report_file"
}

@test "generate-report: empty findings says no issues" {
  local report_file
  report_file=$(_run_report "$FIXTURES_DIR/findings/empty.jsonl" 0 0 0 0)
  [ -f "$report_file" ]

  grep -q "No security issues found" "$report_file"
}

@test "generate-report: contains summary placeholder" {
  local report_file
  report_file=$(_run_report "$FIXTURES_DIR/findings/sample.jsonl" 5 2 2 1)
  [ -f "$report_file" ]

  grep -q "<!-- SUMMARY_PLACEHOLDER -->" "$report_file"
}

@test "generate-report: findings are numbered and grouped by severity" {
  local report_file
  report_file=$(_run_report "$FIXTURES_DIR/findings/sample.jsonl" 5 2 2 1)
  [ -f "$report_file" ]

  # HIGH section appears before MEDIUM
  local high_line medium_line
  high_line=$(grep -n "^### HIGH" "$report_file" | head -1 | cut -d: -f1)
  medium_line=$(grep -n "^### MEDIUM" "$report_file" | head -1 | cut -d: -f1)
  [ "$high_line" -lt "$medium_line" ]

  # Finding numbers increment
  grep -qF '**#1**' "$report_file"
  grep -qF '**#2**' "$report_file"
}

@test "generate-report: report has hotspots section" {
  local report_file
  report_file=$(_run_report "$FIXTURES_DIR/findings/sample.jsonl" 5 2 2 1)
  [ -f "$report_file" ]

  grep -q "### Hotspots" "$report_file"
}
