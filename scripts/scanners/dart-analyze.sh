#!/usr/bin/env bash
# dart analyze scanner wrapper — Dart/Flutter static analysis
# Usage: dart-analyze.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/dart-analyze-findings.jsonl"
: >"$FINDINGS_FILE"

# Check for Dart files or pubspec.yaml
has_dart=false
if [[ -f pubspec.yaml ]] || find . -maxdepth 4 -name "*.dart" -not -path '*/.dart_tool/*' 2>/dev/null | head -1 | grep -q .; then
  has_dart=true
fi

if ! $has_dart; then
  log_info "No Dart files found, skipping dart analyze"
  exit 0
fi

if ! cmd_exists dart; then
  log_skip_tool "dart"
  exit 0
fi

log_step "Running dart analyze (Dart/Flutter static analysis)..."

RAW_OUTPUT=$(mktemp /tmp/cg-dart-analyze-XXXXXX.json)
EXIT_CODE=0

dart analyze --format=json . >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "dart analyze failed (exit code $EXIT_CODE)"
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

    for diag in data.get('diagnostics', []):
        sev_raw = diag.get('severity', 'INFO').upper()
        sev_map = {'ERROR': 'high', 'WARNING': 'medium', 'INFO': 'low'}
        sev = sev_map.get(sev_raw, 'low')

        location = diag.get('location', {})
        file_path = location.get('file', '')
        range_info = location.get('range', {})
        start = range_info.get('start', {})
        line_num = start.get('line', 0)

        # Post-filter to scope
        if scope_files is not None:
            fpath = file_path.lstrip('./')
            if fpath not in scope_files:
                continue

        finding = {
            'tool': 'dart-analyze',
            'severity': sev,
            'rule': diag.get('code', 'dart-analyze'),
            'message': diag.get('problemMessage', ''),
            'file': file_path,
            'line': line_num,
            'autoFixable': diag.get('hasFix', False),
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
  log_warn "dart analyze: found $count issue(s)"
else
  log_ok "dart analyze: no issues found"
fi

echo "$FINDINGS_FILE"
