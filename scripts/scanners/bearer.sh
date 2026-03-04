#!/usr/bin/env bash
# Bearer scanner wrapper — data-flow SAST (multi-language)
# Usage: bearer.sh [--scope-file <file>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SCOPE_FILE=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope-file)
      SCOPE_FILE="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/bearer-findings.jsonl"
: >"$FINDINGS_FILE"

log_step "Running Bearer (data-flow SAST)..."

RAW_OUTPUT=$(mktemp /tmp/cg-bearer-XXXXXX.json)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

BEARER_ARGS=("scan" "." "--format" "json" "--quiet")

# Add exclusion directories
for dir in "${CG_EXCLUDE_DIRS[@]}"; do
  BEARER_ARGS+=("--skip-path" "$dir")
done

if cmd_exists bearer; then
  bearer "${BEARER_ARGS[@]}" \
    >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/src:ro" -w /src \
    "$DOCKER_IMAGE" "${BEARER_ARGS[@]}" \
    >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "Bearer"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Bearer failed (exit code $EXIT_CODE)"
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
    data = json.load(open(sys.argv[1]))
    scope_files = None
    if len(sys.argv) > 2 and sys.argv[2]:
        scope_files = set()
        with open(sys.argv[2]) as f:
            for line in f:
                line = line.strip()
                if line:
                    scope_files.add(line)
                    scope_files.add(line.lstrip('./'))

    findings_list = data if isinstance(data, list) else data.get('findings', [])
    for item in findings_list:
        sev_raw = item.get('severity', 'warning').lower()
        sev_map = {'critical': 'high', 'high': 'high', 'warning': 'medium', 'low': 'low'}
        sev = sev_map.get(sev_raw, 'medium')

        filename = item.get('filename', item.get('full_filename', ''))
        line_num = item.get('line_number', item.get('sink', {}).get('start', 0))
        if isinstance(line_num, dict):
            line_num = line_num.get('line', 0)

        # Post-filter to scope
        if scope_files is not None:
            fpath = filename.lstrip('./')
            if fpath not in scope_files:
                continue

        finding = {
            'tool': 'bearer',
            'severity': sev,
            'rule': item.get('rule_id', item.get('id', 'bearer')),
            'message': item.get('description', item.get('title', '')),
            'file': filename,
            'line': line_num if isinstance(line_num, int) else 0,
            'autoFixable': False,
            'category': 'sast'
        }
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" "$RAW_OUTPUT" "${SCOPE_FILE:-}" >"$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l <"$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Bearer: found $count issue(s)"
else
  log_ok "Bearer: no issues found"
fi

echo "$FINDINGS_FILE"
