#!/usr/bin/env bash
# Main scan orchestrator — runs relevant scanners based on detected stack
# Usage: scan.sh --stack-json <file> --scope <scope> [--base-ref <ref>] [--tools-json <file>] [--tools tool1,tool2,...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/tool-registry.sh"

STACK_JSON=""
TOOLS_JSON=""
SCOPE="codebase"
BASE_REF=""
ONLY_TOOLS=""
REPORT_FILE_OVERRIDE=""

# Load config defaults (CLI args override these)
_cfg_read() { bash "${SCRIPT_DIR}/read-config.sh" --get "$1" 2>/dev/null || true; }

_cfg_scope=$(_cfg_read scope)
[[ -n "$_cfg_scope" ]] && SCOPE="$_cfg_scope"

_cfg_tools=$(_cfg_read tools)
[[ -n "$_cfg_tools" ]] && ONLY_TOOLS="$_cfg_tools"

# Docker fallback: env > config > default (false)
if [[ -z "${CG_DOCKER_FALLBACK:-}" ]]; then
  _cfg_docker=$(_cfg_read dockerFallback)
  if [[ "$_cfg_docker" == "true" ]]; then
    export CG_DOCKER_FALLBACK=1
  else
    export CG_DOCKER_FALLBACK=0
  fi
else
  export CG_DOCKER_FALLBACK
fi

# CLI args override config
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-json)
      STACK_JSON="$2"
      shift 2
      ;;
    --tools-json)
      TOOLS_JSON="$2"
      shift 2
      ;;
    --scope)
      SCOPE="$2"
      shift 2
      ;;
    --base-ref)
      BASE_REF="$2"
      shift 2
      ;;
    --tools)
      ONLY_TOOLS="$2"
      shift 2
      ;;
    --report-file)
      REPORT_FILE_OVERRIDE="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done

# Parse --tools into an array for filtering
only_filter=()
if [[ -n "$ONLY_TOOLS" ]]; then
  while IFS= read -r t; do [[ -n "$t" ]] && only_filter+=("$t"); done < <(tr ',' '\n' <<<"$ONLY_TOOLS")
fi

if [[ -z "$STACK_JSON" ]] || ! [[ -f "$STACK_JSON" ]]; then
  log_error "Stack JSON file required (--stack-json)"
  exit 1
fi

# Create output directory for this scan
SCAN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCAN_OUTPUT_DIR=$(mktemp -d /tmp/code-guardian-scan-${SCAN_TIMESTAMP}-XXXXXX)
export SCAN_OUTPUT_DIR

log_step "Security scan started"
log_info "Scope: $SCOPE"
[[ -n "$BASE_REF" ]] && log_info "Base ref: $BASE_REF"
[[ "$CG_DOCKER_FALLBACK" == "1" ]] && log_info "Docker fallback: enabled" || log_info "Docker fallback: disabled (local tools only)"
echo "" >&2

# Get scope file
SCOPE_FILE=""
if [[ "$SCOPE" != "codebase" ]]; then
  SCOPE_FILE=$(write_scope_file "$SCOPE" "$BASE_REF")
  file_count=$(wc -l <"$SCOPE_FILE" | tr -d ' ')
  log_info "Files in scope: $file_count"
  if [[ "$file_count" -eq 0 ]]; then
    log_ok "No files in scope — nothing to scan"
    python3 -c "import json,sys; print(json.dumps({'scanDir':sys.argv[1],'findings':[],'summaries':[],'scope':sys.argv[2],'fileCount':0}))" "$SCAN_OUTPUT_DIR" "$SCOPE"
    exit 0
  fi
fi

# Parse stack info
parse_json_array() {
  echo "$1" | tr -d '[]"' | tr ',' '\n' | tr -d ' ' | grep -v '^$'
}

# Read each field on its own line to avoid whitespace-splitting JSON arrays
_stack_fields=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d.get('languages', [])))
print(str(d.get('docker', False)).lower())
print(json.dumps(d.get('iacTools', [])))
" "$STACK_JSON" 2>/dev/null || printf '[]\nfalse\n[]\n')
{
  IFS= read -r languages
  IFS= read -r has_docker
  IFS= read -r iac_tools
} <<<"$_stack_fields"

# Parse available tools from tools JSON
available_tools=()
if [[ -n "$TOOLS_JSON" ]] && [[ -f "$TOOLS_JSON" ]]; then
  while IFS= read -r tool; do
    [[ -n "$tool" ]] && available_tools+=("$tool")
  done < <(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for t in data.get('available', []):
    print(t)
" "$TOOLS_JSON" 2>/dev/null || true)
fi

# Determine which scanners to run
scanners_to_run=()
SCOPE_SKIPPED_SCANNERS=()

# Collect needed tools from stack
# Always include gitleaks (secret scanning applies to all repos)
needed_tools=("gitleaks")
while IFS= read -r lang; do
  [[ -z "$lang" ]] && continue
  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    # Deduplicate
    found=false
    for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
      [[ "$existing" == "$tool" ]] && found=true && break
    done
    $found || needed_tools+=("$tool")
  done < <(get_tools_for_stack "$lang" | tr ' ' '\n')
done < <(parse_json_array "$languages")

# Add Docker tools
if [[ "$has_docker" == "true" ]]; then
  for tool in $(get_tools_for_stack "docker"); do
    found=false
    for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
      [[ "$existing" == "$tool" ]] && found=true && break
    done
    $found || needed_tools+=("$tool")
  done
fi

# Add IaC tools
if echo "$iac_tools" | grep -q '[a-z]'; then
  for tool in $(get_tools_for_stack "iac"); do
    found=false
    for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
      [[ "$existing" == "$tool" ]] && found=true && break
    done
    $found || needed_tools+=("$tool")
  done
fi

# Filter to available tools only (and apply --tools filter if set)
for tool in ${needed_tools[@]+"${needed_tools[@]}"}; do
  # If --tools was specified, skip tools not in the filter list
  if [[ ${#only_filter[@]} -gt 0 ]]; then
    in_filter=false
    for f in "${only_filter[@]}"; do
      [[ "$f" == "$tool" ]] && in_filter=true && break
    done
    $in_filter || continue
  fi

  # Skip dependency scanners when scoped, unless their manifest/lockfiles changed
  if [[ -n "$SCOPE_FILE" ]] && [[ -f "$SCOPE_FILE" ]]; then
    manifest_files=$(get_tool_manifest_files "$tool")
    if [[ -n "$manifest_files" ]]; then
      manifest_in_scope=false
      for mf in $manifest_files; do
        # Match basename anywhere in path (e.g. "packages/foo/package.json")
        if grep -qE "(^|/)${mf}$" "$SCOPE_FILE" 2>/dev/null; then
          manifest_in_scope=true
          break
        fi
      done
      if ! $manifest_in_scope; then
        SCOPE_SKIPPED_SCANNERS+=("$tool")
        continue
      fi
    fi
  fi

  if [[ ${#available_tools[@]} -gt 0 ]]; then
    for avail in "${available_tools[@]}"; do
      if [[ "$avail" == "$tool" ]]; then
        scanners_to_run+=("$tool")
        break
      fi
    done
  else
    # No tools JSON provided — check availability directly
    status=$(check_tool_availability "$tool")
    [[ "$status" == "local" || "$status" == "docker" ]] && scanners_to_run+=("$tool")
  fi
done

if [[ ${#scanners_to_run[@]} -eq 0 ]]; then
  log_error "No security tools available to run"
  exit 1
fi

log_info "Scanners to run: ${scanners_to_run[*]}"
echo "" >&2

# ── Run each scanner ──────────────────────────────────────────────────
ALL_FINDINGS=()
ALL_SUMMARIES=()
FAILED_SCANNERS=()
SKIPPED_SCANNERS=()

for scanner in "${scanners_to_run[@]}"; do
  SCANNER_SCRIPT="${SCRIPT_DIR}/scanners/${scanner}.sh"

  if ! [[ -f "$SCANNER_SCRIPT" ]]; then
    log_warn "No scanner script for: $scanner"
    continue
  fi

  SCANNER_ARGS=()
  [[ -n "$SCOPE_FILE" ]] && SCANNER_ARGS+=("--scope-file" "$SCOPE_FILE")

  # Run scanner — capture stdout (last line = findings file path) and exit code
  findings_file=""
  scanner_exit=0
  scanner_docker_image=$(get_tool_docker_image "$scanner")
  findings_file=$(
    CG_DOCKER_IMAGE="$scanner_docker_image" \
      bash "$SCANNER_SCRIPT" ${SCANNER_ARGS[@]+"${SCANNER_ARGS[@]}"} | tail -1
  ) || scanner_exit=$?

  if [[ $scanner_exit -eq 2 ]]; then
    # Exit 2 = tool failure (not "findings found")
    FAILED_SCANNERS+=("$scanner")
    log_error "Scanner $scanner failed — results excluded"
  elif [[ -n "$findings_file" ]] && [[ -f "$findings_file" ]]; then
    ALL_FINDINGS+=("$findings_file")
    summary=$(create_summary "$findings_file" "$scanner")
    ALL_SUMMARIES+=("$summary")
  elif [[ $scanner_exit -eq 0 ]]; then
    # Exit 0 with no output = scanner determined it's not applicable and skipped
    SKIPPED_SCANNERS+=("$scanner")
    log_info "Scanner $scanner skipped (not applicable)"
  else
    FAILED_SCANNERS+=("$scanner")
    log_error "Scanner $scanner produced no output"
  fi

  echo "" >&2
done

# ── Merge all findings ────────────────────────────────────────────────
MERGED_FILE="${SCAN_OUTPUT_DIR}/all-findings.jsonl"
: >"$MERGED_FILE"
for f in "${ALL_FINDINGS[@]+"${ALL_FINDINGS[@]}"}"; do
  if [[ -f "$f" ]] && [[ -s "$f" ]]; then
    cat "$f" >>"$MERGED_FILE"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────
total=$(wc -l <"$MERGED_FILE" | tr -d ' ')
high=$(grep -cE '"severity" *: *"high"' "$MERGED_FILE" 2>/dev/null) || high=0
medium=$(grep -cE '"severity" *: *"medium"' "$MERGED_FILE" 2>/dev/null) || medium=0
low=$(grep -cE '"severity" *: *"low"' "$MERGED_FILE" 2>/dev/null) || low=0

echo "" >&2
log_step "Scan complete"
echo "" >&2
if [[ ${#SCOPE_SKIPPED_SCANNERS[@]} -gt 0 ]]; then
  log_info "Skipped (no manifest in scope): ${SCOPE_SKIPPED_SCANNERS[*]}"
fi
if [[ ${#SKIPPED_SCANNERS[@]} -gt 0 ]]; then
  log_info "Skipped scanners (${#SKIPPED_SCANNERS[@]}): ${SKIPPED_SCANNERS[*]}"
fi
if [[ ${#FAILED_SCANNERS[@]} -gt 0 ]]; then
  log_error "Failed scanners (${#FAILED_SCANNERS[@]}): ${FAILED_SCANNERS[*]}"
fi
if [[ "$total" -gt 0 ]]; then
  log_warn "Total findings: $total (high: $high, medium: $medium, low: $low)"
else
  if [[ ${#FAILED_SCANNERS[@]} -gt 0 ]]; then
    log_warn "No findings from successful scanners, but ${#FAILED_SCANNERS[@]} scanner(s) failed"
  else
    log_ok "No security issues found!"
  fi
fi

# Clean up scope file
[[ -n "$SCOPE_FILE" ]] && rm -f "$SCOPE_FILE"

# Build summaries JSON (used by both report generator and final output)
summaries_json="["
for i in "${!ALL_SUMMARIES[@]}"; do
  [[ $i -gt 0 ]] && summaries_json+=","
  summaries_json+="${ALL_SUMMARIES[$i]}"
done
summaries_json+="]"

# Generate persistent scan report
REPORT_FILE=""
REPORT_ARGS=()
[[ -n "$REPORT_FILE_OVERRIDE" ]] && REPORT_ARGS+=(--report-file "$REPORT_FILE_OVERRIDE")
REPORT_FILE=$(
  bash "${SCRIPT_DIR}/generate-report.sh" \
    --findings-file "$MERGED_FILE" \
    --scope "$SCOPE" \
    --base-ref "$BASE_REF" \
    --scanners-run "$(join_by ',' "${scanners_to_run[@]}")" \
    --skipped-scanners "$(join_by ',' "${SKIPPED_SCANNERS[@]+"${SKIPPED_SCANNERS[@]}"}")" \
    --scope-skipped-scanners "$(join_by ',' "${SCOPE_SKIPPED_SCANNERS[@]+"${SCOPE_SKIPPED_SCANNERS[@]}"}")" \
    --failed-scanners "$(join_by ',' "${FAILED_SCANNERS[@]+"${FAILED_SCANNERS[@]}"}")" \
    --summaries-json "$summaries_json" \
    --total "$total" --high "$high" --medium "$medium" --low "$low" \
    --timestamp "$SCAN_TIMESTAMP" \
    ${REPORT_ARGS[@]+"${REPORT_ARGS[@]}"}
) || REPORT_FILE=""
if [[ -n "$REPORT_FILE" ]]; then
  log_info "Scan report saved: $REPORT_FILE"
fi

# Build JSON array from bash array: ("a" "b") → ["a","b"]
_json_array() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
    return
  fi
  printf '['
  local first=true
  for item in "$@"; do
    $first && first=false || printf ','
    printf '"%s"' "$item"
  done
  printf ']'
}

skipped_json=$(_json_array "${SKIPPED_SCANNERS[@]+"${SKIPPED_SCANNERS[@]}"}")
scope_skipped_json=$(_json_array "${SCOPE_SKIPPED_SCANNERS[@]+"${SCOPE_SKIPPED_SCANNERS[@]}"}")
failed_json=$(_json_array "${FAILED_SCANNERS[@]+"${FAILED_SCANNERS[@]}"}")

python3 -c "
import json, sys
print(json.dumps({
  'scanDir': sys.argv[1],
  'findingsFile': sys.argv[2],
  'reportFile': sys.argv[3],
  'scope': sys.argv[4],
  'baseRef': sys.argv[5],
  'totalFindings': int(sys.argv[6]),
  'high': int(sys.argv[7]),
  'medium': int(sys.argv[8]),
  'low': int(sys.argv[9]),
  'scannersRun': json.loads(sys.argv[10]),
  'skippedScanners': json.loads(sys.argv[11]),
  'scopeSkippedScanners': json.loads(sys.argv[12]),
  'failedScanners': json.loads(sys.argv[13]),
  'summaries': json.loads(sys.argv[14]),
}, indent=2))
" "$SCAN_OUTPUT_DIR" "$MERGED_FILE" "$REPORT_FILE" "$SCOPE" "$BASE_REF" \
  "$total" "$high" "$medium" "$low" \
  "$(_json_array "${scanners_to_run[@]}")" \
  "$skipped_json" "$scope_skipped_json" "$failed_json" "$summaries_json"
