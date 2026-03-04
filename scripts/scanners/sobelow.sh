#!/usr/bin/env bash
# Sobelow scanner wrapper — Elixir/Phoenix security scanner
# Usage: sobelow.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/sobelow-findings.jsonl"
: >"$FINDINGS_FILE"

# Check for mix.exs (Elixir project)
if [[ ! -f mix.exs ]]; then
  log_info "No mix.exs found, skipping Sobelow"
  exit 0
fi

if ! cmd_exists mix; then
  log_skip_tool "Sobelow (mix)"
  exit 0
fi

log_step "Running Sobelow (Elixir security scanner)..."

RAW_OUTPUT=$(mktemp /tmp/cg-sobelow-XXXXXX.json)
EXIT_CODE=0

mix sobelow --format json --quiet >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Sobelow failed (exit code $EXIT_CODE)"
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

    findings_list = data.get('findings', data) if isinstance(data, dict) else data
    if not isinstance(findings_list, list):
        findings_list = []

    for item in findings_list:
        confidence = item.get('confidence', 'Medium')
        sev_map = {'High': 'high', 'Medium': 'medium', 'Low': 'low'}
        sev = sev_map.get(confidence, 'medium')

        file_path = item.get('file', '')
        line_num = item.get('line', 0)

        # Post-filter to scope
        if scope_files is not None:
            fpath = file_path.lstrip('./')
            if fpath not in scope_files:
                continue

        finding = {
            'tool': 'sobelow',
            'severity': sev,
            'rule': item.get('type', 'sobelow'),
            'message': item.get('type', item.get('description', '')),
            'file': file_path,
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
  log_warn "Sobelow: found $count issue(s)"
else
  log_ok "Sobelow: no issues found"
fi

echo "$FINDINGS_FILE"
