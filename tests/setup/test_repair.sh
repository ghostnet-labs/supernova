#!/usr/bin/env bash
# setup-test: Repair module
# setup-test-scope: work
# Regression checks for the internal repair module; no live repairs.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
REPAIR="$REPO_DIR/setup/repair.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-repair-test.XXXXXX")"

cleanup_test() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_test EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

assert_in_order() {
  [[ "$1" == *"$2"*"$3"* ]] || fail_test "expected '$2' before '$3'"
}

# Internal modules do not parse arguments or produce standalone reports.
direct_output="$(/bin/bash "$REPAIR" --help --dependencies-only --upgrade)"
[[ -z "$direct_output" ]] || fail_test "repair module produced standalone output"
if grep -Eq -- '--dependencies-only|--upgrade|show_help\(\)|parse_args\(\)' "$REPAIR"; then
  fail_test "obsolete repair CLI remains in the module"
fi

dispatch_output="$(HOME="$TMP_ROOT" SETUP_LOCAL_ENV_FILE="$TMP_ROOT/env.zsh" /bin/bash -c '
  source "$1"
  detect_platform() { PLATFORM=ubuntu; }
  initialize_configuration() { :; }
  validate_repo_sources() { :; }
  acquire_install_lock() { :; }
  cleanup() { trap - EXIT INT TERM; }
  setup_status_start() { :; }
  verify_dependencies() { printf "verify\n"; }
  install_zj_radar() { printf "radar\n"; }
  prepare_codex_yq() { printf "yq\n"; }
  sync_codex_config() { printf "codex\n"; }
  create_work_dir() { printf "work\n"; }
  ensure_managed_path_dirs() { printf "paths\n"; }
  write_local_env_config() { printf "metadata\n"; }
  symlink_setup() { printf "home-links\n"; }
  install_configs() { printf "config-links\n"; }
  configure_git_hooks() { printf "hooks\n"; }
  configure_zsh_shell() { printf "shell\n"; }
  install_fzf_tab() { printf "fzf\n"; }
  install_apps() { printf "apps\n"; }
  install_fonts_linux() { printf "fonts\n"; }
  setup_repair_apply true acme radar codex metadata links hooks work paths shell fzf platform
' _ "$REPAIR")"
assert_in_order "$dispatch_output" verify radar
assert_in_order "$dispatch_output" radar yq
assert_in_order "$dispatch_output" yq codex
assert_in_order "$dispatch_output" codex work
assert_in_order "$dispatch_output" work paths
assert_in_order "$dispatch_output" paths metadata
assert_in_order "$dispatch_output" metadata home-links
assert_in_order "$dispatch_output" home-links config-links
assert_in_order "$dispatch_output" config-links hooks
assert_in_order "$dispatch_output" hooks shell
assert_in_order "$dispatch_output" shell fzf
assert_in_order "$dispatch_output" fzf apps
assert_in_order "$dispatch_output" apps fonts

# The hooks repair sets core.hooksPath in the checkout, previews in dry-run
# mode, and is a no-op once configured.
hooks_repo="$TMP_ROOT/hooks-repo"
mkdir -p "$hooks_repo/setup"
cp "$REPO_DIR"/setup/*.sh "$hooks_repo/setup/"
git -C "$hooks_repo" init -q
hooks_output="$(/bin/bash -c '
  source "$1"
  SETUP_REPAIR_COMPACT=false
  DRY_RUN=true
  configure_git_hooks
  DRY_RUN=false
  configure_git_hooks
  configure_git_hooks
' _ "$hooks_repo/setup/repair.sh" 2>&1)" || fail_test "Git hooks repair failed: $hooks_output"
[[ "$(git -C "$hooks_repo" config --local --get core.hooksPath)" == .githooks ]] ||
  fail_test "Git hooks repair did not set core.hooksPath"
assert_contains "$hooks_output" "Would: Set core.hooksPath to .githooks"
assert_contains "$hooks_output" "Git hooks already use .githooks"

# A missing ~/.gitconfig is created; an existing one is left untouched.
gitconfig_home="$TMP_ROOT/gitconfig-home"
mkdir -p "$gitconfig_home"
HOME="$gitconfig_home" /bin/bash -c 'source "$1"; ensure_local_gitconfig' _ "$REPAIR" >/dev/null 2>&1 ||
  fail_test "ensure_local_gitconfig failed"
[[ -f "$gitconfig_home/.gitconfig" ]] || fail_test "ensure_local_gitconfig did not create ~/.gitconfig"
printf '[user]\n\tname = kept\n' >"$gitconfig_home/.gitconfig"
HOME="$gitconfig_home" /bin/bash -c 'source "$1"; ensure_local_gitconfig' _ "$REPAIR" >/dev/null 2>&1 ||
  fail_test "ensure_local_gitconfig failed on an existing file"
[[ "$(<"$gitconfig_home/.gitconfig")" == *"name = kept"* ]] || fail_test "ensure_local_gitconfig replaced ~/.gitconfig"

dependency_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  detect_platform() { PLATFORM=ubuntu; }
  initialize_configuration() { :; }
  validate_repo_sources() { :; }
  acquire_install_lock() { :; }
  cleanup() { trap - EXIT INT TERM; }
  setup_status_start() { :; }
  run_dependency_stages() { printf "provision\nverify\n"; }
  verify_dependencies() { printf "unexpected standalone verification\n"; return 1; }
  setup_repair_apply false "" dependencies
' _ "$REPAIR")"
assert_contains "$dependency_output" $'provision\nverify'
assert_not_contains "$dependency_output" "unexpected standalone verification"

macos_shells="$TMP_ROOT/macos-shells"
printf '/bin/zsh\n' >"$macos_shells"
macos_shell_output="$(HOME="$TMP_ROOT" SETUP_SHELLS_FILE="$macos_shells" \
  SETUP_ACCOUNT_SHELL_OVERRIDE=/bin/zsh /bin/bash -c '
  source "$1"
  PLATFORM=macos
  DRY_RUN=false
  activate_brew() { printf "unexpected brew activation\n"; return 1; }
  run_sudo_spinner() { printf "unexpected sudo\n"; return 1; }
  header() { :; }
  info() { printf "info: %s\n" "$1"; }
  configure_zsh_shell
' _ "$REPAIR")"
assert_contains "$macos_shell_output" "info: zsh is already the default shell"
assert_not_contains "$macos_shell_output" "unexpected brew activation"
assert_not_contains "$macos_shell_output" "unexpected sudo"

macos_chsh_output="$(HOME="$TMP_ROOT" SETUP_SHELLS_FILE="$macos_shells" \
  SETUP_ACCOUNT_SHELL_OVERRIDE=/opt/homebrew/bin/zsh /bin/bash -c '
  source "$1"
  PLATFORM=macos
  DRY_RUN=false
  setup_status_action() { printf "action: %s\n" "$1"; }
  chsh() { printf "foreground chsh: %s\n" "$*"; }
  header() { :; }
  pass() { printf "pass: %s\n" "$1"; }
  fail() { printf "failure: %s\n" "$1"; FAILED_TASKS+=("$1"); }
  configure_zsh_shell
' _ "$REPAIR")"
assert_contains "$macos_chsh_output" "action: Change default shell to /bin/zsh"
assert_contains "$macos_chsh_output" "typed characters will not be displayed"
assert_contains "$macos_chsh_output" "foreground chsh: -s /bin/zsh"

linuxbrew_prefix="$TMP_ROOT/linuxbrew"
linux_shells="$TMP_ROOT/linux-shells"
mkdir -p "$linuxbrew_prefix/bin"
printf '#!/bin/sh\nexit 0\n' >"$linuxbrew_prefix/bin/zsh"
chmod +x "$linuxbrew_prefix/bin/zsh"
: >"$linux_shells"
linux_shell_output="$(HOME="$TMP_ROOT" TEST_BREW_PREFIX="$linuxbrew_prefix" \
  SETUP_SHELLS_FILE="$linux_shells" SETUP_ACCOUNT_SHELL_OVERRIDE="$linuxbrew_prefix/bin/zsh" /bin/bash -c '
  source "$1"
  PLATFORM=ubuntu
  DRY_RUN=false
  activate_brew() { BREW_BIN=brew_fixture; }
  brew_fixture() { [[ "$1" == --prefix ]] && printf "%s\n" "$TEST_BREW_PREFIX"; }
  run_sudo_spinner() { printf "sudo: %s\n" "$1"; }
  header() { :; }
  info() { printf "info: %s\n" "$1"; }
  pass() { printf "pass: %s\n" "$1"; }
  fail() { printf "failure: %s\n" "$1"; FAILED_TASKS+=("$1"); }
  configure_zsh_shell
' _ "$REPAIR")"
assert_contains "$linux_shell_output" "sudo: Adding $linuxbrew_prefix/bin/zsh to allowed shells"
assert_contains "$linux_shell_output" "pass: Shell added to $linux_shells"
assert_contains "$linux_shell_output" "info: zsh is already the default shell"

yq_upgrade_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  SETUP_CODEX_CONFIG_SOURCE=dotfiles/codex/config.toml
  SETUP_DIR=/managed/setup
  BREW_BIN=/managed/brew
  activate_brew() { :; }
  setup_reset_dependency_cache() { :; }
  setup_brew_package_installed() { [[ "$1" == yq ]]; }
  run_spinner() { shift; printf "command: %s\n" "$*"; }
  setup_codex_yq_supports_managed_toml() { printf "capability: %s\n" "$1"; }
  header() { :; }
  pass() { printf "pass: %s\n" "$1"; }
  warn() { printf "warning: %s\n" "$1"; }
  fail() { printf "failure: %s\n" "$1"; return 1; }
  prepare_codex_yq
' _ "$REPAIR")"
assert_contains "$yq_upgrade_output" "command: /managed/brew upgrade yq"
assert_contains "$yq_upgrade_output" "capability: /managed/setup/dotfiles/codex/config.toml"
assert_contains "$yq_upgrade_output" "pass: yq is ready for managed Codex TOML"
assert_not_contains "$yq_upgrade_output" "brew upgrade --"

yq_install_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  SETUP_CODEX_CONFIG_SOURCE=dotfiles/codex/config.toml
  SETUP_DIR=/managed/setup
  BREW_BIN=/managed/brew
  activate_brew() { :; }
  setup_reset_dependency_cache() { :; }
  setup_brew_package_installed() { return 1; }
  run_spinner() { shift; printf "command: %s\n" "$*"; }
  setup_codex_yq_supports_managed_toml() { :; }
  header() { :; }
  pass() { :; }
  warn() { :; }
  fail() { return 1; }
  prepare_codex_yq
' _ "$REPAIR")"
assert_contains "$yq_install_output" "command: /managed/brew install yq"

yq_offline_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  SETUP_CODEX_CONFIG_SOURCE=dotfiles/codex/config.toml
  SETUP_DIR=/managed/setup
  BREW_BIN=/managed/brew
  activate_brew() { :; }
  setup_reset_dependency_cache() { :; }
  setup_brew_package_installed() { :; }
  run_spinner() { return 1; }
  setup_codex_yq_supports_managed_toml() { :; }
  header() { :; }
  pass() { :; }
  warn() { printf "warning: %s\n" "$1"; }
  fail() { printf "failure: %s\n" "$1"; return 1; }
  prepare_codex_yq
' _ "$REPAIR")"
assert_contains "$yq_offline_output" "Homebrew could not upgrade yq"
assert_contains "$yq_offline_output" "active yq passed the managed Codex TOML check"
assert_not_contains "$yq_offline_output" "failure:"

rectangle_app="$TMP_ROOT/Rectangle.app"
mkdir -p "$rectangle_app"

run_rectangle_install() {
  TEST_RECTANGLE_BUNDLE_ID="$1" SETUP_RECTANGLE_APP_PATH="$rectangle_app" HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  PLATFORM=macos
  BREW_BIN=brew_fixture
  SETUP_PLUTIL_BIN=plutil_fixture
  SETUP_MACOS_APPS=(rectangle)
  brew_fixture() { [[ "$1 $2" == "list --cask" ]]; }
  plutil_fixture() { printf "%s\n" "$TEST_RECTANGLE_BUNDLE_ID"; }
  run_spinner() { shift; printf "command:"; printf " %s" "$@"; printf "\n"; }
  header() { :; }
  info() { :; }
  pass() { printf "pass: %s\n" "$1"; }
  warn() { :; }
  fail() { printf "failure: %s\n" "$1"; FAILED_TASKS+=("$1"); }
  install_apps
' _ "$REPAIR"
}

rectangle_takeover_output="$(run_rectangle_install com.knollsoft.Rectangle)"
assert_contains "$rectangle_takeover_output" "command: brew_fixture install --cask --force rectangle"
assert_contains "$rectangle_takeover_output" "pass: rectangle replaced with the Homebrew-managed app"

rectangle_refusal_status=0
rectangle_refusal_output="$(run_rectangle_install com.example.Impostor)" || rectangle_refusal_status=$?
[[ "$rectangle_refusal_status" -eq 1 ]] || fail_test "unexpected Rectangle identity returned $rectangle_refusal_status"
assert_contains "$rectangle_refusal_output" "not the expected Rectangle app (bundle com.example.Impostor)"
assert_contains "$rectangle_refusal_output" "refusing to overwrite it"
assert_not_contains "$rectangle_refusal_output" "install --cask --force rectangle"

warning_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  SETUP_SELECTED_DEPENDENCIES=("base|all|brew|jq|command|jq")
  activate_brew() { :; }
  setup_status_start() { :; }
  setup_check_dependency() {
    SETUP_DEPENDENCY_SEVERITY=warning
    SETUP_DEPENDENCY_FAILURE="command jq resolves outside Homebrew"
    return 1
  }
  warn() { printf "warning: %s\n" "$1"; }
  verify_dependencies
  [[ ${#FAILED_TASKS[@]} -eq 0 ]]
' _ "$REPAIR")"
assert_contains "$warning_output" "warning: command jq resolves outside Homebrew"

template_work="$TMP_ROOT/template-work"
mkdir -p "$template_work/bin-template"
printf 'export TOKEN=""\n' >"$template_work/env.zsh.example"
template_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  WORK_ENV=true
  JOB=template
  WORK_DIR="$2"
  WORK_BIN="$2/bin-template"
  DRY_RUN=false
  header() { :; }
  info() { :; }
  pass() { :; }
  fail() { printf "FAIL:%s\\n" "$1"; return 1; }
  create_work_dir
' _ "$REPAIR" "$template_work")"
[[ -z "$template_output" ]] || fail_test "template work scaffolding failed: $template_output"
cmp "$template_work/env.zsh.example" "$template_work/.env.zsh" >/dev/null || fail_test "work environment template was not copied"
[[ "$(file_mode "$template_work/.env.zsh")" == 600 ]] || fail_test "work environment file mode is not 600"
printf 'preserve me\n' >"$template_work/.env.zsh"
HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  WORK_ENV=true; JOB=template; WORK_DIR="$2"; WORK_BIN="$2/bin-template"; DRY_RUN=false
  header() { :; }; info() { :; }; pass() { :; }; fail() { return 1; }
  create_work_dir
' _ "$REPAIR" "$template_work"
[[ "$(cat "$template_work/.env.zsh")" == "preserve me" ]] || fail_test "existing work environment file was replaced"

custom_work="$TMP_ROOT/custom-work"
mkdir -p "$custom_work/bin-custom"
HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  WORK_ENV=true; JOB=custom; WORK_DIR="$2"; WORK_BIN="$2/bin-custom"; DRY_RUN=false
  header() { :; }; info() { :; }; pass() { :; }; fail() { return 1; }
  create_work_dir
' _ "$REPAIR" "$custom_work"
[[ -f "$custom_work/.env.zsh" && ! -s "$custom_work/.env.zsh" ]] || fail_test "custom work environment file is not empty"
[[ "$(file_mode "$custom_work/.env.zsh")" == 600 ]] || fail_test "custom work environment file mode is not 600"

guard_status=0
guard_output="$(HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  detect_platform() { PLATFORM=ubuntu; }
  initialize_configuration() { :; }
  validate_repo_sources() { :; }
  acquire_install_lock() { :; }
  cleanup() { trap - EXIT INT TERM; }
  setup_status_start() { :; }
  verify_dependencies() { printf "guard\n"; FAILED_TASKS+=("missing dependency"); return 1; }
  write_local_env_config() { printf "mutation\n"; }
  setup_repair_apply false "" metadata
' _ "$REPAIR" 2>&1)" || guard_status=$?
[[ "$guard_status" -eq 1 ]] || fail_test "failed dependency guard returned $guard_status"
assert_contains "$guard_output" guard
assert_not_contains "$guard_output" mutation

radar_fixture="$TMP_ROOT/zj-radar-fixture"
radar_archive="$TMP_ROOT/zj-radar-fixture.tar.gz"
mkdir -p "$radar_fixture"
printf '#!/bin/sh\nprintf "zj-radar 0.4.1\\n"\n' >"$radar_fixture/zj-radar"
chmod +x "$radar_fixture/zj-radar"
tar -czf "$radar_archive" -C "$radar_fixture" zj-radar
radar_home="$TMP_ROOT/radar-home"
TEST_ZJ_ARCHIVE="$radar_archive" HOME="$radar_home" /bin/bash -c '
  source "$1"
  PLATFORM=ubuntu
  DRY_RUN=false
  SETUP_REPAIR_COMPACT=false
  FAILED_TASKS=()
  setup_zj_radar_target() { printf "x86_64-unknown-linux-musl\n"; }
  setup_zj_radar_archive_sha256() { setup_file_sha256 "$TEST_ZJ_ARCHIVE"; }
  setup_status_start() { :; }
  header() { :; }
  info() { :; }
  pass() { :; }
  fail() { printf "failure: %s\n" "$1" >&2; }
  run_spinner() { shift; "$@"; }
  curl() {
    local previous=""
    local argument
    for argument in "$@"; do
      if [[ "$previous" == -o ]]; then
        cp "$TEST_ZJ_ARCHIVE" "$argument"
        return
      fi
      previous="$argument"
    done
    return 1
  }
  install_zj_radar
' _ "$REPAIR" || fail_test "pinned zj-radar fixture installation failed"
[[ -x "$radar_home/.local/bin/zj-radar" ]] || fail_test "zj-radar fixture was not installed"
[[ "$("$radar_home/.local/bin/zj-radar" --version)" == "zj-radar 0.4.1" ]] ||
  fail_test "installed zj-radar fixture reported the wrong version"

lock_dir="$TMP_ROOT/repair.lock"
HOME="$TMP_ROOT" SETUP_INSTALL_LOCK_DIR="$lock_dir" /bin/bash -c '
  source "$1"
  acquire_install_lock
  [[ -r "$INSTALL_LOCK_DIR/pid" ]]
  release_install_lock
  [[ ! -e "$INSTALL_LOCK_DIR" ]]
' _ "$REPAIR" || fail_test "repair lock lifecycle failed"

active_lock="$TMP_ROOT/active.lock"
mkdir "$active_lock"
printf '%s\n' "$$" >"$active_lock/pid"
lock_status=0
lock_output="$(HOME="$TMP_ROOT" SETUP_INSTALL_LOCK_DIR="$active_lock" /bin/bash -c 'source "$1"; acquire_install_lock' _ "$REPAIR" 2>&1)" || lock_status=$?
[[ "$lock_status" -eq 3 ]] || fail_test "active repair lock returned $lock_status"
assert_contains "$lock_output" "Another setup repair is already running"

cleanup_dir="$TMP_ROOT/cleanup.lock"
cleanup_child_file="$TMP_ROOT/cleanup-child"
HOME="$TMP_ROOT" SETUP_INSTALL_LOCK_DIR="$cleanup_dir" /bin/bash -c '
  source "$1"
  acquire_install_lock
  sleep 30 &
  ACTIVE_TASK_PID=$!
  printf "%s\n" "$ACTIVE_TASK_PID" >"$2"
  cleanup
  ! kill -0 "$(sed -n "1p" "$2")" 2>/dev/null
  [[ ! -e "$INSTALL_LOCK_DIR" ]]
' _ "$REPAIR" "$cleanup_child_file" || fail_test "repair cleanup left a child or lock behind"

printf '[PASS] repair module checks\n'
