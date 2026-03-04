#!/usr/bin/env bash
# Read code-guardian configuration from .claude/code-guardian.config.json
# Outputs individual config values to stdout based on --get flag.
#
# Usage:
#   read-config.sh --get tools       # → "semgrep,gitleaks" or ""
#   read-config.sh --get scope       # → "codebase" or ""
#   read-config.sh --get autofix     # → "true" or ""
#   read-config.sh --get disabled    # → "trufflehog,dockle" or ""
#   read-config.sh --dump            # → full JSON config (or "{}" if no config)
#
# Exit 0 always. Empty output means "not configured" (use default).
set -euo pipefail

CONFIG_FILE=".claude/code-guardian.config.json"

key=""
mode=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --get) key="$2"; mode="get"; shift 2 ;;
    --dump) mode="dump"; shift ;;
    *) shift ;;
  esac
done

# No config file → empty output
if [[ ! -f "$CONFIG_FILE" ]]; then
  [[ "$mode" == "dump" ]] && echo "{}"
  exit 0
fi

if [[ "$mode" == "dump" ]]; then
  cat "$CONFIG_FILE"
  exit 0
fi

# Read a specific key using python3 (available on macOS and most Linux)
python3 -c "
import json, sys
try:
    config = json.load(open(sys.argv[1]))
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)

key = sys.argv[2]
val = config.get(key)
if val is None:
    sys.exit(0)
if isinstance(val, list):
    print(','.join(str(v) for v in val))
elif isinstance(val, bool):
    print('true' if val else 'false')
else:
    print(val)
" "$CONFIG_FILE" "$key" 2>/dev/null || true
