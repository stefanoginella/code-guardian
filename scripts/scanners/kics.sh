#!/usr/bin/env bash
# KICS scanner wrapper — IaC security scanning (Terraform, CloudFormation, K8s, Docker, etc.)
# Usage: kics.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/kics-findings.jsonl"
: >"$FINDINGS_FILE"

# Check if there are IaC files to scan
has_iac=false
find . -maxdepth 4 \( -name "*.tf" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "Dockerfile" -o -name "docker-compose*.yml" \) -print0 2>/dev/null \
  | xargs -0 grep -lq 'resource\|AWSTemplateFormatVersion\|apiVersion:\|FROM\|services:' 2>/dev/null && has_iac=true

if ! $has_iac; then
  log_info "No IaC files detected, skipping KICS"
  exit 0
fi

log_step "Running KICS (IaC scanning)..."

KICS_TMPDIR=$(mktemp -d /tmp/cg-kics-XXXXXX)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

KICS_ARGS=("scan" "-p" "." "--output-path" "$KICS_TMPDIR" "--report-formats" "json" "--no-progress")

# Add exclusion directories
for dir in "${CG_EXCLUDE_DIRS[@]}"; do
  KICS_ARGS+=("--exclude-paths" "$dir")
done

if cmd_exists kics; then
  kics "${KICS_ARGS[@]}" >/dev/null 2>&1 || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/workspace:ro" -v "$KICS_TMPDIR:/output" \
    "$DOCKER_IMAGE" scan -p /workspace --output-path /output --report-formats json --no-progress \
    >/dev/null 2>&1 || EXIT_CODE=$?
else
  log_skip_tool "KICS"
  rm -rf "$KICS_TMPDIR"
  exit 0
fi

# KICS exits with non-zero on findings; look for results file
RAW_OUTPUT="${KICS_TMPDIR}/results.json"

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "KICS failed (exit code $EXIT_CODE)"
  rm -rf "$KICS_TMPDIR"
  echo "$FINDINGS_FILE"
  exit 2
fi

if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for query in data.get('queries', []):
        sev_raw = query.get('severity', 'MEDIUM').upper()
        sev_map = {'CRITICAL': 'high', 'HIGH': 'high', 'MEDIUM': 'medium', 'LOW': 'low', 'INFO': 'info', 'TRACE': 'info'}
        sev = sev_map.get(sev_raw, 'medium')
        query_name = query.get('query_name', '')
        query_id = query.get('query_id', '')
        for f in query.get('files', []):
            finding = {
                'tool': 'kics',
                'severity': sev,
                'rule': query_id if query_id else query_name,
                'message': f\"{query_name}: {f.get('expected_value', f.get('actual_value', ''))}\",
                'file': f.get('file_name', ''),
                'line': f.get('line', 0),
                'autoFixable': False,
                'category': 'iac'
            }
            print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" "$RAW_OUTPUT" >"$FINDINGS_FILE"
  fi
fi

rm -rf "$KICS_TMPDIR"

count=$(wc -l <"$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "KICS: found $count issue(s)"
else
  log_ok "KICS: no issues found"
fi

echo "$FINDINGS_FILE"
