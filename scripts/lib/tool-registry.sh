#!/usr/bin/env bash
# Tool registry: maps stacks to tools, provides install commands and Docker images
# shellcheck disable=SC2034  # TOOL_* variables are accessed dynamically via ${!var_name}
set -euo pipefail

_TOOL_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_TOOL_REGISTRY_DIR}/common.sh"

# ── Tool definitions ──────────────────────────────────────────────────
# Format: TOOL_<name>_DOCKER, TOOL_<name>_INSTALL_<os>, TOOL_<name>_CATEGORY

# Semgrep — multi-language SAST
TOOL_SEMGREP_DOCKER="semgrep/semgrep:1.153.0"
TOOL_SEMGREP_INSTALL_MACOS="brew install semgrep"
TOOL_SEMGREP_INSTALL_LINUX="pip3 install semgrep"
TOOL_SEMGREP_CATEGORY="sast"

# Trivy — vulnerability scanner (containers, fs, IaC)
TOOL_TRIVY_DOCKER="aquasec/trivy:0.69.1"
TOOL_TRIVY_INSTALL_MACOS="brew install trivy"
TOOL_TRIVY_INSTALL_LINUX="brew install trivy"
TOOL_TRIVY_CATEGORY="vulnerability"

# Gitleaks — secret detection
TOOL_GITLEAKS_DOCKER="zricethezav/gitleaks:v8.30.0"
TOOL_GITLEAKS_INSTALL_MACOS="brew install gitleaks"
TOOL_GITLEAKS_INSTALL_LINUX="brew install gitleaks"
TOOL_GITLEAKS_CATEGORY="secrets"

# Hadolint — Dockerfile linter
TOOL_HADOLINT_DOCKER="hadolint/hadolint:v2.14.0"
TOOL_HADOLINT_INSTALL_MACOS="brew install hadolint"
TOOL_HADOLINT_INSTALL_LINUX="brew install hadolint"
TOOL_HADOLINT_CATEGORY="container"

# Checkov — IaC scanner
TOOL_CHECKOV_DOCKER="bridgecrew/checkov:3.2.506"
TOOL_CHECKOV_INSTALL_MACOS="brew install checkov"
TOOL_CHECKOV_INSTALL_LINUX="pip3 install checkov"
TOOL_CHECKOV_CATEGORY="iac"

# npm audit — JS/TS dependency audit
TOOL_NPM_AUDIT_DOCKER=""
TOOL_NPM_AUDIT_INSTALL_MACOS="(bundled with Node.js)"
TOOL_NPM_AUDIT_INSTALL_LINUX="(bundled with Node.js)"
TOOL_NPM_AUDIT_CATEGORY="dependency"

# pip-audit — Python dependency audit
TOOL_PIP_AUDIT_DOCKER=""
TOOL_PIP_AUDIT_INSTALL_MACOS="brew install pip-audit"
TOOL_PIP_AUDIT_INSTALL_LINUX="pip3 install pip-audit"
TOOL_PIP_AUDIT_CATEGORY="dependency"

# Bandit — Python SAST (uses python:3-slim with inline pip install as Docker fallback)
TOOL_BANDIT_DOCKER="python:3-slim"
TOOL_BANDIT_INSTALL_MACOS="brew install bandit"
TOOL_BANDIT_INSTALL_LINUX="pip3 install bandit"
TOOL_BANDIT_CATEGORY="sast"

# gosec — Go SAST
TOOL_GOSEC_DOCKER="securego/gosec:v2.24.0"
TOOL_GOSEC_INSTALL_MACOS="brew install gosec"
TOOL_GOSEC_INSTALL_LINUX="go install github.com/securego/gosec/v2/cmd/gosec@latest"
TOOL_GOSEC_CATEGORY="sast"

# govulncheck — Go vulnerability checker
TOOL_GOVULNCHECK_DOCKER=""
TOOL_GOVULNCHECK_INSTALL_MACOS="brew install govulncheck"
TOOL_GOVULNCHECK_INSTALL_LINUX="go install golang.org/x/vuln/cmd/govulncheck@latest"
TOOL_GOVULNCHECK_CATEGORY="dependency"

# cargo-audit — Rust dependency audit
TOOL_CARGO_AUDIT_DOCKER=""
TOOL_CARGO_AUDIT_INSTALL_MACOS="brew install cargo-audit"
TOOL_CARGO_AUDIT_INSTALL_LINUX="cargo install cargo-audit"
TOOL_CARGO_AUDIT_CATEGORY="dependency"

# bundler-audit — Ruby dependency audit
TOOL_BUNDLER_AUDIT_DOCKER=""
TOOL_BUNDLER_AUDIT_INSTALL_MACOS="gem install bundler-audit"
TOOL_BUNDLER_AUDIT_INSTALL_LINUX="gem install bundler-audit"
TOOL_BUNDLER_AUDIT_CATEGORY="dependency"

# Brakeman — Ruby/Rails SAST
TOOL_BRAKEMAN_DOCKER="presidentbeef/brakeman:v8.0.3"
TOOL_BRAKEMAN_INSTALL_MACOS="gem install brakeman"
TOOL_BRAKEMAN_INSTALL_LINUX="gem install brakeman"
TOOL_BRAKEMAN_CATEGORY="sast"

# eslint (security plugin) — JS/TS security linting
TOOL_ESLINT_SECURITY_DOCKER=""
TOOL_ESLINT_SECURITY_INSTALL_MACOS="npm install -g eslint eslint-plugin-security"
TOOL_ESLINT_SECURITY_INSTALL_LINUX="npm install -g eslint eslint-plugin-security"
TOOL_ESLINT_SECURITY_CATEGORY="sast"

# Dockle — container image linter
TOOL_DOCKLE_DOCKER="goodwithtech/dockle:v0.4.15"
TOOL_DOCKLE_INSTALL_MACOS="brew install goodwithtech/r/dockle"
TOOL_DOCKLE_INSTALL_LINUX="brew install goodwithtech/r/dockle"
TOOL_DOCKLE_CATEGORY="container"

# TruffleHog — secret detection (OSS)
TOOL_TRUFFLEHOG_DOCKER="trufflesecurity/trufflehog:3.93.6"
TOOL_TRUFFLEHOG_INSTALL_MACOS="brew install trufflehog"
TOOL_TRUFFLEHOG_INSTALL_LINUX="brew install trufflehog"
TOOL_TRUFFLEHOG_CATEGORY="secrets"

# OSV-Scanner — universal dependency vulnerability scanner
TOOL_OSV_SCANNER_DOCKER="ghcr.io/google/osv-scanner:v2.3.3"
TOOL_OSV_SCANNER_INSTALL_MACOS="brew install osv-scanner"
TOOL_OSV_SCANNER_INSTALL_LINUX="brew install osv-scanner"
TOOL_OSV_SCANNER_CATEGORY="dependency"

# PHPStan — PHP static analysis
TOOL_PHPSTAN_DOCKER="ghcr.io/phpstan/phpstan:2.1"
TOOL_PHPSTAN_INSTALL_MACOS="brew install phpstan"
TOOL_PHPSTAN_INSTALL_LINUX="composer global require phpstan/phpstan"
TOOL_PHPSTAN_CATEGORY="sast"

# Bearer — data-flow SAST (multi-language)
TOOL_BEARER_DOCKER="bearer/bearer:v1.47.3"
TOOL_BEARER_INSTALL_MACOS="brew install bearer/tap/bearer"
TOOL_BEARER_INSTALL_LINUX="brew install bearer/tap/bearer"
TOOL_BEARER_CATEGORY="sast"

# Grype — vulnerability scanner (SBOMs, filesystems)
TOOL_GRYPE_DOCKER="anchore/grype:v0.93.0"
TOOL_GRYPE_INSTALL_MACOS="brew install grype"
TOOL_GRYPE_INSTALL_LINUX="brew install grype"
TOOL_GRYPE_CATEGORY="vulnerability"

# KICS — IaC security scanner (Terraform, CloudFormation, K8s, Docker, etc.)
TOOL_KICS_DOCKER="checkmarx/kics:v2.1.7"
TOOL_KICS_INSTALL_MACOS="brew install kics"
TOOL_KICS_INSTALL_LINUX="brew install kics"
TOOL_KICS_CATEGORY="iac"

# Composer audit — PHP dependency audit (bundled with Composer)
TOOL_COMPOSER_AUDIT_DOCKER=""
TOOL_COMPOSER_AUDIT_INSTALL_MACOS="(bundled with Composer)"
TOOL_COMPOSER_AUDIT_INSTALL_LINUX="(bundled with Composer)"
TOOL_COMPOSER_AUDIT_CATEGORY="dependency"

# dotnet audit — .NET dependency audit (bundled with .NET SDK)
TOOL_DOTNET_AUDIT_DOCKER=""
TOOL_DOTNET_AUDIT_INSTALL_MACOS="(bundled with .NET SDK)"
TOOL_DOTNET_AUDIT_INSTALL_LINUX="(bundled with .NET SDK)"
TOOL_DOTNET_AUDIT_CATEGORY="dependency"

# SpotBugs — Java bytecode SAST
TOOL_SPOTBUGS_DOCKER="ghcr.io/spotbugs/spotbugs:4.9.3"
TOOL_SPOTBUGS_INSTALL_MACOS="brew install spotbugs"
TOOL_SPOTBUGS_INSTALL_LINUX="brew install spotbugs"
TOOL_SPOTBUGS_CATEGORY="sast"

# cppcheck — C/C++ static analysis
TOOL_CPPCHECK_DOCKER="facthunder/cppcheck:2.17.1"
TOOL_CPPCHECK_INSTALL_MACOS="brew install cppcheck"
TOOL_CPPCHECK_INSTALL_LINUX="brew install cppcheck"
TOOL_CPPCHECK_CATEGORY="sast"

# SwiftLint — Swift linter/SAST
TOOL_SWIFTLINT_DOCKER="ghcr.io/realm/swiftlint:0.58.0"
TOOL_SWIFTLINT_INSTALL_MACOS="brew install swiftlint"
TOOL_SWIFTLINT_INSTALL_LINUX="brew install swiftlint"
TOOL_SWIFTLINT_CATEGORY="sast"

# Sobelow — Elixir/Phoenix security scanner (requires mix)
TOOL_SOBELOW_DOCKER=""
TOOL_SOBELOW_INSTALL_MACOS="mix archive.install hex sobelow"
TOOL_SOBELOW_INSTALL_LINUX="mix archive.install hex sobelow"
TOOL_SOBELOW_CATEGORY="sast"

# dart analyze — Dart/Flutter static analysis (bundled with Dart SDK)
TOOL_DART_ANALYZE_DOCKER=""
TOOL_DART_ANALYZE_INSTALL_MACOS="brew install dart"
TOOL_DART_ANALYZE_INSTALL_LINUX="(bundled with Dart SDK)"
TOOL_DART_ANALYZE_CATEGORY="sast"

# ── Stack to tool mapping ─────────────────────────────────────────────
# Returns tool names relevant for a given stack component
# Usage: get_tools_for_stack <stack_component>
get_tools_for_stack() {
  local component="$1"
  case "$component" in
    javascript | typescript | nodejs)
      echo "semgrep gitleaks trufflehog npm-audit eslint-security osv-scanner bearer"
      ;;
    python)
      echo "semgrep gitleaks trufflehog bandit pip-audit osv-scanner bearer"
      ;;
    go)
      echo "semgrep gitleaks trufflehog gosec govulncheck osv-scanner bearer"
      ;;
    rust)
      echo "semgrep gitleaks trufflehog cargo-audit osv-scanner"
      ;;
    ruby)
      echo "semgrep gitleaks trufflehog bundler-audit brakeman osv-scanner bearer"
      ;;
    java | kotlin)
      echo "semgrep gitleaks trufflehog spotbugs osv-scanner bearer"
      ;;
    php)
      echo "semgrep gitleaks trufflehog phpstan composer-audit osv-scanner bearer"
      ;;
    csharp | dotnet)
      echo "semgrep gitleaks trufflehog dotnet-audit osv-scanner bearer"
      ;;
    swift)
      echo "semgrep gitleaks trufflehog swiftlint osv-scanner bearer"
      ;;
    cpp)
      echo "semgrep gitleaks trufflehog cppcheck osv-scanner bearer"
      ;;
    elixir)
      echo "semgrep gitleaks trufflehog sobelow osv-scanner bearer"
      ;;
    scala)
      echo "semgrep gitleaks trufflehog spotbugs osv-scanner bearer"
      ;;
    dart)
      echo "semgrep gitleaks trufflehog dart-analyze osv-scanner bearer"
      ;;
    docker)
      echo "trivy hadolint grype"
      ;;
    terraform | cloudformation | kubernetes | iac)
      echo "checkov trivy kics"
      ;;
    *)
      echo "semgrep gitleaks trufflehog"
      ;;
  esac
}

# Get the local binary name for a tool
get_tool_binary() {
  local tool="$1"
  case "$tool" in
    npm-audit) echo "npm" ;;
    pip-audit) echo "pip-audit" ;;
    cargo-audit) echo "cargo-audit" ;;
    bundler-audit) echo "bundler-audit" ;;
    eslint-security) echo "eslint" ;;
    osv-scanner) echo "osv-scanner" ;;
    phpstan) echo "phpstan" ;;
    composer-audit) echo "composer" ;;
    dotnet-audit) echo "dotnet" ;;
    dart-analyze) echo "dart" ;;
    sobelow) echo "mix" ;;
    *) echo "$tool" ;;
  esac
}

# Get Docker image for a tool (empty string if no Docker image)
get_tool_docker_image() {
  local tool="$1"
  local var_name
  var_name="TOOL_$(echo "$tool" | tr '[:lower:]-' '[:upper:]_')_DOCKER"
  echo "${!var_name:-}"
}

# Get install command for a tool
get_tool_install_cmd() {
  local tool="$1"
  local os
  os=$(uname -s)
  local suffix="LINUX"
  [[ "$os" == "Darwin" ]] && suffix="MACOS"
  local var_name
  var_name="TOOL_$(echo "$tool" | tr '[:lower:]-' '[:upper:]_')_INSTALL_${suffix}"
  echo "${!var_name:-}"
}

# Get manifest/lockfiles that a dependency scanner cares about
# Returns space-separated list of file patterns (basenames)
# Empty string means the tool is file-based and doesn't need manifest checking
get_tool_manifest_files() {
  local tool="$1"
  case "$tool" in
    npm-audit) echo "package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock package.json" ;;
    pip-audit) echo "requirements.txt pyproject.toml setup.py Pipfile Pipfile.lock" ;;
    cargo-audit) echo "Cargo.lock Cargo.toml" ;;
    bundler-audit) echo "Gemfile.lock Gemfile" ;;
    govulncheck) echo "go.mod go.sum" ;;
    osv-scanner) echo "package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock package.json requirements.txt pyproject.toml Pipfile.lock go.mod go.sum Cargo.lock Gemfile.lock composer.lock pom.xml build.gradle build.gradle.kts packages.config .csproj pubspec.lock mix.lock Package.resolved build.sbt" ;;
    composer-audit) echo "composer.json composer.lock" ;;
    dotnet-audit) echo ".csproj packages.config .sln" ;;
    spotbugs) echo "pom.xml build.gradle build.gradle.kts" ;;
    *) echo "" ;;
  esac
}

# Get tool category
get_tool_category() {
  local tool="$1"
  local var_name
  var_name="TOOL_$(echo "$tool" | tr '[:lower:]-' '[:upper:]_')_CATEGORY"
  echo "${!var_name:-unknown}"
}

# Check if a tool is available (local binary or Docker image)
# Returns: "local", "docker", "docker-available", or "unavailable"
check_tool_availability() {
  local tool="$1"
  local binary docker_image
  binary=$(get_tool_binary "$tool")
  docker_image=$(get_tool_docker_image "$tool")

  if cmd_exists "$binary"; then
    echo "local"
  elif [[ -n "$docker_image" ]] && docker_available; then
    if docker_fallback_enabled; then
      echo "docker"
    else
      echo "docker-available"
    fi
  else
    echo "unavailable"
  fi
}
