---
name: code-guardian-fix
description: Fix security findings from a scan report
argument-hint: "[report-path] [--levels high|medium|low] [--issues 1,3,5] [--dry-run]"
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Agent
---

# Security Fix Command

Fix security findings from a `/code-guardian:code-guardian-scan` report. By default uses the most recent report and fixes **all** findings via the **security-fixer** agent.

## Execution Flow

### Step 1: Parse Arguments

Parse from `$ARGUMENTS`:
- First positional argument (optional) — path to a specific report file (e.g. `.code-guardian/scan-reports/scan-report-20260302_143000.md`). If not provided, uses the most recent report.
- `--levels` — comma-separated severity levels to fix (e.g. `--levels high` or `--levels high,medium`). Only findings matching these severities will be fixed.
- `--issues` — comma-separated issue numbers from the scan report (e.g. `--issues 1,3,5`). Only these specific findings will be fixed.
- `--dry-run` — preview fixes without applying them. The security-fixer agent will describe proposed changes instead of modifying files.

If neither `--levels` nor `--issues` is provided, fix all findings.

`--levels` and `--issues` are mutually exclusive. If both are passed, `--issues` takes precedence.

### Step 2: Find Scan Report

**If a report path was provided**: verify the file exists. If not, tell the user and stop.

**If no path was provided**: find the most recent report:
```bash
ls -t .code-guardian/scan-reports/scan-report-*.md 2>/dev/null | head -1
```

If no report exists, tell the user: "No scan report found. Run `/code-guardian:code-guardian-scan` first." and stop.

Read the report file and its companion findings JSONL:
```bash
REPORT_FILE="<report path>"
FINDINGS_FILE="${REPORT_FILE%.md}.findings.jsonl"
```

If the findings JSONL doesn't exist, tell the user the scan data is missing and they need to re-run `/code-guardian:code-guardian-scan`.

### Step 3: Load & Filter Findings

Read the findings JSONL. Each line is a JSON object with: tool, severity, rule, message, file, line, autoFixable, category.

Assign progressive numbers to findings (same order as the report — grouped by severity: high, medium, low, info):

```bash
python3 -c "
import json, sys
findings = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: findings.append(json.loads(line))
        except: pass

severity_order = {'high':0,'medium':1,'low':2,'info':3}
findings.sort(key=lambda f: severity_order.get(f.get('severity','info').lower(), 3))

for i, f in enumerate(findings, 1):
    f['issueNumber'] = i
    print(json.dumps(f))
" "$FINDINGS_FILE"
```

Apply filters:
- **`--levels`**: Keep only findings whose severity matches one of the given levels
- **`--issues`**: Keep only findings whose issue number matches one of the given numbers
- **Neither**: Keep all findings

If no findings remain after filtering, tell the user: "No findings match the specified filter." and stop.

Display the findings that will be fixed:
```
Fixing N finding(s):
| # | Severity | Tool | Rule | File:Line |
```

### Step 4: Fix Findings

Write the filtered findings to a temporary JSONL file:
```bash
TEMP_FINDINGS=$(mktemp /tmp/cg-fix-findings-XXXXXX.jsonl)
```

Invoke the **security-fixer** agent with:
- The temporary findings file path
- The plugin root path (`${CLAUDE_PLUGIN_ROOT}`) so it can locate scanner scripts for CLI autofix
- The `dryRun` flag (true if `--dry-run` was passed)

The agent will:
1. Run CLI tools with `--autofix` for auto-fixable findings (e.g. `semgrep --autofix`, `eslint --fix`)
2. Apply AI code-level fixes for remaining findings
3. Report which findings were fixed, which were false positives, and which need human review

### Step 5: Update Report

After fixes are applied, update the report file using the Edit tool:

1. For each successfully fixed finding, change its checkbox from `- [ ]` to `- [x]` (match by issue number `**#N**`)
2. Append a `## What Was Fixed` section at the end of the report (before the `---` footer) with:
   - A table of fixed findings: issue number, severity, what was done
   - A list of any findings that could not be fixed, with reasons (false positive, too complex, etc.)

### Step 6: Summary

Present a final summary:

1. **Fixed** — count and list of issue numbers
2. **Skipped** — count and reasons (false positives, too complex, human review needed)
3. **Report updated** — confirm the report file was updated with checkboxes and the fix summary

If some findings remain unfixed, note that the user can re-run `/code-guardian:code-guardian-fix --issues <numbers>` to retry specific ones.

## Important Notes

- Never modify files outside the project directory
- For secret findings, NEVER display the actual secret value in output
- When fixing code, explain what vulnerability you're addressing and why the fix works
- Prefer minimal, targeted fixes over large refactors
- After fixes, verify the code still compiles/passes basic checks
- This command modifies project files — fixes are applied directly to source code
