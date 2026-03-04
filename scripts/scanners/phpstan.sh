#!/usr/bin/env bash
# PHPStan scanner wrapper — PHP static analysis
# Usage: phpstan.sh [--scope-file <file>]
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

FINDINGS_FILE="${OUTPUT_DIR}/phpstan-findings.jsonl"
> "$FINDINGS_FILE"

# Check for PHP files
php_files_exist=false
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]]; then
  grep -q '\.php$' "$SCOPE_FILE" 2>/dev/null && php_files_exist=true
else
  find . -name "*.php" -maxdepth 4 -not -path "*/vendor/*" 2>/dev/null | head -1 | grep -q . && php_files_exist=true
fi

if ! $php_files_exist; then
  log_info "No PHP files found, skipping PHPStan"
  exit 0
fi

log_step "Running PHPStan (PHP static analysis)..."

RAW_OUTPUT=$(mktemp /tmp/cg-phpstan-XXXXXX.json)
EXIT_CODE=0

DOCKER_IMAGE="${CG_DOCKER_IMAGE:-}"

# Determine analysis paths as an array
ANALYSIS_PATHS=(".")
if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]] && [[ -s "$SCOPE_FILE" ]]; then
  php_file_args=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && php_file_args+=("$f")
  done < <(grep '\.php$' "$SCOPE_FILE")
  if [[ ${#php_file_args[@]} -gt 0 ]]; then
    ANALYSIS_PATHS=("${php_file_args[@]}")
  fi
fi

# Determine PHPStan level — use project config if it exists, else level 5 (balanced)
LEVEL_ARGS=("--level=5")
if [[ -f phpstan.neon ]] || [[ -f phpstan.neon.dist ]] || [[ -f phpstan.dist.neon ]]; then
  LEVEL_ARGS=()  # Let the config file control the level
fi

PHPSTAN_ARGS=("analyse" "--error-format=json" "--no-progress" "${LEVEL_ARGS[@]}" "${ANALYSIS_PATHS[@]}")

if cmd_exists phpstan; then
  phpstan "${PHPSTAN_ARGS[@]}" \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif [[ -f vendor/bin/phpstan ]]; then
  vendor/bin/phpstan "${PHPSTAN_ARGS[@]}" \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
elif docker_fallback_enabled && docker_available && [[ -n "$DOCKER_IMAGE" ]]; then
  log_info "Using Docker image: $DOCKER_IMAGE"
  docker run --rm --network none -v "$(pwd):/app:ro" -w /app \
    "$DOCKER_IMAGE" "${PHPSTAN_ARGS[@]}" \
    > "$RAW_OUTPUT" 2>/dev/null || EXIT_CODE=$?
else
  log_skip_tool "PHPStan"
  rm -f "$RAW_OUTPUT"
  exit 0
fi

# Detect tool failure: non-zero exit with no usable output
if [[ $EXIT_CODE -ne 0 ]] && { [[ ! -f "$RAW_OUTPUT" ]] || [[ ! -s "$RAW_OUTPUT" ]]; }; then
  log_error "PHPStan failed (exit code $EXIT_CODE)"
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
    data = json.load(open('$RAW_OUTPUT'))
    # PHPStan JSON format: { totals: {errors, file_errors}, files: { 'path': {errors, messages: [{message, line, ignorable}]} }, errors: [] }
    files = data.get('files', {})
    for file_path, file_data in files.items():
        for msg in file_data.get('messages', []):
            message_text = msg.get('message', '')
            line_num = msg.get('line', 0)
            # Categorize severity based on message content
            sev = 'medium'
            message_lower = message_text.lower()
            # Security-relevant patterns get high severity
            if any(kw in message_lower for kw in [
                'sql', 'injection', 'eval', 'exec', 'shell_exec', 'system(',
                'passthru', 'popen', 'proc_open', 'unserialize', 'file_get_contents',
                'file_put_contents', 'fopen', 'include', 'require', 'preg_replace',
                'assert(', 'extract(', 'parse_str'
            ]):
                sev = 'high'
            # Type errors and undefined methods are medium
            elif any(kw in message_lower for kw in [
                'undefined variable', 'undefined method', 'undefined property',
                'return type', 'parameter type', 'dead code', 'unreachable'
            ]):
                sev = 'medium'
            # Info-level for less critical issues
            elif any(kw in message_lower for kw in [
                'unused', 'deprecated', 'phpdoc'
            ]):
                sev = 'low'
            # Extract rule identifier from message if possible
            tip = msg.get('tip', '')
            identifier = msg.get('identifier', '')
            rule = identifier if identifier else 'phpstan'
            finding = {
                'tool': 'phpstan',
                'severity': sev,
                'rule': rule,
                'message': message_text,
                'file': file_path,
                'line': line_num if line_num else 0,
                'autoFixable': False,
                'category': 'sast'
            }
            print(json.dumps(finding))
    # Also emit top-level errors (config issues, etc.)
    for error in data.get('errors', []):
        finding = {
            'tool': 'phpstan',
            'severity': 'info',
            'rule': 'phpstan-config',
            'message': error,
            'file': '',
            'line': 0,
            'autoFixable': False,
            'category': 'sast'
        }
        print(json.dumps(finding))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" > "$FINDINGS_FILE"
  fi
fi

rm -f "$RAW_OUTPUT"

count=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
if [[ "$count" -gt 0 ]]; then
  log_warn "PHPStan: found $count issue(s)"
else
  log_ok "PHPStan: no issues found"
fi

echo "$FINDINGS_FILE"
