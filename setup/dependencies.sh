#!/usr/bin/env bash
# Shared setup contract for the internal state and repair modules used by setup.sh.
#
# Fields:
#   scope|platform|provider|package|check type|check value
#
# Scopes are base, work, or work:<job>. Platforms are all, macos, ubuntu,
# redhat (Rocky/RHEL), or linux. Providers are brew, apt, dnf, python, system,
# and external. Keep this file compatible with the Bash 3.2 shipped by macOS.
#
# This file declares only base rows. A work overlay adds its own rows in
# $WORK_ROOT/$JOB/dependencies.sh (see setup_load_work_dependencies); a python
# row there names its requirements file by absolute path, usually under
# $WORK_DIR.

SETUP_HOME_LINKS=(.vim .vimrc .zshrc .zprofile .aliases .tmux.conf .p10k.zsh)
SETUP_CONFIG_LINKS=(nvim ghostty btop zellij git)
SETUP_USER_BIN_DIRS=(.local/bin)
SETUP_CODEX_CONFIG_SOURCE="dotfiles/codex/config.toml"
# Repository-relative hooks directory: pre-commit runs gitleaks, and commit-msg
# and pre-push check commit messages with .github/scripts/check_pr.sh.
SETUP_GIT_HOOKS_PATH=".githooks"
# The pre-commit secret scan uses `gitleaks git --timeout`, added in 8.29.0.
SETUP_GITLEAKS_MIN_VERSION="8.29.0"
SETUP_REQUIRED_REPO_FILES=(
  .githooks/pre-commit
  .githooks/commit-msg
  .githooks/pre-push
  .githooks/check-denylist
  .github/scripts/check_pr.sh
  bootstrap.sh
  setup.sh
  apps/awake/Info.plist
  apps/awake/Sources/Awake.swift
  apps/awake/build.sh
  apps/agent-workspace/Info.plist
  apps/agent-workspace/Main.swift
  dotfiles/.bin/agent-workspace
  dotfiles/.bin/awake
  dotfiles/.vim/colors/tokyonight-night.vim
  dotfiles/.bin/codex-turn-bell
  dotfiles/atuin/config.toml
  dotfiles/functions/atuin.zsh
  dotfiles/lib/toolbox.py
  dotfiles/lib/toolbox_catalog.py
  dotfiles/lib/toolbox_history.py
  dotfiles/lib/toolbox_secrets.py
  dotfiles/toolbox/personal.jsonl
  dotfiles/zellij/config.kdl
  dotfiles/zellij/layouts/default.kdl
  dotfiles/zellij/plugins/tab-picker.wasm
  apps/zj-radar/keyboard-navigation.patch
  dotfiles/zellij/plugins/zj_radar.wasm
  "$SETUP_CODEX_CONFIG_SOURCE"
  setup/repair.sh
  setup/state.sh
  setup/dependencies.sh
  setup/status_output.sh
  setup/symlink_helpers.sh
  setup/codex_config_helpers.sh
)
SETUP_MACOS_APPS=(
  chatgpt font-meslo-for-powerlevel10k font-symbols-only-nerd-font
  ghostty obsidian rectangle
)
SETUP_FZF_TAB_REPO="https://github.com/Aloxaf/fzf-tab"
SETUP_FZF_TAB_REF="fac145167f7ec1861233c54de0c8900b09c650fe"
SETUP_ZJ_RADAR_REPO="marktoda/zj-radar"
SETUP_ZJ_RADAR_VERSION="v0.4.1"
SETUP_ZJ_RADAR_SHA256_LINUX_X86_64="95ea06015a5e1c3e19cac3a093fffd986ef1ca593e58f076374700db9035aaa1"
SETUP_ZJ_RADAR_SHA256_LINUX_AARCH64="e11001bccffed29ca2a70c2f10dbc1e37d0ba2e157efdb4bf2607fad14f71ca8"
SETUP_ZJ_RADAR_SHA256_MACOS_AARCH64="17654c7319b7dc92459eeb430421d45fd23a9a38c12b0245930b99a907556f8f"
SETUP_ZJ_RADAR_WASM_SHA256="13bf8fbd6c6b5c1b15fb6f6d532b71c047062403aca6dd1e4e82ee4a50253338"
SETUP_LINUX_FONT_FILES=(
  "MesloLGS NF Regular.ttf"
  "MesloLGS NF Bold.ttf"
  "MesloLGS NF Italic.ttf"
  "MesloLGS NF Bold Italic.ttf"
)

SETUP_DEPENDENCIES=(
  "base|all|brew|atuin|command|atuin"
  "base|all|brew|bash|command|bash"
  "base|all|brew|bat|command|bat"
  "base|all|brew|btop|command|btop"
  "base|all|brew|eza|command|eza"
  "base|all|brew|fd|command|fd"
  "base|all|brew|fzf|command|fzf"
  "base|all|brew|fzf|command|fzf-tmux"
  "base|all|brew|gitleaks|command|gitleaks"
  "base|all|brew|glow|command|glow"
  "base|all|brew|jq|command|jq"
  "base|all|brew|neovim|command|nvim"
  "base|all|brew|parallel|command|parallel"
  "base|all|brew|pipx|command|pipx"
  "base|all|brew|python|command|python3"
  "base|all|brew|powerlevel10k|brew_file|share/powerlevel10k/powerlevel10k.zsh-theme"
  "base|all|brew|ripgrep|command|rg"
  "base|all|brew|tmux|command|tmux"
  "base|all|brew|tree|command|tree"
  "base|all|brew|watch|command|watch"
  "base|all|brew|yq|command|yq"
  "base|all|brew|zellij|command|zellij"
  "base|linux|brew|zsh|command|zsh"
  "base|all|brew|zsh-autosuggestions|brew_file|share/zsh-autosuggestions/zsh-autosuggestions.zsh"
  "base|all|brew|zsh-syntax-highlighting|brew_file|share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  "base|macos|brew|pylint|command|pylint"

  "base|macos|system|-|command|curl"
  "base|macos|system|-|command|git"
  "base|macos|system|-|command|ps"
  "base|macos|system|-|command|swiftc"
  "base|macos|system|-|command|codesign"
  "base|macos|system|-|command|plutil"
  "base|ubuntu|apt|curl|command|curl"
  "base|ubuntu|apt|git|command|git"
  "base|ubuntu|apt|procps|command|ps"
  "base|redhat|dnf|curl|command|curl"
  "base|redhat|dnf|git|command|git"
  "base|redhat|dnf|procps-ng|command|ps"
  "base|macos|system|-|command|lsof"
  "base|macos|system|-|command|/bin/zsh"
  "base|ubuntu|apt|lsof|command|lsof"
  "base|redhat|dnf|lsof|command|lsof"
)
SETUP_BASE_DEPENDENCIES=("${SETUP_DEPENDENCIES[@]}")
SETUP_WORK_DEPENDENCIES_ERROR=""

# Reset SETUP_DEPENDENCIES to the base rows, then append the rows declared by
# the work overlay at WORK_ROOT/JOB/dependencies.sh when one is configured. The
# overlay file runs with WORK_ROOT, JOB, and WORK_DIR set and appends to
# SETUP_DEPENDENCIES. A missing file adds nothing; a failing one sets
# SETUP_WORK_DEPENDENCIES_ERROR and returns 1.
setup_load_work_dependencies() {
  local work_root="$1"
  local job="$2"
  local file="$work_root/$job/dependencies.sh"

  SETUP_DEPENDENCIES=("${SETUP_BASE_DEPENDENCIES[@]}")
  SETUP_WORK_DEPENDENCIES_ERROR=""
  [[ -n "$work_root" && -n "$job" && -r "$file" ]] || return 0
  if ! WORK_ROOT="$work_root" JOB="$job" WORK_DIR="$work_root/$job" setup_source_work_dependencies "$file"; then
    SETUP_DEPENDENCIES=("${SETUP_BASE_DEPENDENCIES[@]}")
    SETUP_WORK_DEPENDENCIES_ERROR="work dependency file could not be loaded: $file"
    return 1
  fi
}

setup_source_work_dependencies() {
  # shellcheck source=/dev/null
  source "$1"
}

setup_detect_platform() {
  if [[ "${OSTYPE:-}" == "darwin"* ]]; then
    printf 'macos\n'
  elif [[ -f /etc/rocky-release ]]; then
    printf 'rocky\n'
  elif [[ -r /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release; then
    printf 'ubuntu\n'
  elif [[ -f /etc/redhat-release ]]; then
    printf 'rhel\n'
  else
    printf 'linux\n'
  fi
}

setup_os_family() {
  if [[ "$1" == "macos" ]]; then
    printf 'macos\n'
  else
    printf 'linux\n'
  fi
}

setup_install_method() {
  case "$1" in
  ubuntu) printf 'homebrew+apt\n' ;;
  rocky|rhel) printf 'homebrew+dnf\n' ;;
  *) printf 'homebrew\n' ;;
  esac
}

setup_zj_radar_target() {
  local current_platform="$1"
  local architecture

  architecture="$(uname -m)"
  case "$current_platform:$architecture" in
  macos:arm64|macos:aarch64) printf 'aarch64-apple-darwin\n' ;;
  ubuntu:x86_64|rocky:x86_64|rhel:x86_64) printf 'x86_64-unknown-linux-musl\n' ;;
  ubuntu:arm64|ubuntu:aarch64|rocky:arm64|rocky:aarch64|rhel:arm64|rhel:aarch64)
    printf 'aarch64-unknown-linux-musl\n'
    ;;
  *) return 1 ;;
  esac
}

setup_zj_radar_archive_sha256() {
  case "$1" in
  x86_64-unknown-linux-musl) printf '%s\n' "$SETUP_ZJ_RADAR_SHA256_LINUX_X86_64" ;;
  aarch64-unknown-linux-musl) printf '%s\n' "$SETUP_ZJ_RADAR_SHA256_LINUX_AARCH64" ;;
  aarch64-apple-darwin) printf '%s\n' "$SETUP_ZJ_RADAR_SHA256_MACOS_AARCH64" ;;
  *) return 1 ;;
  esac
}

# Succeeds when dotted version $1 is at least $2; missing parts count as 0.
setup_version_at_least() {
  local have="${1#v}." want="${2#v}." have_part want_part

  while [[ -n "$want" ]]; do
    have_part="${have%%.*}"
    want_part="${want%%.*}"
    have="${have#*.}"
    want="${want#*.}"
    [[ "$have_part" =~ ^[0-9]+$ ]] || return 1
    (( 10#$have_part > 10#$want_part )) && return 0
    (( 10#$have_part < 10#$want_part )) && return 1
    [[ -n "$have" ]] || have="0."
  done
}

# Succeeds when the gitleaks command $1 is older than SETUP_GITLEAKS_MIN_VERSION
# and stores its reported version in SETUP_GITLEAKS_VERSION.
setup_gitleaks_too_old() {
  SETUP_GITLEAKS_VERSION="$("$1" version 2>/dev/null)" || SETUP_GITLEAKS_VERSION=""
  ! setup_version_at_least "$SETUP_GITLEAKS_VERSION" "$SETUP_GITLEAKS_MIN_VERSION"
}

setup_file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Read the configured account login shell instead of the current process's
# potentially stale SHELL value. The override is reserved for isolated tests.
setup_account_login_shell() {
  local current_platform="$1"
  local account_name="${USER:-}"
  local account_record

  if [[ -n "${SETUP_ACCOUNT_SHELL_OVERRIDE:-}" ]]; then
    printf '%s\n' "$SETUP_ACCOUNT_SHELL_OVERRIDE"
    return 0
  fi
  [[ -n "$account_name" ]] || account_name="$(id -un 2>/dev/null)" || return 1

  if [[ "$current_platform" == macos ]]; then
    if account_record="$(dscl . -read "/Users/$account_name" UserShell 2>/dev/null)"; then
      account_record="${account_record#UserShell: }"
    elif command -v dscacheutil >/dev/null 2>&1; then
      account_record="$(dscacheutil -q user -a name "$account_name" 2>/dev/null | awk '$1 == "shell:" { print $2; exit }')"
    else
      return 1
    fi
  elif command -v getent >/dev/null 2>&1; then
    account_record="$(getent passwd "$account_name" 2>/dev/null)" || return 1
    account_record="${account_record##*:}"
  elif [[ -r /etc/passwd ]]; then
    account_record="$(awk -F: -v user="$account_name" '$1 == user { print $7; exit }' /etc/passwd)"
  fi

  [[ -n "${account_record:-}" ]] || return 1
  printf '%s\n' "$account_record"
}

setup_platform_supported() {
  case "$1" in
  macos|ubuntu|rocky|rhel) return 0 ;;
  *) return 1 ;;
  esac
}

setup_resolve_brew() {
  local brew_command

  if [[ -n "${SETUP_BREW_BIN:-}" && -x "$SETUP_BREW_BIN" ]]; then
    return 0
  fi
  if brew_command="$(command -v brew 2>/dev/null)" && [[ -n "$brew_command" ]]; then
    SETUP_BREW_BIN="$brew_command"
    return 0
  fi
  for brew_command in \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew \
    /home/linuxbrew/.linuxbrew/bin/brew
  do
    if [[ -x "$brew_command" ]]; then
      SETUP_BREW_BIN="$brew_command"
      return 0
    fi
  done
  return 1
}

setup_platform_matches() {
  local requested="$1"
  local current="$2"

  case "$requested" in
  all) return 0 ;;
  linux) [[ "$current" != "macos" ]] ;;
  redhat) [[ "$current" == "rocky" || "$current" == "rhel" ]] ;;
  *) [[ "$requested" == "$current" ]] ;;
  esac
}

setup_scope_matches() {
  local scope="$1"
  local work_env="$2"
  local job="$3"

  case "$scope" in
  base) return 0 ;;
  work) [[ "$work_env" == true ]] ;;
  work:*) [[ "$work_env" == true && "$job" == "${scope#work:}" ]] ;;
  *) return 1 ;;
  esac
}

setup_array_contains() {
  local expected="$1"
  shift
  local item

  for item in "$@"; do
    [[ "$item" == "$expected" ]] && return 0
  done
  return 1
}

# Print the first path below a directory that is writable by its group or by
# other users. An empty result means the tree satisfies Zsh's completion trust
# requirement used for the managed fzf-tab checkout.
setup_first_group_or_other_writable() {
  find "$1" \( -perm -0020 -o -perm -0002 \) -print -quit 2>/dev/null
}

# Populate provider-specific arrays for the requested host and setup scope.
setup_collect_dependencies() {
  local current_platform="$1"
  local work_env="$2"
  local job="$3"
  local work_root="${4:-}"
  local spec scope platform provider package check_type check_value

  if [[ "$work_env" == true ]]; then
    setup_load_work_dependencies "$work_root" "$job" || true
  else
    setup_load_work_dependencies "" ""
  fi

  SETUP_SELECTED_DEPENDENCIES=()
  SETUP_BREW_PACKAGES=()
  SETUP_APT_PACKAGES=()
  SETUP_DNF_PACKAGES=()
  SETUP_PYTHON_REQUIREMENTS=()

  for spec in "${SETUP_DEPENDENCIES[@]}"; do
    IFS='|' read -r scope platform provider package check_type check_value <<<"$spec"
    setup_platform_matches "$platform" "$current_platform" || continue
    setup_scope_matches "$scope" "$work_env" "$job" || continue
    SETUP_SELECTED_DEPENDENCIES+=("$spec")

    case "$provider" in
    brew)
      setup_array_contains "$package" ${SETUP_BREW_PACKAGES[@]+"${SETUP_BREW_PACKAGES[@]}"} || SETUP_BREW_PACKAGES+=("$package")
      ;;
    apt)
      setup_array_contains "$package" ${SETUP_APT_PACKAGES[@]+"${SETUP_APT_PACKAGES[@]}"} || SETUP_APT_PACKAGES+=("$package")
      ;;
    dnf)
      setup_array_contains "$package" ${SETUP_DNF_PACKAGES[@]+"${SETUP_DNF_PACKAGES[@]}"} || SETUP_DNF_PACKAGES+=("$package")
      ;;
    python)
      setup_array_contains "$package" ${SETUP_PYTHON_REQUIREMENTS[@]+"${SETUP_PYTHON_REQUIREMENTS[@]}"} || SETUP_PYTHON_REQUIREMENTS+=("$package")
      ;;
    esac
  done
}

setup_dependency_label() {
  local package="$1"
  local check_type="$2"
  local check_value="$3"

  case "$check_type" in
  command) printf 'command %s' "$check_value" ;;
  brew_file) printf 'Homebrew file %s (%s)' "$check_value" "$package" ;;
  imports) printf 'Python imports %s' "$check_value" ;;
  *) printf '%s %s' "$check_type" "$check_value" ;;
  esac
}

SETUP_BREW_CACHE_READY=false
SETUP_BREW_INSTALLED_FORMULAE=""
SETUP_BREW_PREFIX_READY=false
SETUP_BREW_PREFIX=""
SETUP_DEPENDENCY_FAILURE=""
SETUP_DEPENDENCY_SEVERITY="fail"

setup_reset_dependency_cache() {
  SETUP_BREW_CACHE_READY=false
  SETUP_BREW_INSTALLED_FORMULAE=""
  SETUP_BREW_PREFIX_READY=false
  SETUP_BREW_PREFIX=""
}

setup_cache_brew_prefix() {
  [[ "$SETUP_BREW_PREFIX_READY" == true ]] && return 0
  setup_resolve_brew || return 1
  if ! SETUP_BREW_PREFIX="$("$SETUP_BREW_BIN" --prefix 2>/dev/null)" || [[ -z "$SETUP_BREW_PREFIX" ]]; then
    SETUP_BREW_PREFIX=""
    return 1
  fi
  SETUP_BREW_PREFIX_READY=true
}

setup_brew_package_installed() {
  local package="$1"
  local brew_command
  local installed_formula

  setup_resolve_brew || return 1
  brew_command="$SETUP_BREW_BIN"
  if [[ "$SETUP_BREW_CACHE_READY" != true ]]; then
    SETUP_BREW_INSTALLED_FORMULAE="$("$brew_command" list --formula 2>/dev/null)" || return 1
    SETUP_BREW_CACHE_READY=true
  fi
  case $'\n'"$SETUP_BREW_INSTALLED_FORMULAE"$'\n' in
  *$'\n'"$package"$'\n'*) return 0 ;;
  esac

  # The `python` alias is listed by Homebrew under its versioned formula name.
  if [[ "$package" == python ]]; then
    for installed_formula in $SETUP_BREW_INSTALLED_FORMULAE; do
      case "$installed_formula" in
      python|python@[0-9]*) return 0 ;;
      esac
    done
  fi
  return 1
}

setup_provider_package_installed() {
  local provider="$1"
  local package="$2"

  case "$provider" in
  brew) setup_brew_package_installed "$package" ;;
  apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' ;;
  dnf) rpm -q "$package" >/dev/null 2>&1 ;;
  system|python|external) return 0 ;;
  *) return 1 ;;
  esac
}

# Return success when one dependency's runtime contract is satisfied.
setup_check_dependency() {
  local package="$1"
  local check_type="$2"
  local check_value="$3"
  local repo_dir="$4"
  local python_command="$5"
  local provider="$6"
  local active_command
  local brew_prefix

  SETUP_DEPENDENCY_FAILURE=""
  SETUP_DEPENDENCY_SEVERITY="fail"
  case "$check_type" in
  command)
    if ! active_command="$(command -v "$check_value" 2>/dev/null)" || [[ -z "$active_command" ]]; then
      if [[ "$provider" == external ]]; then
        SETUP_DEPENDENCY_FAILURE="external work prerequisite $check_value is missing (not installed by setup; provide it through the work environment)"
      elif [[ "$check_value" == gitleaks ]]; then
        SETUP_DEPENDENCY_FAILURE="command gitleaks is missing; the pre-commit secret scan needs gitleaks $SETUP_GITLEAKS_MIN_VERSION or newer (brew install gitleaks)"
      else
        SETUP_DEPENDENCY_FAILURE="command $check_value is missing"
      fi
      return 1
    fi
    if ! setup_provider_package_installed "$provider" "$package"; then
      case "$provider" in
      brew) SETUP_DEPENDENCY_FAILURE="Homebrew formula $package is not installed (command $check_value is present from another provider)" ;;
      apt) SETUP_DEPENDENCY_FAILURE="APT package $package is not installed (command $check_value is present from another provider)" ;;
      dnf) SETUP_DEPENDENCY_FAILURE="DNF package $package is not installed (command $check_value is present from another provider)" ;;
      *) SETUP_DEPENDENCY_FAILURE="provider requirement $provider:$package is not satisfied for command $check_value" ;;
      esac
      return 1
    fi
    if [[ "$provider" == brew ]]; then
      if ! setup_cache_brew_prefix; then
        SETUP_DEPENDENCY_FAILURE="Homebrew prefix could not be resolved"
        return 1
      fi
      case "$active_command" in
      "$SETUP_BREW_PREFIX/bin/"*|"$SETUP_BREW_PREFIX/sbin/"*) ;;
      *)
        SETUP_DEPENDENCY_SEVERITY="warning"
        SETUP_DEPENDENCY_FAILURE="command $check_value resolves to $active_command; expected Homebrew under $SETUP_BREW_PREFIX/bin or $SETUP_BREW_PREFIX/sbin; update PATH or start a new shell"
        return 1
        ;;
      esac
    fi
    if [[ "$check_value" == gitleaks ]] && setup_gitleaks_too_old "$active_command"; then
      SETUP_DEPENDENCY_FAILURE="gitleaks ${SETUP_GITLEAKS_VERSION:-of unknown version} is too old; the pre-commit secret scan needs $SETUP_GITLEAKS_MIN_VERSION or newer (brew upgrade gitleaks)"
      return 1
    fi
    ;;
  brew_file)
    if ! setup_provider_package_installed "$provider" "$package"; then
      SETUP_DEPENDENCY_FAILURE="Homebrew formula $package is not installed"
      return 1
    fi
    if ! setup_cache_brew_prefix; then
      SETUP_DEPENDENCY_FAILURE="Homebrew prefix could not be resolved"
      return 1
    fi
    brew_prefix="$SETUP_BREW_PREFIX"
    if [[ ! -r "$brew_prefix/$check_value" ]]; then
      SETUP_DEPENDENCY_FAILURE="Homebrew file $brew_prefix/$check_value is missing"
      return 1
    fi
    ;;
  imports)
    [[ "$package" == /* ]] || package="$repo_dir/$package"
    if [[ ! -r "$package" ]]; then
      SETUP_DEPENDENCY_FAILURE="Python requirements file $package is missing"
      return 1
    fi
    if [[ ! -x "$python_command" ]]; then
      SETUP_DEPENDENCY_FAILURE="Python environment ${python_command%/bin/python} is missing (required: $check_value)"
      return 1
    fi
    if ! "$python_command" -c 'import importlib, sys; [importlib.import_module(name) for name in sys.argv[1].split(",")]' "$check_value" >/dev/null 2>&1; then
      SETUP_DEPENDENCY_FAILURE="Python imports $check_value are missing from $python_command"
      return 1
    fi
    ;;
  *)
    SETUP_DEPENDENCY_FAILURE="unsupported dependency check type: $check_type"
    return 1
    ;;
  esac
}
