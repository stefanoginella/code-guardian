#!/usr/bin/env bats
# Tests for scripts/detect-stack.sh

setup() {
  load '../helpers/test-helpers'
}

teardown() {
  teardown_tmpdir
}

@test "detect-stack: JS + npm project" {
  use_fixture js-npm
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "javascript"
  assert_json_array_contains ".packageManagers" "npm"
  assert_json_array_contains ".frameworks" "express"
}

@test "detect-stack: TypeScript project" {
  use_fixture js-ts
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "typescript"
  assert_json_array_contains ".languages" "javascript"
  assert_json_array_contains ".frameworks" "react"
}

@test "detect-stack: Python + pip project" {
  use_fixture python-pip
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "python"
  assert_json_array_contains ".packageManagers" "pip"
  assert_json_array_contains ".frameworks" "flask"
}

@test "detect-stack: Go project" {
  use_fixture go
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "go"
  assert_json_array_contains ".packageManagers" "go-modules"
}

@test "detect-stack: Rust project" {
  use_fixture rust
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "rust"
  assert_json_array_contains ".packageManagers" "cargo"
}

@test "detect-stack: Ruby + Rails project" {
  use_fixture ruby-rails
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "ruby"
  assert_json_array_contains ".packageManagers" "bundler"
  assert_json_array_contains ".frameworks" "rails"
}

@test "detect-stack: PHP project" {
  use_fixture php
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "php"
  assert_json_array_contains ".packageManagers" "composer"
}

@test "detect-stack: Docker project" {
  use_fixture docker
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_bool ".docker" "true"
  assert_json_bool ".dockerCompose" "true"
}

@test "detect-stack: Terraform IaC" {
  use_fixture iac-terraform
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".iacTools" "terraform"
}

@test "detect-stack: multi-stack detects all stacks" {
  use_fixture multi-stack
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "javascript"
  assert_json_array_contains ".languages" "python"
  assert_json_bool ".docker" "true"
  assert_json_array_contains ".ciSystems" "github-actions"
  assert_json_array_contains ".frameworks" "express"
  assert_json_array_contains ".frameworks" "flask"
}

@test "detect-stack: Swift project" {
  use_fixture swift
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "swift"
}

@test "detect-stack: C++ project" {
  use_fixture cpp
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "cpp"
  assert_json_array_contains ".packageManagers" "cmake"
}

@test "detect-stack: Elixir + Phoenix project" {
  use_fixture elixir
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "elixir"
  assert_json_array_contains ".packageManagers" "hex"
  assert_json_array_contains ".frameworks" "phoenix"
}

@test "detect-stack: Scala project" {
  use_fixture scala
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "scala"
  assert_json_array_contains ".packageManagers" "sbt"
}

@test "detect-stack: Dart/Flutter project" {
  use_fixture dart
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_array_contains ".languages" "dart"
  assert_json_array_contains ".packageManagers" "pub"
  assert_json_array_contains ".frameworks" "flutter"
}

@test "detect-stack: empty project" {
  use_fixture empty
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  assert_valid_json
  assert_json_key ".languages" "[]"
  assert_json_key ".frameworks" "[]"
  assert_json_bool ".docker" "false"
}

@test "detect-stack: output is valid JSON" {
  use_fixture js-npm
  run bash "$SCRIPTS_DIR/detect-stack.sh" .
  [ "$status" -eq 0 ]
  # Verify python3 can parse the output
  python3 -c "import json, sys; d = json.loads(sys.stdin.read()); assert isinstance(d, dict)" <<<"$output"
}
