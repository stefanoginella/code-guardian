#!/usr/bin/env bats
# Tests for scope-related functions: get_scoped_files, write_scope_file

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  cd "$BATS_TEST_TMPDIR"

  # Initialize a git repo with at least one commit
  git init -q .
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > .gitkeep
  git add .gitkeep
  git commit -q -m "init"
}

teardown() {
  teardown_tmpdir
}

# Helper: source common.sh and call get_scoped_files
_scoped_files() {
  local scope="${1:-codebase}"
  local base_ref="${2:-}"
  bash -c "
    set -euo pipefail
    export NO_COLOR=1
    source '${SCRIPTS_DIR}/lib/common.sh'
    get_scoped_files '$scope' '$base_ref'
  "
}

# Helper: source common.sh and call write_scope_file, cat and clean up
_write_scope() {
  local scope="${1:-codebase}"
  local base_ref="${2:-}"
  bash -c "
    set -euo pipefail
    export NO_COLOR=1
    source '${SCRIPTS_DIR}/lib/common.sh'
    f=\$(write_scope_file '$scope' '$base_ref')
    cat \"\$f\"
    rm -f \"\$f\"
  "
}

# ── get_scoped_files ─────────────────────────────────────────────────

@test "get_scoped_files codebase: includes tracked files" {
  echo "tracked content" > tracked.py
  git add tracked.py
  git commit -q -m "add tracked"

  run _scoped_files "codebase"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked.py"* ]]
}

@test "get_scoped_files codebase: includes untracked files" {
  echo "new file" > untracked.py
  # Deliberately NOT git-added

  run _scoped_files "codebase"
  [ "$status" -eq 0 ]
  [[ "$output" == *"untracked.py"* ]]
}

@test "get_scoped_files codebase: deduplicates tracked + untracked" {
  echo "content" > both.py
  git add both.py
  # File is staged (tracked) — should appear only once

  run _scoped_files "codebase"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | grep -c '^both.py$')
  [ "$count" -eq 1 ]
}

@test "get_scoped_files codebase: excludes gitignored files" {
  echo "ignored/" > .gitignore
  git add .gitignore
  git commit -q -m "add gitignore"
  mkdir -p ignored
  echo "secret" > ignored/secret.py

  run _scoped_files "codebase"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignored/secret.py"* ]]
}

@test "get_scoped_files uncommitted: includes staged + unstaged + untracked" {
  # Staged change
  echo "staged" > staged.py
  git add staged.py

  # Unstaged change to a tracked file
  echo "modified" > .gitkeep

  # Untracked new file
  echo "brand new" > untracked.py

  run _scoped_files "uncommitted"
  [ "$status" -eq 0 ]
  [[ "$output" == *"staged.py"* ]]
  [[ "$output" == *".gitkeep"* ]]
  [[ "$output" == *"untracked.py"* ]]
}

# ── write_scope_file ─────────────────────────────────────────────────

@test "write_scope_file codebase: produces non-empty output" {
  echo "hello" > app.py
  git add app.py
  git commit -q -m "add app"

  run _write_scope "codebase"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"app.py"* ]]
}

@test "write_scope_file codebase: filters out excluded dirs" {
  mkdir -p node_modules
  echo "bad" > node_modules/pkg.py
  # node_modules file must be tracked for it to appear in ls-files
  git add -f node_modules/pkg.py
  git commit -q -m "add node_modules file"

  echo "good" > app.py
  git add app.py
  git commit -q -m "add app"

  run _write_scope "codebase"
  [ "$status" -eq 0 ]
  [[ "$output" == *"app.py"* ]]
  [[ "$output" != *"node_modules"* ]]
}

@test "write_scope_file codebase: filters out venv dirs" {
  mkdir -p venv/lib
  echo "pkg" > venv/lib/site.py
  git add -f venv/lib/site.py
  git commit -q -m "add venv file"

  echo "main" > main.py
  git add main.py
  git commit -q -m "add main"

  run _write_scope "codebase"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main.py"* ]]
  [[ "$output" != *"venv/"* ]]
}

@test "write_scope_file codebase: includes untracked files" {
  echo "tracked" > tracked.py
  git add tracked.py
  git commit -q -m "add tracked"

  echo "new" > new_file.py
  # Not added to git

  run _write_scope "codebase"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked.py"* ]]
  [[ "$output" == *"new_file.py"* ]]
}

@test "write_scope_file uncommitted: only includes changed files" {
  echo "old" > existing.py
  git add existing.py
  git commit -q -m "add existing"

  echo "changed" > existing.py
  echo "new" > added.py

  run _write_scope "uncommitted"
  [ "$status" -eq 0 ]
  [[ "$output" == *"existing.py"* ]]
  [[ "$output" == *"added.py"* ]]
}
