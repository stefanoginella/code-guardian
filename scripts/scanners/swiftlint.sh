#!/usr/bin/env bash
# SwiftLint scanner wrapper — Swift linter/SAST
# Usage: swiftlint.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/swiftlint-findings.jsonl"
: >"$FINDINGS_FILE"

# Check for Swift files
has_swift=false
find . -maxdepth 4 -name "*.swift" -not -path '*/.build/*' -not -path '*/Pods/*' "${CG_FIND_EXCLUDE_ARGS[@]}" 2>/dev/null | head -1 | grep -q . && has_swift=true

if ! $has_swift; then
  log_info "No Swift files found, skipping SwiftLint"
  exit 0
fi

log_step "Running SwiftLint (Swift linter)..."

RAW_OUTPUT=$(mktemp /tmp/cg-swiftlint-XXXXXX.json)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

SWIFTLINT_ARGS=("lint" "--reporter" "json" "--quiet")

if cmd_exists swiftlint; then
  swiftlint "${SWIFTLINT_ARGS[@]}" \
    >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/workspace:ro" -w /workspace \
    "$DOCKER_IMAGE" swiftlint "${SWIFTLINT_ARGS[@]}" \
    >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "SwiftLint"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "SwiftLint failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse JSON output
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

    for item in data:
        sev_raw = item.get('severity', 'Warning')
        sev_map = {'Error': 'high', 'error': 'high', 'Warning': 'medium', 'warning': 'medium'}
        sev = sev_map.get(sev_raw, 'medium')

        file_path = item.get('file', '')
        line_num = item.get('line', 0)

        # Post-filter to scope
        if scope_files is not None:
            fpath = file_path.lstrip('./')
            if fpath not in scope_files:
                continue

        finding = {
            'tool': 'swiftlint',
            'severity': sev,
            'rule': item.get('rule_id', ''),
            'message': item.get('reason', ''),
            'file': file_path,
            'line': line_num,
            'autoFixable': item.get('correction', None) is not None,
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
  log_warn "SwiftLint: found $count issue(s)"
else
  log_ok "SwiftLint: no issues found"
fi

echo "$FINDINGS_FILE"
