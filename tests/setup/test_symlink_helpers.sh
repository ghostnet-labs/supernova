#!/usr/bin/env bash
# setup-test: Managed symlinks
# Regression checks for portable, non-destructive managed-link replacement.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-symlink-test.XXXXXX")"
DRY_RUN=false

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

warn() { :; }
pass() { :; }
dry() { :; }
fail() { printf '[FAIL] %s\n' "$1" >&2; }
info() { printf '[INFO] %s\n' "$1"; }

run_spinner() {
  shift
  if "$@" >/dev/null 2>&1; then
    return 0
  else
    return $?
  fi
}

source "$REPO_DIR/setup/symlink_helpers.sh"

assert_symlink_to() {
  local path="$1"
  local expected="$2"

  [[ -L "$path" ]] || fail_test "$path is not a symlink"
  [[ "$(readlink "$path")" == "$expected" ]] ||
    fail_test "$path points to $(readlink "$path"), expected $expected"
}

assert_absent() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] || fail_test "$path unexpectedly exists"
}

new_file_case() {
  local name="$1"

  CASE_ROOT="$TMP_ROOT/$name"
  SRC="$CASE_ROOT/source"
  DEST="$CASE_ROOT/destination"
  BACKUP="$CASE_ROOT/backups/destination.backup"
  mkdir -p "$CASE_ROOT"
  printf 'managed source\n' >"$SRC"
}

new_file_case missing
link_managed_path "missing" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
assert_absent "$BACKUP"

new_file_case correct
ln -s "$SRC" "$DEST"
link_managed_path "correct" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
assert_absent "$BACKUP"

new_file_case real_file
printf 'original file\n' >"$DEST"
link_managed_path "real file" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
[[ "$(<"$BACKUP")" == "original file" ]] || fail_test "real file backup changed"

CASE_ROOT="$TMP_ROOT/real_directory"
SRC="$CASE_ROOT/source"
DEST="$CASE_ROOT/destination"
BACKUP="$CASE_ROOT/backups/destination.backup"
mkdir -p "$SRC" "$DEST"
printf 'original directory\n' >"$DEST/marker"
link_managed_path "real directory" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
[[ "$(<"$BACKUP/marker")" == "original directory" ]] ||
  fail_test "real directory backup changed"

new_file_case wrong_file_link
printf 'referent\n' >"$CASE_ROOT/referent"
ln -s "$CASE_ROOT/referent" "$DEST"
link_managed_path "wrong file link" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
assert_symlink_to "$BACKUP" "$CASE_ROOT/referent"
[[ "$(<"$CASE_ROOT/referent")" == "referent" ]] || fail_test "file referent changed"

new_file_case broken_link
ln -s "$CASE_ROOT/missing-referent" "$DEST"
link_managed_path "broken link" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
assert_symlink_to "$BACKUP" "$CASE_ROOT/missing-referent"

CASE_ROOT="$TMP_ROOT/directory_link"
SRC="$CASE_ROOT/nvim"
DEST="$CASE_ROOT/home/nvim"
BACKUP="$CASE_ROOT/backups/nvim.backup"
REFERENT="$CASE_ROOT/previous-config"
mkdir -p "$SRC" "$(dirname "$DEST")" "$REFERENT"
printf 'keep me\n' >"$REFERENT/marker"
ln -s "$REFERENT" "$DEST"
link_managed_path "directory link" "$SRC" "$DEST" "$BACKUP"
assert_symlink_to "$DEST" "$SRC"
assert_symlink_to "$BACKUP" "$REFERENT"
[[ "$(<"$REFERENT/marker")" == "keep me" ]] || fail_test "directory referent changed"
assert_absent "$REFERENT/nvim"

new_file_case dry_run
printf 'leave unchanged\n' >"$DEST"
DRY_RUN=true
link_managed_path "dry run" "$SRC" "$DEST" "$BACKUP"
DRY_RUN=false
[[ ! -L "$DEST" && "$(<"$DEST")" == "leave unchanged" ]] ||
  fail_test "dry run changed destination"
assert_absent "$BACKUP"

printf '[PASS] managed symlink regression checks\n'
