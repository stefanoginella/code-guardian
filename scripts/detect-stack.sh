#!/usr/bin/env bash
# Detect project stack: languages, frameworks, Docker, CI systems
# Outputs JSON to stdout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR"

languages=()
frameworks=()
has_docker=false
has_docker_compose=false
ci_systems=()
package_managers=()
iac_tools=()

# Exclude dirs that should never be scanned
_PRUNE=(-path './.git' -o -path './node_modules' -o -path './vendor' -o -path './.venv' -o -path './venv' -o -path './__pycache__')

# Helper: check if a file name exists anywhere within maxdepth (default 3)
file_exists_any() {
  local name="$1" depth="${2:-3}"
  find . -maxdepth "$depth" \( "${_PRUNE[@]}" \) -prune -o -name "$name" -print -quit 2>/dev/null | grep -q .
}

# Helper: check if any file matching an extension exists within maxdepth
ext_exists() {
  local ext="$1" depth="${2:-3}"
  find . -maxdepth "$depth" \( "${_PRUNE[@]}" \) -prune -o -name "*.$ext" -print -quit 2>/dev/null | grep -q .
}

# Helper: grep across all matching files found by find
grep_in_files() {
  local pattern="$1" name_glob="$2" depth="${3:-3}"
  find . -maxdepth "$depth" \( "${_PRUNE[@]}" \) -prune -o -name "$name_glob" -print0 2>/dev/null | \
    xargs -0 grep -lq "$pattern" 2>/dev/null
}

# ── Language detection ────────────────────────────────────────────────

# JavaScript / TypeScript
if ext_exists js || ext_exists ts || ext_exists jsx || ext_exists tsx || file_exists_any package.json; then
  if file_exists_any tsconfig.json; then
    languages+=("typescript")
  fi
  languages+=("javascript")
  # Package managers
  file_exists_any package-lock.json && package_managers+=("npm")
  file_exists_any yarn.lock && package_managers+=("yarn")
  file_exists_any pnpm-lock.yaml && package_managers+=("pnpm")
  { file_exists_any bun.lockb || file_exists_any bun.lock; } && package_managers+=("bun")
  # Frameworks (search all package.json files found in tree)
  grep_in_files '"next"' package.json && frameworks+=("nextjs")
  grep_in_files '"react"' package.json && frameworks+=("react")
  grep_in_files '"vue"' package.json && frameworks+=("vue")
  grep_in_files '"angular"' package.json && frameworks+=("angular")
  grep_in_files '"express"' package.json && frameworks+=("express")
  grep_in_files '"fastify"' package.json && frameworks+=("fastify")
  grep_in_files '"svelte"' package.json && frameworks+=("svelte")
  grep_in_files '"nuxt"' package.json && frameworks+=("nuxt")
  grep_in_files '"astro"' package.json && frameworks+=("astro")
fi

# Python
if ext_exists py || file_exists_any requirements.txt || file_exists_any pyproject.toml || \
   file_exists_any setup.py || file_exists_any Pipfile || file_exists_any uv.lock; then
  languages+=("python")
  file_exists_any requirements.txt && package_managers+=("pip")
  file_exists_any Pipfile && package_managers+=("pipenv")
  file_exists_any poetry.lock && package_managers+=("poetry")
  file_exists_any uv.lock && package_managers+=("uv")
  # Frameworks
  grep_in_files 'from django\|import django' "*.py" && frameworks+=("django")
  grep_in_files 'from flask\|import flask' "*.py" && frameworks+=("flask")
  grep_in_files 'from fastapi\|import fastapi' "*.py" && frameworks+=("fastapi")
fi

# Go
if file_exists_any go.mod || ext_exists go; then
  languages+=("go")
  package_managers+=("go-modules")
fi

# Rust
if file_exists_any Cargo.toml || file_exists_any Cargo.lock; then
  languages+=("rust")
  package_managers+=("cargo")
fi

# Ruby
if file_exists_any Gemfile || file_exists_any Rakefile || ext_exists rb; then
  languages+=("ruby")
  package_managers+=("bundler")
  file_exists_any routes.rb && frameworks+=("rails")
fi

# Java / Kotlin
if file_exists_any pom.xml || file_exists_any build.gradle || file_exists_any "build.gradle.kts"; then
  if file_exists_any "build.gradle.kts" || ext_exists kt; then
    languages+=("kotlin")
  fi
  languages+=("java")
  file_exists_any pom.xml && package_managers+=("maven")
  { file_exists_any build.gradle || file_exists_any "build.gradle.kts"; } && package_managers+=("gradle")
fi

# PHP
if file_exists_any composer.json || ext_exists php; then
  languages+=("php")
  package_managers+=("composer")
  grep_in_files '"laravel/framework"' composer.json && frameworks+=("laravel")
fi

# C# / .NET
if ext_exists csproj || ext_exists sln || file_exists_any global.json; then
  languages+=("csharp")
  package_managers+=("nuget")
fi

# ── Docker detection ──────────────────────────────────────────────────
if file_exists_any Dockerfile || ext_exists dockerfile; then
  has_docker=true
fi
if file_exists_any docker-compose.yml || file_exists_any docker-compose.yaml || \
   file_exists_any compose.yml || file_exists_any compose.yaml; then
  has_docker_compose=true
fi

# ── CI detection ──────────────────────────────────────────────────────
[[ -d .github/workflows ]] && ci_systems+=("github-actions")
[[ -f .gitlab-ci.yml ]] && ci_systems+=("gitlab-ci")
[[ -f Jenkinsfile ]] && ci_systems+=("jenkins")
[[ -f .circleci/config.yml ]] && ci_systems+=("circleci")
[[ -f .travis.yml ]] && ci_systems+=("travis")
[[ -f bitbucket-pipelines.yml ]] && ci_systems+=("bitbucket-pipelines")
[[ -f azure-pipelines.yml ]] && ci_systems+=("azure-pipelines")
[[ -d .buildkite ]] && ci_systems+=("buildkite")

# ── IaC detection ─────────────────────────────────────────────────────
# Terraform: look for .tf files
if find . -maxdepth 3 -name "*.tf" 2>/dev/null | grep -q .; then
  iac_tools+=("terraform")
fi
# CloudFormation: look for AWSTemplateFormatVersion in YAML/JSON
if find . -maxdepth 3 \( -name "*.yaml" -o -name "*.yml" -o -name "*.json" \) -not -path './.git/*' -print0 2>/dev/null | \
   xargs -0 grep -lq "AWSTemplateFormatVersion" 2>/dev/null; then
  iac_tools+=("cloudformation")
fi
# Helm: look for Chart.yaml specifically
if find . -maxdepth 3 -name "Chart.yaml" 2>/dev/null | grep -q .; then
  iac_tools+=("helm")
fi
# Kubernetes: look for k8s manifests (apiVersion + kind in same file, not in node_modules or .github)
if find . -maxdepth 3 \( -name "*.yaml" -o -name "*.yml" \) -not -path './.git/*' -not -path './node_modules/*' -not -path './.github/*' -print0 2>/dev/null | \
   xargs -0 grep -lZ "^apiVersion:" 2>/dev/null | xargs -0 grep -lq "^kind:" 2>/dev/null; then
  iac_tools+=("kubernetes")
fi

# ── Output JSON ───────────────────────────────────────────────────────
json_array() {
  local items=("$@")
  if [[ ${#items[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi
  local out="["
  for i in "${!items[@]}"; do
    [[ $i -gt 0 ]] && out+=","
    out+="\"${items[$i]}\""
  done
  out+="]"
  printf '%s' "$out"
}

# Build each field (use ${arr[@]+"${arr[@]}"} to handle empty arrays with set -u)
_lang=$(json_array ${languages[@]+"${languages[@]}"})
_frame=$(json_array ${frameworks[@]+"${frameworks[@]}"})
_pm=$(json_array ${package_managers[@]+"${package_managers[@]}"})
_ci=$(json_array ${ci_systems[@]+"${ci_systems[@]}"})
_iac=$(json_array ${iac_tools[@]+"${iac_tools[@]}"})

printf '{\n'
printf '  "languages": %s,\n' "$_lang"
printf '  "frameworks": %s,\n' "$_frame"
printf '  "packageManagers": %s,\n' "$_pm"
printf '  "docker": %s,\n' "$has_docker"
printf '  "dockerCompose": %s,\n' "$has_docker_compose"
printf '  "ciSystems": %s,\n' "$_ci"
printf '  "iacTools": %s\n' "$_iac"
printf '}\n'
