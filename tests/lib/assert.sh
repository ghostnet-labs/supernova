#!/usr/bin/env bash
# Shared assertions for tests/*/test_* files. Both Bash and Zsh tests source
# this file, so keep it to syntax the two shells share.

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail_test "missing: $2"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail_test "unexpected: $2"
}

assert_equals() {
  [[ "$1" == "$2" ]] || fail_test "expected '$2', got '$1'"
}
