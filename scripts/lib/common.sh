#!/usr/bin/env bash
# Shared utilities for code-guardian scripts
set -euo pipefail

# Colors (disabled if not a terminal or NO_COLOR set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' BLUE='' CYAN='' BOLD='' RESET=''
fi

log_info() { printf '%b\n' "${BLUE}[info]${RESET} $*" >&2; }
log_ok() { printf '%b\n' "${GREEN}[ok]${RESET} $*" >&2; }
log_warn() { printf '%b\n' "${YELLOW}[warn]${RESET} $*" >&2; }
log_error() { printf '%b\n' "${RED}[error]${RESET} $*" >&2; }
log_step() { printf '%b\n' "${CYAN}[step]${RESET} ${BOLD}$*${RESET}" >&2; }

# Check if a command exists
cmd_exists() { command -v "$1" &>/dev/null; }

# ── Standard exclusion paths ─────────────────────────────────────────
# Directories that should never be scanned (venvs, caches, build artifacts).
# Each scanner maps these to its own CLI flags.
CG_EXCLUDE_DIRS=(
  .git
  .venv
  venv
  .env
  env
  node_modules
  __pycache__
  .mypy_cache
  .pytest_cache
  .ruff_cache
  .tox
  .nox
  .eggs
  .cache
  .gradle
  .maven
  vendor
  dist
  build
  target
  coverage
  .terraform
  .next
  .nuxt
  _bmad
  _bmad-output
  .dart_tool
  _build
  deps
  .build
)

# Load user-configured exclusions from .claude/code-guardian.config.json
# Appends to CG_EXCLUDE_DIRS, deduplicating against existing entries.
_load_user_exclusions() {
  local read_config
  read_config="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/read-config.sh"
  [[ -f "$read_config" ]] || return 0

  local user_csv
  user_csv=$(bash "$read_config" --get exclude 2>/dev/null) || return 0
  [[ -z "$user_csv" ]] && return 0

  IFS=',' read -ra user_dirs <<<"$user_csv"
  for udir in "${user_dirs[@]}"; do
    [[ -z "$udir" ]] && continue
    # Skip if already present
    local already=false
    for existing in "${CG_EXCLUDE_DIRS[@]}"; do
      if [[ "$existing" == "$udir" ]]; then
        already=true
        break
      fi
    done
    $already || CG_EXCLUDE_DIRS+=("$udir")
  done
}
_load_user_exclusions

# Join array elements with a delimiter
# Usage: join_by ',' "${array[@]}"
join_by() {
  local d="$1"
  shift
  [[ $# -eq 0 ]] && return
  local first="$1"
  shift
  printf '%s' "$first" "${@/#/$d}"
}

# Return exclusion dirs as a comma-separated string
get_exclude_dirs_csv() {
  join_by ',' "${CG_EXCLUDE_DIRS[@]}"
}

# Build find(1) exclusion arguments from CG_EXCLUDE_DIRS.
# Outputs -not -path patterns for each excluded directory.
# Usage: find . $(get_find_exclude_args) -name '*.txt'
get_find_exclude_args() {
  for dir in "${CG_EXCLUDE_DIRS[@]}"; do
    printf '%s\n' "-not" "-path" "*/${dir}/*"
  done
}

# Write exclusion patterns (one regex per line) to a temp file for tools
# that accept an exclude-paths file (e.g., trufflehog)
write_exclude_paths_file() {
  local tmpfile
  tmpfile=$(mktemp /tmp/cg-exclude-paths-XXXXXX)
  for dir in "${CG_EXCLUDE_DIRS[@]}"; do
    # Regex pattern matching the directory anywhere in the path
    echo "(^|/)${dir}/"
  done >"$tmpfile"
  echo "$tmpfile"
}

# Check if Docker is available and running
docker_available() {
  cmd_exists docker && docker info &>/dev/null
}

# Check if Docker fallback is opted in (set by orchestrator or env)
docker_fallback_enabled() {
  [[ "${CG_DOCKER_FALLBACK:-0}" == "1" ]]
}

# Log skip message with Docker fallback hint when applicable
log_skip_tool() {
  local tool_name="$1"
  if [[ -n "${CG_DOCKER_IMAGE:-}" ]] && docker_available; then
    log_warn "$tool_name not installed locally (Docker fallback disabled), skipping"
    log_info "  Install locally or enable Docker fallback in .claude/code-guardian.config.json"
  else
    log_warn "$tool_name not available, skipping"
  fi
}

# Output a JSON finding to stdout
# Usage: emit_finding <tool> <severity> <rule> <message> <file> <line> <autofixable> <category>
emit_finding() {
  local tool="$1" severity="$2" rule="$3" message="$4" file="$5" line="$6" autofixable="$7" category="$8"
  # Escape JSON strings
  message="${message//\\/\\\\}"
  message="${message//\"/\\\"}"
  message="${message//$'\n'/\\n}"
  message="${message//$'\r'/}"
  rule="${rule//\\/\\\\}"
  rule="${rule//\"/\\\"}"
  printf '{"tool":"%s","severity":"%s","rule":"%s","message":"%s","file":"%s","line":%s,"autoFixable":%s,"category":"%s"}\n' \
    "$tool" "$severity" "$rule" "$message" "$file" "${line:-0}" "$autofixable" "$category"
}

# Get files in the requested scope
# Usage: get_scoped_files <scope> [base_ref]
# Scope: codebase, uncommitted, unpushed
get_scoped_files() {
  local scope="${1:-codebase}"
  local base_ref="${2:-}"

  case "$scope" in
    codebase)
      git ls-files 2>/dev/null || find . -type f -not -path './.git/*'
      ;;
    uncommitted | changes | all-changes)
      # All local uncommitted work: staged + unstaged + untracked
      {
        git diff --cached --name-only --diff-filter=ACMR 2>/dev/null
        git diff --name-only --diff-filter=ACMR 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
      } | sort -u
      ;;
    unpushed)
      if [[ -n "$base_ref" ]]; then
        if ! [[ "$base_ref" =~ ^[a-zA-Z0-9_./@^~-]+$ ]]; then
          log_error "Invalid base ref: $base_ref"
          return 1
        fi
        git diff "${base_ref}...HEAD" --name-only --diff-filter=ACMR 2>/dev/null
      else
        # Try origin/main, then origin/master
        local default_branch
        default_branch=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo "main")
        git diff "origin/${default_branch}...HEAD" --name-only --diff-filter=ACMR 2>/dev/null
      fi
      ;;
    *)
      log_error "Unknown scope: $scope"
      return 1
      ;;
  esac
}

# Build a grep pattern that matches paths containing any excluded directory
_build_exclude_pattern() {
  local pattern=""
  for dir in "${CG_EXCLUDE_DIRS[@]}"; do
    [[ -n "$pattern" ]] && pattern+="|"
    pattern+="(^|/)${dir}/"
  done
  echo "$pattern"
}

# Write scope files to a temp file and return its path
# Filters out files whose paths match any CG_EXCLUDE_DIRS entry.
write_scope_file() {
  local scope="${1:-codebase}"
  local base_ref="${2:-}"
  local tmpfile
  tmpfile=$(mktemp /tmp/code-guardian-scope-XXXXXX)
  local raw
  raw=$(mktemp /tmp/code-guardian-scope-raw-XXXXXX)
  get_scoped_files "$scope" "$base_ref" >"$raw"

  local exclude_pattern
  exclude_pattern=$(_build_exclude_pattern)
  if [[ -n "$exclude_pattern" ]]; then
    grep -vE "$exclude_pattern" "$raw" >"$tmpfile" || true
  else
    mv "$raw" "$tmpfile"
  fi
  rm -f "$raw"
  echo "$tmpfile"
}

# Filter file list by extensions
# Usage: filter_by_ext <file_list_file> <ext1> [ext2 ...]
filter_by_ext() {
  local file_list="$1"
  shift
  local pattern
  pattern=$(printf '|%s' "$@")
  pattern="${pattern:1}" # Remove leading |
  grep -iE "\.(${pattern})$" "$file_list" 2>/dev/null || true
}

# Create a JSON summary from findings file
# Usage: create_summary <findings_file> <tool_name>
create_summary() {
  local findings_file="$1"
  local tool_name="$2"
  local high=0 medium=0 low=0 info=0

  if [[ -f "$findings_file" ]] && [[ -s "$findings_file" ]]; then
    high=$(grep -cE '"severity" *: *"high"' "$findings_file" 2>/dev/null) || high=0
    medium=$(grep -cE '"severity" *: *"medium"' "$findings_file" 2>/dev/null) || medium=0
    low=$(grep -cE '"severity" *: *"low"' "$findings_file" 2>/dev/null) || low=0
    info=$(grep -cE '"severity" *: *"info"' "$findings_file" 2>/dev/null) || info=0
  fi

  printf '{"tool":"%s","summary":{"high":%d,"medium":%d,"low":%d,"info":%d}}\n' \
    "$tool_name" "$high" "$medium" "$low" "$info"
}
