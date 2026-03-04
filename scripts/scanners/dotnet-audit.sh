#!/usr/bin/env bash
# dotnet audit wrapper — .NET dependency vulnerability scanning
# Usage: dotnet-audit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/dotnet-audit-findings.jsonl"
: >"$FINDINGS_FILE"

# Check for .NET project files
has_dotnet=false
find . -maxdepth 4 \( -name "*.csproj" -o -name "*.sln" -o -name "*.fsproj" \) \
  -not -path '*/bin/*' -not -path '*/obj/*' 2>/dev/null | head -1 | grep -q . && has_dotnet=true

if ! $has_dotnet; then
  log_info "No .NET project files found, skipping dotnet audit"
  exit 0
fi

if ! cmd_exists dotnet; then
  log_skip_tool "dotnet"
  exit 0
fi

log_step "Running dotnet audit (.NET dependency vulnerabilities)..."

RAW_OUTPUT=$(mktemp /tmp/cg-dotnet-audit-XXXXXX.json)
EXIT_CODE=0

# Try JSON format first (requires .NET SDK 8+)
dotnet list package --vulnerable --format json >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?

HAS_JSON=true
if [[ $EXIT_CODE -ne 0 ]] || ! python3 -c "import json; json.load(open('$RAW_OUTPUT'))" 2>/dev/null; then
  # Fall back to tabular output for older SDKs
  HAS_JSON=false
  EXIT_CODE=0
  dotnet list package --vulnerable >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "dotnet audit failed (exit code $EXIT_CODE)"
  rm -f "$RAW_OUTPUT"
  echo "$FINDINGS_FILE"
  exit 2
fi

if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
  if cmd_exists python3; then
    python3 -c "
import json, sys, re

has_json = sys.argv[2] == 'true'

try:
    if has_json:
        data = json.load(open(sys.argv[1]))
        for project in data.get('projects', []):
            proj_path = project.get('path', '')
            for framework in project.get('frameworks', []):
                for pkg in framework.get('topLevelPackages', []) + framework.get('transitivePackages', []):
                    for vuln in pkg.get('vulnerabilities', []):
                        sev_raw = vuln.get('severity', 'Medium')
                        sev_map = {'Critical': 'high', 'High': 'high', 'Medium': 'medium', 'Low': 'low'}
                        sev = sev_map.get(sev_raw, 'medium')
                        finding = {
                            'tool': 'dotnet-audit',
                            'severity': sev,
                            'rule': vuln.get('advisoryurl', '').split('/')[-1] if vuln.get('advisoryurl') else pkg.get('id', ''),
                            'message': f\"{pkg.get('id', '')}@{pkg.get('resolvedVersion', '')}: {vuln.get('advisoryurl', 'vulnerable')}\",
                            'file': proj_path,
                            'line': 0,
                            'autoFixable': pkg.get('resolvedVersion', '') != pkg.get('requestedVersion', ''),
                            'category': 'dependency'
                        }
                        print(json.dumps(finding))
    else:
        # Parse tabular output
        current_project = ''
        with open(sys.argv[1]) as f:
            for line in f:
                line = line.rstrip()
                if line.startswith('Project'):
                    m = re.search(r\"'(.+?)'\", line)
                    if m:
                        current_project = m.group(1)
                elif '>' in line and not line.startswith('--'):
                    parts = line.split()
                    if len(parts) >= 4:
                        pkg_name = parts[1] if parts[0] == '>' else parts[0]
                        resolved = parts[2] if parts[0] == '>' else parts[1]
                        sev_raw = parts[-1] if parts[-1] in ('Critical', 'High', 'Medium', 'Low') else 'Medium'
                        sev_map = {'Critical': 'high', 'High': 'high', 'Medium': 'medium', 'Low': 'low'}
                        finding = {
                            'tool': 'dotnet-audit',
                            'severity': sev_map.get(sev_raw, 'medium'),
                            'rule': pkg_name,
                            'message': f'{pkg_name}@{resolved}: vulnerable',
                            'file': current_project,
                            'line': 0,
                            'autoFixable': False,
                            'category': 'dependency'
                        }
                        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" "$RAW_OUTPUT" "$HAS_JSON" >"$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l <"$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "dotnet audit: found $count vulnerability(s)"
else
  log_ok "dotnet audit: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
