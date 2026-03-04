#!/usr/bin/env bash
# Hadolint scanner wrapper — Dockerfile linting
# Usage: hadolint.sh [--target <Dockerfile>]
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

FINDINGS_FILE="${OUTPUT_DIR}/hadolint-findings.jsonl"
> "$FINDINGS_FILE"

# Find all Dockerfiles
DOCKERFILES=()
if [[ -n "$TARGET" ]]; then
  DOCKERFILES=("$TARGET")
else
  while IFS= read -r -d '' f; do
    DOCKERFILES+=("$f")
  done < <(find . -maxdepth 3 \( -name "Dockerfile" -o -name "Dockerfile.*" -o -name "*.dockerfile" \) -print0 2>/dev/null)
fi

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  log_info "No Dockerfiles found, skipping Hadolint"
  exit 0
fi

log_step "Running Hadolint (Dockerfile linting)..."

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

HADOLINT_AVAILABLE=false
for dockerfile in "${DOCKERFILES[@]}"; do
  RAW_OUTPUT=$(mktemp /tmp/cg-hadolint-XXXXXX.json)
  EXIT_CODE=0

  if cmd_exists hadolint; then
    HADOLINT_AVAILABLE=true
    hadolint --format json "$dockerfile" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
    HADOLINT_AVAILABLE=true
    log_info "Using Docker image: $DOCKER_IMAGE"
    docker run --rm --network none -i "$DOCKER_IMAGE" hadolint --format json - \
      < "$dockerfile" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  else
    log_skip_tool "Hadolint"
    rm -f "$RAW_OUTPUT"
    exit 0
  fi

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    log_error "Hadolint failed on $dockerfile (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      python3 -c "
import json, sys
try:
    raw_path = sys.argv[1]
    dockerfile_path = sys.argv[2]
    data = json.load(open(raw_path))
    for item in data:
        sev_map = {'error': 'high', 'warning': 'medium', 'info': 'low', 'style': 'info'}
        finding = {
            'tool': 'hadolint',
            'severity': sev_map.get(item.get('level', 'info'), 'info'),
            'rule': item.get('code', ''),
            'message': item.get('message', ''),
            'file': dockerfile_path,
            'line': item.get('line', 0),
            'autoFixable': False,
            'category': 'container'
        }
        print(json.dumps(finding))
except Exception as e:
    pass
" "$RAW_OUTPUT" "$dockerfile" >> "$FINDINGS_FILE"
    fi
  fi
  rm -f "$RAW_OUTPUT"
done

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Hadolint: found $count issue(s)"
else
  log_ok "Hadolint: no issues found"
fi

echo "$FINDINGS_FILE"
