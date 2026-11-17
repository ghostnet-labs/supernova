#!/usr/bin/env bash
# setup-test: Atuin history import
# Isolated checks that fix mode imports ~/.zsh_history into the scope's Atuin history once.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-atuin-history-test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

# A stub atuin that records each import's history file and database.
mkdir -p "$TMP_ROOT/bin"
printf '%s\n' '#!/bin/sh' \
  '[ "$1 $2" = "import zsh" ] || exit 2' \
  '[ -z "$TEST_ATUIN_FAIL" ] || exit 1' \
  'printf "%s %s\n" "$HISTFILE" "$ATUIN_DB_PATH" >>"$TEST_ATUIN_LOG"' >"$TMP_ROOT/bin/atuin"
chmod +x "$TMP_ROOT/bin/atuin"

# run_import HOME DRY_RUN [WORK_ENV JOB]
run_import() {
  HOME="$1" PATH="$TMP_ROOT/bin:$PATH" TEST_ATUIN_LOG="$1/atuin.log" XDG_DATA_HOME="" XDG_CONFIG_HOME="" \
    /bin/bash -c '
      source "$1/setup/repair.sh"
      DRY_RUN="$2"
      WORK_ENV="$3"
      JOB="$4"
      SETUP_REPAIR_COMPACT=false
      FAILED_TASKS=()
      import_atuin_history
    ' _ "$REPO_DIR" "$2" "${3:-false}" "${4:-}"
}

# check_state HOME [WORK_ENV JOB] prints the check's severity.
check_state() {
  HOME="$1" XDG_DATA_HOME="" /bin/bash -c '
    source "$1/setup/state.sh"
    setup_state_reset
    CONFIG_WORK_ENV="$2"
    CONFIG_JOB="$3"
    check_atuin_history
    printf "%s\n" "${SETUP_FINDING_SEVERITIES[0]}"
  ' _ "$REPO_DIR" "${2:-false}" "${3:-}"
}

imports() {
  [[ -e "$1/atuin.log" ]] || { printf '0\n'; return; }
  wc -l <"$1/atuin.log" | tr -d ' '
}

# A personal machine imports its history once, into the personal scope.
home="$TMP_ROOT/personal"
data="$home/.local/share/atuin/scopes/personal"
config="$home/.config/atuin/scopes/personal/config.toml"
mkdir -p "$home"
printf '%s\n' 'git status' 'ls' >"$home/.zsh_history"
assert_equals "$(check_state "$home")" "warning" "pending import is reported"
run_import "$home" true >/dev/null
assert_equals "$(imports "$home")" "0" "dry run imports nothing"
[[ ! -e "$data" ]] || fail_test "dry run created the Atuin folder"
run_import "$home" false >/dev/null
assert_equals "$(cat "$home/atuin.log")" "$home/.zsh_history $data/history.db" "imported into the personal database"
[[ -e "$data/zsh-history-imported" ]] || fail_test "no import marker"
cmp -s "$config" "$REPO_DIR/dotfiles/atuin/config.toml" || fail_test "scope config is not the managed template"
assert_equals "$(check_state "$home")" "pass" "finished import passes"

# Later runs leave Atuin alone, even after its database is cleared.
rm -f -- "$data/history.db"
run_import "$home" false >/dev/null
assert_equals "$(imports "$home")" "1" "second run does not import again"

# A work machine imports into its job's scope.
home="$TMP_ROOT/work"
mkdir -p "$home"
printf '%s\n' 'make' >"$home/.zsh_history"
run_import "$home" false true acme >/dev/null
assert_contains "$(cat "$home/atuin.log")" "/atuin/scopes/work-acme/history.db" "work scope database"
assert_equals "$(check_state "$home" true acme)" "pass" "work import passes"

# No history means nothing to import.
home="$TMP_ROOT/empty"
mkdir -p "$home"
: >"$home/.zsh_history"
run_import "$home" false >/dev/null
assert_equals "$(imports "$home")" "0" "empty history imports nothing"
assert_equals "$(check_state "$home")" "pass" "empty history passes"

# A scope config setup didn't write is left alone and the import fails.
home="$TMP_ROOT/foreign"
mkdir -p "$home/.config/atuin/scopes/personal"
printf '%s\n' 'ls' >"$home/.zsh_history"
printf '%s\n' 'search_mode = "prefix"' >"$home/.config/atuin/scopes/personal/config.toml"
if run_import "$home" false >/dev/null 2>&1; then fail_test "imported with a foreign config"; fi
assert_equals "$(imports "$home")" "0" "foreign config blocks the import"
assert_equals "$(cat "$home/.config/atuin/scopes/personal/config.toml")" 'search_mode = "prefix"' "foreign config kept"

# A failed import leaves no marker, so the next run tries again.
home="$TMP_ROOT/failed"
mkdir -p "$home"
printf '%s\n' 'ls' >"$home/.zsh_history"
if TEST_ATUIN_FAIL=1 run_import "$home" false >/dev/null 2>&1; then fail_test "failed import reported success"; fi
[[ ! -e "$home/.local/share/atuin/scopes/personal/zsh-history-imported" ]] || fail_test "failed import left a marker"

printf 'Atuin history import tests passed\n'
