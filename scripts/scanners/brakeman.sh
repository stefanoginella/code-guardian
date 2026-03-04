#!/usr/bin/env bash
# Brakeman scanner wrapper — Ruby on Rails SAST
# Searches recursively for Rails apps (config/routes.rb)
# Usage: brakeman.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

FINDINGS_FILE="${OUTPUT_DIR}/brakeman-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover Rails app locations ─────────────────────────────────────
SCAN_DIRS=()
while IFS= read -r routes; do
  [[ -z "$routes" ]] && continue
  # routes.rb is at config/routes.rb, so the Rails root is two levels up
  SCAN_DIRS+=("$(dirname "$(dirname "$routes")")")
done < <(find . -path '*/config/routes.rb' \
  -not -path '*/vendor/*' \
  -not -path '*/.git/*' \
  -not -path '*/node_modules/*' \
  2>/dev/null | sort)

if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
  log_info "No Rails app detected, skipping Brakeman"
  exit 0
fi

log_step "Running Brakeman (Rails SAST) across ${#SCAN_DIRS[@]} location(s)..."

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"
SCANNED=0

for scan_dir in "${SCAN_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$scan_dir"

  REL_PREFIX="${scan_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  [[ -n "$REL_PREFIX" ]] && log_info "Scanning $REL_PREFIX..." || log_info "Scanning project root..."

  RAW_OUTPUT=$(mktemp /tmp/cg-brakeman-XXXXXX.json)
  EXIT_CODE=0

  if cmd_exists brakeman; then
    brakeman --format json --quiet --no-pager > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
    log_info "Using Docker image: $DOCKER_IMAGE"
    docker run --rm --network none -v "$(pwd):/code:ro" \
      "$DOCKER_IMAGE" --format json --quiet --no-pager /code \
      > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  else
    log_skip_tool "Brakeman"
    rm -f "$RAW_OUTPUT"
    exit 0
  fi

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "Brakeman failed${loc} (exit code $EXIT_CODE)"
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
    for warning in data.get('warnings', []):
        conf_map = {'High': 'high', 'Medium': 'medium', 'Weak': 'low'}
        sev = conf_map.get(warning.get('confidence', 'Medium'), 'medium')
        fpath = warning.get('file', '')
        if rel_prefix and fpath and not fpath.startswith(rel_prefix):
            fpath = rel_prefix + '/' + fpath
        finding = {
            'tool': 'brakeman',
            'severity': sev,
            'rule': warning.get('warning_type', ''),
            'message': warning.get('message', ''),
            'file': fpath,
            'line': warning.get('line', 0) or 0,
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
  log_info "No scannable Rails apps found, skipping"
  exit 0
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Brakeman: found $count issue(s)"
else
  log_ok "Brakeman: no issues found"
fi

echo "$FINDINGS_FILE"
