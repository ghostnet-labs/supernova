#!/usr/bin/env zsh
# setup-test: .zshrc reload
# setup-test-scope: work
# Covers source_zsh reloading .zshrc in work mode without duplicating PATH entries.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
original_path=("${path[@]}")
for functions_file in "$repo_dir"/dotfiles/functions/*.zsh; do source "$functions_file"; done

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")" || exit 1
# Helpers print resolved paths; macOS TMPDIR is a symlink with a trailing slash.
tmp_root="${tmp_root:A}"
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

assert_path_entry_count() {
  local target="$1"
  local expected_count="$2"
  local entry
  local count=0

  for entry in "${path[@]}"; do
    [[ "$entry" == "$target" ]] && ((count++))
  done
  [[ "$count" == "$expected_count" ]] || fail_test "$target appeared $count time(s), expected $expected_count"
}

SETUP_DIR="$repo_dir"
DOTFILE_DIR="$repo_dir/dotfiles"
WORK_ENV=true
JOB=acme
WORK_DIR="$tmp_root/overlay/$JOB"
work_bin="$WORK_DIR/bin-$JOB"
SETUP_PYTHON_VENV="$SETUP_DIR/.local/${JOB}-venv"
python_venv_bin="$SETUP_PYTHON_VENV/bin"
stale_work_path="$work_bin/wtf"
preserved_path="/codex/bootstrap/bin"
reload_home="$tmp_root/reload-home"
mkdir -p "$reload_home"
mkdir -p "$work_bin"
print -r -- '# Fixture work helpers.' >"$work_bin/functions-$JOB.sh"
print -rl -- \
  'typeset -gU path PATH' \
  'path=("$WORK_DIR/bin-$JOB" "$DOTFILE_DIR/.bin" "$HOME/.local/bin" "$SETUP_PYTHON_VENV/bin" "${path[@]}")' \
  'for functions_file in "$DOTFILE_DIR"/functions/*.zsh; do source "$functions_file"; done' \
  'source "$WORK_DIR/bin-$JOB/functions-$JOB.sh"' \
  >"$reload_home/.zshrc"
HOME="$reload_home"
path=("${original_path[@]}" "$DOTFILE_DIR/.bin" "$stale_work_path" "$work_bin" "$python_venv_bin" "$preserved_path" "$DOTFILE_DIR/.bin" "$stale_work_path" "$work_bin" "$python_venv_bin")

source_zsh
assert_path_entry_count "$stale_work_path" 0
assert_path_entry_count "$DOTFILE_DIR/.bin" 1
assert_path_entry_count "$work_bin" 1
assert_path_entry_count "$python_venv_bin" 1
assert_path_entry_count "$preserved_path" 1
normalized_path="${(pj:\n:)path}"
source_zsh
[[ "${(pj:\n:)path}" == "$normalized_path" ]] || fail_test "reloading .zshrc changed the normalized PATH"
grep -Fq 'typeset -gU path PATH' "$repo_dir/dotfiles/.zshrc" || fail_test ".zshrc does not keep PATH unique"
if grep -Fq '_normalize_setup_path' "$repo_dir/dotfiles/.zshrc"; then
  fail_test ".zshrc still relies on post-startup PATH normalization"
fi

print -r -- "PASS: .zshrc reload checks"
