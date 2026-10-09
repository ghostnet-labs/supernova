#!/usr/bin/env bash
# setup-test: Work overlay hooks
# setup-test-scope: work
# Checks every work overlay hook point against the acme fixture overlay in
# tests/fixtures/overlay, then removes the overlay and checks each hook is a
# silent no-op. Shells run with a sandboxed HOME and local environment file.
set -euo pipefail
exec </dev/null

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_DIR/tests/lib/assert.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/overlay-test.XXXXXX")"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

# The overlay is copied so .env.zsh (gitignored) and compiled .zwc files stay
# out of the repository.
WORK_ROOT="$TMP_ROOT/overlay"
WORK_DIR="$WORK_ROOT/acme"
cp -R "$REPO_DIR/tests/fixtures/overlay" "$WORK_ROOT"
printf '%s\n' 'export ACME_TOKEN="fixture"' >"$WORK_DIR/.env.zsh"
SANDBOX_HOME="$TMP_ROOT/home"
mkdir -p "$SANDBOX_HOME" "$TMP_ROOT/venv/bin"
for name in .zshrc .zprofile .tmux.conf; do
  ln -s "$REPO_DIR/dotfiles/$name" "$SANDBOX_HOME/$name"
done
ENV_FILE="$TMP_ROOT/env.zsh"
write_env() { # write_env WORK_ENV [WORK_ROOT]
  printf '%s\n' "WORK_ENV=$1" 'JOB=acme' "WORK_ROOT=${2:-}" "export SETUP_PYTHON_VENV=$TMP_ROOT/venv" >"$ENV_FILE"
}

# Run zsh in the sandbox with a minimal environment; extra NAME=VALUE pairs
# come before the zsh arguments.
sandbox_zsh() {
  local -a extra=()
  while [[ "${1:-}" == *=* ]]; do extra+=("$1"); shift; done
  env -i HOME="$SANDBOX_HOME" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
    SETUP_LOCAL_ENV_FILE="$ENV_FILE" ${extra[@]+"${extra[@]}"} zsh "$@"
}

interactive_probe='
  print -r -- "path0=${path[1]} ${path[2]} ${path[3]} ${path[4]} ${path[5]}"
  print -r -- "hello=${commands[acme-hello]:-none}"
  print -r -- "alias=${aliases[acme-alias]:-none}"
  print -r -- "acme_fn=$+functions[acme_fn] acme_widget=$+functions[acme_widget]"
  print -r -- "token=${ACME_TOKEN:-none} last=${ACME_ZSHRC_LAST:-none}"
  print -r -- "work_dir=${WORK_DIR:-none} venv=${path[(r)$SETUP_PYTHON_VENV/bin]:-none}"
  print -r -- "toolbox:"; toolbox acme 2>&1 || true
'

# --- Overlay on: every hook loads the acme version ---
write_env true "$WORK_ROOT"
on_output="$(sandbox_zsh -i -c "$interactive_probe" 2>"$TMP_ROOT/on.err")"
assert_contains "$on_output" "path0=$REPO_DIR/dotfiles/.bin $SANDBOX_HOME/.local/bin $TMP_ROOT/venv/bin $WORK_DIR/bin-acme "
assert_contains "$on_output" "hello=$WORK_DIR/bin-acme/acme-hello"
assert_contains "$on_output" "alias=print -r -- acme alias"
assert_contains "$on_output" 'acme_fn=1 acme_widget=1'
assert_contains "$on_output" 'token=fixture last=1'
assert_contains "$on_output" "work_dir=$WORK_DIR venv=$TMP_ROOT/venv/bin"
toolbox_output="${on_output#*toolbox:}"
assert_contains "$toolbox_output" 'acme_fn'
assert_contains "$toolbox_output" 'acme_widget'
assert_contains "$toolbox_output" 'acme-hello'
assert_not_contains "$(cat "$TMP_ROOT/on.err")" 'acme'
assert_not_contains "$on_output" 'Warning'

login_output="$(sandbox_zsh -l -c 'print -r -- "zprofile=${ACME_ZPROFILE:-none}"')"
assert_contains "$login_output" 'zprofile=1'

tmux_option() { # tmux_option WORK_DIR_VALUE OPTION
  local socket="overlay-test-$$-$RANDOM"
  env -i HOME="$SANDBOX_HOME" PATH="/usr/local/bin:/usr/bin:/bin" TERM=xterm WORK_DIR="$1" \
    tmux -L "$socket" -f "$SANDBOX_HOME/.tmux.conf" new-session -d \; show -gqv "$2" \; kill-server 2>&1 || true
}
if command -v tmux >/dev/null 2>&1; then
  assert_equals "$(tmux_option "$WORK_DIR" @acme_overlay)" 'yes'
  assert_equals "$(tmux_option "$WORK_DIR" @setup_dashboard)" 'acme'
else
  printf 'SKIP: tmux overlay hook (tmux not installed)\n'
fi

# fix links dotfiles/git/work.config to the overlay's git/config, and the
# tracked Git config includes it. Use a copy of dotfiles/git, never the checkout.
git_dir="$TMP_ROOT/dotfiles/git"
mkdir -p "$git_dir"
cp "$REPO_DIR/dotfiles/git/config" "$git_dir/config"
/bin/bash -c '
  source "$1/setup/repair.sh"
  DOTFILE_DIR="$2" WORK_DIR="$3" DRY_RUN=false
  link_work_git_config && (( ${#FAILED_TASKS[@]} == 0 ))
' _ "$REPO_DIR" "$TMP_ROOT/dotfiles" "$WORK_DIR" || fail_test 'linking the work Git config failed'
assert_equals "$(readlink "$git_dir/work.config")" "$WORK_DIR/git/config"
assert_equals "$(git config -f "$git_dir/config" --includes --get acme.marker)" 'yes'

# setup.sh: the test plan runs the overlay's tests and Syntax/Help rows, the
# dependency contract adds the overlay's rows, and the health check reads them.
test_plan="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  LOCAL_ENV_FILE="$2"
  run_test_check() { printf "%s|" "$1"; shift; printf "%s " "$@"; printf "\n"; }
  run_repository_tests
' _ "$REPO_DIR/setup.sh" "$ENV_FILE")"
assert_contains "$test_plan" 'Syntax: acme tools and tests|'
assert_contains "$test_plan" "$WORK_DIR/bin-acme/functions-acme.sh"
assert_contains "$test_plan" "Tests: Acme fixture overlay|/bin/bash $WORK_ROOT/tests/acme/test_acme.sh"
assert_contains "$test_plan" "Help: acme-hello|check_help_output env PYTHONDONTWRITEBYTECODE=1 $WORK_DIR/bin-acme/acme-hello"
assert_contains "$test_plan" "Help: acme shell functions|check_function_help $WORK_DIR/bin-acme/functions-acme.sh $WORK_DIR/functions/widgets.zsh"
dependency_rows="$(/bin/bash -c '
  source "$1/setup/dependencies.sh"
  setup_collect_dependencies macos true acme "$2"
  printf "%s\n" "${SETUP_SELECTED_DEPENDENCIES[@]}" "requirements=${SETUP_PYTHON_REQUIREMENTS[*]}"
' _ "$REPO_DIR" "$WORK_ROOT")"
assert_contains "$dependency_rows" 'work:acme|all|external|-|command|acme-external-tool'
assert_contains "$dependency_rows" "requirements=$WORK_DIR/requirements.txt"
check_findings="$(/bin/bash -c '
  SETUP_LOCAL_ENV_FILE="$2" SETUP_SOURCE_ONLY=true
  source "$1"
  setup_state_scan "" "" true || true
  printf "%s\n" "${SETUP_FINDING_MESSAGES[@]}"
' _ "$REPO_DIR/setup.sh" "$ENV_FILE")"
assert_contains "$check_findings" "work overlay checkout: $WORK_ROOT"
assert_contains "$check_findings" 'work environment enabled for JOB=acme'
assert_contains "$check_findings" 'acme-external-tool'
assert_contains "$check_findings" 'work helper file is readable'
assert_contains "$check_findings" "Git does not include the work config: link $REPO_DIR/dotfiles/git/work.config"

apps="$(WORK_ROOT="$WORK_ROOT" JOB=acme "$REPO_DIR/dotfiles/.bin/reinstall-apps" --list)"
assert_contains "$apps" "acme-app	$WORK_DIR/bin-acme/acme-app"
assert_contains "$apps" "awake	$REPO_DIR/dotfiles/.bin/awake"

# --- Overlay off: every hook is a silent no-op ---
write_env false
off_output="$(sandbox_zsh -i -c "$interactive_probe" 2>"$TMP_ROOT/off.err")"
assert_contains "$off_output" 'hello=none'
assert_contains "$off_output" 'alias=none'
assert_contains "$off_output" 'acme_fn=0 acme_widget=0'
assert_contains "$off_output" 'token=none last=none'
assert_contains "$off_output" 'work_dir=none'
assert_not_contains "$off_output" 'Warning'
assert_not_contains "$off_output" "$WORK_DIR"
assert_not_contains "$(cat "$TMP_ROOT/off.err")" 'acme'
assert_contains "$(sandbox_zsh -l -c 'print -r -- "zprofile=${ACME_ZPROFILE:-none}"')" 'zprofile=none'
if command -v tmux >/dev/null 2>&1; then
  assert_equals "$(tmux_option '' @acme_overlay)" ''
  assert_equals "$(tmux_option '' @setup_dashboard)" ''
fi
rm -f "$git_dir/work.config"
assert_equals "$(git config -f "$git_dir/config" --includes --get acme.marker || printf 'unset')" 'unset'
off_plan="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  LOCAL_ENV_FILE="$2"
  run_test_check() { printf "%s|" "$1"; shift; printf "%s " "$@"; printf "\n"; }
  run_repository_tests
' _ "$REPO_DIR/setup.sh" "$ENV_FILE")"
assert_not_contains "$off_plan" 'acme'
apps="$(WORK_ROOT='' JOB='' "$REPO_DIR/dotfiles/.bin/reinstall-apps" --list)"
assert_not_contains "$apps" 'acme'

# A work scope whose overlay checkout is missing warns once and stays personal.
write_env true "$TMP_ROOT/missing"
missing_output="$(sandbox_zsh -i -c "$interactive_probe" 2>&1)"
assert_contains "$missing_output" 'Warning: WORK_ENV=true but the work overlay'
assert_contains "$missing_output" 'acme_fn=0 acme_widget=0'

printf 'PASS: work overlay hooks\n'
