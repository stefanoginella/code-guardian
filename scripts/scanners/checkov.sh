#!/usr/bin/env bash
# Checkov scanner wrapper — IaC security scanning (Terraform, CloudFormation, K8s, etc.)
# Usage: checkov.sh [--autofix]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

AUTOFIX=false
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --autofix) AUTOFIX=true; shift ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/checkov-findings.jsonl"
> "$FINDINGS_FILE"

# Check if there are IaC files to scan
has_iac=false
find . -maxdepth 4 \( -name "*.tf" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" \) -print0 2>/dev/null | \
  xargs -0 grep -lq 'resource\|AWSTemplateFormatVersion\|apiVersion:' 2>/dev/null && has_iac=true

if ! $has_iac; then
  log_info "No IaC files detected, skipping Checkov"
  exit 0
fi

log_step "Running Checkov (IaC scanning)..."

RAW_OUTPUT=$(mktemp /tmp/cg-checkov-XXXXXX.json)
EXIT_CODE=0

CHECKOV_ARGS=("-d" "." "--output" "json" "--quiet" "--compact")

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists checkov; then
  checkov "${CHECKOV_ARGS[@]}" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/tf:ro" -w /tf \
    "$DOCKER_IMAGE" "${CHECKOV_ARGS[@]}" \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "Checkov"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Checkov failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
try:
    data = json.load(open('$RAW_OUTPUT'))
    # Checkov can return a list or dict
    checks = []
    if isinstance(data, list):
        for item in data:
            checks.extend(item.get('results', {}).get('failed_checks', []))
    elif isinstance(data, dict):
        checks = data.get('results', {}).get('failed_checks', [])

    for check in checks:
        sev_map = {'CRITICAL': 'high', 'HIGH': 'high', 'MEDIUM': 'medium', 'LOW': 'low'}
        sev = sev_map.get(check.get('severity', 'MEDIUM'), 'medium')
        finding = {
            'tool': 'checkov',
            'severity': sev,
            'rule': check.get('check_id', ''),
            'message': check.get('check_result', {}).get('evaluated_keys', [''])[0] if isinstance(check.get('check_result', {}).get('evaluated_keys'), list) else check.get('name', ''),
            'file': check.get('file_path', ''),
            'line': check.get('file_line_range', [0])[0] if check.get('file_line_range') else 0,
            'autoFixable': False,
            'category': 'iac'
        }
        # Use name as message if message is empty
        if not finding['message']:
            finding['message'] = check.get('name', check.get('check_id', ''))
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Checkov: found $count issue(s)"
else
  log_ok "Checkov: no issues found"
fi

echo "$FINDINGS_FILE"
