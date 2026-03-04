---
name: code-guardian-scan
description: Run security scan on the codebase using detected stack-appropriate tools
argument-hint: "[--scope codebase|uncommitted|unpushed] [--tools tool1,tool2,...] [--refresh]"
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - AskUserQuestion
---

# Security Scan Command

Run a comprehensive security scan using open-source CLI tools appropriate for the project's detected stack. Scans with whatever tools are available — missing tools are skipped and reported at the end.

## Configuration

The scan respects project-level configuration from `.claude/code-guardian.config.json`. CLI arguments always override config values. See `/code-guardian:code-guardian-setup` for details on the config file.

## Execution Flow

### Step 1: Parse Arguments

Parse from `$ARGUMENTS`:
- `--scope` (codebase, uncommitted, unpushed) — default: codebase (or config `scope`)
- `--tools` — comma-separated list of specific tools to run (e.g. `--tools semgrep,gitleaks`). Only these tools will run; all others are skipped. If omitted, uses config `tools` if set, otherwise all available tools run.
- `--refresh` — force re-detection, ignore cache

Config values (`tools`, `scope`) are loaded automatically by scan.sh. CLI args override them.

If scope is not provided via CLI, scan.sh uses the config `scope` value, falling back to `codebase`. Do NOT ask the user for scope — just proceed with the default. If the user passed `--scope unpushed` without a base ref, ask the user: "Compare against which base?" — default branch, remote tracking branch, or custom ref.

### Step 2: Detect Stack & Tools

Unless `--refresh` was passed, try cached results first:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cache-state.sh --read --max-age 86400
```

- **Exit 0** (fresh): Use cached `stack` and `tools`. Tell the user "Using cached detection results" and skip to Step 3.
- **Exit 1 or 2** (missing/stale): Run fresh detection:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/detect-stack.sh .
echo '<stack_json>' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-tools.sh
```

Display a brief summary: languages detected, tools available, tools skipped.

Cache the fresh results:
```bash
echo '<stack_json>' > /tmp/cg-stack.json
echo '<tools_json>' > /tmp/cg-tools.json
bash ${CLAUDE_PLUGIN_ROOT}/scripts/cache-state.sh --write \
  --stack-file /tmp/cg-stack.json --tools-file /tmp/cg-tools.json
```

### Step 3: Run Security Scan

Run the scan in report-only mode. This command never fixes code — it only detects and reports.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/scan.sh \
  --stack-json /tmp/cg-stack.json \
  --tools-json /tmp/cg-tools.json \
  --scope <scope> \
  [--base-ref <ref>] \
  [--tools tool1,tool2,...]
```

Pass `--tools` if the user passed `--tools`.

### Step 3b: AI Security Review

After CLI tools complete, run the AI reviewer to catch business logic vulnerabilities that deterministic tools miss.

1. Set the AI findings output path:
   ```
   AI_FINDINGS="${scanDir}/ai-review-findings.jsonl"
   ```
   (where `scanDir` is the `scanDir` value from the scan.sh JSON output)

2. Invoke the **ai-reviewer** agent with:
   - `scope` — the scan scope (codebase, uncommitted, unpushed)
   - `baseRef` — the base reference (if scope is unpushed)
   - `findingsFile` — path to the merged findings file (`all-findings.jsonl` from scan output)
   - `outputFile` — the `AI_FINDINGS` path above

3. If the AI findings file exists and is non-empty, first validate it:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-findings.sh "$AI_FINDINGS" --strict
   ```
   - If validation fails (exit 1): log a warning ("AI review findings failed schema validation — skipping AI findings") and skip to Step 4. Do NOT merge invalid AI findings into the report.
   - If validation succeeds (exit 0): proceed to merge.

   a. Append AI findings to the merged findings file:
      ```bash
      cat "$AI_FINDINGS" >> "$FINDINGS_FILE"
      ```
   b. Recount severities from the merged file using python3:
      ```bash
      python3 -c "
      import json, sys
      counts = {'high':0,'medium':0,'low':0}
      with open(sys.argv[1]) as f:
          for line in f:
              line = line.strip()
              if not line: continue
              try:
                  sev = json.loads(line).get('severity','').lower()
                  if sev in counts: counts[sev] += 1
              except: pass
      total = sum(counts.values())
      print(json.dumps({'total':total, **counts}))
      " "$FINDINGS_FILE"
      ```
   c. Build an updated summaries JSON array — add an `ai-review` entry with the AI finding counts to the existing summaries array from scan.sh output
   d. Re-run generate-report.sh with `--report-file <existing report path>` and the updated severity counts and summaries to regenerate the report with AI findings included

4. If the AI findings file is empty or does not exist, note: "AI review completed — no additional findings."

### Step 4: Process Results

Read the findings file from the scan output (each line is a JSON finding with: tool, severity, rule, message, file, line, autoFixable, category).

**If no findings**: Report success. Suggest CI scanning if none detected.

**If findings exist**:
1. Present findings grouped by severity (high first), then by category
2. Show a numbered summary table (numbers match the report):
   ```
   | # | Severity | Tool | Rule | File:Line | Auto-fixable |
   ```
3. Save the findings JSONL alongside the report for use by the fix command:
   ```bash
   cp "$FINDINGS_FILE" "${reportFile%.md}.findings.jsonl"
   ```
   (where `reportFile` is the `reportFile` value from the scan.sh JSON output)
4. Proceed to the Final Report (Step 5)

### Step 4b: Write Report Summary

After the report file is generated, use the Edit tool to replace the `<!-- SUMMARY_PLACEHOLDER -->` marker in the report with a short textual summary paragraph (2-4 sentences). The summary should:
- State the overall health of the scan (e.g. "The scan completed cleanly" or "Several security issues were found")
- Highlight the most important findings (e.g. "3 high-severity issues in authentication code require immediate attention")
- Mention auto-fixable count if any (e.g. "5 of these can be auto-fixed")
- Note any scanners that were skipped due to missing tools

This paragraph goes right below the severity count table inside `## Summary`, giving readers a quick at-a-glance understanding before they dive into the details.

### Step 5: Final Report

Always end with these sections:

1. **Findings summary** — counts by severity
2. **Skipped tools** — list any tools that were needed but not installed, with install commands:
   > The following tools were not available and their checks were skipped:
   > - `trivy` — install: `brew install trivy`
   > - `checkov` — install: `pip3 install checkov`
   >
   > Run `/code-guardian:code-guardian-setup` to see all tool status.
3. **CI recommendation** — if no CI security scanning detected, suggest `/code-guardian:code-guardian-ci`
4. **Scan report** — tell the user a detailed report was saved to disk (the path is in the `reportFile` field of the scan output JSON). Each finding is numbered and listed as a `- [ ]` checkbox item. Example: "A detailed report has been saved to `<reportFile>`."
5. **AI review results** — report how many AI review findings were found and which categories they fall into (e.g., "AI review found 3 additional findings: 2 auth-bypass, 1 race-condition"). If no AI findings, note that the AI review completed cleanly.
6. **Fix command** — if there are any findings, end with:
   > To fix findings, run `/code-guardian:code-guardian-fix`. Options:
   > - Fix all: `/code-guardian:code-guardian-fix` (default — fixes everything)
   > - Fix by severity: `/code-guardian:code-guardian-fix --levels high` or `--levels high,medium`
   > - Fix specific issues: `/code-guardian:code-guardian-fix --issues 1,3,5` (use issue numbers from the report)

## Scope & Dependency Scanners

Dependency audit tools (npm-audit, pip-audit, cargo-audit, bundler-audit, govulncheck, osv-scanner) scan lockfiles/manifests that are project-wide — the concept of "only check uncommitted files" doesn't apply to them.

When `--scope` is `uncommitted` or `unpushed`, dependency scanners are **automatically skipped** unless their manifest or lockfile (e.g. `package-lock.json`, `Cargo.lock`, `go.sum`) appears in the changed files. This prevents noisy, irrelevant dependency findings when scanning just your recent work.

When `--scope` is `codebase` (default), all scanners run as normal.

Skipped dependency scanners are reported in the final summary under "Skipped (no manifest in scope)".

## Important Notes

- This command only scans and reports — it never modifies project files
- For secret findings, NEVER display the actual secret value in output
