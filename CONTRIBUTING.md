# Contributing

Thank you for your interest in contributing! This repository contains the **code-guardian** Claude Code plugin — deterministic + AI security scanning layer.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- `bash` and `python3`
- `jq` installed (used by hook scripts)
- Optional: Docker (for fallback scanner execution)

## Development Setup

After cloning, configure git to use the repo's hooks:

```bash
git config core.hooksPath .githooks
```

This enables the pre-commit hook that auto-syncs `package/package.json` versions when `plugin.json` changes.

Test the plugin locally without installing from the marketplace:

```bash
claude --plugin-dir /path/to/code-guardian
```

This loads the plugin for that session. Add `--debug` to see hook execution and plugin loading details.

## Repository Structure

```
.claude-plugin/
  plugin.json               — Plugin manifest (source of truth for version)

commands/                   — Slash commands (scan, fix, setup, ci)
agents/                     — AI agents (security-fixer, ai-reviewer)
skills/                     — Security scanning knowledge base
  security-scanning/
    SKILL.md
    references/

scripts/                    — Scanner wrappers and orchestration
  lib/                      — Shared utilities and tool registry
    common.sh
    tool-registry.sh
  scanners/                 — 18 individual scanner wrappers
  detect-stack.sh
  check-tools.sh
  scan.sh
  generate-report.sh
  ci-recommend.sh
  read-config.sh
  cache-state.sh

hooks/                      — Hook definitions and scripts

package/                    — npm companion package (@stefanoginella/code-guardian)
  package.json
  cli.js                    — npx entry point

build/                      — Build scripts (separate from plugin scripts/)
  prepublish.sh
  sync-versions.sh
  update-tool-versions.sh

.githooks/
  pre-commit                — Auto-syncs package.json versions on commit

.github/workflows/
  publish.yml               — CI: auto-publish to npm on plugin.json version bump
  update-tool-versions.yml  — Weekly check for new security tool releases
```

### Key Files

- **`.claude-plugin/plugin.json`** — Plugin manifest; bump the version when making meaningful changes (source of truth for npm package version)
- **`commands/*.md`** — Each file is a slash command with YAML frontmatter and a markdown body
- **`scripts/lib/tool-registry.sh`** — Stack-to-tools mapping, Docker image pins, install commands
- **`scripts/scanners/*.sh`** — Individual scanner wrappers producing unified JSONL output
- **`package/cli.js`** — npm bin entry point; adds marketplace and installs plugin via `claude` CLI
- **`build/prepublish.sh`** — Run before `npm publish` to sync versions and copy README/LICENSE

## Running Tests

The test suite uses [bats-core](https://github.com/bats-core/bats-core) and installs it automatically on first run:

```bash
bash tests/run-tests.sh
```

Tests cover stack detection, config reading, cache I/O, report generation, and findings validation.

## Linting

All shell scripts are checked with ShellCheck and formatted with shfmt:

```bash
# ShellCheck — static analysis
shellcheck --severity=warning --shell=bash \
  scripts/lib/*.sh scripts/*.sh scripts/scanners/*.sh \
  build/*.sh hooks/scripts/*.sh

# shfmt — formatting check
shfmt -d -i 2 -ci -bn \
  scripts/lib/*.sh scripts/*.sh scripts/scanners/*.sh \
  build/*.sh hooks/scripts/*.sh

# Auto-format all scripts
shfmt -w -i 2 -ci -bn \
  scripts/lib/*.sh scripts/*.sh scripts/scanners/*.sh \
  build/*.sh hooks/scripts/*.sh
```

Both checks run in CI on every push and PR.

## How to Contribute

### Reporting Issues

- Open an issue on GitHub with a clear description of the problem
- Include which command you were running (`scan`, `fix`, `setup`, `ci`)
- Paste any relevant error output

### Suggesting Features

- Open an issue describing the feature and its use case

### Submitting Changes

1. Fork the repository
2. Create a branch for your change
3. Make your changes
4. Test the affected command(s) with a real project
5. Submit a pull request

## What Can Be Contributed

- **Scanner wrappers** (`scripts/scanners/`) — New scanner integrations, improvements to existing wrappers
- **Command improvements** (`commands/`) — Better prompts, new options
- **Agent improvements** (`agents/`) — Enhanced AI review capabilities
- **Tool registry updates** (`scripts/lib/tool-registry.sh`) — New tool versions, new tools
- **Hook improvements** (`hooks/`) — New hook scripts, new hook types
- **Manifest updates** (`.claude-plugin/plugin.json`) — Version bumps, metadata
- **Documentation** — README, CONTRIBUTING, examples

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE.md).
