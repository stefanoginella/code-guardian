#!/usr/bin/env bash
set -euo pipefail
# update-tool-versions.sh — Check for new releases of pinned security tools
# and update tool-registry.sh + ci-recommend.sh in-place.
#
# Dependencies: curl, jq, docker (with buildx), gh (optional, for GITHUB_TOKEN)
# Environment:
#   DRY_RUN=true        — report changes without modifying files
#   GITHUB_TOKEN=...    — avoids GitHub API rate limits
#   OUTPUT_CHANGES=true — emit machine-readable CHANGE: lines (for CI)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="${REPO_ROOT}/scripts/lib/tool-registry.sh"
CI_RECOMMEND="${REPO_ROOT}/scripts/ci-recommend.sh"

DRY_RUN="${DRY_RUN:-false}"
OUTPUT_CHANGES="${OUTPUT_CHANGES:-false}"

# ── Section 1: Setup & helpers ──────────────────────────────────────

CHANGES=()
ERRORS=()
MAJOR_BUMPS=()

# Portable sed -i (macOS vs GNU)
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# GitHub API wrapper — adds auth header when token is available
gh_api() {
  local url="$1"
  local -a headers=(-H "Accept: application/vnd.github+json")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -sfL "${headers[@]}" "$url"
}

log_info() { printf '  %-14s %s\n' "$1" "$2"; }
log_change() { printf '  %-14s %s → %s\n' "$1" "$2" "$3"; }

# ── Section 2: GitHub API helpers ───────────────────────────────────

# Get latest release tag (e.g. "v0.58.2")
get_latest_release() {
  local repo="$1"
  gh_api "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty'
}

# Resolve a tag (possibly annotated) to its commit SHA
resolve_tag_sha() {
  local repo="$1" tag="$2"
  local ref_json sha type
  ref_json=$(gh_api "https://api.github.com/repos/${repo}/git/ref/tags/${tag}")
  sha=$(echo "$ref_json" | jq -r '.object.sha // empty')
  type=$(echo "$ref_json" | jq -r '.object.type // empty')

  # Annotated tags point to a tag object; dereference to commit
  if [[ "$type" == "tag" ]]; then
    sha=$(gh_api "https://api.github.com/repos/${repo}/git/tags/${sha}" | jq -r '.object.sha // empty')
  fi
  echo "$sha"
}

# Strip leading 'v' from a version string
strip_v() { echo "${1#v}"; }

# Strip @sha256:... digest suffix from a docker reference
strip_digest() { echo "${1%%@sha256:*}"; }

# Fetch the manifest digest for a Docker image (tag or tag@digest)
# Returns sha256:... or empty string on failure
fetch_docker_digest() {
  local image="$1"
  local ref
  ref=$(strip_digest "$image")
  docker buildx imagetools inspect "$ref" 2>/dev/null \
    | grep '^Digest:' | awk '{print $2}'
}

# Compare major version: returns 0 if same major, 1 if different
same_major() {
  local old="$1" new="$2"
  local old_major new_major
  old_major="${old%%.*}"
  new_major="${new%%.*}"
  [[ "$old_major" == "$new_major" ]]
}

# ── Section 3: Tool version update logic ────────────────────────────

# update_tool TOOL_KEY GITHUB_REPO DOCKER_PREFIX INSTALL_PREFIX [FLAGS]
#
# DOCKER_PREFIX: "v" if docker tag uses v-prefix (e.g. "v8.24.0"), "" if bare
# INSTALL_PREFIX: "v" if install URLs use v-prefix, "pip" / "gem" / "composer" to skip
# FLAGS: comma-separated — "gitlab" to also update GitLab CI image,
#        "bare_tarball" if tarball filename uses bare version (no v),
#        "2part_docker" for major.minor-only docker tags (phpstan)
update_tool() {
  local key="$1" repo="$2" docker_prefix="$3" install_prefix="$4"
  local flags="${5:-}"
  local has_gitlab=false bare_tarball=false two_part_docker=false

  [[ "$flags" == *gitlab* ]] && has_gitlab=true
  [[ "$flags" == *bare_tarball* ]] && bare_tarball=true
  [[ "$flags" == *2part_docker* ]] && two_part_docker=true

  local latest_tag latest_bare current_bare
  latest_tag=$(get_latest_release "$repo") || true
  if [[ -z "$latest_tag" ]]; then
    ERRORS+=("${key}: failed to fetch latest release from ${repo}")
    return
  fi
  latest_bare=$(strip_v "$latest_tag")

  # Extract current Docker version from registry
  local docker_var="TOOL_${key}_DOCKER"
  local current_docker_line
  current_docker_line=$(grep "^${docker_var}=" "$REGISTRY" || true)
  if [[ -z "$current_docker_line" ]]; then
    ERRORS+=("${key}: variable ${docker_var} not found in registry")
    return
  fi

  # Parse current version from docker image tag
  # e.g. "semgrep/semgrep:1.113.0@sha256:abc..." → tag="1.113.0", bare="1.113.0"
  # Extract full image ref between quotes, then split on first ':'
  local current_tag current_bare current_full_ref current_full_image
  current_full_image="${current_docker_line#*\"}"
  current_full_image="${current_full_image%\"*}"
  current_full_ref="${current_full_image#*:}"
  current_tag=$(strip_digest "$current_full_ref")
  current_bare=$(strip_v "$current_tag")

  if [[ "$current_bare" == "$latest_bare" ]]; then
    log_info "$key" "up to date ($current_bare)"
    return
  fi

  # Check for major version bump
  if ! same_major "$current_bare" "$latest_bare"; then
    MAJOR_BUMPS+=("${key}: ${current_bare} → ${latest_bare} (major bump, skipped)")
    log_info "$key" "MAJOR bump ${current_bare} → ${latest_bare} (skipped)"
    return
  fi

  # Build the new Docker tag
  local new_docker_tag
  if $two_part_docker; then
    # phpstan: use major.minor only
    local major minor
    major="${latest_bare%%.*}"
    minor="${latest_bare#*.}"
    minor="${minor%%.*}"
    new_docker_tag="${major}.${minor}"
    # Only update if major.minor changed
    if [[ "$current_tag" == "$new_docker_tag" ]]; then
      log_info "$key" "up to date (docker ${new_docker_tag}, latest ${latest_bare})"
      return
    fi
  else
    new_docker_tag="${docker_prefix}${latest_bare}"
  fi

  log_change "$key" "$current_bare" "$latest_bare"

  CHANGES+=("${key}|${current_bare}|${latest_bare}")

  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi

  # ── Update Docker tag in tool-registry.sh ──
  local docker_image_base
  docker_image_base="${current_docker_line#*\"}"
  docker_image_base="${docker_image_base%%:*}"

  # Fetch SHA256 digest for the new image
  local new_digest new_docker_ref
  new_digest=$(fetch_docker_digest "${docker_image_base}:${new_docker_tag}")
  if [[ -n "$new_digest" ]]; then
    new_docker_ref="${new_docker_tag}@${new_digest}"
  else
    log_info "$key" "WARNING: could not fetch digest, pinning by tag only"
    new_docker_ref="${new_docker_tag}"
  fi

  sedi "s|${docker_var}=\"${docker_image_base}:${current_full_ref}\"|${docker_var}=\"${docker_image_base}:${new_docker_ref}\"|" "$REGISTRY"

  # ── Update install URL in tool-registry.sh ──
  local install_var="TOOL_${key}_INSTALL_LINUX"
  case "$install_prefix" in
    pip | gem | composer)
      # Package manager install — no version in the command
      ;;
    *)
      local old_install_ver="${install_prefix}${current_bare}"
      local new_install_ver="${install_prefix}${latest_bare}"
      # Replace all occurrences on the install line (trivy/gosec have version repeated)
      local current_install_line
      current_install_line=$(grep "^${install_var}=" "$REGISTRY" || true)
      if [[ -n "$current_install_line" ]]; then
        # Replace versioned prefix (e.g. v0.58.2 → v0.69.1) on the install line
        sedi "/${install_var}=/s|${old_install_ver}|${new_install_ver}|g" "$REGISTRY"
        # Also replace bare version in tarball filenames (gitleaks, dockle)
        if $bare_tarball; then
          sedi "/${install_var}=/s|${current_bare}|${latest_bare}|g" "$REGISTRY"
        fi
      fi
      ;;
  esac

  # ── Update GitLab CI image in ci-recommend.sh ──
  # CI templates use tag-only references (no digest pinning)
  if $has_gitlab; then
    local old_gl_tag="${docker_prefix}${current_bare}"
    local new_gl_tag="${docker_prefix}${latest_bare}"
    if $two_part_docker; then
      old_gl_tag="${current_tag}"
      new_gl_tag="${new_docker_tag}"
    fi
    sedi "s|image: ${docker_image_base}:${old_gl_tag}|image: ${docker_image_base}:${new_gl_tag}|g" "$CI_RECOMMEND"
  fi
}

# ── Section 4: GitHub Actions SHA update logic ──────────────────────

# update_action ACTION_PATH REPO TRACKED_TAG
# Resolves the tag to a SHA and updates ci-recommend.sh if it changed.
update_action() {
  local action_path="$1" repo="$2" tracked_tag="$3"

  local current_sha new_sha
  # Extract current SHA from ci-recommend.sh: "uses: action_path@SHA # comment"
  # Use grep + awk to avoid sed delimiter issues with paths containing /
  current_sha=$(grep "uses: ${action_path}@" "$CI_RECOMMEND" | head -1 | awk -F'@' '{print $2}' | awk '{print $1}' || true)
  if [[ -z "$current_sha" ]]; then
    ERRORS+=("action ${action_path}: SHA not found in ci-recommend.sh")
    return
  fi

  new_sha=$(resolve_tag_sha "$repo" "$tracked_tag") || true
  if [[ -z "$new_sha" ]]; then
    ERRORS+=("action ${action_path}: failed to resolve tag ${tracked_tag}")
    return
  fi

  if [[ "$current_sha" == "$new_sha" ]]; then
    log_info "$action_path" "SHA up to date"
    return
  fi

  log_change "$action_path" "${current_sha:0:12}" "${new_sha:0:12}"
  CHANGES+=("action:${action_path}|${current_sha:0:12}|${new_sha:0:12}")

  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi

  sedi "s|uses: ${action_path}@${current_sha}|uses: ${action_path}@${new_sha}|g" "$CI_RECOMMEND"
}

# ── Section 5: Run all checks ───────────────────────────────────────

echo "=== Tool version check ==="
echo ""
echo "Files:"
echo "  registry:     ${REGISTRY}"
echo "  ci-recommend: ${CI_RECOMMEND}"
echo "  dry run:      ${DRY_RUN}"
echo ""

echo "── Docker images & install URLs ──"
echo ""

#              KEY              REPO                              DOCKER_PFX  INSTALL_PFX  FLAGS
update_tool SEMGREP semgrep/semgrep "" "pip" "gitlab"
update_tool TRIVY aquasecurity/trivy "" "v" "gitlab"
update_tool GITLEAKS gitleaks/gitleaks "v" "v" "gitlab,bare_tarball"
update_tool HADOLINT hadolint/hadolint "v" "v" ""
update_tool CHECKOV bridgecrewio/checkov "" "pip" "gitlab"
update_tool GOSEC securego/gosec "v" "v" ""
update_tool BRAKEMAN presidentbeef/brakeman "v" "gem" ""
update_tool DOCKLE goodwithtech/dockle "v" "v" "bare_tarball"
update_tool TRUFFLEHOG trufflesecurity/trufflehog "" "v" "gitlab"
update_tool OSV_SCANNER google/osv-scanner "v" "v" "gitlab"
update_tool PHPSTAN phpstan/phpstan "" "composer" "gitlab,2part_docker"
update_tool BEARER bearer/bearer "v" "v" "gitlab"
update_tool GRYPE anchore/grype "v" "v" "gitlab"
update_tool KICS Checkmarx/kics "v" "v" "gitlab"
update_tool SPOTBUGS spotbugs/spotbugs "" "" "gitlab"
update_tool CPPCHECK facthunder/cppcheck "" "" "gitlab"
update_tool SWIFTLINT realm/SwiftLint "" "" "gitlab"

echo ""
echo "── GitHub Actions SHAs ──"
echo ""

#                ACTION_PATH                                              REPO                              TAG
update_action "actions/checkout" "actions/checkout" "v4"
update_action "gitleaks/gitleaks-action" "gitleaks/gitleaks-action" "v2"
update_action "semgrep/semgrep-action" "semgrep/semgrep-action" "v1"
update_action "aquasecurity/trivy-action" "aquasecurity/trivy-action" "0.34.1"
update_action "github/codeql-action/upload-sarif" "github/codeql-action" "v3"
update_action "hadolint/hadolint-action" "hadolint/hadolint-action" "v3.1.0"
update_action "bridgecrewio/checkov-action" "bridgecrewio/checkov-action" "v12"
update_action "securego/gosec" "securego/gosec" "v2.24.0"
update_action "google/osv-scanner-action/osv-scanner" "google/osv-scanner-action" "v2.3.3"
update_action "trufflesecurity/trufflehog" "trufflesecurity/trufflehog" "v3.93.6"
update_action "bearer/bearer-action" "bearer/bearer-action" "v2"
update_action "anchore/scan-action" "anchore/scan-action" "v6"
update_action "checkmarx/kics-github-action" "checkmarx/kics-github-action" "v2"

# ── Section 6: Summary ─────────────────────────────────────────────

echo ""
echo "══════════════════════════════════"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "Errors (${#ERRORS[@]}):"
  for err in "${ERRORS[@]}"; do
    echo "  ✗ $err"
  done
fi

if [[ ${#MAJOR_BUMPS[@]} -gt 0 ]]; then
  echo ""
  echo "Major version bumps detected (not applied):"
  for bump in "${MAJOR_BUMPS[@]}"; do
    echo "  ⚠ $bump"
  done
fi

if [[ ${#CHANGES[@]} -gt 0 ]]; then
  echo ""
  echo "Changes (${#CHANGES[@]}):"
  for change in "${CHANGES[@]}"; do
    IFS='|' read -r name old new <<<"$change"
    printf '  %-40s %s → %s\n' "$name" "$old" "$new"
  done

  if [[ "$OUTPUT_CHANGES" == "true" ]]; then
    echo ""
    for change in "${CHANGES[@]}"; do
      echo "CHANGE: $change"
    done
  fi
else
  echo ""
  echo "All tools up to date."
fi

echo ""
