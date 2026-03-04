#!/usr/bin/env bash
# Grype scanner wrapper — vulnerability scanning (filesystem/SBOM)
# Usage: grype.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/grype-findings.jsonl"
: >"$FINDINGS_FILE"

log_step "Running Grype (vulnerability scanning)..."

RAW_OUTPUT=$(mktemp /tmp/cg-grype-XXXXXX.json)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

GRYPE_ARGS=("dir:." "--output" "json" "--quiet")

if cmd_exists grype; then
  grype "${GRYPE_ARGS[@]}" >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm -v "$(pwd):/workspace:ro" -w /workspace \
    "$DOCKER_IMAGE" "${GRYPE_ARGS[@]}" \
    >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "Grype"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "Grype failed (exit code $EXIT_CODE)"
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

    for match in data.get('matches', []):
        vuln = match.get('vulnerability', {})
        artifact = match.get('artifact', {})
        sev_raw = vuln.get('severity', 'Unknown')
        sev_map = {'Critical': 'high', 'High': 'high', 'Medium': 'medium', 'Low': 'low', 'Negligible': 'info'}
        sev = sev_map.get(sev_raw, 'info')

        # Determine file from artifact locations
        locations = artifact.get('locations', [])
        file_path = locations[0].get('path', '') if locations else ''

        # Post-filter to scope
        if scope_files is not None:
            fpath = file_path.lstrip('./')
            if fpath not in scope_files:
                continue

        fix_versions = vuln.get('fix', {}).get('versions', [])
        finding = {
            'tool': 'grype',
            'severity': sev,
            'rule': vuln.get('id', ''),
            'message': f\"{artifact.get('name', '')}@{artifact.get('version', '')}: {vuln.get('description', vuln.get('id', ''))}\",
            'file': file_path,
            'line': 0,
            'autoFixable': len(fix_versions) > 0,
            'category': 'vulnerability'
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
  log_warn "Grype: found $count vulnerability(s)"
else
  log_ok "Grype: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
