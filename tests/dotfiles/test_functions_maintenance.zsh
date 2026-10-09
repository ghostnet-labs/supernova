#!/usr/bin/env zsh
# setup-test: newdev
# Covers newdev logging and summaries in dotfiles/functions/maintenance.zsh.
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

mkdir -p "$tmp_root/dev/good/.git" "$tmp_root/dev/dirty/.git"
HOME="$tmp_root"
export XDG_CONFIG_HOME="$tmp_root/config" XDG_DATA_HOME="$tmp_root/data"
unset ATUIN_DB_PATH
WORK_ENV=false JOB=''
test_mode="failure"

git() {
  if [[ "$*" == *"$HOME/dev/dirty"* && "$*" == *"status --porcelain"* ]]; then
    print -r -- " M changed-file"
    return 0
  fi

  case "$*" in
    *"status --porcelain"*|*"symbolic-ref"*|*"rev-parse"*) return 0 ;;
  esac
  return 0
}

run_spinner() {
  local label="$1"

  print -r -- "[RUNNING] $label"
  if [[ "$test_mode" == failure && "$label" == "brew upgrade --cask" ]]; then
    run_spinner_status=1
    run_spinner_output="Error: simulated cask failure"
  elif [[ "$label" == "dev/good" ]]; then
    run_spinner_status=0
    run_spinner_output="Already up to date."
  else
    run_spinner_status=0
    run_spinner_output="Completed successfully."
  fi
}

failure_status=0
failure_output="$(newdev --verbose)" || failure_status=$?
[[ "$failure_status" == 1 ]] || fail_test "failure scenario returned $failure_status"
assert_contains "$failure_output" "[FAIL] brew upgrade --cask — simulated cask failure"
assert_contains "$failure_output" "[SKIP] dev/good — Already up to date."
assert_contains "$failure_output" "[SKIP] dev/dirty — tracked local changes"
assert_contains "$failure_output" $'\n\n[SUMMARY] 1 failure(s)\n'
summary_output="${failure_output#*$'\n\n[SUMMARY]'}"
assert_contains "$summary_output" "[FAIL] Homebrew — brew upgrade --cask"
assert_not_contains "$summary_output" "dev/good"
assert_not_contains "$summary_output" "dev/dirty"

test_mode="success"
skip_status=0
skip_output="$(newdev)" || skip_status=$?
[[ "$skip_status" == 0 ]] || fail_test "skip-only scenario returned $skip_status"
assert_contains "$skip_output" "[SKIP] dev/good — Already up to date."
assert_contains "$skip_output" "[SKIP] dev/dirty — tracked local changes"
assert_not_contains "$skip_output" "[SUMMARY]"
assert_contains "$skip_output" "[COMPLETE] All the things updated"

SETUP_DIR="$tmp_root/setup"
homebrew_update() { print -r -- homebrew >>"$tmp_root/update-order"; }
pull_repos() { print -r -- repos >>"$tmp_root/update-order"; }
# Direct history search must not create a separate review queue on updates.
mkdir -p "$SETUP_DIR/dotfiles/lib"
printf '%s\n' 'raise RuntimeError("newdev must not collect review candidates")' \
  >"$SETUP_DIR/dotfiles/lib/toolbox_catalog.py"
WORK_ENV=true JOB=fixture
typeset +x WORK_ENV JOB SETUP_DIR
: >"$tmp_root/update-order"
update_output="$(newdev)" || fail_test "direct-history update failed newdev"
assert_equals "$(command cat -- "$tmp_root/update-order")" $'homebrew\nrepos'
assert_not_contains "$update_output" "review"

print -r -- "PASS: newdev checks"
