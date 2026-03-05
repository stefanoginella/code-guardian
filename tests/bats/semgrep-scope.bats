#!/usr/bin/env bats
# Tests for semgrep.sh scope handling (large file count guard)

setup() {
  load '../helpers/test-helpers'
  setup_tmpdir
  cd "$BATS_TEST_TMPDIR"
  git init -q .
  mkdir -p .claude
}

teardown() {
  teardown_tmpdir
}

# Helper: build semgrep args and print them (without actually running semgrep)
# We override cmd_exists to prevent semgrep from actually running, then inspect
# the constructed SEMGREP_ARGS array.
_get_semgrep_args() {
  local scope_file="$1"
  bash -c "
    set -euo pipefail
    export NO_COLOR=1
    export SCAN_OUTPUT_DIR='$BATS_TEST_TMPDIR'

    source '${SCRIPTS_DIR}/lib/common.sh'

    # Build args exactly as semgrep.sh does, but just print them
    SEMGREP_ARGS=('--config' 'auto' '--json' '--quiet')

    for edir in \"\${CG_EXCLUDE_DIRS[@]}\"; do
      SEMGREP_ARGS+=('--exclude' \"\$edir\")
    done

    SCOPE_FILE='$scope_file'
    if [[ -n \"\$SCOPE_FILE\" ]] && [[ -f \"\$SCOPE_FILE\" ]] && [[ -s \"\$SCOPE_FILE\" ]]; then
      _scope_count=\$(wc -l <\"\$SCOPE_FILE\" | tr -d ' ')
      if [[ \"\$_scope_count\" -le 500 ]]; then
        while IFS= read -r f; do
          [[ -n \"\$f\" ]] && SEMGREP_ARGS+=('--include' \"\$f\")
        done <\"\$SCOPE_FILE\"
      fi
    fi

    printf '%s\n' \"\${SEMGREP_ARGS[@]}\"
  "
}

@test "semgrep scope: adds --include for small scope file" {
  # Create a scope file with 3 files
  printf 'src/app.py\nsrc/util.py\nlib/core.py\n' > "$BATS_TEST_TMPDIR/scope.txt"

  run _get_semgrep_args "$BATS_TEST_TMPDIR/scope.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--include"* ]]
  [[ "$output" == *"src/app.py"* ]]
  [[ "$output" == *"src/util.py"* ]]
  [[ "$output" == *"lib/core.py"* ]]
}

@test "semgrep scope: skips --include for large scope file (>500 files)" {
  # Generate a scope file with 600 entries
  local scope_file="$BATS_TEST_TMPDIR/large-scope.txt"
  for i in $(seq 1 600); do
    echo "src/file_${i}.py"
  done > "$scope_file"

  run _get_semgrep_args "$scope_file"
  [ "$status" -eq 0 ]
  # Should NOT contain --include args
  [[ "$output" != *"--include"* ]]
  # Should still have --exclude args
  [[ "$output" == *"--exclude"* ]]
}

@test "semgrep scope: boundary — 500 files uses --include" {
  local scope_file="$BATS_TEST_TMPDIR/boundary-scope.txt"
  for i in $(seq 1 500); do
    echo "src/file_${i}.py"
  done > "$scope_file"

  run _get_semgrep_args "$scope_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--include"* ]]
}

@test "semgrep scope: boundary — 501 files skips --include" {
  local scope_file="$BATS_TEST_TMPDIR/boundary-scope.txt"
  for i in $(seq 1 501); do
    echo "src/file_${i}.py"
  done > "$scope_file"

  run _get_semgrep_args "$scope_file"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--include"* ]]
}

@test "semgrep scope: empty scope file adds no --include" {
  touch "$BATS_TEST_TMPDIR/empty-scope.txt"

  run _get_semgrep_args "$BATS_TEST_TMPDIR/empty-scope.txt"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--include"* ]]
}
