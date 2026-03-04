#!/usr/bin/env bash
# TruffleHog scanner wrapper — deep secret detection (filesystem)
# Usage: trufflehog.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/trufflehog-findings.jsonl"
> "$FINDINGS_FILE"

log_step "Running TruffleHog (deep secret detection)..."

RAW_OUTPUT=$(mktemp /tmp/cg-trufflehog-XXXXXX.json)
> "$RAW_OUTPUT"
EXIT_CODE=0

# Build exclude-paths file for trufflehog
EXCLUDE_FILE=$(write_exclude_paths_file)

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

if cmd_exists trufflehog; then
  trufflehog filesystem --json --no-update \
    --exclude-paths "$EXCLUDE_FILE" . \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none \
    -v "$(pwd):/workspace:ro" -v "$EXCLUDE_FILE:/tmp/exclude-paths:ro" \
    -w /workspace \
    "$DOCKER_IMAGE" filesystem --json --no-update \
    --exclude-paths /tmp/exclude-paths /workspace \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "TruffleHog"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "TruffleHog failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse output — TruffleHog outputs one JSON object per line (JSONL)
if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
seen = set()
with open('$RAW_OUTPUT') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            # TruffleHog outputs SourceMetadata with Data containing file info
            source = obj.get('SourceMetadata', {}).get('Data', {})
            # Filesystem source has 'Filesystem' key
            fs_data = source.get('Filesystem', {})
            file_path = fs_data.get('file', '')
            line_num = fs_data.get('line', 0)
            # Git source has 'Git' key
            if not file_path:
                git_data = source.get('Git', {})
                file_path = git_data.get('file', '')
                line_num = git_data.get('line', 0)
            detector = obj.get('DetectorName', obj.get('detectorName', ''))
            # Deduplicate by detector + file + line
            key = f'{detector}:{file_path}:{line_num}'
            if key in seen:
                continue
            seen.add(key)
            finding = {
                'tool': 'trufflehog',
                'severity': 'high',
                'rule': detector,
                'message': f'Secret detected by {detector} detector',
                'file': file_path,
                'line': int(line_num) if line_num else 0,
                'autoFixable': False,
                'category': 'secrets'
            }
            print(json.dumps(finding))
        except (json.JSONDecodeError, KeyError):
            continue
" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT" "$EXCLUDE_FILE"

# Post-filter findings to scope if scope file provided
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$FINDINGS_FILE" ]]; then
  FILTERED=$(mktemp /tmp/cg-trufflehog-filtered-XXXXXX.jsonl)
  python3 -c "
import json, sys
scope_files = set()
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            scope_files.add(line)
            scope_files.add(line.lstrip('./'))
with open(sys.argv[2]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            finding = json.loads(line)
            fpath = finding.get('file', '').lstrip('./')
            if fpath in scope_files or any(fpath == s.lstrip('./') for s in scope_files):
                print(line)
        except json.JSONDecodeError:
            continue
" "$SCOPE_FILE" "$FINDINGS_FILE" > "$FILTERED"
  mv "$FILTERED" "$FINDINGS_FILE"
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "TruffleHog: found $count secret(s)!"
else
  log_ok "TruffleHog: no secrets found"
fi

echo "$FINDINGS_FILE"
