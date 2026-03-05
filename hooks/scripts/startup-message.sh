#!/usr/bin/env bash
# SessionStart hook: plugin startup message.
#
# Outputs a systemMessage with plugin status and a link to the README.

set -euo pipefail

cat <<'EOF'
{
  "systemMessage": "The `code-guardian` plugin is active. This plugin is EXPERIMENTAL. Check https://github.com/stefanoginella/code-guardian for details and usage instructions."
}
EOF
exit 0
