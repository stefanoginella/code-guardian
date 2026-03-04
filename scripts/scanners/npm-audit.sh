#!/usr/bin/env bash
# npm/yarn/pnpm audit wrapper — JS/TS dependency vulnerability scanning
# Searches recursively for package.json files (monorepo-aware)
# Usage: npm-audit.sh [--autofix] [--pm npm|yarn|pnpm|bun]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

AUTOFIX=false
FORCE_PM=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --autofix) AUTOFIX=true; shift ;;
    --pm) FORCE_PM="$2"; shift 2 ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/npm-audit-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover audit targets ───────────────────────────────────────────
# Find directories containing package.json (excluding build artifacts)
AUDIT_DIRS=()
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  AUDIT_DIRS+=("$(dirname "$pkg")")
done < <(find . -name package.json \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/vendor/*' \
  -not -path '*/.cache/*' \
  -not -path '*/dist/*' \
  -not -path '*/build/*' \
  2>/dev/null | sort)

if [[ ${#AUDIT_DIRS[@]} -eq 0 ]]; then
  log_info "No package.json found in project, skipping npm audit (OSV-Scanner covers dependency vulnerabilities)"
  exit 0
fi

log_step "Running npm audit (dependency vulnerabilities) across ${#AUDIT_DIRS[@]} location(s)..."

AUDITED=0

for audit_dir in "${AUDIT_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$audit_dir"

  # Relative path prefix for findings (empty string for project root)
  REL_PREFIX="${audit_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  # Detect package manager for this directory
  PM="$FORCE_PM"
  if [[ -z "$PM" ]]; then
    if [[ -f pnpm-lock.yaml ]]; then PM="pnpm"
    elif [[ -f yarn.lock ]]; then PM="yarn"
    elif [[ -f bun.lockb ]] || [[ -f bun.lock ]]; then PM="bun"
    elif [[ -f package-lock.json ]] || [[ -f package.json ]]; then PM="npm"
    fi
  fi

  [[ -z "$PM" ]] && continue

  # For bun projects, fall back to npm binary for audit
  local_bin="$PM"
  [[ "$PM" == "bun" ]] && local_bin="npm"

  if ! cmd_exists "$local_bin"; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_info "Skipping npm audit${loc} — $local_bin not available locally"
    continue
  fi

  [[ -n "$REL_PREFIX" ]] && log_info "Auditing $REL_PREFIX ($PM)..." || log_info "Auditing project root ($PM)..."

  RAW_OUTPUT=$(mktemp /tmp/cg-npm-audit-XXXXXX.json)
  EXIT_CODE=0

  case "$PM" in
    npm)
      if $AUTOFIX; then
        npm audit fix --force 2>/dev/null || true
        log_info "Ran npm audit fix --force"
      fi
      npm audit --json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
      ;;
    yarn)
      yarn audit --json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
      ;;
    pnpm)
      pnpm audit --json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
      ;;
    bun)
      # Bun doesn't have built-in audit; use npm audit if available
      npm audit --json > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
      ;;
  esac

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "$PM audit failed${loc} (exit code $EXIT_CODE)"
    rm -f "$RAW_OUTPUT"
    continue
  fi

  if [[ -f "$RAW_OUTPUT" ]] && [[ -s "$RAW_OUTPUT" ]]; then
    if cmd_exists python3; then
      MANIFEST_PATH="${REL_PREFIX:+${REL_PREFIX}/}package.json"
      python3 -c "
import json, sys
manifest = '$MANIFEST_PATH'
try:
    data = json.load(open('$RAW_OUTPUT'))
    vulns = data.get('vulnerabilities', {})
    for name, vuln in vulns.items():
        sev_map = {'critical': 'high', 'high': 'high', 'moderate': 'medium', 'low': 'low', 'info': 'info'}
        sev = sev_map.get(vuln.get('severity', 'info'), 'info')
        finding = {
            'tool': 'npm-audit',
            'severity': sev,
            'rule': name,
            'message': f\"{name}@{vuln.get('range','')}: {vuln.get('title', vuln.get('name',''))}\",
            'file': manifest,
            'line': 0,
            'autoFixable': vuln.get('fixAvailable', False) is True or isinstance(vuln.get('fixAvailable'), dict),
            'category': 'dependency'
        }
        print(json.dumps(finding))
except Exception as e:
    # yarn audit uses a different JSON format (one JSON object per line)
    try:
        with open('$RAW_OUTPUT') as f:
            for line in f:
                line = line.strip()
                if not line: continue
                obj = json.loads(line)
                if obj.get('type') == 'auditAdvisory':
                    adv = obj.get('data', {}).get('advisory', {})
                    sev_map = {'critical': 'high', 'high': 'high', 'moderate': 'medium', 'low': 'low', 'info': 'info'}
                    finding = {
                        'tool': 'npm-audit',
                        'severity': sev_map.get(adv.get('severity', 'info'), 'info'),
                        'rule': adv.get('module_name', ''),
                        'message': adv.get('title', ''),
                        'file': manifest,
                        'line': 0,
                        'autoFixable': False,
                        'category': 'dependency'
                    }
                    print(json.dumps(finding))
    except Exception:
        pass
" >> "$FINDINGS_FILE"
    fi
  fi

  rm -f "$RAW_OUTPUT"
  AUDITED=$((AUDITED + 1))
done

cd "$PROJECT_ROOT"

if [[ $AUDITED -eq 0 ]]; then
  log_info "No auditable JS/TS projects found (no package manager detected), skipping (OSV-Scanner covers dependency vulnerabilities)"
  exit 0
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "npm audit: found $count vulnerability(s)"
  $AUTOFIX && log_info "Auto-fix was applied where possible"
else
  log_ok "npm audit: no vulnerabilities found"
fi

echo "$FINDINGS_FILE"
