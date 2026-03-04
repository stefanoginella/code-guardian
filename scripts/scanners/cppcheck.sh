#!/usr/bin/env bash
# cppcheck scanner wrapper — C/C++ static analysis
# Usage: cppcheck.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/cppcheck-findings.jsonl"
: >"$FINDINGS_FILE"

# Check for C/C++ files
has_cpp=false
find . -maxdepth 4 \( -name "*.c" -o -name "*.cpp" -o -name "*.cc" -o -name "*.h" -o -name "*.hpp" \) \
  -not -path '*/vendor/*' -not -path '*/build/*' -not -path '*/.build/*' 2>/dev/null | head -1 | grep -q . && has_cpp=true

if ! $has_cpp; then
  log_info "No C/C++ source files found, skipping cppcheck"
  exit 0
fi

log_step "Running cppcheck (C/C++ static analysis)..."

RAW_OUTPUT=$(mktemp /tmp/cg-cppcheck-XXXXXX.xml)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

CPPCHECK_ARGS=("--xml" "--enable=warning,portability" "--error-exitcode=0" "--quiet")

# Add exclusion dirs
for dir in "${CG_EXCLUDE_DIRS[@]}"; do
  CPPCHECK_ARGS+=("-i" "$dir")
done

CPPCHECK_ARGS+=(".")

if cmd_exists cppcheck; then
  cppcheck "${CPPCHECK_ARGS[@]}" 2>"$RAW_OUTPUT" >/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/src:ro" -w /src \
    "$DOCKER_IMAGE" cppcheck "${CPPCHECK_ARGS[@]}" 2>"$RAW_OUTPUT" >/dev/null || EXIT_CODE=$?
else
  log_skip_tool "cppcheck"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "cppcheck failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse XML output
if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
import xml.etree.ElementTree as ET

scope_files = None
if len(sys.argv) > 2 and sys.argv[2]:
    scope_files = set()
    with open(sys.argv[2]) as f:
        for line in f:
            line = line.strip()
            if line:
                scope_files.add(line)
                scope_files.add(line.lstrip('./'))

try:
    tree = ET.parse(sys.argv[1])
    root = tree.getroot()
    errors = root.find('errors')
    if errors is None:
        sys.exit(0)
    for error in errors.iter('error'):
        sev_raw = error.get('severity', 'style')
        sev_map = {'error': 'high', 'warning': 'medium', 'style': 'low', 'performance': 'low', 'portability': 'low', 'information': 'info'}
        sev = sev_map.get(sev_raw, 'low')

        error_id = error.get('id', '')
        message = error.get('msg', error.get('verbose', ''))

        # Get location
        location = error.find('location')
        file_path = ''
        line_num = 0
        if location is not None:
            file_path = location.get('file', '')
            line_num = int(location.get('line', '0'))

        # Post-filter to scope
        if scope_files is not None:
            fpath = file_path.lstrip('./')
            if fpath not in scope_files:
                continue

        finding = {
            'tool': 'cppcheck',
            'severity': sev,
            'rule': error_id,
            'message': message,
            'file': file_path,
            'line': line_num,
            'autoFixable': False,
            'category': 'sast'
        }
        print(json.dumps(finding))
except ET.ParseError:
    pass
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" "$RAW_OUTPUT" "${SCOPE_FILE:-}" >"$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l <"$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "cppcheck: found $count issue(s)"
else
  log_ok "cppcheck: no issues found"
fi

echo "$FINDINGS_FILE"
