#!/usr/bin/env bash
# Trivy scanner wrapper — vulnerability scanning (filesystem, containers, IaC)
# Usage: trivy.sh [--mode fs|image|config] [--target <path_or_image>] [--scope-file <file>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

MODE="fs"
TARGET="."
SCOPE_FILE=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --scope-file) SCOPE_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/trivy-findings.jsonl"
> "$FINDINGS_FILE"

log_step "Running Trivy ($MODE mode)..."

RAW_OUTPUT=$(mktemp /tmp/cg-trivy-XXXXXX.json)
EXIT_CODE=0

TRIVY_ARGS=("$MODE" "--format" "json" "--quiet")

# Add directory exclusions for filesystem and config scans
if [[ "$MODE" == "fs" ]] || [[ "$MODE" == "config" ]]; then
  for dir in "${CG_EXCLUDE_DIRS[@]}"; do
    TRIVY_ARGS+=("--skip-dirs" "$dir")
  done
fi

case "$MODE" in
  fs)
    TRIVY_ARGS+=("--scanners" "vuln,secret,misconfig")
    TRIVY_ARGS+=("$TARGET")
    ;;
  image)
    TRIVY_ARGS+=("$TARGET")
    ;;
  config)
    TRIVY_ARGS+=("$TARGET")
    ;;
esac

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists trivy; then
  trivy "${TRIVY_ARGS[@]}" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker_run_args=("--rm" "-v" "$(pwd):/workspace:ro" "-w" "/workspace")
  # For image scanning, need Docker socket
  [[ "$MODE" == "image" ]] && docker_run_args+=("-v" "/var/run/docker.sock:/var/run/docker.sock")
  # Trivy cache
  docker_run_args+=("-v" "${HOME}/.cache/trivy:/root/.cache/")

  docker run "${docker_run_args[@]}" "$DOCKER_IMAGE" "${TRIVY_ARGS[@]}" \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "Trivy"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Trivy failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse trivy JSON output
if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
try:
    data = json.load(open('$RAW_OUTPUT'))
    results = data.get('Results', [])
    for result in results:
        target = result.get('Target', '')
        # Vulnerabilities
        for vuln in result.get('Vulnerabilities', []):
            sev = vuln.get('Severity', 'UNKNOWN').lower()
            if sev == 'critical': sev = 'high'
            finding = {
                'tool': 'trivy',
                'severity': sev if sev in ('high','medium','low','info') else 'info',
                'rule': vuln.get('VulnerabilityID', ''),
                'message': f\"{vuln.get('PkgName','')}: {vuln.get('Title','')}\",
                'file': target,
                'line': 0,
                'autoFixable': vuln.get('FixedVersion', '') != '',
                'category': 'dependency'
            }
            print(json.dumps(finding))
        # Secrets
        for secret in result.get('Secrets', []):
            finding = {
                'tool': 'trivy',
                'severity': secret.get('Severity', 'high').lower(),
                'rule': secret.get('RuleID', ''),
                'message': secret.get('Title', ''),
                'file': target,
                'line': secret.get('StartLine', 0),
                'autoFixable': False,
                'category': 'secrets'
            }
            print(json.dumps(finding))
        # Misconfigs
        for mc in result.get('Misconfigurations', []):
            sev = mc.get('Severity', 'UNKNOWN').lower()
            if sev == 'critical': sev = 'high'
            finding = {
                'tool': 'trivy',
                'severity': sev if sev in ('high','medium','low','info') else 'info',
                'rule': mc.get('ID', ''),
                'message': mc.get('Title', ''),
                'file': target,
                'line': 0,
                'autoFixable': False,
                'category': 'iac'
            }
            print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

# Post-filter findings to scope if scope file provided
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$FINDINGS_FILE" ]]; then
  FILTERED=$(mktemp /tmp/cg-trivy-filtered-XXXXXX.jsonl)
  python3 -c "
import json, sys
scope_files = set()
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            scope_files.add(line)
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
  log_warn "Trivy ($MODE): found $count issue(s)"
else
  log_ok "Trivy ($MODE): no issues found"
fi

echo "$FINDINGS_FILE"
