#!/usr/bin/env bash
# pip-audit wrapper — Python dependency vulnerability scanning
# Searches recursively for Python manifest files (monorepo-aware)
# Usage: pip-audit.sh [--autofix]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

AUTOFIX=false
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --autofix) AUTOFIX=true; shift ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/pip-audit-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover audit targets ───────────────────────────────────────────
# Find directories containing Python manifests (excluding venvs, build artifacts)
AUDIT_DIRS=()
while IFS= read -r manifest; do
  [[ -z "$manifest" ]] && continue
  dir="$(dirname "$manifest")"
  # Deduplicate directories
  already=false
  for existing in "${AUDIT_DIRS[@]+"${AUDIT_DIRS[@]}"}"; do
    [[ "$existing" == "$dir" ]] && already=true && break
  done
  $already || AUDIT_DIRS+=("$dir")
done < <(find . \( -name requirements.txt -o -name pyproject.toml -o -name setup.py -o -name Pipfile \) \
  -not -path '*/.git/*' \
  -not -path '*/venv/*' \
  -not -path '*/.venv/*' \
  -not -path '*/env/*' \
  -not -path '*/.env/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/vendor/*' \
  -not -path '*/.cache/*' \
  -not -path '*/__pycache__/*' \
  -not -path '*/dist/*' \
  -not -path '*/.tox/*' \
  -not -path '*/.nox/*' \
  -not -path '*/*.egg-info/*' \
  2>/dev/null | sort)

if [[ ${#AUDIT_DIRS[@]} -eq 0 ]]; then
  log_info "No Python dependency files found in project, skipping pip-audit (OSV-Scanner covers dependency vulnerabilities)"
  exit 0
fi

if ! cmd_exists pip-audit; then
  log_warn "pip-audit not available locally, skipping (OSV-Scanner covers dependency vulnerabilities)"
  exit 0
fi

log_step "Running pip-audit (Python dependency vulnerabilities) across ${#AUDIT_DIRS[@]} location(s)..."

for audit_dir in "${AUDIT_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$audit_dir"

  # Relative path prefix for findings (empty string for project root)
  REL_PREFIX="${audit_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  [[ -n "$REL_PREFIX" ]] && log_info "Auditing $REL_PREFIX..." || log_info "Auditing project root..."

  RAW_OUTPUT=$(mktemp /tmp/cg-pip-audit-XXXXXX.json)
  EXIT_CODE=0

  PIP_AUDIT_ARGS=("--format" "json" "--output" "$RAW_OUTPUT")
  $AUTOFIX && PIP_AUDIT_ARGS+=("--fix")

  # Determine requirements source — prefer requirements.txt for -r flag
  REQ_FILE=""
  if [[ -f requirements.txt ]]; then
    PIP_AUDIT_ARGS+=("-r" "requirements.txt")
    REQ_FILE="requirements.txt"
  fi
  # For pyproject.toml, setup.py, Pipfile — pip-audit auto-detects when run in directory

  pip-audit "${PIP_AUDIT_ARGS[@]}" 2>/dev/null || EXIT_CODE=$?

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "pip-audit failed${loc} (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      # Use the most specific manifest path for findings
      if [[ -n "$REQ_FILE" ]]; then
        MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}requirements.txt"
      elif [[ -f pyproject.toml ]]; then
        MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}pyproject.toml"
      elif [[ -f setup.py ]]; then
        MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}setup.py"
      elif [[ -f Pipfile ]]; then
        MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}Pipfile"
      else
        MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}requirements.txt"
      fi
      python3 -c "
import json, sys
manifest = '$MANIFEST_PATH'
try:
    data = json.load(open('$RAW_OUTPUT'))
    deps = data.get('dependencies', [])
    for dep in deps:
        for vuln in dep.get('vulns', []):
            finding = {
                'tool': 'pip-audit',
                'severity': 'high' if 'CRITICAL' in vuln.get('description','').upper() or 'HIGH' in vuln.get('description','').upper() else 'medium',
                'rule': vuln.get('id', ''),
                'message': f\"{dep.get('name','')}=={dep.get('version','')}: {vuln.get('description', vuln.get('id',''))[:200]}\",
                'file': manifest,
                'line': 0,
                'autoFixable': vuln.get('fix_versions', []) != [],
                'category': 'dependency'
            }
            print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" >> "$FINDINGS_FILE"
    fi
  fi

  rm -f "$RAW_OUTPUT"
done

cd "$PROJECT_ROOT"

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "pip-audit: found $count vulnerability(s)"
  $AUTOFIX && log_info "Auto-fix was applied where possible"
else
  log_ok "pip-audit: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
