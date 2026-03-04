#!/usr/bin/env bash
# cargo-audit wrapper — Rust dependency vulnerability scanning
# Searches recursively for Cargo.lock files (workspace-aware, e.g. src-tauri/)
# Usage: cargo-audit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

FINDINGS_FILE="${OUTPUT_DIR}/cargo-audit-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover Cargo.lock locations ────────────────────────────────────
AUDIT_DIRS=()
while IFS= read -r lockfile; do
  [[ -z "$lockfile" ]] && continue
  AUDIT_DIRS+=("$(dirname "$lockfile")")
done < <(find . -name Cargo.lock \
  -not -path '*/target/*' \
  -not -path '*/.git/*' \
  -not -path '*/vendor/*' \
  2>/dev/null | sort)

if [[ ${#AUDIT_DIRS[@]} -eq 0 ]]; then
  log_info "No Cargo.lock found, skipping cargo-audit"
  exit 0
fi

log_step "Running cargo-audit (Rust dependency vulnerabilities) across ${#AUDIT_DIRS[@]} location(s)..."

AUDITED=0

for audit_dir in "${AUDIT_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$audit_dir"

  # Relative path prefix for findings (empty string for project root)
  REL_PREFIX="${audit_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  [[ -n "$REL_PREFIX" ]] && log_info "Auditing $REL_PREFIX..." || log_info "Auditing project root..."

  RAW_OUTPUT=$(mktemp /tmp/cg-cargo-audit-XXXXXX.json)
  EXIT_CODE=0

  if cmd_exists cargo-audit; then
    cargo audit --json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  elif cmd_exists cargo && cargo audit --version &>/dev/null; then
    cargo audit --json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
  else
    log_warn "cargo-audit not available, skipping"
    rm -f "$RAW_OUTPUT"
    exit 0
  fi

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "cargo-audit failed${loc} (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      LOCKFILE_PATH="${REL_PREFIX:+${REL_PREFIX}/}Cargo.lock"
      python3 -c "
import json, sys
lockfile = '$LOCKFILE_PATH'
try:
    data = json.load(open('$RAW_OUTPUT'))
    vulns = data.get('vulnerabilities', {}).get('list', [])
    for vuln in vulns:
        adv = vuln.get('advisory', {})
        pkg = vuln.get('package', {})
        finding = {
            'tool': 'cargo-audit',
            'severity': 'high',
            'rule': adv.get('id', ''),
            'message': f\"{pkg.get('name','')}@{pkg.get('version','')}: {adv.get('title','')}\",
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
  log_info "No auditable Rust projects found, skipping"
  exit 0
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "cargo-audit: found $count vulnerability(s)"
else
  log_ok "cargo-audit: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
