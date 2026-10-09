#!/usr/bin/env bash
# setup-test: Setup dependency contract
# setup-test-scope: work
# Deterministic checks for the shared setup dependency contract.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_DIR/setup/dependencies.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

assert_array_contains() {
  local expected="$1"
  shift
  setup_array_contains "$expected" "$@" || fail_test "missing dependency: $expected"
}

assert_array_excludes() {
  local unexpected="$1"
  shift
  ! setup_array_contains "$unexpected" "$@" || fail_test "unexpected dependency: $unexpected"
}

assert_array_contains .local/bin "${SETUP_USER_BIN_DIRS[@]}"
for awake_source in apps/awake/Info.plist apps/awake/Sources/Awake.swift apps/awake/build.sh dotfiles/.bin/awake; do
  assert_array_contains "$awake_source" "${SETUP_REQUIRED_REPO_FILES[@]}"
done
for hook_source in .githooks/pre-commit .githooks/commit-msg .githooks/pre-push .githooks/check-denylist .github/scripts/check_pr.sh; do
  assert_array_contains "$hook_source" "${SETUP_REQUIRED_REPO_FILES[@]}"
done
for workspace_source in apps/agent-workspace/Info.plist apps/agent-workspace/Main.swift dotfiles/.bin/agent-workspace; do
  assert_array_contains "$workspace_source" "${SETUP_REQUIRED_REPO_FILES[@]}"
done
for hardware_source in Info.plist Models.swift ProjectFormat.swift HardwareStore.swift Main.swift PlannerModel.swift PlannerView.swift PartEditor.swift AssemblyEditor.swift ProjectDetailsEditor.swift VisualFixtures.swift install_support.py; do
  assert_array_contains "apps/hardware-planner/$hardware_source" "${SETUP_REQUIRED_REPO_FILES[@]}"
done
assert_array_contains dotfiles/.bin/hardware-planner "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_excludes .bin "${SETUP_USER_BIN_DIRS[@]}"
assert_array_excludes bin "${SETUP_USER_BIN_DIRS[@]}"
[[ ${#SETUP_USER_BIN_DIRS[@]} -eq 1 ]] || fail_test "expected only ~/.local/bin to be setup-managed"
[[ ${#SETUP_LINUX_FONT_FILES[@]} -eq 4 ]] || fail_test "expected four managed Linux font files"
assert_array_contains "MesloLGS NF Regular.ttf" "${SETUP_LINUX_FONT_FILES[@]}"
assert_array_contains "MesloLGS NF Bold Italic.ttf" "${SETUP_LINUX_FONT_FILES[@]}"
assert_array_contains zellij "${SETUP_CONFIG_LINKS[@]}"
assert_array_contains dotfiles/atuin/config.toml "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_contains dotfiles/functions/atuin.zsh "${SETUP_REQUIRED_REPO_FILES[@]}"
for toolbox_source in dotfiles/lib/toolbox.py dotfiles/lib/toolbox_catalog.py dotfiles/lib/toolbox_history.py dotfiles/lib/toolbox_secrets.py dotfiles/toolbox/personal.jsonl; do
  assert_array_contains "$toolbox_source" "${SETUP_REQUIRED_REPO_FILES[@]}"
done
assert_array_contains dotfiles/.bin/codex-turn-bell "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_contains dotfiles/zellij/config.kdl "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_contains dotfiles/zellij/layouts/default.kdl "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_contains dotfiles/zellij/plugins/tab-picker.wasm "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_contains apps/zj-radar/keyboard-navigation.patch "${SETUP_REQUIRED_REPO_FILES[@]}"
assert_array_contains dotfiles/zellij/plugins/zj_radar.wasm "${SETUP_REQUIRED_REPO_FILES[@]}"
[[ "$SETUP_ZJ_RADAR_REPO" == marktoda/zj-radar ]] || fail_test "zj-radar repository mismatch"
[[ "$SETUP_ZJ_RADAR_VERSION" == v0.4.1 ]] || fail_test "zj-radar version mismatch"
[[ "$SETUP_ZJ_RADAR_SHA256_LINUX_X86_64" == 95ea06015a5e1c3e19cac3a093fffd986ef1ca593e58f076374700db9035aaa1 ]] ||
  fail_test "Linux x86_64 zj-radar checksum mismatch"
[[ "$SETUP_ZJ_RADAR_SHA256_LINUX_AARCH64" == e11001bccffed29ca2a70c2f10dbc1e37d0ba2e157efdb4bf2607fad14f71ca8 ]] ||
  fail_test "Linux aarch64 zj-radar checksum mismatch"
[[ "$SETUP_ZJ_RADAR_SHA256_MACOS_AARCH64" == 17654c7319b7dc92459eeb430421d45fd23a9a38c12b0245930b99a907556f8f ]] ||
  fail_test "macOS aarch64 zj-radar checksum mismatch"
[[ "$SETUP_ZJ_RADAR_WASM_SHA256" == 13bf8fbd6c6b5c1b15fb6f6d532b71c047062403aca6dd1e4e82ee4a50253338 ]] ||
  fail_test "zj-radar WebAssembly checksum mismatch"
[[ "$(setup_zj_radar_archive_sha256 x86_64-unknown-linux-musl)" == "$SETUP_ZJ_RADAR_SHA256_LINUX_X86_64" ]] ||
  fail_test "Linux x86_64 zj-radar checksum lookup failed"
[[ "$(setup_zj_radar_archive_sha256 aarch64-unknown-linux-musl)" == "$SETUP_ZJ_RADAR_SHA256_LINUX_AARCH64" ]] ||
  fail_test "Linux aarch64 zj-radar checksum lookup failed"
[[ "$(setup_zj_radar_archive_sha256 aarch64-apple-darwin)" == "$SETUP_ZJ_RADAR_SHA256_MACOS_AARCH64" ]] ||
  fail_test "macOS aarch64 zj-radar checksum lookup failed"
! setup_zj_radar_archive_sha256 unsupported >/dev/null || fail_test "unsupported zj-radar checksum lookup passed"

declare -a seen=()
for spec in "${SETUP_DEPENDENCIES[@]}"; do
  IFS='|' read -r scope platform provider package check_type check_value <<<"$spec"
  [[ -n "$scope" && -n "$platform" && -n "$provider" && -n "$package" && -n "$check_value" ]] || fail_test "incomplete dependency row: $spec"
  [[ "$check_type" == command || "$check_type" == brew_file || "$check_type" == imports ]] || fail_test "invalid check type: $check_type"
  case "$provider" in
  brew|apt|dnf|python|system|external) ;;
  *) fail_test "invalid provider: $provider" ;;
  esac
  key="$scope|$platform|$provider|$package|$check_type|$check_value"
  setup_array_contains "$key" ${seen[@]+"${seen[@]}"} && fail_test "duplicate dependency row: $key"
  seen+=("$key")
done

setup_collect_dependencies macos false ""
assert_array_contains atuin "${SETUP_BREW_PACKAGES[@]}"
[[ ${#SETUP_SELECTED_DEPENDENCIES[@]} -gt 0 ]] || fail_test "selected dependency rows are empty"
assert_array_contains eza "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains fd "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains jq "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains ripgrep "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains zellij "${SETUP_BREW_PACKAGES[@]}"
assert_array_excludes codex "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains pylint "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains python "${SETUP_BREW_PACKAGES[@]}"
assert_array_excludes zsh "${SETUP_BREW_PACKAGES[@]}"
assert_array_excludes fping "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains font-meslo-for-powerlevel10k "${SETUP_MACOS_APPS[@]}"
assert_array_contains "base|macos|system|-|command|/bin/zsh" "${SETUP_SELECTED_DEPENDENCIES[@]}"
assert_array_contains "base|macos|system|-|command|swiftc" "${SETUP_SELECTED_DEPENDENCIES[@]}"
assert_array_contains "base|macos|system|-|command|codesign" "${SETUP_SELECTED_DEPENDENCIES[@]}"

# The base contract declares no work rows; a work overlay adds its own from
# WORK_ROOT/JOB/dependencies.sh, and only for its own job.
for spec in "${SETUP_BASE_DEPENDENCIES[@]}"; do
  [[ "$spec" == base\|* ]] || fail_test "base contract declares a non-base row: $spec"
done
overlay_root="$REPO_DIR/tests/fixtures/overlay"
setup_collect_dependencies macos true acme "$overlay_root"
assert_array_contains "work:acme|all|external|-|command|acme-external-tool" "${SETUP_SELECTED_DEPENDENCIES[@]}"
assert_array_contains "$overlay_root/acme/requirements.txt" "${SETUP_PYTHON_REQUIREMENTS[@]}"
assert_array_contains eza "${SETUP_BREW_PACKAGES[@]}"
setup_collect_dependencies macos true other-job "$overlay_root"
assert_array_excludes "work:acme|all|external|-|command|acme-external-tool" "${SETUP_SELECTED_DEPENDENCIES[@]}"
setup_collect_dependencies macos false acme "$overlay_root"
assert_array_excludes "work:acme|all|external|-|command|acme-external-tool" "${SETUP_SELECTED_DEPENDENCIES[@]}"
[[ ${#SETUP_PYTHON_REQUIREMENTS[@]} -eq 0 ]] || fail_test "personal scope selected Python requirements"
broken_root="$(mktemp -d "${TMPDIR:-/tmp}/setup-dependency-overlay.XXXXXX")"
mkdir -p "$broken_root/acme"
printf '%s\n' 'return 1' >"$broken_root/acme/dependencies.sh"
setup_collect_dependencies macos true acme "$broken_root"
assert_array_excludes "work:acme|all|external|-|command|acme-external-tool" "${SETUP_SELECTED_DEPENDENCIES[@]}"
[[ "$SETUP_WORK_DEPENDENCIES_ERROR" == *"$broken_root/acme/dependencies.sh"* ]] || fail_test "a failing overlay dependency file was not reported"
rm -rf -- "$broken_root"

setup_collect_dependencies ubuntu false ""
assert_array_contains atuin "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains curl "${SETUP_APT_PACKAGES[@]}"
assert_array_contains git "${SETUP_APT_PACKAGES[@]}"
assert_array_contains procps "${SETUP_APT_PACKAGES[@]}"
assert_array_contains lsof "${SETUP_APT_PACKAGES[@]}"
assert_array_contains zsh "${SETUP_BREW_PACKAGES[@]}"
assert_array_excludes pylint "${SETUP_BREW_PACKAGES[@]}"

setup_collect_dependencies rocky false ""
assert_array_contains atuin "${SETUP_BREW_PACKAGES[@]}"
assert_array_contains curl "${SETUP_DNF_PACKAGES[@]}"
assert_array_contains git "${SETUP_DNF_PACKAGES[@]}"
assert_array_contains procps-ng "${SETUP_DNF_PACKAGES[@]}"
assert_array_contains lsof "${SETUP_DNF_PACKAGES[@]}"

[[ "$(setup_os_family macos)" == macos ]] || fail_test "macOS family mismatch"
[[ "$(setup_os_family ubuntu)" == linux ]] || fail_test "Linux family mismatch"
[[ "$(setup_install_method macos)" == homebrew ]] || fail_test "macOS install method mismatch"
[[ "$(setup_install_method ubuntu)" == homebrew+apt ]] || fail_test "Ubuntu install method mismatch"
[[ "$(setup_install_method rocky)" == homebrew+dnf ]] || fail_test "Rocky install method mismatch"
setup_platform_supported macos || fail_test "macOS was not recognized as supported"
setup_platform_supported ubuntu || fail_test "Ubuntu was not recognized as supported"
! setup_platform_supported linux || fail_test "generic Linux was unexpectedly supported"

for managed_source in "${SETUP_HOME_LINKS[@]}"; do
  [[ -e "$REPO_DIR/dotfiles/$managed_source" ]] || fail_test "missing managed source: $managed_source"
done
for managed_source in "${SETUP_CONFIG_LINKS[@]}"; do
  [[ -d "$REPO_DIR/dotfiles/$managed_source" ]] || fail_test "missing managed config: $managed_source"
done
for managed_source in "${SETUP_REQUIRED_REPO_FILES[@]}"; do
  [[ -f "$REPO_DIR/$managed_source" ]] || fail_test "missing required setup file: $managed_source"
done
[[ "$SETUP_CODEX_CONFIG_SOURCE" == dotfiles/codex/config.toml ]] || fail_test "Codex config source path mismatch"
grep -Fq '$HOME/.local/bin' "$REPO_DIR/dotfiles/.zshrc" || fail_test "~/.local/bin is missing from PATH"
grep -Fq '$WORK_DIR/bin-$JOB' "$REPO_DIR/dotfiles/.zshrc" || fail_test "job bin is missing from PATH"
grep -Fq '_setup_refresh_forwarded_ssh_agent' "$REPO_DIR/dotfiles/.zshrc" || fail_test "forwarded SSH agent refresh is not called"
grep -Fq 'SETUP_FORWARDED_SSH_AGENT_LINK' "$REPO_DIR/.local/env.zsh.example" || fail_test "forwarded SSH agent opt-in is undocumented"
! grep -Fq '$HOME/.bin' "$REPO_DIR/dotfiles/.zshrc" || fail_test "~/.bin remains in PATH"
! grep -Fq '$HOME/bin' "$REPO_DIR/dotfiles/.zshrc" || fail_test "~/bin remains in PATH"
grep -Fxq 'bell-features = system,border,title,attention' "$REPO_DIR/dotfiles/ghostty/config" || fail_test "Ghostty Codex bell features are missing"
grep -Fxq 'keybind = alt+left=csi:1;3D' "$REPO_DIR/dotfiles/ghostty/config" || fail_test "Ghostty Alt+Left encoding is missing"
grep -Fxq 'keybind = alt+right=csi:1;3C' "$REPO_DIR/dotfiles/ghostty/config" || fail_test "Ghostty Alt+Right encoding is missing"
grep -Fq '/usr/share/zsh/$ZSH_VERSION/functions' "$REPO_DIR/dotfiles/.zshrc" ||
  fail_test "macOS system Zsh function path is not selected"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-dependency-test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM
permission_fixture="$TMP_ROOT/permission-fixture"
mkdir "$permission_fixture"
chmod g+w "$permission_fixture"
[[ "$(setup_first_group_or_other_writable "$permission_fixture")" == "$permission_fixture" ]] ||
  fail_test "group-writable path was not detected"
chmod go-w "$permission_fixture"
[[ -z "$(setup_first_group_or_other_writable "$permission_fixture")" ]] ||
  fail_test "secure permission path was reported"

printf '#!/bin/sh\nexit 1\n' >"$TMP_ROOT/brew"
chmod +x "$TMP_ROOT/brew"
setup_reset_dependency_cache
if PATH="$TMP_ROOT:/usr/bin:/bin" setup_check_dependency bash command bash "$REPO_DIR" /usr/bin/python3 brew; then
  fail_test "brew-declared bash passed without the Homebrew formula"
fi
brew_prefix="$TMP_ROOT/homebrew"
mkdir -p "$brew_prefix/bin"
printf '#!/bin/sh\nif [ "$1" = list ]; then printf "bash\\n"; elif [ "$1" = --prefix ]; then printf "%%s\\n" "$TEST_BREW_PREFIX"; fi\nexit 0\n' >"$TMP_ROOT/brew"
export TEST_BREW_PREFIX="$brew_prefix"
setup_reset_dependency_cache
system_bash="$(PATH="/usr/bin:/bin" command -v bash)"
if PATH="$TMP_ROOT:/usr/bin:/bin" setup_check_dependency bash command bash "$REPO_DIR" /usr/bin/python3 brew; then
  fail_test "brew-declared bash passed while the active command came from the system"
fi
[[ "$SETUP_DEPENDENCY_SEVERITY" == warning ]] || fail_test "provider mismatch was not classified as a warning"
[[ "$SETUP_DEPENDENCY_FAILURE" == *"resolves to $system_bash; expected Homebrew under $brew_prefix/bin or $brew_prefix/sbin"* ]] ||
  fail_test "provider mismatch did not report the active command"
ln -s "$system_bash" "$brew_prefix/bin/bash"
setup_reset_dependency_cache
PATH="$brew_prefix/bin:$TMP_ROOT:/usr/bin:/bin" setup_check_dependency bash command bash "$REPO_DIR" /usr/bin/python3 brew ||
  fail_test "brew-declared bash did not pass with an active Homebrew command and formula"

[[ "$SETUP_GITLEAKS_MIN_VERSION" == 8.29.0 ]] || fail_test "gitleaks minimum version mismatch"
assert_array_contains "base|all|brew|gitleaks|command|gitleaks" "${SETUP_DEPENDENCIES[@]}"
for version_case in 8.29.0:8.29.0 v8.29.0:8.29.0 8.30.1:8.29.0 8.100:8.29.0 9.0.0:8.29.0; do
  setup_version_at_least "${version_case%%:*}" "${version_case#*:}" ||
    fail_test "version ${version_case%%:*} was not accepted as at least ${version_case#*:}"
done
for version_case in 8.28.0:8.29.0 8.9.9:8.29.0 7.99.0:8.29.0 :8.29.0 unknown:8.29.0; do
  ! setup_version_at_least "${version_case%%:*}" "${version_case#*:}" ||
    fail_test "version '${version_case%%:*}' was accepted as at least ${version_case#*:}"
done
printf '#!/bin/sh\nif [ "$1" = list ]; then printf "gitleaks\\n"; elif [ "$1" = --prefix ]; then printf "%%s\\n" "$TEST_BREW_PREFIX"; fi\nexit 0\n' >"$TMP_ROOT/brew"
setup_reset_dependency_cache
if PATH="$TMP_ROOT:/usr/bin:/bin" setup_check_dependency gitleaks command gitleaks "$REPO_DIR" /usr/bin/python3 brew; then
  fail_test "missing gitleaks unexpectedly passed"
fi
[[ "$SETUP_DEPENDENCY_FAILURE" == *"gitleaks 8.29.0 or newer"*"brew install gitleaks"* ]] ||
  fail_test "missing gitleaks did not name the minimum version and install command: $SETUP_DEPENDENCY_FAILURE"
printf '#!/bin/sh\n[ "$1" = version ] && printf "%%s\\n" "$TEST_GITLEAKS_VERSION"\n' >"$brew_prefix/bin/gitleaks"
chmod +x "$brew_prefix/bin/gitleaks"
setup_reset_dependency_cache
if TEST_GITLEAKS_VERSION=8.28.0 PATH="$brew_prefix/bin:$TMP_ROOT:/usr/bin:/bin" \
  setup_check_dependency gitleaks command gitleaks "$REPO_DIR" /usr/bin/python3 brew; then
  fail_test "gitleaks 8.28.0 passed below the minimum version"
fi
[[ "$SETUP_DEPENDENCY_SEVERITY" == fail ]] || fail_test "old gitleaks was not classified as a failure"
[[ "$SETUP_DEPENDENCY_FAILURE" == *"gitleaks 8.28.0 is too old"*"8.29.0 or newer"*"brew upgrade gitleaks"* ]] ||
  fail_test "old gitleaks did not name the versions and upgrade command: $SETUP_DEPENDENCY_FAILURE"
TEST_GITLEAKS_VERSION=8.29.0 PATH="$brew_prefix/bin:$TMP_ROOT:/usr/bin:/bin" \
  setup_check_dependency gitleaks command gitleaks "$REPO_DIR" /usr/bin/python3 brew ||
  fail_test "gitleaks 8.29.0 did not pass: $SETUP_DEPENDENCY_FAILURE"

# fzf and Atuin are checked with the options the shell passes them.
printf '#!/bin/sh\nif [ "$1" = list ]; then printf "fzf\\natuin\\n"; elif [ "$1" = --prefix ]; then printf "%%s\\n" "$TEST_BREW_PREFIX"; fi\nexit 0\n' >"$TMP_ROOT/brew"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "0.44.1 (debian)" && exit 0\n[ "$1" = --zsh ] && [ -z "$TEST_NEW" ] && exit 2\nexit 0\n' >"$brew_prefix/bin/fzf"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "atuin 18.2.0" && exit 0\nfor a; do [ "$a" = --disable-ai ] && [ -z "$TEST_NEW" ] && exit 2; done\nexit 0\n' >"$brew_prefix/bin/atuin"
chmod +x "$brew_prefix/bin/fzf" "$brew_prefix/bin/atuin"
for tool in fzf atuin; do
  setup_reset_dependency_cache
  if PATH="$brew_prefix/bin:$TMP_ROOT:/usr/bin:/bin" setup_check_dependency "$tool" command "$tool" "$REPO_DIR" /usr/bin/python3 brew; then
    fail_test "$tool without the options the shell uses passed"
  fi
  [[ "$SETUP_DEPENDENCY_SEVERITY" == fail ]] || fail_test "old $tool was not classified as a failure"
  [[ "$SETUP_DEPENDENCY_FAILURE" == *"is too old"*"(brew upgrade $tool)" ]] ||
    fail_test "old $tool did not name the upgrade command: $SETUP_DEPENDENCY_FAILURE"
  TEST_NEW=1 PATH="$brew_prefix/bin:$TMP_ROOT:/usr/bin:/bin" setup_check_dependency "$tool" command "$tool" "$REPO_DIR" /usr/bin/python3 brew ||
    fail_test "current $tool did not pass: $SETUP_DEPENDENCY_FAILURE"
done
setup_command_too_old fzf "$brew_prefix/bin/fzf" || fail_test "old fzf was not reported"
[[ "$SETUP_COMMAND_TOO_OLD" == "fzf 0.44.1 is too old; the shell's key bindings need fzf --zsh (0.48.0 or newer)" ]] ||
  fail_test "old fzf message: $SETUP_COMMAND_TOO_OLD"

if PATH="/usr/bin:/bin" setup_check_dependency - command acme-external-tool "$REPO_DIR" /usr/bin/python3 external; then
  fail_test "missing external work prerequisite unexpectedly passed"
fi
[[ "$SETUP_DEPENDENCY_FAILURE" == *"not installed by setup"*"work environment"* ]] ||
  fail_test "external work prerequisite diagnostic was not actionable"
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/acme-external-tool"
chmod +x "$TMP_ROOT/acme-external-tool"
PATH="$TMP_ROOT:/usr/bin:/bin" setup_check_dependency - command acme-external-tool "$REPO_DIR" /usr/bin/python3 external ||
  fail_test "available external work prerequisite did not pass"

printf '[PASS] setup dependency contract checks\n'
