#!/usr/bin/env bash
set -euo pipefail

# Syncs version from plugin.json → package.json (no file copying).
# Usage: bash build/sync-versions.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
PACKAGE_JSON="${REPO_ROOT}/package/package.json"

if [ ! -f "${PLUGIN_JSON}" ]; then
  echo "Error: ${PLUGIN_JSON} not found" >&2
  exit 1
fi
if [ ! -f "${PACKAGE_JSON}" ]; then
  echo "Error: ${PACKAGE_JSON} not found" >&2
  exit 1
fi

version=$(grep '"version"' "${PLUGIN_JSON}" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/\"version\":[[:space:]]*\"[^\"]*\"/\"version\": \"${version}\"/" "${PACKAGE_JSON}"
else
  sed -i "s/\"version\":[[:space:]]*\"[^\"]*\"/\"version\": \"${version}\"/" "${PACKAGE_JSON}"
fi

echo "code-guardian: ${version}"
