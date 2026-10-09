#!/usr/bin/env bash
# setup-test: Setup state
# setup-test-scope: work
# Deterministic local checks for setup/state.sh; no host configuration changes.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE="$REPO_DIR/setup/state.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-state-test.XXXXXX")"
source "$REPO_DIR/setup/dependencies.sh"
REAL_YQ="$(command -v yq)"
REAL_JQ="$(command -v jq)"

run_state() (
  local strict=false
  local require_work=false
  local scan_status=0
  local index
  local severity
  local glyph

  while (( $# > 0 )); do
    case "$1" in
      --strict) strict=true ;;
      --work) require_work=true ;;
      *) fail_test "unknown state-test option: $1" ;;
    esac
    shift
  done

  hash -r
  source "$STATE"
  setup_state_scan "" "" "$require_work" || scan_status=$?
  for index in "${!SETUP_FINDING_IDS[@]}"; do
    severity="${SETUP_FINDING_SEVERITIES[$index]}"
    case "$severity" in
      pass) glyph='✓' ;;
      info) glyph='•' ;;
      warning) glyph='!' ;;
      manual) glyph='•' ;;
      fail) glyph='✗' ;;
    esac
    printf '%s  %s\n' "$glyph" "${SETUP_FINDING_MESSAGES[$index]}"
  done
  printf '\n[SUMMARY] %s failure(s), %s warning(s), %s manual follow-up(s)\n' "$FAILURES" "$WARNINGS" "$MANUAL_FOLLOWUPS"
  if (( FAILURES > 0 )); then
    for index in "${!SETUP_FINDING_IDS[@]}"; do
      [[ "${SETUP_FINDING_SEVERITIES[$index]}" == fail ]] || continue
      printf '  - %s\n' "${SETUP_FINDING_MESSAGES[$index]}"
    done
  fi

  (( FAILURES > 0 )) && return 1
  [[ "$strict" == true && $WARNINGS -gt 0 ]] && return 1
  return 0
)

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

assert_static_status_output() {
  local text="$1"

  assert_not_contains "$text" "[CHECK]"
  assert_not_contains "$text" "[PASS]"
  assert_not_contains "$text" $'\033'
  assert_not_contains "$text" $'\r'
}

command_dir="$TMP_ROOT/test-bin"
current_platform="$(setup_detect_platform)"
brew_prefix="$TMP_ROOT/homebrew"
managed_zsh="$brew_prefix/bin/zsh"
[[ "$current_platform" == macos ]] && managed_zsh=/bin/zsh
mkdir -p "$TMP_ROOT/.local/bin" "$command_dir" "$brew_prefix/bin"
setup_collect_dependencies "$current_platform" false ""
brew_formula_file="$TMP_ROOT/brew-formulae"
brew_cask_file="$TMP_ROOT/brew-casks"
printf '%s\n' "${SETUP_BREW_PACKAGES[@]}" >"$brew_formula_file"
printf '%s\n' "${SETUP_MACOS_APPS[@]}" >"$brew_cask_file"
export TEST_BREW_FORMULAE="$brew_formula_file"
export TEST_BREW_CASKS="$brew_cask_file"
export TEST_BREW_PREFIX="$brew_prefix"
for spec in "${SETUP_DEPENDENCIES[@]}"; do
  IFS='|' read -r scope platform provider package check_type check_value <<<"$spec"
  setup_platform_matches "$platform" "$current_platform" || continue
  setup_scope_matches "$scope" false "" || continue
  if [[ "$check_type" == command ]]; then
    if [[ "$provider" == brew ]]; then
      printf '#!/bin/sh\nexit 0\n' >"$brew_prefix/bin/$check_value"
      chmod +x "$brew_prefix/bin/$check_value"
    elif [[ "$check_value" == /* && -x "$check_value" ]]; then
      :
    else
      printf '#!/bin/sh\nexit 0\n' >"$command_dir/$check_value"
      chmod +x "$command_dir/$check_value"
    fi
  elif [[ "$check_type" == brew_file ]]; then
    mkdir -p "$brew_prefix/$(dirname "$check_value")"
    printf 'test fixture\n' >"$brew_prefix/$check_value"
  fi
done
printf '#!/bin/sh\necho %s\n' "$SETUP_GITLEAKS_MIN_VERSION" >"$brew_prefix/bin/gitleaks"
rm -f "$brew_prefix/bin/yq"
ln -s "$REAL_YQ" "$brew_prefix/bin/yq"
rm -f "$brew_prefix/bin/jq"
ln -s "$REAL_JQ" "$brew_prefix/bin/jq"
{
  printf '#!/bin/sh\n'
  printf '%s\n' 'printf '\''{"checks":{"config.load":{"status":"ok"}}}\n'\'''
  printf 'exit 1\n'
} >"$command_dir/codex"
chmod +x "$command_dir/codex"
for command_name in brew; do
  printf '#!/bin/sh\nexit 0\n' >"$command_dir/$command_name"
  chmod +x "$command_dir/$command_name"
done
printf '#!/bin/sh\nif [ "$1" = "--prefix" ]; then printf "%%s\\n" "$TEST_BREW_PREFIX"; elif [ "$1" = list ] && [ "$2" = --formula ]; then cat "$TEST_BREW_FORMULAE"; elif [ "$1" = list ] && [ "$2" = --cask ]; then cat "$TEST_BREW_CASKS"; fi\nexit 0\n' >"$command_dir/brew"
chmod +x "$command_dir/brew"
printf '#!/bin/sh\nprintf "install ok installed\\n"\n' >"$command_dir/dpkg-query"
printf '#!/bin/sh\nexit 0\n' >"$command_dir/rpm"
chmod +x "$command_dir/dpkg-query" "$command_dir/rpm"
export TEST_FZF_REF="$SETUP_FZF_TAB_REF"
export TEST_HOOKS_PATH=.githooks
printf '#!/bin/sh\nif [ "$3:$4" = "rev-parse:HEAD" ]; then printf "%%s\\n" "$TEST_FZF_REF"; fi\nif [ "$3:$6" = "config:core.hooksPath" ] && [ -n "$TEST_HOOKS_PATH" ]; then printf "%%s\\n" "$TEST_HOOKS_PATH"; fi\nexit 0\n' >"$command_dir/git"
chmod +x "$command_dir/git"

mkdir -p "$TMP_ROOT/.fzf-tab/.git" "$TMP_ROOT/.fzf-tab/lib"
printf '#!/bin/sh\nexit 0\n' >"$brew_prefix/bin/zsh"
printf 'test fixture\n' >"$TMP_ROOT/.fzf-tab/fzf-tab.plugin.zsh"
printf '#!/bin/sh\nprintf "zj-radar 0.4.1\\n"\n' >"$TMP_ROOT/.local/bin/zj-radar"
chmod +x "$TMP_ROOT/.local/bin/zj-radar"
chmod +x "$brew_prefix/bin/zsh"
shells_file="$TMP_ROOT/shells"
printf '%s\n' "$managed_zsh" >"$shells_file"
export SHELL="$managed_zsh"
export SETUP_ACCOUNT_SHELL_OVERRIDE="$managed_zsh"
export SETUP_SHELLS_FILE="$shells_file"
if [[ "$current_platform" != macos ]]; then
  mkdir -p "$TMP_ROOT/.local/share/fonts"
  for font in "${SETUP_LINUX_FONT_FILES[@]}"; do
    printf 'test fixture\n' >"$TMP_ROOT/.local/share/fonts/$font"
  done
fi
managed_path="$REPO_DIR/dotfiles/.bin:$TMP_ROOT/.local/bin"
doctor_path="$managed_path:$brew_prefix/bin:$command_dir:/usr/bin:/bin"
doctor_env_file="$TMP_ROOT/.local/.env.zsh"
mkdir -p "$TMP_ROOT/.codex"
cp "$REPO_DIR/$SETUP_CODEX_CONFIG_SOURCE" "$TMP_ROOT/.codex/config.toml"
TEST_CODEX_NOTIFIER="$REPO_DIR/dotfiles/.bin/codex-turn-bell" \
  TEST_CODEX_PROJECT="$TMP_ROOT/local-project" yq -i -p=toml -o=toml \
  '.notify = [strenv(TEST_CODEX_NOTIFIER)] | .projects[strenv(TEST_CODEX_PROJECT)].trust_level = "trusted"' \
  "$TMP_ROOT/.codex/config.toml"
chmod 600 "$TMP_ROOT/.codex/config.toml"

output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$output" "!  ~/.zshrc is missing: $TMP_ROOT/.zshrc"
assert_contains "$output" "✓  command eza is available"
assert_contains "$output" $'\n\n[SUMMARY]'
assert_static_status_output "$output"

external_missing="$TMP_ROOT/external-runtime-path"
external_path_output="$(HOME="$TMP_ROOT" PATH="$doctor_path:$external_missing" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$external_path_output" "✓  setup-managed PATH directories exist"
assert_contains "$external_path_output" "✓  setup-managed PATH directories are active"
assert_not_contains "$external_path_output" "$external_missing"

missing_managed="$TMP_ROOT/.local/bin"
rm "$TMP_ROOT/.local/bin/zj-radar"
rmdir "$missing_managed"
missing_managed_status=0
missing_managed_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)" || missing_managed_status=$?
[[ "$missing_managed_status" -ne 0 ]] || fail_test "missing managed directory and zj-radar unexpectedly passed"
assert_contains "$missing_managed_output" "!  setup-managed PATH directory is missing: $missing_managed"
assert_contains "$missing_managed_output" "✗  zj-radar is missing or not executable: $missing_managed/zj-radar"

if HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state --strict >/dev/null; then
  fail_test "--strict unexpectedly accepted warnings"
fi

for name in "${SETUP_HOME_LINKS[@]}"; do
  ln -s "$REPO_DIR/dotfiles/$name" "$TMP_ROOT/$name"
done
mkdir -p "$TMP_ROOT/.config"
for name in "${SETUP_CONFIG_LINKS[@]}"; do
  ln -s "$REPO_DIR/dotfiles/$name" "$TMP_ROOT/.config/$name"
done
gitconfig_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || true
assert_contains "$gitconfig_output" "✓  ~/.config/git points to this checkout"
assert_contains "$gitconfig_output" "!  ~/.gitconfig is missing; global Git writes would change the tracked config"
: >"$TMP_ROOT/.gitconfig"

mkdir -p "$missing_managed"
printf '#!/bin/sh\nprintf "zj-radar 0.4.1\\n"\n' >"$TMP_ROOT/.local/bin/zj-radar"
chmod +x "$TMP_ROOT/.local/bin/zj-radar"
printf 'export SETUP_OS=%s\nexport SETUP_PLATFORM=%s\nexport SETUP_INSTALL_METHOD=%s\nWORK_ENV=false\n' \
  "$(setup_os_family "$current_platform")" "$current_platform" "$(setup_install_method "$current_platform")" >"$doctor_env_file"
linked_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_static_status_output "$linked_output"
assert_contains "$linked_output" "✓  ~/.vim points to this checkout"
assert_contains "$linked_output" "✓  ~/.zshrc points to this checkout"
assert_contains "$linked_output" "✓  ~/.config/nvim points to this checkout"
assert_contains "$linked_output" "✓  ~/.config/zellij points to this checkout"
assert_contains "$linked_output" "✓  SETUP_PLATFORM=$current_platform"
assert_contains "$linked_output" "✓  account login shell is $managed_zsh"
assert_contains "$linked_output" "✓  fzf-tab is installed at pinned revision $SETUP_FZF_TAB_REF"
assert_contains "$linked_output" "✓  fzf-tab checkout has compaudit-safe permissions"
assert_contains "$linked_output" "✓  zj-radar is installed at pinned version $SETUP_ZJ_RADAR_VERSION"
assert_contains "$linked_output" "✓  Codex config includes the managed portable settings"
assert_contains "$linked_output" "✓  Codex accepted the active config in strict mode"
HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state --strict >/dev/null || fail_test "complete dependency contract failed strict state scan"
assert_contains "$linked_output" "✓  no dangling or legacy links in ~, ~/.config, or ~/.local/bin"

# Links left by an older setup are reported, never repaired: a dangling one
# and one into another setup checkout, such as an old ~/.bin.
legacy_checkout="$TMP_ROOT/legacy-setup"
mkdir -p "$legacy_checkout/dotfiles/.bin"
: >"$legacy_checkout/setup.sh"
# The report names the physical path; macOS TMPDIR runs through a symlink.
legacy_checkout="$(cd -- "$legacy_checkout" && pwd -P)"
ln -s "$legacy_checkout/dotfiles/.bin" "$TMP_ROOT/.bin"
ln -s "$TMP_ROOT/no-such-tool" "$TMP_ROOT/.config/old-tool"
stray_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || true
assert_contains "$stray_output" "~/.bin points into another setup checkout ($legacy_checkout)"
assert_contains "$stray_output" "~/.config/old-tool is a dangling link to $TMP_ROOT/no-such-tool"
assert_not_contains "$stray_output" "~/.zshrc points into another"
[[ -L "$TMP_ROOT/.bin" && -L "$TMP_ROOT/.config/old-tool" ]] || fail_test "state scan changed stray links"
rm -f -- "$TMP_ROOT/.bin" "$TMP_ROOT/.config/old-tool"
rm -rf -- "$legacy_checkout"
hooks_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" TEST_HOOKS_PATH= run_state 2>&1)" || true
assert_contains "$hooks_output" "!  Git hooks path is unset; expected .githooks"

mv "$command_dir/codex" "$command_dir/codex.missing"
manual_codex_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$manual_codex_output" "•  Codex CLI is not installed"
assert_contains "$manual_codex_output" "[SUMMARY] 0 failure(s), 0 warning(s), 1 manual follow-up(s)"
mv "$command_dir/codex.missing" "$command_dir/codex"

stale_process_shell_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" SHELL=/bin/sh TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$stale_process_shell_output" "•  a new login is needed before the current process uses $managed_zsh"
assert_contains "$stale_process_shell_output" "[SUMMARY] 0 failure(s), 0 warning(s), 0 manual follow-up(s)"

printf '#!/bin/sh\nexit 0\n' >"$command_dir/eza"
chmod +x "$command_dir/eza"
stale_path="$managed_path:$command_dir:$brew_prefix/bin:/usr/bin:/bin"
stale_path_output="$(HOME="$TMP_ROOT" PATH="$stale_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$stale_path_output" "!  command eza resolves to $command_dir/eza; expected Homebrew under $brew_prefix/bin or $brew_prefix/sbin; update PATH or start a new shell"
assert_contains "$stale_path_output" "[SUMMARY] 0 failure(s), 1 warning(s), 0 manual follow-up(s)"
rm "$command_dir/eza"

chmod g+w "$TMP_ROOT/.fzf-tab/lib"
permission_status=0
permission_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || permission_status=$?
[[ "$permission_status" -ne 0 ]] || fail_test "insecure fzf-tab permissions unexpectedly passed"
assert_contains "$permission_output" "✗  fzf-tab path is group/other-writable: $TMP_ROOT/.fzf-tab/lib"
chmod g-w "$TMP_ROOT/.fzf-tab/lib"

shell_status=0
shell_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" SETUP_ACCOUNT_SHELL_OVERRIDE=/bin/sh TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || shell_status=$?
[[ "$shell_status" -ne 0 ]] || fail_test "wrong login shell unexpectedly passed"
assert_contains "$shell_output" "✗  account login shell is /bin/sh; expected $managed_zsh"

fzf_status=0
fzf_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_FZF_REF=wrong-revision TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || fzf_status=$?
[[ "$fzf_status" -ne 0 ]] || fail_test "wrong fzf-tab revision unexpectedly passed"
assert_contains "$fzf_output" "✗  fzf-tab revision is wrong-revision; expected $SETUP_FZF_TAB_REF"

printf '#!/bin/sh\nprintf "zj-radar 0.0.0\\n"\n' >"$TMP_ROOT/.local/bin/zj-radar"
radar_status=0
radar_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || radar_status=$?
[[ "$radar_status" -ne 0 ]] || fail_test "wrong zj-radar version unexpectedly passed"
assert_contains "$radar_output" "✗  zj-radar version is zj-radar 0.0.0; expected $SETUP_ZJ_RADAR_VERSION"
printf '#!/bin/sh\nprintf "zj-radar 0.4.1\\n"\n' >"$TMP_ROOT/.local/bin/zj-radar"
chmod +x "$TMP_ROOT/.local/bin/zj-radar"

if [[ "$current_platform" != macos ]]; then
  missing_font="$TMP_ROOT/.local/share/fonts/${SETUP_LINUX_FONT_FILES[0]}"
  mv "$missing_font" "$missing_font.missing"
  font_status=0
  font_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || font_status=$?
  [[ "$font_status" -ne 0 ]] || fail_test "missing managed font unexpectedly passed"
  assert_contains "$font_output" "✗  managed Nerd Font files are missing"
  mv "$missing_font.missing" "$missing_font"
else
  grep -vx "${SETUP_MACOS_APPS[0]}" "$brew_cask_file" >"$brew_cask_file.missing"
  mv "$brew_cask_file.missing" "$brew_cask_file"
  cask_status=0
  cask_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || cask_status=$?
  [[ "$cask_status" -ne 0 ]] || fail_test "missing managed cask unexpectedly passed"
  assert_contains "$cask_output" "✗  Homebrew cask ${SETUP_MACOS_APPS[0]} is not installed"
  printf '%s\n' "${SETUP_MACOS_APPS[@]}" >"$brew_cask_file"
fi

grep -vx 'eza' "$brew_formula_file" >"$brew_formula_file.without-eza"
mv "$brew_formula_file.without-eza" "$brew_formula_file"
dependency_status=0
dependency_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_FZF_REF=wrong-revision TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || dependency_status=$?
[[ "$dependency_status" -ne 0 ]] || fail_test "missing required dependency unexpectedly passed"
assert_contains "$dependency_output" "✗  Homebrew formula eza is not installed"
assert_contains "$dependency_output" $'\n\n[SUMMARY]'
assert_contains "$dependency_output" "[SUMMARY] 2 failure(s), 0 warning(s), 0 manual follow-up(s)"
assert_static_status_output "$dependency_output"
failure_summary="${dependency_output#*$'\n[SUMMARY]'}"
assert_not_contains "$failure_summary" "Failures:"
assert_contains "$failure_summary" "  - Homebrew formula eza is not installed"
assert_contains "$failure_summary" "  - fzf-tab revision is wrong-revision; expected $SETUP_FZF_TAB_REF"

# Work scope reads the overlay checkout named by WORK_ROOT: a copy of the acme
# fixture overlay, whose dependencies.sh adds an external command and a Python
# requirements row.
work_root="$TMP_ROOT/work-root"
cp -R "$REPO_DIR/tests/fixtures/overlay" "$work_root"
# The Git include link is covered by the overlay test; keep these counts to the
# checks below.
rm -r "$work_root/acme/git"
setup_collect_dependencies "$current_platform" true acme "$work_root"
printf '%s\n' "${SETUP_BREW_PACKAGES[@]}" >"$brew_formula_file"
for spec in "${SETUP_DEPENDENCIES[@]}"; do
  IFS='|' read -r scope platform provider package check_type check_value <<<"$spec"
  setup_platform_matches "$platform" "$current_platform" || continue
  setup_scope_matches "$scope" true acme || continue
  if [[ "$check_type" == command ]]; then
    if [[ "$provider" == brew && ! -x "$brew_prefix/bin/$check_value" ]]; then
      printf '#!/bin/sh\nexit 0\n' >"$brew_prefix/bin/$check_value"
      chmod +x "$brew_prefix/bin/$check_value"
    elif [[ "$provider" != brew && "$check_value" != /* && ! -x "$command_dir/$check_value" ]]; then
      printf '#!/bin/sh\nexit 0\n' >"$command_dir/$check_value"
      chmod +x "$command_dir/$check_value"
    fi
  fi
done
printf 'test fixture\n' >"$work_root/acme/.env.zsh"
mkdir -p "$TMP_ROOT/.local/acme-venv/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/.local/acme-venv/bin/python"
chmod +x "$TMP_ROOT/.local/acme-venv/bin/python"
doctor_path="$TMP_ROOT/.local/acme-venv/bin:$work_root/acme/bin-acme:$doctor_path"
printf 'export SETUP_OS=%s\nexport SETUP_PLATFORM=%s\nexport SETUP_INSTALL_METHOD=%s\nWORK_ENV=true\nJOB=acme\nWORK_ROOT=%s\n' \
  "$(setup_os_family "$current_platform")" "$current_platform" "$(setup_install_method "$current_platform")" "$work_root" >"$doctor_env_file"
work_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$work_output" "✓  Python imports json is available"
assert_contains "$work_output" "work overlay checkout: $work_root"

# Work scope without WORK_ROOT, or with a missing checkout, fails clearly.
sed '/^WORK_ROOT=/d' "$doctor_env_file" >"$TMP_ROOT/no-root.zsh"
no_root_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$TMP_ROOT/no-root.zsh" run_state 2>&1)" || true
assert_contains "$no_root_output" "WORK_ENV=true requires WORK_ROOT"
sed "s|^WORK_ROOT=.*|WORK_ROOT=$TMP_ROOT/absent-overlay|" "$doctor_env_file" >"$TMP_ROOT/absent-root.zsh"
absent_root_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$TMP_ROOT/absent-root.zsh" run_state 2>&1)" || true
assert_contains "$absent_root_output" "work overlay checkout is missing: $TMP_ROOT/absent-overlay"

cp "$work_root/acme/env.zsh.example" "$work_root/acme/.env.zsh"
manual_work_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$manual_work_output" "✓  yq can round-trip the managed Codex TOML"
assert_contains "$manual_work_output" "•  work environment value ACME_TOKEN is empty"
assert_contains "$manual_work_output" "1 manual follow-up(s)"
printf 'test fixture\n' >"$work_root/acme/.env.zsh"

rm "$command_dir/acme-external-tool"
external_status=0
external_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || external_status=$?
[[ "$external_status" -eq 0 ]] || fail_test "manual-only external prerequisite returned $external_status"
assert_contains "$external_output" "•  external work prerequisite acme-external-tool is missing"
assert_contains "$external_output" "not installed by setup"
assert_contains "$external_output" "manual follow-up(s)"
printf '#!/bin/sh\nexit 0\n' >"$command_dir/acme-external-tool"
chmod +x "$command_dir/acme-external-tool"

rm "$TMP_ROOT/.tmux.conf"
ln -s "$TMP_ROOT/wrong-tmux.conf" "$TMP_ROOT/.tmux.conf"
wrong_link_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state)"
assert_contains "$wrong_link_output" "!  ~/.tmux.conf points to $TMP_ROOT/wrong-tmux.conf"

yq -i -p=toml -o=toml \
  '.model = "drifted-model" | .tui.status_line = ["git-branch"]' \
  "$TMP_ROOT/.codex/config.toml"
codex_drift_status=0
codex_drift_output="$(HOME="$TMP_ROOT" PATH="$doctor_path" TEST_BREW_PREFIX="$brew_prefix" SETUP_LOCAL_ENV_FILE="$doctor_env_file" run_state 2>&1)" || codex_drift_status=$?
[[ "$codex_drift_status" -ne 0 ]] || fail_test "Codex managed-setting drift unexpectedly passed"
assert_contains "$codex_drift_output" '✗  Codex setting mismatch: model; expected "gpt-5.6-sol", actual "drifted-model"'
assert_contains "$codex_drift_output" '✗  Codex setting mismatch: tui.status_line; expected ["model-with-reasoning","current-dir","context-remaining","used-tokens","project-name","git-branch","pull-request-number","branch-changes","run-state","task-progress"], actual ["git-branch"]'
assert_contains "$codex_drift_output" "[SUMMARY] 2 failure(s), 1 warning(s), 0 manual follow-up(s)"
assert_not_contains "$codex_drift_output" "Codex config differs from the managed settings"
assert_not_contains "$codex_drift_output" "$TMP_ROOT/local-project"

source "$STATE"
setup_state_reset
SETUP_STATE_AREA="Dependencies"
SETUP_STATE_ACTION="dependencies"
setup_state_check "managed command"
setup_state_fail "managed command is missing"
first_finding_id="${SETUP_FINDING_IDS[0]}"
[[ "${SETUP_FINDING_AREAS[0]}" == Dependencies ]] || fail_test "finding area was not recorded"
[[ "${SETUP_FINDING_SEVERITIES[0]}" == fail ]] || fail_test "finding severity was not recorded"
[[ "${SETUP_FINDING_REPAIR_IDS[0]}" == dependencies ]] || fail_test "finding repair action was not recorded"
setup_state_reset
SETUP_STATE_AREA="Dependencies"
SETUP_STATE_ACTION="dependencies"
setup_state_check "managed command"
setup_state_fail "managed command is missing"
[[ "${SETUP_FINDING_IDS[0]}" == "$first_finding_id" ]] || fail_test "finding ID is not stable"

(
  source "$REPO_DIR/setup/repair.sh"
  setup_state_reset
  SETUP_STATE_AREA="Dependencies"
  SETUP_STATE_ACTION="dependencies"
  setup_state_check "post-repair scan"
  setup_state_fail "post-repair finding"
  [[ "${SETUP_FINDING_MESSAGES[0]}" == "post-repair finding" ]] || fail_test "repair module replaced state collector helpers"
)

printf '[PASS] setup state regression checks\n'
