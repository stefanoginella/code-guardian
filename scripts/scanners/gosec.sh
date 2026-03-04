#!/usr/bin/env bash
# gosec scanner wrapper — Go SAST
# Searches recursively for go.mod files (multi-module aware)
# Usage: gosec.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/gosec-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover go.mod locations ────────────────────────────────────────
SCAN_DIRS=()
while IFS= read -r gomod; do
  [[ -z "$gomod" ]] && continue
  SCAN_DIRS+=("$(dirname "$gomod")")
done < <(find . -name go.mod \
  -not -path '*/vendor/*' \
  -not -path '*/.git/*' \
  2>/dev/null | sort)

if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
  log_info "No go.mod found, skipping gosec"
  exit 0
fi

log_step "Running gosec (Go SAST) across ${#SCAN_DIRS[@]} location(s)..."

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"
SCANNED=0

for scan_dir in "${SCAN_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$scan_dir"

  REL_PREFIX="${scan_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  [[ -n "$REL_PREFIX" ]] && log_info "Scanning $REL_PREFIX..." || log_info "Scanning project root..."

  RAW_OUTPUT=$(mktemp /tmp/cg-gosec-XXXXXX.json)
  EXIT_CODE=0

  if cmd_exists gosec; then
    gosec -fmt=json -out="$RAW_OUTPUT" ./... 2>/dev/null || EXIT_CODE=$?
  elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
    log_info "Using Docker image: $DOCKER_IMAGE"
    REPORT_DIR=$(mktemp -d /tmp/cg-gosec-report-XXXXXX)
    docker run --rm --network none \
      -v "$(pwd):/workspace:ro" -v "$REPORT_DIR:/report" -w /workspace \
      "$DOCKER_IMAGE" -fmt=json -out=/report/gosec-output.json ./... 2>/dev/null || EXIT_CODE=$?
    [[ -f "$REPORT_DIR/gosec-output.json" ]] && mv "$REPORT_DIR/gosec-output.json" "$RAW_OUTPUT"
    rm -rf "$REPORT_DIR"
  else
    log_skip_tool "gosec"
    rm -f "$RAW_OUTPUT"
    exit 0
  fi

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "gosec failed${loc} (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      python3 -c "
import json, sys
rel_prefix = '$REL_PREFIX'
try:
    data = json.load(open('$RAW_OUTPUT'))
    for issue in data.get('Issues', []):
        sev = issue.get('severity', 'MEDIUM').lower()
        fpath = issue.get('file', '')
        # Prefix relative path for subdirectory modules
        if rel_prefix and fpath and not fpath.startswith(rel_prefix):
            fpath = rel_prefix + '/' + fpath
        finding = {
            'tool': 'gosec',
            'severity': sev if sev in ('high','medium','low') else 'medium',
            'rule': issue.get('rule_id', issue.get('cwe', {}).get('id', '')),
            'message': issue.get('details', ''),
            'file': fpath,
            'line': int(issue.get('line', '0').split('-')[0]) if issue.get('line') else 0,
            'autoFixable': False,
            'category': 'sast'
        }
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" >> "$FINDINGS_FILE"
    fi
  fi

  rm -f "$RAW_OUTPUT"
  SCANNED=$((SCANNED + 1))
done

cd "$PROJECT_ROOT"

if [[ $SCANNED -eq 0 ]]; then
  log_info "No scannable Go modules found, skipping"
  exit 0
fi

# Post-filter findings to scope if scope file provided
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$FINDINGS_FILE" ]]; then
  FILTERED=$(mktemp /tmp/cg-gosec-filtered-XXXXXX.jsonl)
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
  log_warn "gosec: found $count issue(s)"
else
  log_ok "gosec: no issues found"
fi

echo "$FINDINGS_FILE"
