#!/usr/bin/env bash
# ESLint security plugin wrapper — JS/TS security linting with autofix
# Searches recursively for package.json files (monorepo-aware)
# Usage: eslint-security.sh [--autofix] [--scope-file <file>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

AUTOFIX=false
SCOPE_FILE=""
OUTPUT_DIR="${SCAN_OUTPUT_DIR:-.}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --autofix) AUTOFIX=true; shift ;;
    --scope-file) SCOPE_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

FINDINGS_FILE="${OUTPUT_DIR}/eslint-security-findings.jsonl"
> "$FINDINGS_FILE"

PROJECT_ROOT="$(pwd)"

# ── Discover package.json locations with ESLint + security plugin ────
SCAN_DIRS=()
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  dir="$(dirname "$pkg")"
  # Check for eslint binary and security plugin in this location
  if [[ -f "$dir/node_modules/.bin/eslint" ]] && [[ -d "$dir/node_modules/eslint-plugin-security" ]]; then
    SCAN_DIRS+=("$dir")
  fi
done < <(find . -name package.json \
  -not -path '*/node_modules/*' \
  -not -path '*/.git/*' \
  -not -path '*/vendor/*' \
  -not -path '*/.cache/*' \
  -not -path '*/dist/*' \
  -not -path '*/build/*' \
  2>/dev/null | sort)

# Also check for global eslint with security plugin at root
if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
  if [[ -f package.json ]]; then
    ESLINT_BIN=""
    if [[ -f node_modules/.bin/eslint ]]; then
      ESLINT_BIN="node_modules/.bin/eslint"
    elif cmd_exists eslint; then
      ESLINT_BIN="eslint"
    fi

    if [[ -n "$ESLINT_BIN" ]]; then
      has_security_plugin=false
      if [[ -d node_modules/eslint-plugin-security ]]; then
        has_security_plugin=true
      elif $ESLINT_BIN --print-config . 2>/dev/null | grep -q "security" 2>/dev/null; then
        has_security_plugin=true
      fi

      if $has_security_plugin; then
        SCAN_DIRS+=(".")
      fi
    fi
  fi
fi

if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
  # Check if package.json exists at all to give the right skip message
  if find . -name package.json -not -path '*/node_modules/*' -print -quit 2>/dev/null | grep -q .; then
    log_info "eslint-plugin-security not installed in any project, skipping. Install: npm install -D eslint-plugin-security"
  else
    log_info "No package.json found, skipping ESLint security"
  fi
  exit 0
fi

log_step "Running ESLint with security rules across ${#SCAN_DIRS[@]} location(s)..."

SCANNED=0

for scan_dir in "${SCAN_DIRS[@]}"; do
  cd "$PROJECT_ROOT/$scan_dir"

  REL_PREFIX="${scan_dir#./}"
  [[ "$REL_PREFIX" == "." ]] && REL_PREFIX=""

  [[ -n "$REL_PREFIX" ]] && log_info "Linting $REL_PREFIX..." || log_info "Linting project root..."

  # Find eslint binary for this location
  ESLINT_BIN=""
  if [[ -f node_modules/.bin/eslint ]]; then
    ESLINT_BIN="node_modules/.bin/eslint"
  elif cmd_exists eslint; then
    ESLINT_BIN="eslint"
  fi

  if [[ -z "$ESLINT_BIN" ]]; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_info "Skipping ESLint${loc} — eslint not available"
    continue
  fi

  RAW_OUTPUT=$(mktemp /tmp/cg-eslint-sec-XXXXXX.json)
  EXIT_CODE=0

  ESLINT_ARGS=("--format" "json" "--no-error-on-unmatched-pattern")
  $AUTOFIX && ESLINT_ARGS+=("--fix")

  # Determine target files
  if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$SCOPE_FILE" ]]; then
    js_file_args=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && js_file_args+=("$f")
    done < <(grep -E '\.(js|jsx|ts|tsx|mjs|cjs)$' "$SCOPE_FILE")
    if [[ ${#js_file_args[@]} -eq 0 ]]; then
      log_info "No JS/TS files in scope, skipping ESLint security"
      rm -f "$RAW_OUTPUT"
      continue
    fi
    ESLINT_ARGS+=("${js_file_args[@]}")
  else
    ESLINT_ARGS+=(".")
  fi

  $ESLINT_BIN "${ESLINT_ARGS[@]}" > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?

  # Detect tool failure: non-zero exit with no usable output
  if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
    [[ -n "$REL_PREFIX" ]] && loc=" in $REL_PREFIX" || loc=""
    log_error "ESLint failed${loc} (exit code $EXIT_CODE)"
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
    for file_result in data:
        filepath = file_result.get('filePath', '')
        for msg in file_result.get('messages', []):
            rule_id = msg.get('ruleId', '')
            # Only include security-related rules
            if not rule_id or 'security' not in rule_id:
                continue
            # Prefix relative path for subdirectory projects
            fpath = filepath
            if rel_prefix and fpath and not fpath.startswith(rel_prefix):
                fpath = rel_prefix + '/' + fpath
            sev = 'high' if msg.get('severity', 1) == 2 else 'medium'
            finding = {
                'tool': 'eslint-security',
                'severity': sev,
                'rule': rule_id,
                'message': msg.get('message', ''),
                'file': fpath,
                'line': msg.get('line', 0),
                'autoFixable': msg.get('fix') is not None,
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
  log_info "No lintable JS/TS projects found with security plugin, skipping"
  exit 0
fi

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "ESLint security: found $count issue(s)"
  $AUTOFIX && log_info "Auto-fix was applied where possible"
else
  log_ok "ESLint security: no issues found"
fi

echo "$FINDINGS_FILE"
