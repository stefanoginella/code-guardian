#!/usr/bin/env bash
# Cache I/O for code-guardian state (stack + tools detection results)
# Stores results in .claude/code-guardian-cache.json for reuse across commands.
#
# Usage:
#   cache-state.sh --write --stack-file <path> --tools-file <path>
#   cache-state.sh --read [--max-age <seconds>]
#   cache-state.sh --check [--max-age <seconds>]
#
# Exit codes (read/check):
#   0 = fresh cache available (read: JSON on stdout)
#   1 = missing, invalid, or path mismatch
#   2 = stale (exists but expired)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CACHE_FILE=".claude/code-guardian-cache.json"
CACHE_VERSION=1
DEFAULT_MAX_AGE=86400 # 24 hours

# Resolve effective dockerFallback setting (env > config > false)
_resolve_docker_fallback() {
  if [[ -n "${CG_DOCKER_FALLBACK:-}" ]]; then
    [[ "$CG_DOCKER_FALLBACK" == "1" ]] && echo "true" || echo "false"
  else
    local cfg
    cfg=$(bash "${SCRIPT_DIR}/read-config.sh" --get dockerFallback 2>/dev/null || true)
    [[ "$cfg" == "true" ]] && echo "true" || echo "false"
  fi
}

# ── Argument parsing ─────────────────────────────────────────────────

mode=""
stack_file=""
tools_file=""
max_age="$DEFAULT_MAX_AGE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write)
      mode="write"
      shift
      ;;
    --read)
      mode="read"
      shift
      ;;
    --check)
      mode="check"
      shift
      ;;
    --stack-file)
      stack_file="$2"
      shift 2
      ;;
    --tools-file)
      tools_file="$2"
      shift 2
      ;;
    --max-age)
      max_age="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$mode" ]]; then
  log_error "Must specify --write, --read, or --check"
  exit 1
fi

# ── Write mode ───────────────────────────────────────────────────────

do_write() {
  if [[ -z "$stack_file" ]] || [[ -z "$tools_file" ]]; then
    log_error "--write requires --stack-file and --tools-file"
    exit 1
  fi
  if [[ ! -f "$stack_file" ]]; then
    log_error "Stack file not found: $stack_file"
    exit 1
  fi
  if [[ ! -f "$tools_file" ]]; then
    log_error "Tools file not found: $tools_file"
    exit 1
  fi

  mkdir -p .claude

  local tmpfile
  tmpfile=$(mktemp .claude/.cg-cache-XXXXXX)

  local docker_fb
  docker_fb=$(_resolve_docker_fallback)

  python3 -c "
import json, sys, datetime, os

stack = json.load(open(sys.argv[1]))
tools = json.load(open(sys.argv[2]))
cache_version = int(sys.argv[3])
docker_fallback = sys.argv[4] == 'true'

cache = {
    'version': cache_version,
    'cachedAt': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'projectPath': os.path.basename(os.path.abspath('.')),
    'dockerFallback': docker_fallback,
    'stack': stack,
    'tools': tools,
}

json.dump(cache, sys.stdout, indent=2)
print()
" "$stack_file" "$tools_file" "$CACHE_VERSION" "$docker_fb" >"$tmpfile"

  mv "$tmpfile" "$CACHE_FILE"
  log_ok "Cache written to $CACHE_FILE"
}

# ── Read / Check mode ───────────────────────────────────────────────

do_read() {
  local output="${1:-true}" # true = print JSON, false = exit code only

  # Existence check
  if [[ ! -f "$CACHE_FILE" ]]; then
    log_info "No cache file found"
    exit 1
  fi

  # Validate and check staleness via python3
  local result
  local docker_fb
  docker_fb=$(_resolve_docker_fallback)

  result=$(python3 -c "
import json, sys, datetime, os

cache_file = sys.argv[1]
cache_version = int(sys.argv[2])
max_age_secs = int(sys.argv[3])
current_docker_fb = sys.argv[4] == 'true'

try:
    cache = json.load(open(cache_file))
except (json.JSONDecodeError, FileNotFoundError):
    print('invalid')
    sys.exit(0)

# Version check
if cache.get('version') != cache_version:
    print('invalid')
    sys.exit(0)

# Path check
if cache.get('projectPath') != os.path.basename(os.path.abspath('.')):
    print('invalid')
    sys.exit(0)

# Docker fallback setting changed — tool statuses are stale
if cache.get('dockerFallback') != current_docker_fb:
    print('invalid')
    sys.exit(0)

# Staleness check
cached_at = datetime.datetime.strptime(cache['cachedAt'], '%Y-%m-%dT%H:%M:%SZ')
cached_at = cached_at.replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
age_seconds = (now - cached_at).total_seconds()

if age_seconds >= max_age_secs:
    print('stale')
    sys.exit(0)

print('fresh')
" "$CACHE_FILE" "$CACHE_VERSION" "$max_age" "$docker_fb" 2>/dev/null) || { exit 1; }

  case "$result" in
    fresh)
      if [[ "$output" == "true" ]]; then
        cat "$CACHE_FILE"
      fi
      log_ok "Cache is fresh"
      exit 0
      ;;
    stale)
      log_warn "Cache is stale (older than ${max_age}s)"
      exit 2
      ;;
    invalid | *)
      log_info "Cache is invalid or path mismatch"
      exit 1
      ;;
  esac
}

# ── Dispatch ─────────────────────────────────────────────────────────

case "$mode" in
  write) do_write ;;
  read) do_read true ;;
  check) do_read false ;;
esac
