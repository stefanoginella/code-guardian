#!/usr/bin/env bash
# Check availability of required security tools for the detected stack
# Input: stack JSON from detect-stack.sh (via stdin or file arg)
# Output: JSON report of tool availability
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/tool-registry.sh"

# Docker fallback: env > config > default (false)
if [[ -z "${CG_DOCKER_FALLBACK:-}" ]]; then
  _cfg_docker=$(bash "${SCRIPT_DIR}/read-config.sh" --get dockerFallback 2>/dev/null || true)
  [[ "$_cfg_docker" == "true" ]] && export CG_DOCKER_FALLBACK=1 || export CG_DOCKER_FALLBACK=0
fi

# Read stack JSON from stdin or file
if [[ -n "${1:-}" ]] && [[ -f "$1" ]]; then
  stack_json=$(cat "$1")
else
  stack_json=$(cat)
fi

# Extract a JSON array value by key (handles single-line and multi-line JSON)
_json_array() {
  echo "$stack_json" | tr '\n' ' ' | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | sed 's/^[^[]*//'
}

# Extract a JSON scalar value by key (handles single-line and multi-line JSON)
_json_scalar() {
  echo "$stack_json" | tr '\n' ' ' | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[^,}[:space:]][^,}]*" | sed 's/^[^:]*:[[:space:]]*//'
}

# Parse a JSON array string into newline-separated values
parse_json_array() {
  echo "$1" | tr -d '[]"' | tr ',' '\n' | tr -d ' ' | grep -v '^$'
}

languages=$(_json_array languages)
has_docker=$(_json_scalar docker)
iac_tools=$(_json_array iacTools)

# Collect all needed tools (deduplicated)
needed_tools=()

while IFS= read -r lang; do
  [[ -z "$lang" ]] && continue
  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    # Check if tool already in array
    local_found=false
    for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
      if [[ "$existing" == "$tool" ]]; then
        local_found=true
        break
      fi
    done
    $local_found || needed_tools+=("$tool")
  done < <(get_tools_for_stack "$lang" | tr ' ' '\n')
done < <(parse_json_array "$languages")

# Add Docker tools if Docker detected
if [[ "$has_docker" == "true" ]]; then
  for tool in $(get_tools_for_stack "docker"); do
    local_found=false
    for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
      [[ "$existing" == "$tool" ]] && local_found=true && break
    done
    $local_found || needed_tools+=("$tool")
  done
fi

# Add IaC tools if detected
iac_list=$(parse_json_array "$iac_tools" 2>/dev/null || true)
if [[ -n "$iac_list" ]]; then
  for tool in $(get_tools_for_stack "iac"); do
    local_found=false
    for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
      [[ "$existing" == "$tool" ]] && local_found=true && break
    done
    $local_found || needed_tools+=("$tool")
  done
fi

# Always include gitleaks for secrets
gitleaks_found=false
for existing in "${needed_tools[@]+"${needed_tools[@]}"}"; do
  [[ "$existing" == "gitleaks" ]] && gitleaks_found=true && break
done
$gitleaks_found || needed_tools+=("gitleaks")

# Check each tool and build report
available_tools=()
docker_available_tools=()
unavailable_tools=()
tool_details=""

for tool in "${needed_tools[@]}"; do
  status=$(check_tool_availability "$tool")
  binary=$(get_tool_binary "$tool")
  docker_image=$(get_tool_docker_image "$tool")
  install_cmd=$(get_tool_install_cmd "$tool")
  category=$(get_tool_category "$tool")

  detail="$(printf '{"name":"%s","binary":"%s","status":"%s","dockerImage":"%s","installCmd":"%s","category":"%s"}' \
    "$tool" "$binary" "$status" "$docker_image" "$install_cmd" "$category")"

  [[ -n "$tool_details" ]] && tool_details+=","
  tool_details+="$detail"

  case "$status" in
    local|docker)        available_tools+=("$tool") ;;
    docker-available)    docker_available_tools+=("$tool") ;;
    unavailable)         unavailable_tools+=("$tool") ;;
  esac
done

# Summary to stderr for user
log_step "Tool availability check"
[[ "$CG_DOCKER_FALLBACK" == "1" ]] && log_info "Docker fallback: enabled" || log_info "Docker fallback: disabled (local tools only)"
echo "" >&2
for tool in "${needed_tools[@]}"; do
  status=$(check_tool_availability "$tool")
  case "$status" in
    local)  log_ok "$tool — available locally" ;;
    docker) log_ok "$tool — available via Docker (fallback enabled)" ;;
    docker-available)
      install_cmd=$(get_tool_install_cmd "$tool")
      docker_image=$(get_tool_docker_image "$tool")
      log_warn "$tool — NOT INSTALLED locally (Docker image exists, enable fallback to use)"
      [[ -n "$install_cmd" ]] && log_info "  Install: $install_cmd"
      [[ -n "$docker_image" ]] && log_info "  Docker:  enable dockerFallback + docker pull $docker_image"
      ;;
    unavailable)
      install_cmd=$(get_tool_install_cmd "$tool")
      log_warn "$tool — NOT AVAILABLE"
      [[ -n "$install_cmd" ]] && log_info "  Install: $install_cmd"
      ;;
  esac
done
echo "" >&2

# Output JSON
json_name_array() {
  local arr=("$@")
  if [[ ${#arr[@]} -eq 0 ]]; then echo "[]"; return; fi
  local out="["
  for i in "${!arr[@]}"; do
    [[ $i -gt 0 ]] && out+=","
    out+="\"${arr[$i]}\""
  done
  echo "$out]"
}

cat <<EOF
{
  "tools": [${tool_details}],
  "available": $(json_name_array "${available_tools[@]+"${available_tools[@]}"}"),
  "dockerAvailable": $(json_name_array "${docker_available_tools[@]+"${docker_available_tools[@]}"}"),
  "unavailable": $(json_name_array "${unavailable_tools[@]+"${unavailable_tools[@]}"}"),
  "dockerFallback": $( [[ "$CG_DOCKER_FALLBACK" == "1" ]] && echo "true" || echo "false"),
  "totalNeeded": ${#needed_tools[@]},
  "totalAvailable": ${#available_tools[@]},
  "totalDockerAvailable": ${#docker_available_tools[@]},
  "totalUnavailable": ${#unavailable_tools[@]}
}
EOF
