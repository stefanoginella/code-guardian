#!/usr/bin/env bash
set -euo pipefail

# Prepublish script: syncs versions and copies README/LICENSE for npm package.
# Usage: bash build/prepublish.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
PACKAGE_JSON="${REPO_ROOT}/package/package.json"

# Sync version from plugin.json → package.json
version=$(grep '"version"' "${PLUGIN_JSON}" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/\"version\":[[:space:]]*\"[^\"]*\"/\"version\": \"${version}\"/" "${PACKAGE_JSON}"
else
  sed -i "s/\"version\":[[:space:]]*\"[^\"]*\"/\"version\": \"${version}\"/" "${PACKAGE_JSON}"
fi

echo "  version: ${version}"

# Copy README and LICENSE to package dir (for npmjs.com)
cp "${REPO_ROOT}/README.md" "${REPO_ROOT}/package/"
cp "${REPO_ROOT}/LICENSE.md" "${REPO_ROOT}/package/"

echo "  done"
