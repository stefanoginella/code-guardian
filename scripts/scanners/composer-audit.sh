#!/usr/bin/env bash
# Composer audit wrapper — PHP dependency vulnerability scanning
# Searches recursively for composer.json files (monorepo-aware)
# Usage: composer-audit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/composer-audit-findings.jsonl"
: >"$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# Discover audit targets — find directories containing composer.json
AUDIT_DIRS=()
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  AUDIT_DIRS+=("$(dirname "$pkg")")
done < <(find . -name composer.json \
  -not -path '*/vendor/*' \
  -not -path '*/.git/*' \
  -not -path '*/.cache/*' \
  "${CG_FIND_EXCLUDE_ARGS[@]}" \
  2>/dev/null | sort)

if [[ ${#AUDIT_DIRS[@]} -eq 0 ]]; then
  log_info "No composer.json found, skipping Composer audit"
  exit 0
fi

if ! cmd_exists composer; then
  log_skip_tool "Composer"
  exit 0
fi

log_step "Running Composer audit (PHP dependency vulnerabilities) across ${#AUDIT_DIRS[@]} location(s)..."

AUDITED=0

for audit_dir in "${AUDIT_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$audit_dir"

  # Relative path prefix for findings
  REL_PREFIX="${audit_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  # Skip dirs without a lock file — audit requires composer.lock
  if [[ ! -f composer.lock ]]; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_info "No composer.lock${loc}, skipping (run composer install first)"
    continue
  fi

  [[ -n "$REL_PREFIX" ]] && log_info "Auditing $REL_PREFIX..." || log_info "Auditing project root..."

  RAW_OUTPUT=$(mktemp /tmp/cg-composer-audit-XXXXXX.json)
  EXIT_CODE=0

  composer audit --format=json >"$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "Composer audit failed${loc} (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}composer.json"
      python3 -c "
import json, sys
manifest = sys.argv[1]
try:
    data = json.load(open(sys.argv[2]))
    advisories = data.get('advisories', {})
    for pkg_name, advs in advisories.items():
        for adv in advs:
            sev_raw = adv.get('severity', 'medium').lower()
            sev_map = {'critical': 'high', 'high': 'high', 'medium': 'medium', 'low': 'low'}
            sev = sev_map.get(sev_raw, 'medium')
            finding = {
                'tool': 'composer-audit',
                'severity': sev,
                'rule': adv.get('advisoryId', adv.get('cve', pkg_name)),
                'message': f\"{pkg_name}: {adv.get('title', adv.get('advisoryId', ''))}\",
                'file': manifest,
                'line': 0,
                'autoFixable': False,
                'category': 'dependency'
            }
            print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" "$MANIFEST_PATH" "$RAW_OUTPUT" >>"$FINDINGS_FILE"
    fi
  fi

  rm -f "$RAW_OUTPUT"
  AUDITED=$((AUDITED + 1))
done

cd "$PROJECT_ROOT"

if [[ $AUDITED -eq 0 ]]; then
  log_info "No auditable PHP projects found, skipping"
  exit 0
fi

count=$(wc -l <"$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "Composer audit: found $count vulnerability(s)"
else
  log_ok "Composer audit: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
