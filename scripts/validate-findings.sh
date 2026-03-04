#!/usr/bin/env bash
# Validate JSONL findings against the code-guardian schema
# Usage: validate-findings.sh <findings.jsonl> [--strict]
#
# Exit codes:
#   0 = all lines valid
#   1 = validation errors found (printed to stderr)
#
# --strict mode: validates AI-specific constraints:
#   - rule must be one of the 8 AI review categories
#   - autoFixable must be false
#   - category must be "ai-review"
#   - tool must be "ai-review"
set -euo pipefail

FINDINGS_FILE="${1:-}"
STRICT=false

for arg in "$@"; do
  [[ "$arg" == "--strict" ]] && STRICT=true
done

if [[ -z "$FINDINGS_FILE" ]]; then
  echo "Usage: validate-findings.sh <findings.jsonl> [--strict]" >&2
  exit 1
fi

if [[ ! -f "$FINDINGS_FILE" ]]; then
  echo "File not found: $FINDINGS_FILE" >&2
  exit 1
fi

# Empty file is valid
if [[ ! -s "$FINDINGS_FILE" ]]; then
  exit 0
fi

python3 -c "
import json, sys

findings_file = sys.argv[1]
strict = sys.argv[2] == 'true'

REQUIRED_FIELDS = ['tool', 'severity', 'rule', 'message', 'file', 'line', 'autoFixable', 'category']
VALID_SEVERITIES = {'high', 'medium', 'low', 'info'}
VALID_CATEGORIES = {'sast', 'secrets', 'dependency', 'container', 'iac', 'ai-review'}
AI_RULES = {'auth-bypass', 'idor', 'race-condition', 'mass-assignment', 'data-leak', 'input-validation', 'business-logic', 'error-info-leak'}

errors = []
line_num = 0

with open(findings_file) as f:
    for raw_line in f:
        line_num += 1
        raw_line = raw_line.strip()
        if not raw_line:
            continue

        # Parse JSON
        try:
            finding = json.loads(raw_line)
        except json.JSONDecodeError as e:
            errors.append(f'line {line_num}: invalid JSON: {e}')
            continue

        if not isinstance(finding, dict):
            errors.append(f'line {line_num}: expected JSON object, got {type(finding).__name__}')
            continue

        # Required fields
        for field in REQUIRED_FIELDS:
            if field not in finding:
                errors.append(f'line {line_num}: missing required field \"{field}\"')

        # Severity validation
        sev = finding.get('severity', '')
        if sev and sev.lower() not in VALID_SEVERITIES:
            errors.append(f'line {line_num}: invalid severity \"{sev}\" (expected: {sorted(VALID_SEVERITIES)})')

        # Category validation
        cat = finding.get('category', '')
        if cat and cat not in VALID_CATEGORIES:
            errors.append(f'line {line_num}: invalid category \"{cat}\" (expected: {sorted(VALID_CATEGORIES)})')

        # Strict mode: AI-specific constraints
        if strict:
            tool = finding.get('tool', '')
            if tool != 'ai-review':
                errors.append(f'line {line_num}: strict: tool must be \"ai-review\", got \"{tool}\"')

            rule = finding.get('rule', '')
            if rule and rule not in AI_RULES:
                errors.append(f'line {line_num}: strict: rule \"{rule}\" not in allowed AI rules {sorted(AI_RULES)}')

            if finding.get('autoFixable') is not False:
                errors.append(f'line {line_num}: strict: autoFixable must be false for AI findings')

            if cat != 'ai-review':
                errors.append(f'line {line_num}: strict: category must be \"ai-review\", got \"{cat}\"')

if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)
" "$FINDINGS_FILE" "$STRICT"
