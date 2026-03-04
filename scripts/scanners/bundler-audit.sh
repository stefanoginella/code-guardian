#!/usr/bin/env bash
# bundler-audit wrapper — Ruby dependency vulnerability scanning
# Searches recursively for Gemfile.lock files (monorepo-aware)
# Usage: bundler-audit.sh [--autofix]
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

FINDINGS_FILE="${OUTPUT_DIR}/bundler-audit-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover Gemfile.lock locations ──────────────────────────────────
AUDIT_DIRS=()
while IFS= read -r lockfile; do
  [[ -z "$lockfile" ]] && continue
  AUDIT_DIRS+=("$(dirname "$lockfile")")
done < <(find . -name Gemfile.lock \
  -not -path '*/vendor/*' \
  -not -path '*/.git/*' \
  -not -path '*/.bundle/*' \
  2>/dev/null | sort)

if [[ ${#AUDIT_DIRS[@]} -eq 0 ]]; then
  log_info "No Gemfile.lock found, skipping bundler-audit"
  exit 0
fi

log_step "Running bundler-audit (Ruby dependency vulnerabilities) across ${#AUDIT_DIRS[@]} location(s)..."

AUDITED=0

for audit_dir in "${AUDIT_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$audit_dir"

  REL_PREFIX="${audit_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  [[ -n "$REL_PREFIX" ]] && log_info "Auditing $REL_PREFIX..." || log_info "Auditing project root..."

  if $AUTOFIX; then
    if cmd_exists bundle-audit; then
      bundle-audit update 2>/dev/null || true
    elif cmd_exists bundler-audit; then
      bundler-audit update 2>/dev/null || true
    fi
  fi

  RAW_OUTPUT=$(mktemp /tmp/cg-bundler-audit-XXXXXX.txt)
  EXIT_CODE=0

  if cmd_exists bundle-audit; then
    bundle-audit check --format json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  elif cmd_exists bundler-audit; then
    bundler-audit check --format json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  else
    log_warn "bundler-audit not available, skipping"
    rm -f "$RAW_OUTPUT"
    exit 0
  fi

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "bundler-audit failed${loc} (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      LOCKFILE_PATH="${REL_PREFIX:+${REL_PREFIX}/}Gemfile.lock"
      python3 -c "
import json, sys
lockfile = '$LOCKFILE_PATH'
try:
    data = json.load(open('$RAW_OUTPUT'))
    for result in data.get('results', []):
        adv = result.get('advisory', {})
        gem = result.get('gem', {})
        raw_sev = adv.get('criticality', 'medium')
        sev = raw_sev.lower() if isinstance(raw_sev, str) else 'medium'
        if sev not in ('high', 'medium', 'low', 'info'):
            sev = 'medium'
        finding = {
            'tool': 'bundler-audit',
            'severity': sev,
            'rule': adv.get('id', adv.get('cve', '')),
            'message': f\"{gem.get('name','')}@{gem.get('version','')}: {adv.get('title','')}\",
            'file': lockfile,
            'line': 0,
            'autoFixable': False,
            'category': 'dependency'
        }
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" >> "$FINDINGS_FILE"
    fi
  fi

  rm -f "$RAW_OUTPUT"
  AUDITED=$((AUDITED + 1))
done

cd "$PROJECT_ROOT"

if [[ $AUDITED -eq 0 ]]; then
  log_info "No auditable Ruby projects found, skipping"
  exit 0
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "bundler-audit: found $count vulnerability(s)"
else
  log_ok "bundler-audit: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
