#!/bin/bash
# SessionStart hook: plugin startup message.
#
# Outputs a systemMessage with plugin status and a link to the README.

set -euo pipefail

cat <<'EOF'
{
  "systemMessage": "The `code-guardian` plugin is active. This plugin is EXPERIMENTAL. Check https://github.com/stefanoginella/claude-code-plugins/blob/main/plugins/code-guardian/README.md for requirements, details and usage instructions."
}
EOF
exit 0
