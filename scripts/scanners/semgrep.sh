#!/usr/bin/env bash
# Semgrep scanner wrapper — multi-language SAST with autofix support
# Usage: semgrep.sh [--autofix] [--scope-file <file>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

AUTOFIX=false
SCOPE_FILE=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --autofix) AUTOFIX=true; shift ;;
    --scope-file) SCOPE_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/semgrep-findings.jsonl"
> "$FINDINGS_FILE"

log_step "Running Semgrep (SAST)..."

# Build semgrep command
SEMGREP_ARGS=("--config" "auto" "--json" "--quiet")
$AUTOFIX && SEMGREP_ARGS+=("--autofix")

# Scope handling: if scope file provided, use --include for each file
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$SCOPE_FILE" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && SEMGREP_ARGS+=("--include" "$f")
  done < "$SCOPE_FILE"
fi

# Run semgrep
RAW_OUTPUT=$(mktemp /tmp/cg-semgrep-XXXXXX.json)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists semgrep; then
  semgrep "${SEMGREP_ARGS[@]}" . > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  mount_flag=":ro"
  $AUTOFIX && mount_flag=""
  docker run --rm -v "$(pwd):/src${mount_flag}" -w /src \
    "$DOCKER_IMAGE" semgrep "${SEMGREP_ARGS[@]}" /src \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "Semgrep"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Semgrep failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse semgrep JSON output into unified format
if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  # Extract results array using python/jq
  if cmd_exists python3; then
    python3 -c "
import json, sys
try:
    data = json.load(open('$RAW_OUTPUT'))
    results = data.get('results', [])
    for r in results:
        severity_map = {'ERROR': 'high', 'WARNING': 'medium', 'INFO': 'low'}
        sev = severity_map.get(r.get('extra', {}).get('severity', 'INFO'), 'info')
        finding = {
            'tool': 'semgrep',
            'severity': sev,
            'rule': r.get('check_id', 'unknown'),
            'message': r.get('extra', {}).get('message', '').replace('\n', ' '),
            'file': r.get('path', ''),
            'line': r.get('start', {}).get('line', 0),
            'autoFixable': r.get('extra', {}).get('fix', '') != '',
            'category': 'sast'
        }
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" > "$FINDINGS_FILE"
  elif cmd_exists jq; then
    jq -c '.results[] | {
      tool: "semgrep",
      severity: (if .extra.severity == "ERROR" then "high" elif .extra.severity == "WARNING" then "medium" else "low" end),
      rule: .check_id,
      message: (.extra.message // "" | gsub("\n"; " ")),
      file: .path,
      line: .start.line,
      autoFixable: ((.extra.fix // "") != ""),
      category: "sast"
    }' "$RAW_OUTPUT" > "$FINDINGS_FILE" 2>/dev/null || true
  fi
fi

rm -f "$RAW_OUTPUT"

# Count findings
count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Semgrep: found $count issue(s)"
  $AUTOFIX && log_info "Auto-fix was applied where possible"
else
  log_ok "Semgrep: no issues found"
fi

echo "$FINDINGS_FILE"
