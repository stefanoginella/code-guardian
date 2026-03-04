#!/usr/bin/env bash
# Gitleaks scanner wrapper — secret detection
# Usage: gitleaks.sh [--scope-file <file>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SCOPE_FILE=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope-file) SCOPE_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/gitleaks-findings.jsonl"
> "$FINDINGS_FILE"

log_step "Running Gitleaks (secret detection)..."

RAW_OUTPUT=$(mktemp /tmp/cg-gitleaks-XXXXXX.json)
EXIT_CODE=0

# Build a gitleaks config extension with path exclusions
GITLEAKS_CONFIG=$(mktemp /tmp/cg-gitleaks-config-XXXXXX.toml)
{
  echo '[extend]'
  echo 'useDefault = true'
  echo ''
  echo '[allowlist]'
  printf 'paths = [\n'
  first=true
  for dir in "${CG_EXCLUDE_DIRS[@]}"; do
    $first || printf ',\n'
    # TOML string: regex matching dir anywhere in path
    printf "  \"(^|/)%s/\"" "$dir"
    first=false
  done
  printf '\n]\n'
} > "$GITLEAKS_CONFIG"

GITLEAKS_ARGS=("detect" "--source" "." "--report-format" "json" "--report-path" "$RAW_OUTPUT" "--no-banner" "--config" "$GITLEAKS_CONFIG")

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists gitleaks; then
  gitleaks "${GITLEAKS_ARGS[@]}" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  REPORT_DIR=$(mktemp -d /tmp/cg-gitleaks-report-XXXXXX)
  docker run --rm --network none \
    -v "$(pwd):/workspace:ro" -v "$REPORT_DIR:/report" \
    -v "$GITLEAKS_CONFIG:/tmp/gitleaks-config.toml:ro" \
    -w /workspace \
    "$DOCKER_IMAGE" detect --source /workspace \
    --report-format json --report-path /report/gitleaks-report.json \
    --no-banner --config /tmp/gitleaks-config.toml \
    2>/dev/null || EXIT_CODE=$?
  [[ -f "$REPORT_DIR/gitleaks-report.json" ]] && mv "$REPORT_DIR/gitleaks-report.json" "$RAW_OUTPUT"
  rm -rf "$REPORT_DIR"
else
  log_skip_tool "Gitleaks"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
# Note: gitleaks exits 1 when leaks are found (with valid output), so only fail on empty output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Gitleaks failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse output
if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
try:
    data = json.load(open('$RAW_OUTPUT'))
    if isinstance(data, list):
        for leak in data:
            finding = {
                'tool': 'gitleaks',
                'severity': 'high',
                'rule': leak.get('RuleID', leak.get('ruleID', '')),
                'message': f\"Secret detected: {leak.get('Description', leak.get('description', ''))}\",
                'file': leak.get('File', leak.get('file', '')),
                'line': leak.get('StartLine', leak.get('startLine', 0)),
                'autoFixable': False,
                'category': 'secrets'
            }
            print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT" "$GITLEAKS_CONFIG"

# Post-filter findings to scope if scope file provided
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$FINDINGS_FILE" ]]; then
  FILTERED=$(mktemp /tmp/cg-gitleaks-filtered-XXXXXX.jsonl)
  python3 -c "
import json, sys
scope_files = set()
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            scope_files.add(line)
            # Also match without leading ./
            scope_files.add(line.lstrip('./'))
with open(sys.argv[2]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            finding = json.loads(line)
            fpath = finding.get('file', '').lstrip('./')
            if fpath in scope_files or any(fpath == s.lstrip('./') for s in scope_files):
                print(line)
        except json.JSONDecodeError:
            continue
" "$SCOPE_FILE" "$FINDINGS_FILE" > "$FILTERED"
  mv "$FILTERED" "$FINDINGS_FILE"
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Gitleaks: found $count secret(s)!"
else
  log_ok "Gitleaks: no secrets found"
fi

echo "$FINDINGS_FILE"
