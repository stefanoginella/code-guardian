#!/usr/bin/env bash
# Bandit scanner wrapper — Python SAST
# Usage: bandit.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/bandit-findings.jsonl"
> "$FINDINGS_FILE"

# Check for Python files
py_files_exist=false
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]]; then
  grep -q '\.py$' "$SCOPE_FILE" 2>/dev/null && py_files_exist=true
else
  find . -name "*.py" -maxdepth 4 2>/dev/null | head -1 &>/dev/null && py_files_exist=true
fi

if ! $py_files_exist; then
  log_info "No Python files found, skipping Bandit"
  exit 0
fi

log_step "Running Bandit (Python SAST)..."

RAW_OUTPUT=$(mktemp /tmp/cg-bandit-XXXXXX.json)
EXIT_CODE=0

BANDIT_ARGS=("-r" "." "-f" "json" "-q" "--exclude" "$(get_exclude_dirs_csv)")

# Scope filtering: build array of .py files from scope
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$SCOPE_FILE" ]]; then
  py_file_args=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && py_file_args+=("$f")
  done < <(grep '\.py$' "$SCOPE_FILE")
  if [[ ${#py_file_args[@]} -gt 0 ]]; then
    BANDIT_ARGS=("-f" "json" "-q" "${py_file_args[@]}")
  fi
fi

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists bandit; then
  bandit "${BANDIT_ARGS[@]}" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  # Write args to a temp file to avoid shell quoting issues in sh -c
  ARGS_FILE=$(mktemp /tmp/cg-bandit-args-XXXXXX)
  printf '%s\0' "${BANDIT_ARGS[@]}" > "$ARGS_FILE"
  docker run --rm -v "$(pwd):/src:ro" -v "$ARGS_FILE:/tmp/bandit-args:ro" -w /src \
    "$DOCKER_IMAGE" sh -c 'pip install -q bandit && xargs -0 bandit < /tmp/bandit-args' \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  rm -f "$ARGS_FILE"
else
  log_skip_tool "Bandit"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Bandit failed (exit code $EXIT_CODE)"
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
    for result in data.get('results', []):
        sev = result.get('issue_severity', 'MEDIUM').lower()
        finding = {
            'tool': 'bandit',
            'severity': sev if sev in ('high','medium','low') else 'medium',
            'rule': result.get('test_id', ''),
            'message': result.get('issue_text', ''),
            'file': result.get('filename', ''),
            'line': result.get('line_number', 0),
            'autoFixable': False,
            'category': 'sast'
        }
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Bandit: found $count issue(s)"
else
  log_ok "Bandit: no issues found"
fi

echo "$FINDINGS_FILE"
