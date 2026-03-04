#!/usr/bin/env bash
# SpotBugs scanner wrapper — Java bytecode SAST
# Usage: spotbugs.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/spotbugs-findings.jsonl"
: >"$FINDINGS_FILE"

# Check for compiled bytecode — SpotBugs needs .class files
has_bytecode=false
if find . -maxdepth 6 \( -path "*/target/classes/*.class" -o -path "*/build/classes/*.class" \) 2>/dev/null | head -1 | grep -q .; then
  has_bytecode=true
fi

if ! $has_bytecode; then
  log_info "No compiled Java bytecode found (target/classes or build/classes), skipping SpotBugs"
  log_info "  Build the project first (mvn compile / gradle build) to enable SpotBugs analysis"
  exit 0
fi

log_step "Running SpotBugs (Java bytecode SAST)..."

RAW_OUTPUT=$(mktemp /tmp/cg-spotbugs-XXXXXX.xml)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

# Collect class directories
CLASS_DIRS=()
while IFS= read -r d; do
  [[ -n "$d" ]] && CLASS_DIRS+=("$d")
done < <(find . -maxdepth 6 \( -path "*/target/classes" -o -path "*/build/classes" \) -type d 2>/dev/null)

if [[ ${#CLASS_DIRS[@]} -eq 0 ]]; then
  log_info "No class directories found, skipping SpotBugs"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

SPOTBUGS_ARGS=("-textui" "-xml:withMessages" "-effort:max" "-low" "-output" "$RAW_OUTPUT")
SPOTBUGS_ARGS+=("${CLASS_DIRS[@]}")

if cmd_exists spotbugs; then
  spotbugs "${SPOTBUGS_ARGS[@]}" >/dev/null 2>&1 || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/workspace:ro" -w /workspace \
    "$DOCKER_IMAGE" "${SPOTBUGS_ARGS[@]}" \
    >/dev/null 2>&1 || EXIT_CODE=$?
else
  log_skip_tool "SpotBugs"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "SpotBugs failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

# Parse XML output
if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys
import xml.etree.ElementTree as ET

scope_files = None
if len(sys.argv) > 2 and sys.argv[2]:
    scope_files = set()
    with open(sys.argv[2]) as f:
        for line in f:
            line = line.strip()
            if line:
                scope_files.add(line)
                scope_files.add(line.lstrip('./'))

try:
    tree = ET.parse(sys.argv[1])
    root = tree.getroot()
    for bug in root.iter('BugInstance'):
        priority = int(bug.get('priority', '3'))
        sev_map = {1: 'high', 2: 'medium'}
        sev = sev_map.get(priority, 'low')

        bug_type = bug.get('type', '')
        category = bug.get('category', '')
        message_elem = bug.find('LongMessage')
        message = message_elem.text if message_elem is not None else bug.get('type', '')

        # Get source location
        source = bug.find('SourceLine')
        file_path = ''
        line_num = 0
        if source is not None:
            file_path = source.get('sourcepath', '')
            line_num = int(source.get('start', '0'))

        # Post-filter to scope
        if scope_files is not None:
            fpath = file_path.lstrip('./')
            if fpath not in scope_files:
                continue

        finding = {
            'tool': 'spotbugs',
            'severity': sev,
            'rule': bug_type,
            'message': f'[{category}] {message}',
            'file': file_path,
            'line': line_num,
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
  log_warn "SpotBugs: found $count issue(s)"
else
  log_ok "SpotBugs: no issues found"
fi

echo "$FINDINGS_FILE"
