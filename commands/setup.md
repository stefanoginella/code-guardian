---
name: code-guardian-setup
description: Check security tool availability for the detected stack and show install instructions
allowed-tools:
  - Bash
  - Read
  - Write
---

# Security Tools Setup

Detect the project stack, check which security tools are available, and report what's missing with install instructions.

This command does NOT install anything — it gives you a clear picture and copy-pasteable commands.

## Execution Flow

### Step 1: Detect Stack

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh .
```

Display detected stack: languages, frameworks, package managers, Docker, CI systems, IaC tools.

### Step 2: Check Tools

```bash
echo '<stack_json>' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-tools.sh
```

### Step 3: Cache Results

Save detection results for future scan/ci commands:

```bash
echo '<stack_json>' > /tmp/cg-stack.json
echo '<tools_json>' > /tmp/cg-tools.json
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cache-state.sh --write \
  --stack-file /tmp/cg-stack.json --tools-file /tmp/cg-tools.json
```

### Step 4: Present Report

Show a clear table of all needed tools:

```
| Tool          | Category    | Status                  | How Available          |
|---------------|-------------|-------------------------|------------------------|
| semgrep       | SAST        | Ready                   | Local binary           |
| gitleaks      | Secrets     | Not installed           | Docker available       |
| trivy         | Vuln scan   | MISSING                 | —                      |
| hadolint      | Container   | Ready (Docker fallback) | Docker image (opted in)|
```

Status meanings:
- **Ready** — installed locally, will run directly
- **Ready (Docker fallback)** — not installed locally, but Docker fallback is enabled and image is available
- **Not installed — Docker available** — Docker image exists but fallback is disabled; install locally or enable `dockerFallback`
- **MISSING** — no local binary and no Docker image available

### Step 5: Show Install Instructions for Missing/Unavailable Tools

For tools not installed locally, lead with local install commands. Mention Docker fallback as secondary option:

```
Tools not installed locally:

  gitleaks:
    Install: brew install gitleaks
    (Docker image available — enable dockerFallback to use)

  trivy:
    Install: brew install trivy

  checkov:
    Install: pip3 install checkov
    (Docker image available — enable dockerFallback to use)
```

End with: "Scans use locally installed tools by default. Install what you need and run `/code-guardian:code-guardian-setup` again to verify. To use Docker images as fallback, set `dockerFallback: true` in `.claude/code-guardian.config.json`."

If ESLint security is in the tool list, note that it requires the `eslint-plugin-security` package to be installed in the project (`npm install -D eslint-plugin-security`). Without it, the scanner will skip even if ESLint itself is available.

If all tools are available, just say so: "All recommended security tools are available. Run `/code-guardian:code-guardian-scan` to scan."

### Step 6: Detect Test Directories

Search the project for directories commonly used for test code, fixtures, and mocks. These directories generate false positives in SAST and secret scanners because they intentionally contain fake credentials, mock auth tokens, test SQL queries, etc.

**Patterns to search for** (only top-level and one level deep): `tests`, `test`, `__tests__`, `spec`, `e2e`, `cypress`, `playwright`, `fixtures`, `__fixtures__`, `__mocks__`, `mocks`, `testdata`, `test-data`

Use `find` to discover which of these exist:
```bash
find . -maxdepth 2 -type d \( -name "tests" -o -name "test" -o -name "__tests__" -o -name "spec" -o -name "e2e" -o -name "cypress" -o -name "playwright" -o -name "fixtures" -o -name "__fixtures__" -o -name "__mocks__" -o -name "mocks" -o -name "testdata" -o -name "test-data" \) -not -path "./.git/*" -not -path "*/node_modules/*" 2>/dev/null
```

Then read current exclusions to filter out already-excluded dirs:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh --get exclude
```

Filter out directories that are already in the hardcoded exclusion list (`node_modules`, `.venv`, `dist`, `build`, `coverage`, etc.) or already in the user's config `exclude` key.

Store the detected test directories for use in Step 8.

**If test directories are found that are NOT already excluded**: mention them in the report (Step 8 will auto-add them).

**If no test directories are found**: Skip silently (no output).

### Step 7: Write Configuration

Always generate `.claude/code-guardian.config.json` with all options explicitly set, using sensible defaults based on what was detected:

- **tools**: List all available tool names from the check-tools output (Step 2). This makes it explicit which tools will run.
- **scope**: `"codebase"`
- **dockerFallback**: `false`
- **aiReview**: `true`
- **exclude**: Include any test directories detected in Step 6. Merge with any existing exclusions from a previous config (don't lose them).

If the config file already exists, read it first and preserve any user customizations (e.g. if they changed `scope` to `"uncommitted"`, keep that). Only fill in missing keys with defaults and update `tools` to reflect currently available tools.

Write the config file and display it.

### Step 8: Finish

Tell the user the config has been saved, then explain the available options they can customize:

> **Configuration saved to `.claude/code-guardian.config.json`.**
>
> You can customize these options by editing the file:
>
> - **`tools`** — List of tools to run (e.g. `["gitleaks", "semgrep"]`). Remove tools you don't want, or leave all for full coverage.
> - **`scope`** — What to scan: `"codebase"` (everything), `"uncommitted"` (unstaged/staged changes only), or `"unpushed"` (commits not yet pushed).
> - **`dockerFallback`** — Set `true` to use Docker images for tools not installed locally.
> - **`aiReview`** — Set `false` to skip the AI security review pass after CLI tools finish.
> - **`exclude`** — Directories to skip in SAST/secret scans (e.g. test dirs with fake credentials). Dependency scanners are unaffected.
>
> CLI arguments (`--tools`, `--scope`) always override config values. Run `/code-guardian:scan` to scan.

## Configuration File Reference

**Location**: `.claude/code-guardian.config.json`

| Key              | Type     | Default        | Description                                           |
|------------------|----------|----------------|-------------------------------------------------------|
| `tools`          | string[] | (all available) | Only run these tools. Omit to run all available.     |
| `scope`          | string   | `"codebase"`    | Default scan scope: codebase, uncommitted, unpushed. |
| `dockerFallback` | boolean  | `false`         | Allow Docker images as fallback when tools aren't installed locally. |
| `aiReview`       | boolean  | `true`          | Run AI security review after CLI tools. Set `false` to skip.             |
| `exclude`        | string[] | `[]`            | Additional directories to exclude from SAST/secret scans (e.g. test dirs). |

**Precedence**: CLI `--tools` / `--scope` always override config values.

## Important Notes

- This command always writes the config file with sensible defaults
- Tool availability is cached for 24 hours so future scans skip re-detection
- Scans work fine with partial tool coverage — missing tools just mean fewer checks
- The config file should be committed to the repo so the team shares the same defaults
