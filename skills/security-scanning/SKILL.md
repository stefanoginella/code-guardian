---
name: security-scanning
description: "Provides knowledge about code-guardian's security scanning tools, result interpretation, and vulnerability fix patterns. Auto-activates when users ask about security scanning, vulnerability remediation, SAST tools, secret detection, dependency auditing, or container security in the context of code-guardian. Use when the user asks `how do I fix this vulnerability`, `what security tools should I use`, `explain this security finding`, or `how does code-guardian work`."
---

# Security Scanning Knowledge

## code-guardian Overview

code-guardian is a deterministic security scanning plugin for Claude Code. It detects the project stack and runs appropriate open-source CLI tools. All tools are free for private repositories.

### Commands
- `/code-guardian:code-guardian-scan` — Run a security scan (report only — never modifies files)
- `/code-guardian:code-guardian-fix` — Fix findings from the latest scan report
- `/code-guardian:code-guardian-setup` — Check tool availability and show install instructions
- `/code-guardian:code-guardian-ci` — Generate CI security pipeline config

### How It Works
1. `detect-stack.sh` identifies languages, frameworks, Docker, CI, IaC
2. `check-tools.sh` verifies tool availability (local binary first, Docker image fallback)
3. `scan.sh` orchestrates running relevant scanners
4. Each scanner outputs unified JSONL findings
5. The `security-fixer` agent applies code-level fixes for findings that tools can't auto-fix
6. The `ai-reviewer` agent analyzes code for business logic flaws, auth bypass, race conditions, and other vulnerabilities that pattern-based CLI tools miss

## Tool Reference

### Multi-Language SAST
**Semgrep** — Pattern-based static analysis. Supports 30+ languages. Has autofix.
- Runs: `semgrep --config auto` (uses community rules)
- Autofix: `semgrep --config auto --autofix`
- Docker: `semgrep/semgrep:latest`

### Secret Detection
**Gitleaks** — Scans git history and working tree for secrets (API keys, passwords, tokens).
- Docker: `zricethezav/gitleaks:latest`
- No autofix (secrets must be rotated manually)

**TruffleHog** — Deep secret detection across filesystem and git history using detector-based verification.
- Docker: `trufflesecurity/trufflehog:latest`
- No autofix (secrets must be rotated manually)
- Complements Gitleaks with different detection heuristics

### Dependency Vulnerability Scanning
| Tool | Language | Autofix |
|------|----------|---------|
| `npm audit` | JS/TS | Yes (`npm audit fix`) |
| `pip-audit` | Python | Yes (`--fix`) |
| `cargo-audit` | Rust | No |
| `bundler-audit` | Ruby | No |
| `govulncheck` | Go | No |
| `osv-scanner` | All ecosystems | No |

### Container Security
**Trivy** — Scans container images, filesystems, IaC for vulnerabilities.
- Modes: `fs` (filesystem), `image` (Docker image), `config` (IaC)
- Docker: `aquasec/trivy:latest`

**Hadolint** — Dockerfile linter. Checks for best practice violations.
- Docker: `hadolint/hadolint:latest`

**Dockle** — Container image linter. Checks CIS benchmarks.
- Docker: `goodwithtech/dockle:latest`

### Language-Specific SAST
| Tool | Language | Autofix |
|------|----------|---------|
| Bandit | Python | No |
| gosec | Go | No |
| Brakeman | Ruby/Rails | No |
| ESLint (security) | JS/TS | Partial |
| PHPStan | PHP | No |

### IaC Security
**Checkov** — Scans Terraform, CloudFormation, Kubernetes, Helm for misconfigurations.
- Docker: `bridgecrew/checkov:latest`

## Unified Finding Format

All scanners output JSONL with this schema:
```json
{
  "tool": "scanner-name",
  "severity": "high|medium|low|info",
  "rule": "rule-identifier",
  "message": "human-readable description",
  "file": "relative/path/to/file",
  "line": 42,
  "autoFixable": true,
  "category": "sast|secrets|dependency|container|iac|ai-review"
}
```

## Common Vulnerability Fix Patterns

For detailed fix patterns, see `references/fix-patterns.md`.

## Scan Scope Options

| Scope | What It Scans |
|-------|---------------|
| `codebase` | All tracked files |
| `uncommitted` | All local uncommitted work (staged + unstaged + untracked) |
| `unpushed` | All changes since diverging from base |

## AI Security Review

After CLI tools complete, the `ai-reviewer` agent automatically analyzes code for vulnerabilities that deterministic pattern-matching tools miss. This runs as a built-in pipeline step on every scan — no flags or configuration needed.

### What It Catches

The AI reviewer focuses on logic-level vulnerabilities:

| Category | Rule | Examples |
|----------|------|----------|
| Auth/Authz Bypass | `auth-bypass` | Missing auth middleware, JWT validation gaps, privilege escalation |
| IDOR | `idor` | User-supplied IDs without ownership checks, guessable identifiers |
| Race Conditions | `race-condition` | TOCTOU bugs, non-atomic read-modify-write, double-spend |
| Mass Assignment | `mass-assignment` | Unfiltered request body into ORM, modifiable hidden fields |
| Data Leaks | `data-leak` | Secrets logged, sensitive data in responses, credentials in URLs |
| Input Validation | `input-validation` | Missing validation on security-sensitive operations, type confusion |
| Business Logic | `business-logic` | State machine errors, missing business rules, replay attacks |
| Error Info Leaks | `error-info-leak` | Stack traces in responses, verbose DB errors, internal path exposure |

### Scope Behavior

- **uncommitted**: Reviews `git diff` + staged changes + untracked files
- **unpushed**: Reviews `git diff <baseRef>...HEAD`
- **codebase**: Reviews files already flagged by CLI tools plus high-risk pattern files (auth, middleware, routes, permissions) — capped at 20 files

### Deduplication

AI findings are deduplicated against CLI tool findings. If a CLI tool already reported an issue at the same file and line, the AI reviewer skips it. Only high-confidence findings are emitted.

### Finding Format

AI findings use `"tool": "ai-review"` and `"category": "ai-review"` in the unified JSONL format. They appear in the scan report tagged with `[ai-review]` and are included in the Per-Tool Breakdown and By Category tables.
