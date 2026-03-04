# 🛡 Code Guardian

[![npm version](https://img.shields.io/npm/v/@stefanoginella/code-guardian)](https://www.npmjs.com/package/@stefanoginella/code-guardian) [![CI](https://github.com/stefanoginella/code-guardian/actions/workflows/lint.yml/badge.svg)](https://github.com/stefanoginella/code-guardian/actions/workflows/lint.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md) [![Plugin](https://img.shields.io/badge/Claude_Code-Plugin-blueviolet)](https://docs.anthropic.com/en/docs/claude-code) [![Status](https://img.shields.io/badge/Status-Experimental-orange)]()

> **⚠️ EXPERIMENTAL** — This plugin is under active development. Scripts, commands, and output formats may change without notice. Test in non-critical projects first.

Deterministic security scanning layer for Claude Code.

Auto-detects your project's tech stack and runs appropriate open-source CLI tools (SAST, secret detection, dependency auditing, container and IaC scanning) to find vulnerabilities. Every tool is free for private repositories, prefers local binaries, and produces a unified findings format so Claude can process results consistently. Docker is available as an opt-in fallback with pinned versions, read-only mounts, and network isolation. Scanning and fixing are separate commands — scan first to see the full picture, then fix what matters.

> 🔧 The plugin ships 18 scanner wrappers and 4 orchestration scripts. The deterministic layer runs real CLI tools for known vulnerability patterns. After CLI tools finish, an AI reviewer automatically analyzes the code for business logic flaws, auth bypass, race conditions, and other issues that no scanner has rules for. You get both in one unified workflow.

## 🚀 Commands

| Command | Description |
|---------|-------------|
| `/code-guardian:code-guardian-scan` | Run a security scan on the codebase (report only — never modifies files) |
| `/code-guardian:code-guardian-fix` | Fix findings from the latest scan report (or a specific report path) |
| `/code-guardian:code-guardian-setup` | Check which security tools are available for the detected stack, install missing ones |
| `/code-guardian:code-guardian-ci` | Generate CI security pipeline configuration for GitHub Actions, GitLab CI, or other systems |

## 🛠 Typical Workflow

1. **Run `/code-guardian:code-guardian-setup`** to check what security tools are available for your project's stack. The plugin auto-detects languages, frameworks, Docker, CI systems, and IaC, then reports which tools are installed locally, which have Docker images available (opt-in fallback), and which are missing with install commands.
2. **Run `/code-guardian:code-guardian-scan`** to kick off a security scan. Findings are grouped by severity with numbered issues and a summary table.
3. **Run `/code-guardian:code-guardian-fix`** to fix findings. By default it fixes everything; use `--levels high` to fix only high-severity issues, or `--issues 1,3,5` to fix specific numbered findings from the report.
4. **Run `/code-guardian:code-guardian-ci`** to add security scanning to your CI pipeline if you haven't already.

### Scan Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `--scope` | `codebase`, `uncommitted`, `unpushed` | `codebase` | What files to scan. `codebase` = all tracked files. `uncommitted` = staged + unstaged + untracked changes. `unpushed` = commits not yet pushed to remote. When scoped, dependency scanners (npm-audit, pip-audit, etc.) are skipped unless their lockfile/manifest is in the changed files. |
| `--tools` | comma-separated tool names | all available | Only run these specific tools (e.g. `--tools semgrep,gitleaks`). Others are skipped. |
| `--refresh` | — | off | Force re-detection of stack and tools, ignoring the 24-hour cache. |

### Fix Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| (positional) | report file path | latest report | Path to a specific scan report. If omitted, uses the most recent report in `.code-guardian/scan-reports/`. |
| `--levels` | comma-separated severities | all | Only fix findings matching these severity levels (e.g. `--levels high` or `--levels high,medium`). |
| `--issues` | comma-separated issue numbers | all | Only fix these specific numbered findings from the report (e.g. `--issues 1,3,5`). |

Scan options can also be set as persistent defaults in `.claude/code-guardian.config.json` — see [Configuration](#️-configuration) below. CLI arguments always override config values.

**Examples:**

```
/code-guardian:code-guardian-scan                              # scan everything
/code-guardian:code-guardian-scan --scope uncommitted          # only scan your local changes
/code-guardian:code-guardian-scan --scope unpushed             # scan commits not yet pushed
/code-guardian:code-guardian-scan --tools semgrep,gitleaks     # only run specific tools

/code-guardian:code-guardian-fix                               # fix all findings from the latest scan
/code-guardian:code-guardian-fix --levels high                  # fix only high-severity findings
/code-guardian:code-guardian-fix --levels high,medium           # fix high and medium severity
/code-guardian:code-guardian-fix --issues 1,3,5                # fix specific numbered findings
/code-guardian:code-guardian-fix path/to/report.md             # fix findings from a specific report
```

## ⚙️ Configuration

Scan defaults can be persisted in `.claude/code-guardian.config.json` so you don't have to pass flags every time. Create it manually or run `/code-guardian:code-guardian-setup` to configure interactively.

```json
{
  "tools": ["semgrep", "gitleaks", "trivy"],
  "scope": "uncommitted",
  "dockerFallback": false,
  "exclude": ["tests", "__tests__", "cypress"]
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `tools` | `string[]` | all available | Only run these tools. Omit to run everything available. |
| `scope` | `string` | `"codebase"` | Default scan scope: `codebase`, `uncommitted`, or `unpushed`. |
| `dockerFallback` | `boolean` | `false` | Allow Docker images as fallback for tools not installed locally. |
| `exclude` | `string[]` | `[]` | Additional directories to exclude from SAST/secret scans (e.g. test dirs). Dependency scanners are unaffected. |

**Precedence:** CLI flags always win over config values. `CG_DOCKER_FALLBACK=1` env var overrides the config `dockerFallback` setting. 

This file should be committed to the repo so the team shares the same scan defaults.

## 🤖 AI Security Review

After CLI tools finish, an AI-powered reviewer automatically analyzes your code for vulnerabilities that pattern-based scanners miss. This runs on every scan as a built-in pipeline step — no flags needed.

**What it catches:** auth/authz bypass, IDOR, race conditions, mass assignment, insecure data flows, input validation gaps, business logic flaws, and error information leaks.

**How it works:** The AI reviewer reads the code in scope (diffs for scoped scans, hotspot files for codebase scans), cross-references against existing CLI findings to avoid duplicates, and emits only high-confidence findings. Results appear in the same report, tagged `[ai-review]`, under the standard severity headings.

## 🧰 Supported Tools

All tools are free, open-source, and work on private repositories with no limitations.

| Category | Tool | Languages/Targets | Autofix | Docker Image |
|----------|------|-------------------|---------|--------------|
| SAST | Semgrep | Multi-language (30+) | Yes | `semgrep/semgrep` |
| SAST | Bandit | Python | No | `python:3-slim` |
| SAST | gosec | Go | No | `securego/gosec` |
| SAST | Brakeman | Ruby/Rails | No | `presidentbeef/brakeman` |
| SAST | ESLint (security) | JS/TS | Partial | — |
| SAST | PHPStan | PHP | No | `ghcr.io/phpstan/phpstan` |
| Secrets | Gitleaks | All | No | `zricethezav/gitleaks` |
| Secrets | TruffleHog | All (filesystem) | No | `trufflesecurity/trufflehog` |
| Dependencies | OSV-Scanner | All ecosystems | No | `ghcr.io/google/osv-scanner` |
| Dependencies | npm audit | JS/TS | Yes | — |
| Dependencies | pip-audit | Python | Yes | — |
| Dependencies | cargo-audit | Rust | No | — |
| Dependencies | bundler-audit | Ruby | No | — |
| Dependencies | govulncheck | Go | No | — |
| Container | Trivy | Images, FS, IaC | No | `aquasec/trivy` |
| Container | Hadolint | Dockerfiles | No | `hadolint/hadolint` |
| Container | Dockle | Docker images (manual) | No | `goodwithtech/dockle` |
| IaC | Checkov | Terraform, CFN, K8s | No | `bridgecrew/checkov` |

> Local installation is the recommended method for all tools. Tools with Docker images can optionally use Docker as a fallback when `dockerFallback` is enabled — see [Configuration](#️-configuration). Tools without a Docker image always require local installation. Run `/code-guardian:code-guardian-setup` to see what's needed and get install commands.

## 📦 Installation

One-command install via npx:

```bash
npx @stefanoginella/code-guardian
```

Or from the marketplace inside Claude Code:

```
/plugin marketplace add stefanoginella/claude-code-plugins
/plugin install code-guardian@stefanoginella-plugins --scope <project|user|local>
```

Scopes: `project` (shared with team), `user` (all your projects), `local` (personal, gitignored).

### Verify Installation

After installing, verify the plugin is loaded:

```
/code-guardian:code-guardian-setup
```

This should detect your project stack and show available tools. If the command isn't recognized, the plugin isn't loaded — check your plugin scope or restart Claude Code.

To verify the npm package:

```bash
npm info @stefanoginella/code-guardian version
```

Or as a local plugin for development:

```bash
claude --plugin-dir /path/to/plugins/code-guardian
```

## 📋 Prerequisites

### Required

- `bash` — shell scripts
- `python3` — JSON parsing in scanner output processing

### Optional

- **Docker** — when explicitly opted in via `"dockerFallback": true` in config, the plugin can use official Docker images as a fallback for tools not installed locally. Docker images are pinned to specific versions, mounted read-only, and run with network isolation where possible. Without Docker or without opt-in, all tools must be installed locally.

### Security Tools

You don't need to install anything upfront. Run `/code-guardian:code-guardian-setup` and the plugin will:
1. Detect your stack
2. Show which tools are needed
3. Report which are installed locally vs. available via Docker
4. Show install commands for anything missing

Local installation is the primary execution method. Docker fallback is available as an opt-in alternative.

## 🏗 Architecture

```
code-guardian/
├── commands/              # Slash commands (scan, fix, setup, ci)
├── agents/                # AI agents (security-fixer for remediation, ai-reviewer for logic-level review)
├── skills/                # Security scanning knowledge base
│   └── security-scanning/
│       ├── SKILL.md
│       └── references/
├── scripts/
│   ├── lib/               # Shared utilities and tool registry
│   │   ├── common.sh      # Colors, logging, Docker helpers, scope management
│   │   └── tool-registry.sh  # Stack → tools mapping, install commands, Docker images
│   ├── scanners/          # 18 individual scanner wrappers (unified JSONL output)
│   ├── detect-stack.sh    # Detects languages, frameworks, Docker, CI, IaC
│   ├── check-tools.sh     # Checks tool availability (local + Docker)
│   ├── scan.sh            # Main scan orchestrator
│   ├── generate-report.sh # Persistent markdown report generator
│   ├── ci-recommend.sh    # CI config generator
│   ├── read-config.sh     # Reads project config (.claude/code-guardian.config.json)
│   └── cache-state.sh     # Cache I/O for stack + tools detection results
└── .claude-plugin/
    └── plugin.json
```

### How the Deterministic Layer Works

Each scanner wrapper follows a local-first execution strategy:

1. **Local binary** (default) — If the tool is installed locally, it runs directly. Fastest option, zero overhead, respects your installed version and configuration.
2. **Docker image** (opt-in fallback) — If the tool isn't installed locally and Docker fallback is enabled (`"dockerFallback": true` in config or `CG_DOCKER_FALLBACK=1` env var), it runs via the tool's official Docker image with hardened security controls:
   - **Pinned versions** — Docker images use exact version tags from the tool registry, never `:latest`
   - **Read-only mounts** — Source code is mounted `:ro`
   - **Network isolation** — `--network none` for tools that don't need network access (gitleaks, hadolint, checkov, gosec, brakeman, trufflehog, phpstan, osv-scanner, dockle)
   - **Minimal socket access** — Docker socket only mounted for image-scanning tools (trivy image mode, dockle)

After choosing the execution environment, each wrapper:
1. Runs the tool with appropriate flags for the requested scope
2. Parses the tool's native output (JSON/SARIF/text) into a unified JSONL format
3. Reports finding count to stderr, returns findings file path to stdout

The unified finding format:
```json
{"tool":"semgrep","severity":"high","rule":"rule-id","message":"description","file":"path/to/file","line":42,"autoFixable":true,"category":"sast"}
```

This means Claude always gets findings in the same shape regardless of which tool produced them — consistent processing, no tool-specific parsing logic in the AI layer.

### State Caching

The plugin caches stack detection and tool availability results in `.claude/code-guardian-cache.json` (already gitignored). This avoids re-running Docker checks and binary lookups on every command.

- **`setup`** writes the cache after detecting the stack and verifying tools
- **`scan`** and **`ci`** read from the cache if it's fresh (< 24 hours), skipping re-detection
- Cache is invalidated automatically if it's older than 24 hours or the project path changes
- Use `--refresh` on the scan command to bypass the cache and force re-detection

## 📝 Scan Reports

Each scan automatically saves a detailed markdown report to `.code-guardian/scan-reports/scan-report-YYYYMMDD-HHMMSS.md`.

**Report contents:**
- Header with date, scope, and scanners run
- Summary table with finding counts by severity
- Per-tool breakdown table
- Every finding as a numbered `- [ ]` checkbox item (e.g. `**#1**`), grouped by severity (high first), with tool, rule ID, message, and file location
- Skipped tools (with install commands) and failed tools
- Scope-skipped dependency scanners (when using `--scope uncommitted` or `--scope unpushed`)

**Remediation tracking:** Run `/code-guardian:code-guardian-fix` to fix findings — it checks off fixed items (`- [x]`) in the report automatically. You can also open the report in any markdown editor and check off items manually. The reports persist in your project directory — add `.code-guardian/` to `.gitignore` if you don't want them committed, or commit them to track remediation progress across the team.

## 🔐 Permissions

The scan command runs bash scripts that invoke Docker or local CLI tools. Claude Code will prompt you to approve these if they aren't already in your allow list. For smoother runs, consider adding these patterns to your project's `.claude/settings.json` under `permissions.allow`:

- `Bash(bash */code-guardian/scripts/*)`

## 📄 License

[MIT](LICENSE.md)
