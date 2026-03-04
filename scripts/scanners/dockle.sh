#!/usr/bin/env bash
# Dockle wrapper — container image best practice linter
# Usage: dockle.sh [--target <image_name>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

TARGET=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/dockle-findings.jsonl"
> "$FINDINGS_FILE"

if [[ -z "$TARGET" ]]; then
  log_info "No Docker image target specified, skipping Dockle"
  exit 0
fi

log_step "Running Dockle (container image lint: $TARGET)..."

RAW_OUTPUT=$(mktemp /tmp/cg-dockle-XXXXXX.json)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists dockle; then
  dockle --format json "$TARGET" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]] && docker image inspect "$TARGET" &>/dev/null; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v /var/run/docker.sock:/var/run/docker.sock \
    "$DOCKER_IMAGE" --format json "$TARGET" \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "Dockle"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Dockle failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
try:
    raw_path = sys.argv[1]
    target_name = sys.argv[2]
    data = json.load(open(raw_path))
    for detail in data.get('details', []):
        sev_map = {'FATAL': 'high', 'WARN': 'medium', 'INFO': 'low', 'SKIP': 'info', 'PASS': 'info'}
        finding = {
            'tool': 'dockle',
            'severity': sev_map.get(detail.get('level', 'INFO'), 'info'),
            'rule': detail.get('code', ''),
            'message': detail.get('title', ''),
            'file': target_name,
            'line': 0,
            'autoFixable': False,
            'category': 'container'
        }
        if finding['severity'] != 'info':
            print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" "$RAW_OUTPUT" "$TARGET" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Dockle: found $count issue(s)"
else
  log_ok "Dockle: no issues found"
fi

echo "$FINDINGS_FILE"
