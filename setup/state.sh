#!/usr/bin/env bash
# Read-only setup state collector. Source this module through ./setup.sh.

SETUP_STATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd -- "$SETUP_STATE_DIR/.." && pwd)}"
DOTFILE_DIR="$REPO_DIR/dotfiles"
LOCAL_ENV_FILE="${SETUP_LOCAL_ENV_FILE:-$REPO_DIR/.local/.env.zsh}"
SHELLS_FILE="${SETUP_SHELLS_FILE:-/etc/shells}"
# The work overlay checkout comes from WORK_ROOT in the local environment file;
# SETUP_WORK_ROOT overrides it (tests use this).
SETUP_WORK_ROOT="${SETUP_WORK_ROOT:-}"
source "$SETUP_STATE_DIR/dependencies.sh"
source "$SETUP_STATE_DIR/codex_config_helpers.sh"

SETUP_STATE_AREAS=(
  "Repository"
  "Dependencies"
  "Codex"
  "Files and Paths"
  "Shell and Plugins"
  "Platform Assets"
  "Work Environment"
)
SETUP_FINDING_IDS=()
SETUP_FINDING_AREAS=()
SETUP_FINDING_SEVERITIES=()
SETUP_FINDING_MESSAGES=()
SETUP_FINDING_REPAIR_IDS=()
SETUP_STATE_AREA="Repository"
SETUP_STATE_ACTION=""
SETUP_STATE_PENDING_LABEL=""
SETUP_STATE_PLATFORM=""
REQUIRE_WORK=false
FAILURES=0
WARNINGS=0
MANUAL_FOLLOWUPS=0
CONFIG_WORK_ENV=""
CONFIG_JOB=""
CONFIG_WORK_ROOT=""
CONFIG_SETUP_OS=""
CONFIG_SETUP_PLATFORM=""
CONFIG_INSTALL_METHOD=""
CONFIG_PYTHON_VENV=""

setup_state_reset() {
  SETUP_FINDING_IDS=()
  SETUP_FINDING_AREAS=()
  SETUP_FINDING_SEVERITIES=()
  SETUP_FINDING_MESSAGES=()
  SETUP_FINDING_REPAIR_IDS=()
  SETUP_STATE_PENDING_LABEL=""
  FAILURES=0
  WARNINGS=0
  MANUAL_FOLLOWUPS=0
  CONFIG_WORK_ENV=""
  CONFIG_JOB=""
  CONFIG_WORK_ROOT=""
  CONFIG_SETUP_OS=""
  CONFIG_SETUP_PLATFORM=""
  CONFIG_INSTALL_METHOD=""
  CONFIG_PYTHON_VENV=""
}

setup_state_record() {
  local severity="$1"
  local message="$2"
  local repair_id="${3:-$SETUP_STATE_ACTION}"
  local finding_id="$SETUP_STATE_AREA|$SETUP_STATE_PENDING_LABEL|$message"

  finding_id="${finding_id//$'\n'/ }"
  SETUP_FINDING_IDS+=("$finding_id")
  SETUP_FINDING_AREAS+=("$SETUP_STATE_AREA")
  SETUP_FINDING_SEVERITIES+=("$severity")
  SETUP_FINDING_MESSAGES+=("$message")
  SETUP_FINDING_REPAIR_IDS+=("$repair_id")
}

setup_state_complete() { setup_state_record pass "$1" ""; }
setup_state_check() { SETUP_STATE_PENDING_LABEL="$1"; }
setup_state_info() { setup_state_record info "$1" ""; }
setup_state_warn() {
  WARNINGS=$((WARNINGS + 1))
  setup_state_record warning "$1"
}
setup_state_manual() {
  MANUAL_FOLLOWUPS=$((MANUAL_FOLLOWUPS + 1))
  setup_state_record manual "$1" ""
}
setup_state_fail() {
  FAILURES=$((FAILURES + 1))
  setup_state_record fail "$1"
}

check_command() {
  local command_name="$1"

  setup_state_check "$command_name availability"
  if command -v "$command_name" >/dev/null 2>&1; then
    setup_state_complete "$command_name is available"
  else
    setup_state_fail "$command_name is not available on PATH"
  fi
}

check_link() {
  local destination="$1"
  local expected="$2"
  local label="$3"
  local target

  setup_state_check "$label link"
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    setup_state_warn "$label is missing: $destination"
    return
  fi

  if [[ ! -L "$destination" ]]; then
    setup_state_warn "$label is not a symlink: $destination"
    return
  fi

  target="$(readlink "$destination")"
  if [[ "$target" == "$expected" ]]; then
    setup_state_complete "$label points to this checkout"
  else
    setup_state_warn "$label points to $target (expected $expected)"
  fi
}

check_managed_links() {
  local name

  for name in "${SETUP_HOME_LINKS[@]}"; do
    check_link "$HOME/$name" "$DOTFILE_DIR/$name" "~/$name"
  done

  for name in "${SETUP_CONFIG_LINKS[@]}"; do
    check_link "$HOME/.config/$name" "$DOTFILE_DIR/$name" "~/.config/$name"
  done

  # Without ~/.gitconfig, `git config --global` writes into the tracked
  # dotfiles/git/config through the ~/.config/git link.
  setup_state_check "machine-local Git config"
  if [[ -f "$HOME/.gitconfig" ]]; then
    setup_state_complete "~/.gitconfig holds machine-local Git settings"
  else
    setup_state_warn "~/.gitconfig is missing; global Git writes would change the tracked config"
  fi
}

check_codex_config() {
  local current_platform="$1"
  local source_file="$REPO_DIR/$SETUP_CODEX_CONFIG_SOURCE"
  local destination="$HOME/.codex/config.toml"
  local expected
  local discrepancies
  local discrepancy
  local validation_status
  local current_mode

  setup_state_check "Codex config file"
  if [[ ! -r "$source_file" ]]; then
    setup_state_fail "tracked Codex config source is missing: $source_file"
    return
  fi
  setup_state_check "Codex TOML encoder"
  if setup_codex_yq_supports_managed_toml "$source_file"; then
    setup_state_complete "yq can round-trip the managed Codex TOML"
  else
    setup_state_fail "$SETUP_CODEX_CONFIG_ERROR"
    return
  fi
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    setup_state_fail "Codex config is missing: $destination; run ./setup.sh --fix"
    return
  fi
  if [[ -L "$destination" ]]; then
    setup_state_fail "Codex config is a symlink instead of an atomically managed file: $destination"
    return
  fi
  if [[ ! -f "$destination" || ! -r "$destination" ]]; then
    setup_state_fail "Codex config is not a readable regular file: $destination"
    return
  fi
  if ! setup_codex_validate_toml "$destination"; then
    setup_state_fail "$SETUP_CODEX_CONFIG_ERROR"
    return
  fi
  setup_state_complete "Codex config is readable and valid TOML"

  setup_state_check "Codex config permissions"
  current_mode="$(setup_codex_file_mode "$destination")" || current_mode="unknown"
  if [[ "$current_mode" == 600 ]]; then
    setup_state_complete "Codex config permissions are 600"
  else
    setup_state_fail "Codex config permissions are $current_mode; expected 600"
  fi

  setup_state_check "Codex managed settings"
  expected="$(mktemp "${TMPDIR:-/tmp}/setup-codex-state.XXXXXX")" || {
    setup_state_fail "Could not create a temporary expected Codex config"
    return
  }
  if ! setup_codex_render_config "$source_file" "$destination" "$current_platform" "$HOME" "$expected"; then
    setup_state_fail "$SETUP_CODEX_CONFIG_ERROR"
    rm -f -- "$expected"
    return
  fi
  if setup_codex_semantically_equal "$destination" "$expected"; then
    setup_state_complete "Codex config includes the managed portable settings"
  else
    if ! discrepancies="$(setup_codex_list_discrepancies "$destination" "$expected")"; then
      setup_state_fail "$SETUP_CODEX_CONFIG_ERROR"
    elif [[ -z "$discrepancies" ]]; then
      setup_state_fail "Codex config differs from the managed settings; run ./setup.sh --fix"
    else
      while IFS= read -r discrepancy; do
        [[ -n "$discrepancy" ]] && setup_state_fail "$discrepancy"
      done <<<"$discrepancies"
    fi
  fi
  rm -f -- "$expected"

  setup_state_check "Codex strict validation"
  setup_codex_validate_with_cli "$destination"
  validation_status=$?
  case "$validation_status" in
  0) setup_state_complete "Codex accepted the active config in strict mode" ;;
  2)
    SETUP_STATE_ACTION=""
    setup_state_manual "Codex CLI is not installed; install and sign in to Codex when needed (TOML validation passed)"
    SETUP_STATE_ACTION="codex"
    ;;
  *) setup_state_fail "$SETUP_CODEX_CONFIG_ERROR" ;;
  esac
}

check_repo_sources() {
  local item
  local missing=0

  setup_state_check "tracked setup sources"
  for item in "${SETUP_HOME_LINKS[@]}"; do
    if [[ ! -e "$DOTFILE_DIR/$item" ]]; then
      setup_state_fail "tracked dotfile source is missing: $DOTFILE_DIR/$item"
      missing=$((missing + 1))
    fi
  done
  for item in "${SETUP_CONFIG_LINKS[@]}"; do
    if [[ ! -d "$DOTFILE_DIR/$item" ]]; then
      setup_state_fail "tracked config source is missing: $DOTFILE_DIR/$item"
      missing=$((missing + 1))
    fi
  done
  for item in "${SETUP_REQUIRED_REPO_FILES[@]}"; do
    if [[ ! -f "$REPO_DIR/$item" ]]; then
      setup_state_fail "tracked setup file is missing: $REPO_DIR/$item"
      missing=$((missing + 1))
    fi
  done

  (( missing == 0 )) && setup_state_complete "tracked setup sources are present"
}

check_git_hooks() {
  local hooks_path

  setup_state_check "repository Git hooks"
  hooks_path="$(git -C "$REPO_DIR" config --local --get core.hooksPath 2>/dev/null || true)"
  if [[ "$hooks_path" == "$SETUP_GIT_HOOKS_PATH" ]]; then
    setup_state_complete "commits and pushes run the tracked Git hooks"
  else
    setup_state_warn "Git hooks path is ${hooks_path:-unset}; expected $SETUP_GIT_HOOKS_PATH"
  fi
}

load_local_env_config() {
  local name
  local value

  [[ -r "$LOCAL_ENV_FILE" ]] || return 0
  while IFS='=' read -r name value; do
    case "$name" in
    WORK_ENV) CONFIG_WORK_ENV="$value" ;;
    JOB) CONFIG_JOB="$value" ;;
    WORK_ROOT) CONFIG_WORK_ROOT="$value" ;;
    SETUP_OS) CONFIG_SETUP_OS="$value" ;;
    SETUP_PLATFORM) CONFIG_SETUP_PLATFORM="$value" ;;
    SETUP_INSTALL_METHOD) CONFIG_INSTALL_METHOD="$value" ;;
    SETUP_PYTHON_VENV) CONFIG_PYTHON_VENV="$value" ;;
    esac
  done < <(
    sed -n -E \
      "s/^[[:space:]]*(export[[:space:]]+)?(WORK_ENV|JOB|WORK_ROOT|SETUP_OS|SETUP_PLATFORM|SETUP_INSTALL_METHOD|SETUP_PYTHON_VENV)[[:space:]]*=[[:space:]]*[\"']?([^\"'[:space:]]+)[\"']?.*$/\2=\3/p" \
      "$LOCAL_ENV_FILE"
  )
}

check_path_entries() {
  local entry
  local index
  local relative_path
  local -a missing_entries=()
  local -a missing_actions=()
  local -a absent_entries=()
  local -a managed_entries=("$DOTFILE_DIR/.bin")
  local -a managed_actions=("")

  for relative_path in "${SETUP_USER_BIN_DIRS[@]}"; do
    managed_entries+=("$HOME/$relative_path")
    managed_actions+=("paths")
  done

  if [[ "$CONFIG_WORK_ENV" == true && -n "$CONFIG_JOB" && -n "$CONFIG_WORK_ROOT" ]]; then
    managed_entries+=("$CONFIG_WORK_ROOT/$CONFIG_JOB/bin-$CONFIG_JOB")
    managed_actions+=("work")
  fi
  if [[ -n "$CONFIG_PYTHON_VENV" ]]; then
    managed_entries+=("$CONFIG_PYTHON_VENV/bin")
    managed_actions+=("dependencies")
  fi

  setup_state_check "setup-managed PATH directories"
  for index in "${!managed_entries[@]}"; do
    entry="${managed_entries[$index]}"
    if [[ ! -d "$entry" ]]; then
      missing_entries+=("$entry")
      missing_actions+=("${managed_actions[$index]}")
    fi
    case ":${PATH:-}:" in
      *":$entry:"*) ;;
      *) absent_entries+=("$entry") ;;
    esac
  done

  if (( ${#missing_entries[@]} == 0 )); then
    setup_state_complete "setup-managed PATH directories exist"
  else
    for index in "${!missing_entries[@]}"; do
      SETUP_STATE_ACTION="${missing_actions[$index]}"
      setup_state_warn "setup-managed PATH directory is missing: ${missing_entries[$index]}"
    done
  fi

  setup_state_check "active setup-managed PATH entries"
  SETUP_STATE_ACTION=""
  if (( ${#absent_entries[@]} == 0 )); then
    setup_state_complete "setup-managed PATH directories are active"
  else
    for entry in "${absent_entries[@]}"; do
      setup_state_warn "setup-managed PATH directory is not active: $entry; start a new Zsh session"
    done
  fi
  SETUP_STATE_ACTION="paths"
}

check_work_environment() {
  local work_dir
  local work_bin
  local template_file
  local variable_name

  setup_state_check "work environment configuration"
  SETUP_STATE_ACTION="metadata"
  if [[ ! -r "$LOCAL_ENV_FILE" ]]; then
    if [[ "$REQUIRE_WORK" == true ]]; then
      setup_state_fail "work configuration is missing: $LOCAL_ENV_FILE"
    else
      setup_state_warn "local environment configuration is missing: $LOCAL_ENV_FILE"
    fi
    [[ "$CONFIG_WORK_ENV" == true && -n "$CONFIG_JOB" ]] || return
  fi

  if [[ "$CONFIG_WORK_ENV" != true ]]; then
    if [[ "$REQUIRE_WORK" == true ]]; then
      setup_state_fail "--work requires WORK_ENV=true in $LOCAL_ENV_FILE"
    else
      setup_state_info "work environment is disabled"
    fi
    return
  fi

  if [[ -z "$CONFIG_JOB" ]]; then
    setup_state_fail "WORK_ENV=true requires JOB in $LOCAL_ENV_FILE"
    return
  fi

  setup_state_check "work overlay checkout"
  if [[ -z "$CONFIG_WORK_ROOT" ]]; then
    setup_state_fail "WORK_ENV=true requires WORK_ROOT (the work overlay checkout) in $LOCAL_ENV_FILE; run ./setup.sh --fix --work-root PATH"
    return
  fi
  if [[ ! -d "$CONFIG_WORK_ROOT" ]]; then
    SETUP_STATE_ACTION=""
    setup_state_fail "work overlay checkout is missing: $CONFIG_WORK_ROOT; clone it or pass --work-root PATH"
    return
  fi
  setup_state_complete "work overlay checkout: $CONFIG_WORK_ROOT"

  SETUP_STATE_ACTION="work"
  setup_state_complete "work environment enabled for JOB=$CONFIG_JOB"
  work_dir="$CONFIG_WORK_ROOT/$CONFIG_JOB"
  work_bin="$work_dir/bin-$CONFIG_JOB"
  setup_state_check "work directory"
  [[ -d "$work_dir" ]] && setup_state_complete "work directory exists: $work_dir" || setup_state_fail "work directory is missing: $work_dir"
  setup_state_check "work bin directory"
  [[ -d "$work_bin" ]] && setup_state_complete "work bin directory exists: $work_bin" || setup_state_fail "work bin directory is missing: $work_bin"
  setup_state_check "work helper file"
  [[ -r "$work_bin/functions-$CONFIG_JOB.sh" ]] && setup_state_complete "work helper file is readable" || setup_state_fail "work helper file is missing: $work_bin/functions-$CONFIG_JOB.sh"
  setup_state_check "work aliases file"
  [[ -r "$work_dir/.aliases-$CONFIG_JOB" ]] && setup_state_complete "work aliases file is readable" || setup_state_fail "work aliases file is missing: $work_dir/.aliases-$CONFIG_JOB"

  setup_state_check "work environment file"
  if [[ -r "$work_dir/.env.zsh" ]]; then
    setup_state_complete "work environment file is readable"
    template_file="$work_dir/env.zsh.example"
    if [[ -r "$template_file" ]]; then
      while IFS= read -r variable_name; do
        [[ -n "$variable_name" ]] || continue
        if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${variable_name}[[:space:]]*=[[:space:]]*(\"\"|'')[[:space:]]*(#.*)?$" "$work_dir/.env.zsh"; then
          setup_state_manual "work environment value $variable_name is empty in $work_dir/.env.zsh"
        fi
      done < <(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*""[[:space:]]*(#.*)?$/\2/p' "$template_file")
    fi
  else
    setup_state_fail "work environment file is missing: $work_dir/.env.zsh"
  fi

  setup_state_check "work Git config"
  if [[ ! -f "$work_dir/git/config" ]]; then
    setup_state_info "work overlay has no git/config"
  elif [[ -L "$DOTFILE_DIR/git/work.config" && "$(readlink "$DOTFILE_DIR/git/work.config")" == "$work_dir/git/config" ]]; then
    setup_state_complete "Git includes the work config: $work_dir/git/config"
  else
    setup_state_warn "Git does not include the work config: link $DOTFILE_DIR/git/work.config to $work_dir/git/config"
  fi
}

check_install_metadata() {
  local current_platform="$1"
  local current_os
  local expected_install_method

  current_os="$(setup_os_family "$current_platform")"
  expected_install_method="$(setup_install_method "$current_platform")"

  setup_state_check "setup install metadata"
  if [[ -z "$CONFIG_SETUP_OS" || -z "$CONFIG_SETUP_PLATFORM" || -z "$CONFIG_INSTALL_METHOD" ]]; then
    setup_state_warn "setup install metadata is missing; run ./setup.sh --fix to record it"
    return
  fi

  setup_state_complete "setup install metadata is present"
  setup_state_check "SETUP_OS metadata"
  [[ "$CONFIG_SETUP_OS" == "$current_os" ]] && setup_state_complete "SETUP_OS=$CONFIG_SETUP_OS" || setup_state_fail "SETUP_OS=$CONFIG_SETUP_OS does not match this host ($current_os)"
  setup_state_check "SETUP_PLATFORM metadata"
  [[ "$CONFIG_SETUP_PLATFORM" == "$current_platform" ]] && setup_state_complete "SETUP_PLATFORM=$CONFIG_SETUP_PLATFORM" || setup_state_fail "SETUP_PLATFORM=$CONFIG_SETUP_PLATFORM does not match this host ($current_platform)"
  setup_state_check "SETUP_INSTALL_METHOD metadata"
  [[ "$CONFIG_INSTALL_METHOD" == "$expected_install_method" ]] && setup_state_complete "SETUP_INSTALL_METHOD=$CONFIG_INSTALL_METHOD" || setup_state_fail "SETUP_INSTALL_METHOD=$CONFIG_INSTALL_METHOD does not match this host ($expected_install_method)"
}

check_dependencies() {
  local current_platform="$1"
  local default_python_venv
  local python_command
  local spec scope platform provider package check_type check_value label

  setup_collect_dependencies "$current_platform" "${CONFIG_WORK_ENV:-false}" "$CONFIG_JOB" "$CONFIG_WORK_ROOT"
  if [[ -n "$SETUP_WORK_DEPENDENCIES_ERROR" ]]; then
    SETUP_STATE_ACTION=""
    setup_state_check "work dependency declarations"
    setup_state_fail "$SETUP_WORK_DEPENDENCIES_ERROR"
  fi
  python_command="$(command -v python3 2>/dev/null || true)"
  default_python_venv="$(dirname "$LOCAL_ENV_FILE")/${CONFIG_JOB}-venv"
  if [[ -z "$CONFIG_PYTHON_VENV" && "$CONFIG_WORK_ENV" == true && -n "$CONFIG_JOB" && ${#SETUP_PYTHON_REQUIREMENTS[@]} -gt 0 ]]; then
    CONFIG_PYTHON_VENV="$default_python_venv"
  fi
  if [[ -n "$CONFIG_PYTHON_VENV" ]]; then
    python_command="$CONFIG_PYTHON_VENV/bin/python"
  fi

  for spec in "${SETUP_SELECTED_DEPENDENCIES[@]}"; do
    IFS='|' read -r scope platform provider package check_type check_value <<<"$spec"
    if [[ "$provider" == external ]]; then
      SETUP_STATE_ACTION=""
    else
      SETUP_STATE_ACTION="dependencies"
    fi
    label="$(setup_dependency_label "$package" "$check_type" "$check_value")"
    setup_state_check "$label"
    if setup_check_dependency "$package" "$check_type" "$check_value" "$REPO_DIR" "$python_command" "$provider"; then
      setup_state_complete "$label is available"
    elif [[ "$provider" == external ]]; then
      setup_state_manual "${SETUP_DEPENDENCY_FAILURE:-$label is unavailable}"
    elif [[ "$SETUP_DEPENDENCY_SEVERITY" == warning ]]; then
      SETUP_STATE_ACTION=""
      setup_state_warn "${SETUP_DEPENDENCY_FAILURE:-$label is unavailable}"
    else
      setup_state_fail "${SETUP_DEPENDENCY_FAILURE:-$label is unavailable}"
    fi
  done
  SETUP_STATE_ACTION="dependencies"
}

check_login_shell() {
  local brew_command
  local brew_prefix
  local target_zsh
  local account_shell

  setup_state_check "managed login shell"
  if [[ "$SETUP_STATE_PLATFORM" == macos ]]; then
    target_zsh=/bin/zsh
  else
    if ! setup_resolve_brew; then
      setup_state_fail "managed login shell cannot be determined because Homebrew is unavailable"
      return
    fi
    brew_command="$SETUP_BREW_BIN"
    if ! brew_prefix="$("$brew_command" --prefix 2>/dev/null)"; then
      setup_state_fail "managed login shell cannot be determined because the Homebrew prefix is unavailable"
      return
    fi
    target_zsh="$brew_prefix/bin/zsh"
  fi
  setup_state_complete "managed login shell is $target_zsh"

  setup_state_check "managed Zsh executable"
  if [[ -x "$target_zsh" ]]; then
    setup_state_complete "managed Zsh is executable: $target_zsh"
  else
    setup_state_fail "managed Zsh is missing or not executable: $target_zsh"
  fi
  setup_state_check "account login shell"
  if ! account_shell="$(setup_account_login_shell "$SETUP_STATE_PLATFORM")"; then
    setup_state_fail "account login shell could not be read from the platform account database"
  elif [[ "$account_shell" == "$target_zsh" ]]; then
    setup_state_complete "account login shell is $target_zsh"
    if [[ "${SHELL:-}" != "$target_zsh" ]]; then
      setup_state_info "a new login is needed before the current process uses $target_zsh"
    fi
  else
    setup_state_fail "account login shell is $account_shell; expected $target_zsh"
  fi
  setup_state_check "allowed login shells"
  if [[ ! -r "$SHELLS_FILE" ]]; then
    setup_state_fail "allowed-shells file is not readable: $SHELLS_FILE"
  elif grep -Fxq "$target_zsh" "$SHELLS_FILE"; then
    setup_state_complete "$target_zsh is listed in $SHELLS_FILE"
  else
    setup_state_fail "$target_zsh is missing from $SHELLS_FILE"
  fi
}

check_fzf_tab() {
  local install_dir="$HOME/.fzf-tab"
  local current_ref
  local insecure_path

  setup_state_check "fzf-tab installation"
  if [[ ! -d "$install_dir" ]]; then
    setup_state_fail "fzf-tab checkout is missing: $install_dir"
    return
  fi
  if [[ ! -d "$install_dir/.git" ]]; then
    setup_state_fail "fzf-tab installation is not a Git checkout: $install_dir"
    return
  fi
  if [[ ! -r "$install_dir/fzf-tab.plugin.zsh" ]]; then
    setup_state_fail "fzf-tab plugin file is missing: $install_dir/fzf-tab.plugin.zsh"
    return
  fi
  current_ref="$(git -C "$install_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$current_ref" == "$SETUP_FZF_TAB_REF" ]]; then
    setup_state_complete "fzf-tab is installed at pinned revision $SETUP_FZF_TAB_REF"
  else
    setup_state_fail "fzf-tab revision is ${current_ref:-unknown}; expected $SETUP_FZF_TAB_REF"
  fi
  setup_state_check "fzf-tab permissions"
  if ! insecure_path="$(setup_first_group_or_other_writable "$install_dir")"; then
    setup_state_fail "fzf-tab permissions could not be audited: $install_dir"
  elif [[ -n "$insecure_path" ]]; then
    setup_state_fail "fzf-tab path is group/other-writable: $insecure_path"
  else
    setup_state_complete "fzf-tab checkout has compaudit-safe permissions"
  fi
}

check_zj_radar() {
  local binary="$HOME/.local/bin/zj-radar"
  local expected_version="${SETUP_ZJ_RADAR_VERSION#v}"
  local current_version

  setup_state_check "zj-radar installation"
  if [[ ! -x "$binary" ]]; then
    setup_state_fail "zj-radar is missing or not executable: $binary"
    return
  fi
  current_version="$("$binary" --version 2>/dev/null || true)"
  if [[ "$current_version" == "zj-radar $expected_version" ]]; then
    setup_state_complete "zj-radar is installed at pinned version $SETUP_ZJ_RADAR_VERSION"
  else
    setup_state_fail "zj-radar version is ${current_version:-unknown}; expected $SETUP_ZJ_RADAR_VERSION"
  fi
}

check_macos_apps() {
  local current_platform="$1"
  local brew_command
  local installed
  local app

  [[ "$current_platform" == macos ]] || return 0
  setup_state_check "installed Homebrew casks"
  if ! setup_resolve_brew; then
    setup_state_fail "macOS applications cannot be checked because Homebrew is unavailable"
    return
  fi
  brew_command="$SETUP_BREW_BIN"
  if ! installed="$("$brew_command" list --cask 2>/dev/null)"; then
    setup_state_fail "installed Homebrew casks could not be queried"
    return
  fi
  setup_state_complete "installed Homebrew casks were queried"
  for app in "${SETUP_MACOS_APPS[@]}"; do
    setup_state_check "Homebrew cask $app"
    if grep -Fxq "$app" <<<"$installed"; then
      setup_state_complete "Homebrew cask $app is installed"
    else
      setup_state_fail "Homebrew cask $app is not installed"
    fi
  done
}

check_linux_fonts() {
  local current_platform="$1"
  local font_dir="$HOME/.local/share/fonts"
  local font
  local missing_fonts=()

  [[ "$current_platform" != macos ]] || return 0
  setup_state_check "managed MesloLGS Nerd Font files"
  for font in "${SETUP_LINUX_FONT_FILES[@]}"; do
    [[ -f "$font_dir/$font" ]] || missing_fonts+=("$font")
  done
  if [[ ${#missing_fonts[@]} -eq 0 ]]; then
    setup_state_complete "all ${#SETUP_LINUX_FONT_FILES[@]} managed MesloLGS Nerd Font files are installed"
  else
    setup_state_fail "managed Nerd Font files are missing from $font_dir: ${missing_fonts[*]}"
  fi
}

setup_state_scan() {
  local desired_work="${1:-}"
  local desired_job="${2:-}"
  local require_work="${3:-false}"
  local desired_work_root="${4:-}"
  local saved_work
  local saved_job

  setup_state_reset
  REQUIRE_WORK="$require_work"
  load_local_env_config
  saved_work="$CONFIG_WORK_ENV"
  saved_job="$CONFIG_JOB"
  [[ -n "$SETUP_WORK_ROOT" ]] && CONFIG_WORK_ROOT="$SETUP_WORK_ROOT"
  SETUP_STATE_PLATFORM="$(setup_detect_platform)"

  if [[ -n "$desired_work" ]]; then
    SETUP_STATE_AREA="Files and Paths"
    SETUP_STATE_ACTION="metadata"
    setup_state_check "selected setup scope"
    if [[ "$saved_work" != "$desired_work" || ( "$desired_work" == true && "$saved_job" != "$desired_job" ) ]] ||
      [[ "$desired_work" == true && -n "$desired_work_root" && "$CONFIG_WORK_ROOT" != "$desired_work_root" ]]; then
      setup_state_warn "saved setup scope does not match the requested scope"
    else
      setup_state_complete "saved setup scope matches the requested scope"
    fi
    CONFIG_WORK_ENV="$desired_work"
    CONFIG_JOB="$desired_job"
    [[ "$desired_work" == true && -n "$desired_work_root" ]] && CONFIG_WORK_ROOT="$desired_work_root"
  fi

  SETUP_STATE_AREA="Repository"
  SETUP_STATE_ACTION=""
  check_repo_sources
  SETUP_STATE_ACTION="hooks"
  check_git_hooks

  SETUP_STATE_AREA="Dependencies"
  SETUP_STATE_ACTION="dependencies"
  check_command brew
  check_dependencies "$SETUP_STATE_PLATFORM"

  SETUP_STATE_AREA="Codex"
  SETUP_STATE_ACTION="codex"
  check_codex_config "$SETUP_STATE_PLATFORM"

  SETUP_STATE_AREA="Files and Paths"
  SETUP_STATE_ACTION="metadata"
  check_install_metadata "$SETUP_STATE_PLATFORM"
  SETUP_STATE_ACTION="links"
  check_managed_links
  SETUP_STATE_ACTION="paths"
  check_path_entries

  SETUP_STATE_AREA="Shell and Plugins"
  SETUP_STATE_ACTION="shell"
  check_login_shell
  SETUP_STATE_ACTION="fzf"
  check_fzf_tab
  SETUP_STATE_ACTION="radar"
  check_zj_radar

  SETUP_STATE_AREA="Platform Assets"
  SETUP_STATE_ACTION="platform"
  check_macos_apps "$SETUP_STATE_PLATFORM"
  check_linux_fonts "$SETUP_STATE_PLATFORM"

  SETUP_STATE_AREA="Work Environment"
  SETUP_STATE_ACTION="work"
  check_work_environment

  (( FAILURES == 0 && WARNINGS == 0 ))
}
