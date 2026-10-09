#!/usr/bin/env bash
# Managed repair operations. Source this module through ./setup.sh.

DRY_RUN=false
ALLOW_MISSING_EXTERNAL=true
SETUP_REPAIR_COMPACT=true

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTFILE_DIR="$SETUP_DIR/dotfiles"
LOCAL_ENV_DIR="$SETUP_DIR/.local"
LOCAL_ENV_FILE="${SETUP_LOCAL_ENV_FILE:-$LOCAL_ENV_DIR/.env.zsh}"
source "$SETUP_DIR/setup/dependencies.sh"
source "$SETUP_DIR/setup/symlink_helpers.sh"
source "$SETUP_DIR/setup/codex_config_helpers.sh"
source "$SETUP_DIR/setup/status_output.sh"

detect_platform() {
  PLATFORM="$(setup_detect_platform)"
  if ! setup_platform_supported "$PLATFORM"; then
    setup_status_fail "Unsupported operating system"
    setup_status_info "Supported: macOS, Rocky Linux 9.x, RHEL-family Linux, Ubuntu"
    return 1
  fi
  if [[ "$PLATFORM" == rocky ]] && ! grep -q "Rocky Linux release 9" /etc/rocky-release 2>/dev/null; then
    setup_status_warning "This script is tested on Rocky Linux 9.x"
  fi
}
# Note: set -e disabled due to issues with background processes and wait
# set -e          # Exit immediately if a command exits with a non-zero status

# Cleanup state for the install lock and active spinner task.
ACTIVE_TASK_PID=""
ACTIVE_OUTPUT_FILE=""
ACTIVE_CODEX_CONFIG_TEMP=""
ACTIVE_ZJ_RADAR_TEMP_DIR=""
ACTIVE_ZJ_RADAR_INSTALL_TEMP=""
INSTALL_LOCK_DIR="${SETUP_INSTALL_LOCK_DIR:-${TMPDIR:-/tmp}/setup-install-${UID}.lock}"
INSTALL_LOCK_HELD=false

release_install_lock() {
  [[ "$INSTALL_LOCK_HELD" == true ]] || return 0
  rm -f -- "$INSTALL_LOCK_DIR/pid"
  rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
  INSTALL_LOCK_HELD=false
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  setup_status_clear

  if [[ -n "$ACTIVE_TASK_PID" ]]; then
    kill -TERM "$ACTIVE_TASK_PID" 2>/dev/null || true
    wait "$ACTIVE_TASK_PID" 2>/dev/null || true
    ACTIVE_TASK_PID=""
  fi
  if [[ -n "$ACTIVE_OUTPUT_FILE" ]]; then
    rm -f -- "$ACTIVE_OUTPUT_FILE"
    ACTIVE_OUTPUT_FILE=""
  fi
  if [[ -n "$ACTIVE_CODEX_CONFIG_TEMP" ]]; then
    rm -f -- "$ACTIVE_CODEX_CONFIG_TEMP"
    ACTIVE_CODEX_CONFIG_TEMP=""
  fi
  if [[ -n "$ACTIVE_ZJ_RADAR_INSTALL_TEMP" ]]; then
    rm -f -- "$ACTIVE_ZJ_RADAR_INSTALL_TEMP"
    ACTIVE_ZJ_RADAR_INSTALL_TEMP=""
  fi
  if [[ -n "$ACTIVE_ZJ_RADAR_TEMP_DIR" ]]; then
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
  fi
  if [[ -n "${SETUP_CODEX_VALIDATION_TEMP:-}" ]]; then
    rm -rf -- "$SETUP_CODEX_VALIDATION_TEMP"
    SETUP_CODEX_VALIDATION_TEMP=""
  fi
  release_install_lock
  return "$status"
}

handle_signal() {
  exit "$1"
}

acquire_install_lock() {
  local owner_pid=""

  if mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    INSTALL_LOCK_HELD=true
    printf '%s\n' "$$" >"$INSTALL_LOCK_DIR/pid"
    return 0
  fi

  [[ -r "$INSTALL_LOCK_DIR/pid" ]] && owner_pid="$(sed -n '1p' "$INSTALL_LOCK_DIR/pid")"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    setup_status_fail "Another setup repair is already running with PID $owner_pid."
    return 3
  fi

  rm -f -- "$INSTALL_LOCK_DIR/pid"
  if ! rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || ! mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    setup_status_fail "Could not acquire setup repair lock: $INSTALL_LOCK_DIR"
    return 3
  fi
  INSTALL_LOCK_HELD=true
  printf '%s\n' "$$" >"$INSTALL_LOCK_DIR/pid"
}

# =====[ Config ]==============================================================
PLATFORM=""
SETUP_OS=""
SETUP_INSTALL_METHOD=""
SETUP_PYTHON_VENV=""
WORK_ROOT=""
WORK_DIR=""
WORK_BIN=""
BREW_BIN=""
SETUP_BREW_BIN=""

initialize_configuration() {
  SETUP_OS="$(setup_os_family "$PLATFORM")"
  SETUP_INSTALL_METHOD="$(setup_install_method "$PLATFORM")"
  WORK_ROOT=""
  [[ "$WORK_ENV" == true ]] && WORK_ROOT="${SETUP_REPAIR_WORK_ROOT:-}"
  setup_collect_dependencies "$PLATFORM" "$WORK_ENV" "${JOB:-}" "$WORK_ROOT"

  SETUP_PYTHON_VENV=""
  if [[ ${#SETUP_PYTHON_REQUIREMENTS[@]} -gt 0 ]]; then
    SETUP_PYTHON_VENV="$LOCAL_ENV_DIR/${JOB}-venv"
  fi
  if [[ "$WORK_ENV" == true ]]; then
    WORK_DIR="$WORK_ROOT/$JOB"
    WORK_BIN="$WORK_DIR/bin-$JOB"
  fi
}

validate_repo_sources() {
  local item

  for item in "${SETUP_HOME_LINKS[@]}"; do
    [[ -e "$DOTFILE_DIR/$item" ]] || fail "Tracked dotfile source is missing: $DOTFILE_DIR/$item"
  done
  for item in "${SETUP_CONFIG_LINKS[@]}"; do
    [[ -d "$DOTFILE_DIR/$item" ]] || fail "Tracked config source is missing: $DOTFILE_DIR/$item"
  done
  for item in "${SETUP_REQUIRED_REPO_FILES[@]}"; do
    [[ -f "$SETUP_DIR/$item" ]] || fail "Tracked setup file is missing: $SETUP_DIR/$item"
  done
  ((${#FAILED_TASKS[@]} == 0))
}

# Array to track failed tasks for the summary report
FAILED_TASKS=()

# =====[ Colors / Helpers ]=====================================================
# Helper functions for colored output and status messages.
LAST_SPINNER_FAILURE_OUTPUT=""

print_spinner_failure_output() {
  [[ -n "$LAST_SPINNER_FAILURE_OUTPUT" ]] || return 0
  printf '%s\n' "$LAST_SPINNER_FAILURE_OUTPUT" | tail -n 20 | sed 's/^/  | /'
  LAST_SPINNER_FAILURE_OUTPUT=""
}

info() {
  [[ "$SETUP_REPAIR_COMPACT" == true ]] || setup_status_info "$1"
  print_spinner_failure_output
}
warn() {
  setup_status_warning "$1"
  print_spinner_failure_output
}
fail() {
  setup_status_fail "$1"
  print_spinner_failure_output
  FAILED_TASKS+=("$1")
}
pass() {
  [[ "$DRY_RUN" == true || "$SETUP_REPAIR_COMPACT" == true ]] && return 0
  setup_status_pass "$1"
}
header() {
  [[ "$SETUP_REPAIR_COMPACT" == true ]] || setup_status_section "$1"
}
dry() {
  setup_status_action "Would: $1"
}

# Resolve Homebrew once and activate its environment for this process.
activate_brew() {
  local brew_command

  [[ -n "$BREW_BIN" && -x "$BREW_BIN" ]] && return 0
  setup_resolve_brew || return 1
  brew_command="$SETUP_BREW_BIN"
  eval "$("$brew_command" shellenv)"
  BREW_BIN="$(command -v brew 2>/dev/null || printf '%s' "$brew_command")"
  SETUP_BREW_BIN="$BREW_BIN"
}

# =====[ Spinner ]=============================================================
# Displays a spinner animation while a command runs in the background.
# Usage: run_spinner "Message" command args...
# Output of the command is captured in a temp file for later inspection.
# In dry-run mode, just prints what would be executed.
run_spinner() {
  local msg="$1"
  local status
  shift
  LAST_SPINNER_FAILURE_OUTPUT=""

  # In dry-run mode, just show what would happen
  if [[ "$DRY_RUN" == true ]]; then
    dry "$msg"
    return 0
  fi

  ACTIVE_OUTPUT_FILE="$(mktemp)"
  if [[ -z "$ACTIVE_OUTPUT_FILE" ]]; then
    LAST_SPINNER_FAILURE_OUTPUT="Could not create temporary output file."
    return 1
  fi

  setup_status_start "$msg"
  # Run the command in the background, redirecting output
  "$@" &>"$ACTIVE_OUTPUT_FILE" &
  ACTIVE_TASK_PID=$!

  # Wait for the process to finish and capture exit status
  if wait "$ACTIVE_TASK_PID"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_TASK_PID=""
  if [[ $status -ne 0 ]]; then
    LAST_SPINNER_FAILURE_OUTPUT="$(tail -n 20 "$ACTIVE_OUTPUT_FILE")"
  fi
  rm -f -- "$ACTIVE_OUTPUT_FILE"
  ACTIVE_OUTPUT_FILE=""
  return "$status"
}

# Refresh sudo in the foreground so background tasks never wait on a prompt.
run_sudo_spinner() {
  local msg="$1"
  shift

  if [[ "$DRY_RUN" != true ]] && ! sudo -v; then
    LAST_SPINNER_FAILURE_OUTPUT="sudo authentication failed"
    return 1
  fi
  run_spinner "$msg" sudo "$@"
}

# =====[ Setup Functions ]=====================================================
# Creates directory structure for work-related files if WORK_ENV is true.
create_work_dir() {
  local directory
  local file
  local environment_file="$WORK_DIR/.env.zsh"
  local environment_template="$WORK_DIR/env.zsh.example"
  local environment_temporary=""

  header "Creating work directory"
  if [[ "$WORK_ENV" != true ]]; then
    info "WORK_ENV disabled — skipping"
    return 0
  fi

  for directory in "$WORK_DIR" "$WORK_BIN"; do
    if [[ -d "$directory" ]]; then
      info "$directory already exists"
    elif [[ "$DRY_RUN" == true ]]; then
      dry "Create directory $directory"
    elif mkdir -p "$directory"; then
      pass "Created $directory"
    else
      fail "Failed to create $directory"
    fi
  done

  for file in "$WORK_BIN/functions-$JOB.sh" "$WORK_DIR/.aliases-$JOB"; do
    if [[ -f "$file" ]]; then
      info "$file already exists"
    elif [[ "$DRY_RUN" == true ]]; then
      dry "Create file $file"
    elif touch "$file"; then
      pass "Created $file"
    else
      fail "Failed to create $file"
    fi
  done

  link_work_git_config

  if [[ -e "$environment_file" || -L "$environment_file" ]]; then
    info "$environment_file already exists"
  elif [[ "$DRY_RUN" == true && -f "$environment_template" ]]; then
    dry "Copy $environment_template to $environment_file with mode 600"
  elif [[ "$DRY_RUN" == true ]]; then
    dry "Create empty $environment_file with mode 600"
  else
    environment_temporary="$(mktemp "$WORK_DIR/.env.zsh.XXXXXX")" || {
      fail "Failed to stage $environment_file"
      return 1
    }
    if [[ -f "$environment_template" ]]; then
      cp "$environment_template" "$environment_temporary" || {
        rm -f -- "$environment_temporary"
        fail "Failed to stage $environment_file"
        return 1
      }
    fi
    chmod 600 "$environment_temporary" || {
      rm -f -- "$environment_temporary"
      fail "Failed to secure $environment_file"
      return 1
    }
    if ln "$environment_temporary" "$environment_file" 2>/dev/null; then
      rm -f -- "$environment_temporary"
      if [[ -f "$environment_template" ]]; then
        pass "Copied $environment_template to $environment_file with mode 600"
      else
        pass "Created $environment_file with mode 600"
      fi
    else
      rm -f -- "$environment_temporary"
      info "$environment_file appeared during setup and was preserved"
    fi
  fi
}

# Points dotfiles/git/work.config, which dotfiles/git/config includes, at the
# work overlay's git/config. Nothing happens when the overlay has none.
link_work_git_config() {
  local source="$WORK_DIR/git/config"
  local link="$DOTFILE_DIR/git/work.config"

  [[ -f "$source" ]] || return 0
  if [[ -L "$link" && "$(readlink "$link")" == "$source" ]]; then
    info "$link already points to $source"
  elif [[ -e "$link" && ! -L "$link" ]]; then
    fail "$link is not a symlink; move it aside and rerun"
  elif [[ "$DRY_RUN" == true ]]; then
    dry "Link $link to $source"
  elif ln -sfn "$source" "$link"; then
    pass "Linked $link to $source"
  else
    fail "Failed to link $link to $source"
  fi
}

# Creates the user-local binary directories added to PATH by dotfiles/.zshrc.
ensure_managed_path_dirs() {
  local relative_path
  local directory

  header "Creating setup-managed PATH directories"
  for relative_path in "${SETUP_USER_BIN_DIRS[@]}"; do
    directory="$HOME/$relative_path"
    if [[ -d "$directory" ]]; then
      info "$directory already exists"
    elif [[ "$DRY_RUN" == true ]]; then
      dry "Create directory $directory"
    elif mkdir -p "$directory"; then
      pass "Created $directory"
    else
      fail "Failed to create $directory"
    fi
  done
}

# Writes local per-machine environment choices for .zshrc to source.
write_local_env_config() {
  local expected

  header "Writing local environment configuration"
  expected="$({
    echo "# Local setup environment. Generated by ./setup.sh --fix."
    printf 'export SETUP_OS=%q\n' "$SETUP_OS"
    printf 'export SETUP_PLATFORM=%q\n' "$PLATFORM"
    printf 'export SETUP_INSTALL_METHOD=%q\n' "$SETUP_INSTALL_METHOD"
    echo "WORK_ENV=$WORK_ENV"
    [[ "$WORK_ENV" == true ]] && echo "JOB=$JOB"
    [[ "$WORK_ENV" == true ]] && printf 'WORK_ROOT=%q\n' "$WORK_ROOT"
    [[ -n "$SETUP_PYTHON_VENV" ]] && printf 'export SETUP_PYTHON_VENV=%q\n' "$SETUP_PYTHON_VENV"
  })"

  if [[ -r "$LOCAL_ENV_FILE" && "$(cat "$LOCAL_ENV_FILE")" == "$expected" ]]; then
    info "$LOCAL_ENV_FILE already matches the selected setup"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$WORK_ENV" == true ]]; then
      dry "Write $LOCAL_ENV_FILE with WORK_ENV=true, JOB=$JOB, WORK_ROOT=$WORK_ROOT, and setup metadata"
    else
      dry "Write $LOCAL_ENV_FILE with WORK_ENV=false and setup metadata"
    fi
    return 0
  fi

  mkdir -p "$LOCAL_ENV_DIR"
  printf '%s\n' "$expected" >"$LOCAL_ENV_FILE"

  if [[ -f "$LOCAL_ENV_FILE" ]]; then
    pass "Wrote $LOCAL_ENV_FILE"
  else
    fail "Failed to write $LOCAL_ENV_FILE"
  fi
}

# Links dotfiles from the repo to the user's home directory.
# Backs up every existing destination that is not already the expected symlink.
symlink_setup() {
  header "Linking dotfiles from $DOTFILE_DIR → ~/"
  local backup_dir="$HOME/.dotfiles-backup"
  local backup_stamp
  backup_stamp="$(date +%Y%m%d%H%M%S)"

  for file in "${SETUP_HOME_LINKS[@]}"; do
    local src="$DOTFILE_DIR/$file"
    local dest="$HOME/$file"
    local backup="$backup_dir/$file.$backup_stamp"

    link_managed_path "$file" "$src" "$dest" "$backup"
  done
}

install_homebrew_prerequisites() {
  case "$PLATFORM" in
  macos)
    return 0
    ;;
  ubuntu)
    run_sudo_spinner "Updating apt package metadata for Homebrew" apt-get update &&
      run_sudo_spinner "Installing Homebrew system dependencies" \
        apt-get install -y build-essential procps curl file git locales
    ;;
  rocky|rhel)
    run_sudo_spinner "Installing Homebrew development tools" dnf groupinstall -y "Development Tools" &&
      run_sudo_spinner "Installing Homebrew system dependencies" \
        dnf install -y procps-ng curl file git glibc-langpack-en
    ;;
  esac
}

# Installs Homebrew on every supported platform.
install_package_manager() {
  local locale_command=()

  header "Checking Homebrew installation"

  if activate_brew; then
    info "Homebrew already installed"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    dry "Install Homebrew"
    return 0
  fi
  if ! install_homebrew_prerequisites; then
    fail "Homebrew system dependencies failed"
    return 1
  fi
  [[ "$PLATFORM" != macos ]] && pass "Homebrew system dependencies installed"

  if [[ "$PLATFORM" != macos ]] && ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    if [[ "$PLATFORM" == ubuntu ]]; then
      locale_command=(locale-gen en_US.UTF-8)
    else
      locale_command=(localedef -i en_US -f UTF-8 en_US.UTF-8)
    fi
    if run_sudo_spinner "Generating en_US.UTF-8 locale" "${locale_command[@]}"; then
      pass "en_US.UTF-8 locale available"
    else
      warn "Could not generate en_US.UTF-8 locale"
    fi
  fi

  if ! run_spinner "Installing Homebrew" bash -c \
    'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; then
    fail "Homebrew installation failed"
    return 1
  fi
  pass "Homebrew installed"
  if ! activate_brew; then
    fail "Homebrew installed but its executable could not be located"
    return 1
  fi
}

# Uses macOS's system Zsh and Linuxbrew Zsh as the managed login shells.
configure_zsh_shell() {
  header "Setting zsh as default shell"

  local target_zsh
  local brew_prefix
  local account_shell
  local shells_file="${SETUP_SHELLS_FILE:-/etc/shells}"
  if [[ "$PLATFORM" == macos ]]; then
    target_zsh=/bin/zsh
  else
    if ! activate_brew || ! brew_prefix="$("$BREW_BIN" --prefix 2>/dev/null)"; then
      warn "Homebrew is unavailable; default shell was not changed"
      return 0
    fi
    target_zsh="$brew_prefix/bin/zsh"
  fi

  if [[ ! -x "$target_zsh" ]]; then
    info "Managed zsh is not yet installed: $target_zsh"
    return 0
  fi

  account_shell="$(setup_account_login_shell "$PLATFORM" 2>/dev/null || true)"
  if ! grep -Fxq "$target_zsh" "$shells_file" 2>/dev/null; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Add $target_zsh to $shells_file"
    elif run_sudo_spinner "Adding $target_zsh to allowed shells" \
      sh -c 'printf "%s\n" "$1" >> "$2"' sh "$target_zsh" "$shells_file"; then
      pass "Shell added to $shells_file"
    else
      fail "Failed to add shell to $shells_file"
      return 1
    fi
  fi

  if [[ "$account_shell" != "$target_zsh" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Change default shell to $target_zsh"
    elif [[ "$PLATFORM" == macos ]]; then
      setup_status_action "Change default shell to $target_zsh"
      printf '   macOS may ask for your login password; typed characters will not be displayed.\n'
      if chsh -s "$target_zsh"; then
        pass "Shell changed to zsh"
      else
        fail "Failed to change shell"
      fi
    else
      if run_sudo_spinner "Changing default shell" usermod -s "$target_zsh" "$USER"; then
        pass "Shell changed to zsh"
      else
        fail "Failed to change shell"
      fi
    fi
  else
    info "zsh is already the default shell"
  fi
}

system_package_installed() {
  case "$1" in
  apt) dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q 'ok installed' ;;
  dnf) rpm -q "$2" >/dev/null 2>&1 ;;
  esac
}

run_system_package_install() {
  local manager="$1"
  local message="$2"
  shift 2

  case "$manager" in
  apt) run_sudo_spinner "$message" apt-get install -y "$@" ;;
  dnf) run_sudo_spinner "$message" dnf install -y "$@" ;;
  esac
}

# Installs selected Linux system packages that provide required local commands.
install_system_packages() {
  local manager
  local packages=()
  local to_install=()
  local package

  case "$PLATFORM" in
  ubuntu)
    manager="apt"
    packages=("${SETUP_APT_PACKAGES[@]}")
    ;;
  rocky|rhel)
    manager="dnf"
    packages=("${SETUP_DNF_PACKAGES[@]}")
    ;;
  esac

  [[ ${#packages[@]} -gt 0 ]] || return 0
  header "Installing system dependencies"

  for package in "${packages[@]}"; do
    if system_package_installed "$manager" "$package"; then
      info "$package already installed"
    else
      to_install+=("$package")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    info "All system dependencies are already installed"
    return 0
  fi

  if [[ "$manager" == apt ]]; then
    if ! run_sudo_spinner "Updating apt package metadata" apt-get update; then
      fail "apt package metadata update failed"
      return 1
    fi
  fi

  if run_system_package_install "$manager" \
    "Installing ${#to_install[@]} system packages: ${to_install[*]}" "${to_install[@]}"; then
    for package in "${to_install[@]}"; do
      pass "$package installed"
    done
    return 0
  fi

  # A missing package must not prevent available packages from being installed.
  warn "Batch system-package installation failed; retrying packages individually"
  for package in "${to_install[@]}"; do
    if run_system_package_install "$manager" "Installing system package $package" "$package"; then
      pass "$package installed"
    else
      fail "$package installation failed"
    fi
  done
}

# Installs manifest-selected CLI packages via Homebrew on every platform.
install_packages() {
  header "Installing CLI packages"
  activate_brew || true

  local packages=("${SETUP_BREW_PACKAGES[@]}")
  local brew_command="${BREW_BIN:-brew}"
  local package

  if [[ -z "$BREW_BIN" && "$DRY_RUN" != true ]]; then
    fail "Homebrew is unavailable; CLI packages were not installed"
    return 1
  fi

  setup_reset_dependency_cache
  local to_install=()
  local gitleaks_command
  for package in "${packages[@]}"; do
    if ! setup_brew_package_installed "$package"; then
      to_install+=("$package")
    elif [[ "$package" == gitleaks ]] &&
      gitleaks_command="$(command -v gitleaks 2>/dev/null)" &&
      setup_gitleaks_too_old "$gitleaks_command"; then
      if ! run_spinner "Upgrading gitleaks $SETUP_GITLEAKS_VERSION to $SETUP_GITLEAKS_MIN_VERSION or newer" \
        "$brew_command" upgrade gitleaks; then
        fail "gitleaks upgrade failed; the pre-commit secret scan needs $SETUP_GITLEAKS_MIN_VERSION or newer"
      fi
    else
      info "$package already installed"
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    info "All CLI packages are already installed"
    return 0
  fi

  # Batch install for faster dependency resolution
  if run_spinner "Installing ${#to_install[@]} packages: ${to_install[*]}" \
    "$brew_command" install "${to_install[@]}"; then
    setup_reset_dependency_cache
    for package in "${to_install[@]}"; do
      pass "$package installed"
    done
    return 0
  fi

  # Retry separately so an unavailable formula cannot block available ones.
  warn "Batch Homebrew installation failed; retrying formulae individually"
  setup_reset_dependency_cache
  for package in "${to_install[@]}"; do
    if setup_brew_package_installed "$package"; then
      pass "$package installed"
      continue
    fi
    if run_spinner "Installing Homebrew package $package" "$brew_command" install "$package"; then
      setup_reset_dependency_cache
      pass "$package installed"
    else
      fail "$package installation failed or is unavailable"
    fi
  done
}

# Creates a repo-local Python environment for selected work-tool requirements.
install_python_dependencies() {
  [[ ${#SETUP_PYTHON_REQUIREMENTS[@]} -gt 0 ]] || return 0
  header "Installing Python dependencies"

  local requirements
  if [[ ! -x "$SETUP_PYTHON_VENV/bin/python" ]]; then
    if [[ "$DRY_RUN" != true ]]; then
      mkdir -p "$LOCAL_ENV_DIR"
    fi
    if ! run_spinner "Creating Python environment at $SETUP_PYTHON_VENV" python3 -m venv "$SETUP_PYTHON_VENV"; then
      fail "Could not create Python environment at $SETUP_PYTHON_VENV"
      return 1
    fi
  else
    info "Python environment already exists at $SETUP_PYTHON_VENV"
  fi

  for requirements in "${SETUP_PYTHON_REQUIREMENTS[@]}"; do
    [[ "$requirements" == /* ]] || requirements="$SETUP_DIR/$requirements"
    if [[ ! -r "$requirements" ]]; then
      fail "Python requirements file is missing: $requirements"
      continue
    fi
    if run_spinner "Installing Python dependencies from $requirements" \
      "$SETUP_PYTHON_VENV/bin/python" -m pip install --disable-pip-version-check -r "$requirements"; then
      pass "$requirements installed"
    else
      fail "$requirements installation failed"
    fi
  done
}

# Verifies every selected dependency against the same contract used to install it.
verify_dependencies() {
  header "Verifying setup dependencies"
  if [[ "$DRY_RUN" == true ]]; then
    dry "Verify selected commands, sourced files, and Python imports"
    return 0
  fi

  activate_brew || true
  local python_command
  python_command="$(command -v python3 2>/dev/null || true)"
  [[ -n "$SETUP_PYTHON_VENV" ]] && python_command="$SETUP_PYTHON_VENV/bin/python"

  local spec scope platform provider package check_type check_value label
  for spec in "${SETUP_SELECTED_DEPENDENCIES[@]}"; do
    IFS='|' read -r scope platform provider package check_type check_value <<<"$spec"
    [[ "$provider" == external && "$ALLOW_MISSING_EXTERNAL" == true ]] && continue
    label="$(setup_dependency_label "$package" "$check_type" "$check_value")"
    setup_status_start "$label"
    if setup_check_dependency "$package" "$check_type" "$check_value" "$SETUP_DIR" "$python_command" "$provider"; then
      pass "$label is available"
    elif [[ "$SETUP_DEPENDENCY_SEVERITY" == warning ]]; then
      warn "${SETUP_DEPENDENCY_FAILURE:-$label is unavailable after installation}"
    else
      fail "${SETUP_DEPENDENCY_FAILURE:-$label is unavailable after installation}"
    fi
  done
}

# Installs defined GUI applications (macOS only via Homebrew Cask).
install_apps() {
  # Skip GUI apps on Linux
  if [[ "$PLATFORM" != macos ]]; then
    header "Skipping GUI apps (Linux CLI-only mode)"
    return 0
  fi

  header "Installing GUI apps"
  local apps=("${SETUP_MACOS_APPS[@]}")
  local brew_command="${BREW_BIN:-brew}"
  local rectangle_app_path="${SETUP_RECTANGLE_APP_PATH:-/Applications/Rectangle.app}"
  local plutil_command="${SETUP_PLUTIL_BIN:-/usr/bin/plutil}"

  # Query installed casks once instead of per-app
  local installed
  installed=$("$brew_command" list --cask 2>/dev/null)

  local rectangle_bundle_id=""
  if ! grep -qx rectangle <<<"$installed" &&
    [[ -e "$rectangle_app_path" || -L "$rectangle_app_path" ]]; then
    if [[ ! -d "$rectangle_app_path" || -L "$rectangle_app_path" ]] ||
      ! rectangle_bundle_id="$("$plutil_command" -extract CFBundleIdentifier raw -o - \
        "$rectangle_app_path/Contents/Info.plist" 2>/dev/null)" ||
      [[ "$rectangle_bundle_id" != com.knollsoft.Rectangle ]]; then
      fail "Existing $rectangle_app_path is not the expected Rectangle app (bundle ${rectangle_bundle_id:-unknown}); refusing to overwrite it"
      return 1
    fi
    if ! run_spinner "Replacing the existing Rectangle app with the Homebrew cask" \
      "$brew_command" install --cask --force rectangle; then
      fail "rectangle takeover failed"
      return 1
    fi
    pass "rectangle replaced with the Homebrew-managed app"
    installed="${installed}"$'\nrectangle'
  fi

  local to_install=()
  for app in "${apps[@]}"; do
    if grep -qx "$app" <<<"$installed"; then
      info "$app already installed"
    else
      to_install+=("$app")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    info "All GUI apps are already installed"
    return 0
  fi

  # Batch install for fewer brew invocations
  if run_spinner "Installing ${#to_install[@]} apps: ${to_install[*]}" \
    "$brew_command" install --cask "${to_install[@]}"; then
    for app in "${to_install[@]}"; do
      pass "$app installed"
    done
  else
    # Some failed — check which ones individually
    warn "Batch cask installation failed; checking installed casks"
    local now_installed
    now_installed=$("$brew_command" list --cask 2>/dev/null)
    for app in "${to_install[@]}"; do
      if grep -qx "$app" <<<"$now_installed"; then
        pass "$app installed"
      else
        fail "$app installation failed"
      fi
    done
  fi
}

secure_fzf_tab_permissions() {
  local install_dir="$1"
  local insecure_path

  if insecure_path="$(setup_first_group_or_other_writable "$install_dir")" && [[ -z "$insecure_path" ]]; then
    info "fzf-tab completion permissions are already secure"
    return 0
  fi
  if [[ ! -d "$install_dir" && "$DRY_RUN" != true ]]; then
    fail "Failed to audit fzf-tab permissions in $install_dir"
    return 1
  fi
  if ! run_spinner "Securing fzf-tab completion permissions" \
    chmod -R go-w "$install_dir"; then
    fail "Failed to remove group/other write access from $install_dir"
    return 1
  fi
  [[ "$DRY_RUN" == true ]] && return 0
  if ! insecure_path="$(setup_first_group_or_other_writable "$install_dir")"; then
    fail "Failed to audit fzf-tab permissions in $install_dir"
    return 1
  fi
  if [[ "$DRY_RUN" != true && -n "$insecure_path" ]]; then
    fail "fzf-tab path is group/other-writable after repair: $insecure_path"
    return 1
  fi
  pass "fzf-tab completion permissions are secure"
}

# Points this checkout at the tracked hooks, which scan commits for secrets and
# check commit messages.
configure_git_hooks() {
  local current

  header "Configuring repository Git hooks"
  current="$(git -C "$SETUP_DIR" config --local --get core.hooksPath 2>/dev/null || true)"
  if [[ "$current" == "$SETUP_GIT_HOOKS_PATH" ]]; then
    info "Git hooks already use $SETUP_GIT_HOOKS_PATH"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    dry "Set core.hooksPath to $SETUP_GIT_HOOKS_PATH in $SETUP_DIR"
    return 0
  fi
  if git -C "$SETUP_DIR" config --local core.hooksPath "$SETUP_GIT_HOOKS_PATH"; then
    pass "Git hooks now use $SETUP_GIT_HOOKS_PATH"
  else
    fail "Could not set core.hooksPath in $SETUP_DIR"
    return 1
  fi
}

# Installs fzf-tab (fuzzy completion for zsh) and enforces compaudit-safe modes.
install_fzf_tab() {
  local install_dir="$HOME/.fzf-tab"
  local current_ref=""

  header "Installing fzf-tab"
  if [[ -d "$install_dir" ]]; then
    if [[ ! -d "$install_dir/.git" ]]; then
      fail "Existing $install_dir is not a Git checkout; fzf-tab was not replaced"
      return 1
    fi
    current_ref="$(git -C "$install_dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$current_ref" == "$SETUP_FZF_TAB_REF" && -r "$install_dir/fzf-tab.plugin.zsh" ]]; then
      info "fzf-tab is already installed at the pinned revision"
      secure_fzf_tab_permissions "$install_dir"
      return $?
    fi
    if ! run_spinner "Fetching pinned fzf-tab revision" \
      git -C "$install_dir" fetch origin "$SETUP_FZF_TAB_REF"; then
      fail "Failed to fetch pinned fzf-tab revision"
      return 1
    fi
  else
    if ! run_spinner "Cloning fzf-tab" git clone --no-checkout "$SETUP_FZF_TAB_REPO" "$install_dir"; then
      fail "Failed to clone fzf-tab"
      return 1
    fi
  fi

  if run_spinner "Checking out pinned fzf-tab revision" \
    git -C "$install_dir" checkout --detach "$SETUP_FZF_TAB_REF" &&
    [[ "$DRY_RUN" == true || -r "$install_dir/fzf-tab.plugin.zsh" ]] &&
    secure_fzf_tab_permissions "$install_dir"; then
    pass "fzf-tab installed at $SETUP_FZF_TAB_REF"
  else
    fail "Failed to install pinned fzf-tab revision"
  fi
}

# Installs the pinned zj-radar CLI used by the tracked Zellij sidebar and Codex hooks.
install_zj_radar() {
  local install_dir="$HOME/.local/bin"
  local binary="$install_dir/zj-radar"
  local expected_version="${SETUP_ZJ_RADAR_VERSION#v}"
  local current_version=""
  local target
  local expected_sha256
  local actual_sha256
  local archive
  local candidate
  local url

  header "Installing zj-radar"
  if [[ -x "$binary" ]]; then
    current_version="$("$binary" --version 2>/dev/null || true)"
    if [[ "$current_version" == "zj-radar $expected_version" ]]; then
      info "zj-radar is already installed at $SETUP_ZJ_RADAR_VERSION"
      return 0
    fi
  fi

  if ! target="$(setup_zj_radar_target "$PLATFORM")"; then
    fail "No prebuilt zj-radar $SETUP_ZJ_RADAR_VERSION binary supports $PLATFORM/$(uname -m)"
    return 1
  fi
  if ! expected_sha256="$(setup_zj_radar_archive_sha256 "$target")"; then
    fail "No pinned zj-radar checksum is configured for $target"
    return 1
  fi
  if [[ "$DRY_RUN" == true ]]; then
    dry "Download, verify, and install zj-radar $SETUP_ZJ_RADAR_VERSION to $binary"
    return 0
  fi

  ACTIVE_ZJ_RADAR_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/setup-zj-radar.XXXXXX")" || {
    fail "Could not create a temporary directory for zj-radar"
    return 1
  }
  archive="$ACTIVE_ZJ_RADAR_TEMP_DIR/zj-radar.tar.gz"
  url="https://github.com/$SETUP_ZJ_RADAR_REPO/releases/download/$SETUP_ZJ_RADAR_VERSION/zj-radar-$target.tar.gz"
  if ! run_spinner "Downloading zj-radar $SETUP_ZJ_RADAR_VERSION" \
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -o "$archive" "$url"; then
    fail "Failed to download zj-radar $SETUP_ZJ_RADAR_VERSION"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  if ! actual_sha256="$(setup_file_sha256 "$archive")"; then
    fail "Could not calculate the zj-radar archive checksum"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    fail "zj-radar archive checksum mismatch; refusing to install"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  if ! run_spinner "Extracting zj-radar $SETUP_ZJ_RADAR_VERSION" \
    tar -xzf "$archive" -C "$ACTIVE_ZJ_RADAR_TEMP_DIR"; then
    fail "Failed to extract zj-radar $SETUP_ZJ_RADAR_VERSION"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  if [[ ! -x "$ACTIVE_ZJ_RADAR_TEMP_DIR/zj-radar" ]] ||
    [[ "$("$ACTIVE_ZJ_RADAR_TEMP_DIR/zj-radar" --version 2>/dev/null || true)" != "zj-radar $expected_version" ]]; then
    fail "Downloaded zj-radar binary did not report version $expected_version"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  if ! mkdir -p "$install_dir"; then
    fail "Could not create the zj-radar install directory: $install_dir"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  candidate="$(mktemp "$install_dir/.zj-radar.setup.XXXXXX")" || {
    fail "Could not create a temporary zj-radar install file"
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  }
  ACTIVE_ZJ_RADAR_INSTALL_TEMP="$candidate"
  if ! install -m 0755 "$ACTIVE_ZJ_RADAR_TEMP_DIR/zj-radar" "$candidate" ||
    ! mv -f -- "$candidate" "$binary"; then
    fail "Could not atomically install zj-radar to $binary"
    rm -f -- "$candidate"
    ACTIVE_ZJ_RADAR_INSTALL_TEMP=""
    rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
    ACTIVE_ZJ_RADAR_TEMP_DIR=""
    return 1
  fi
  ACTIVE_ZJ_RADAR_INSTALL_TEMP=""
  rm -rf -- "$ACTIVE_ZJ_RADAR_TEMP_DIR"
  ACTIVE_ZJ_RADAR_TEMP_DIR=""
  pass "zj-radar $SETUP_ZJ_RADAR_VERSION installed"
}

# Installs Nerd Fonts manually on Linux; macOS uses Homebrew Casks.
install_fonts_linux() {
  [[ "$PLATFORM" == macos ]] && return 0

  header "Installing Nerd Fonts (manual)"

  local font_dir="$HOME/.local/share/fonts"
  local font
  local encoded_font
  local missing_fonts=()

  for font in "${SETUP_LINUX_FONT_FILES[@]}"; do
    [[ -f "$font_dir/$font" ]] || missing_fonts+=("$font")
  done
  if [[ ${#missing_fonts[@]} -eq 0 ]]; then
    info "MesloLGS Nerd Font is already installed"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    dry "Download ${#missing_fonts[@]} missing MesloLGS Nerd Font file(s): ${missing_fonts[*]}"
    return 0
  fi

  mkdir -p "$font_dir"

  local base_url="https://github.com/romkatv/powerlevel10k-media/raw/master"
  for font in "${missing_fonts[@]}"; do
    encoded_font="${font// /%20}"
    if ! run_spinner "Downloading $font" \
      curl -fsSL -o "$font_dir/$font" "$base_url/$encoded_font"; then
      fail "Failed to download $font"
    fi
  done

  # Rebuild font cache
  if command -v fc-cache &>/dev/null; then
    if run_spinner "Rebuilding font cache" fc-cache -f "$font_dir"; then
      pass "Nerd Fonts installed"
    else
      fail "Failed to rebuild font cache"
    fi
  else
    pass "Fonts downloaded (fc-cache not available)"
  fi
}

# Links a config directory from the repo to ~/.config/<name>
# Usage: link_config <name>
link_config() {
  local name="$1"
  local src="$DOTFILE_DIR/$name"
  local dest="$HOME/.config/$name"
  local backup="$HOME/.config/${name}.bak.$(date +%Y%m%d%H%M%S)"

  link_managed_path "$name config" "$src" "$dest" "$backup"
}

# Links tracked app configs from the repo to ~/.config/.
install_configs() {
  header "Linking app configs to ~/.config"
  if [[ -d "$HOME/.config" ]]; then
    info "$HOME/.config already exists"
  elif [[ "$DRY_RUN" == true ]]; then
    dry "Create directory $HOME/.config"
  elif mkdir -p "$HOME/.config"; then
    pass "Created $HOME/.config"
  else
    fail "Failed to create $HOME/.config"
    return 1
  fi

  for name in "${SETUP_CONFIG_LINKS[@]}"; do
    link_config "$name"
  done
  ensure_local_gitconfig
}

# Keeps ~/.gitconfig present so `git config --global` writes machine-local
# settings there instead of into the tracked dotfiles/git/config.
ensure_local_gitconfig() {
  local gitconfig="$HOME/.gitconfig"

  if [[ -f "$gitconfig" ]]; then
    info "~/.gitconfig already exists"
  elif [[ "$DRY_RUN" == true ]]; then
    dry "Create $gitconfig for machine-local Git settings"
  elif printf '%s\n' '# Machine-local Git settings (identity, credentials). Shared settings live in' \
    '# ~/.config/git/config, linked from the setup repository.' >"$gitconfig"; then
    pass "Created $gitconfig"
  else
    fail "Failed to create $gitconfig"
    return 1
  fi
}

sync_codex_config() {
  local source_file="$SETUP_DIR/$SETUP_CODEX_CONFIG_SOURCE"
  local destination_dir="$HOME/.codex"
  local destination="$destination_dir/config.toml"
  local backup_dir="$HOME/.dotfiles-backup/codex"
  local backup_stamp
  local backup_path
  local backup_suffix=0
  local candidate
  local validation_status
  local current_mode

  header "Synchronizing Codex settings"
  if [[ -d "$destination" ]]; then
    fail "Codex config path is a directory: $destination"
    return 1
  fi

  if [[ "$DRY_RUN" == true ]]; then
    candidate="$(mktemp "${TMPDIR:-/tmp}/setup-codex-config.XXXXXX")" || {
      fail "Could not create a temporary Codex config"
      return 1
    }
  else
    if [[ ! -d "$destination_dir" ]]; then
      if [[ -e "$destination_dir" || -L "$destination_dir" ]]; then
        fail "Codex home path is not a directory: $destination_dir"
        return 1
      fi
      if ! mkdir -p "$destination_dir" || ! chmod 700 "$destination_dir"; then
        fail "Could not create Codex home directory: $destination_dir"
        return 1
      fi
    fi
    candidate="$(mktemp "$destination_dir/.config.toml.setup.XXXXXX")" || {
      fail "Could not create an atomic Codex config candidate"
      return 1
    }
  fi
  ACTIVE_CODEX_CONFIG_TEMP="$candidate"

  if ! setup_codex_render_config "$source_file" "$destination" "$PLATFORM" "$HOME" "$candidate"; then
    fail "$SETUP_CODEX_CONFIG_ERROR"
    rm -f -- "$candidate"
    ACTIVE_CODEX_CONFIG_TEMP=""
    return 1
  fi
  if [[ "$SETUP_CODEX_NOTIFY_STATE" == fallback ]]; then
    warn "Computer Use notifier is unavailable; using the terminal bell fallback"
  fi

  if [[ -f "$destination" && ! -L "$destination" ]] && \
    setup_codex_semantically_equal "$destination" "$candidate"; then
    if [[ "$DRY_RUN" != true ]]; then
      current_mode="$(setup_codex_file_mode "$destination")" || {
        fail "Could not inspect Codex config permissions: $destination"
        rm -f -- "$candidate"
        ACTIVE_CODEX_CONFIG_TEMP=""
        return 1
      }
      if [[ "$current_mode" != 600 ]] && ! chmod 600 "$destination"; then
        fail "Could not secure Codex config permissions: $destination"
        rm -f -- "$candidate"
        ACTIVE_CODEX_CONFIG_TEMP=""
        return 1
      fi
    fi
    info "Codex config already includes the managed settings"
    rm -f -- "$candidate"
    ACTIVE_CODEX_CONFIG_TEMP=""
    return 0
  fi

  setup_codex_validate_with_cli "$candidate"
  validation_status=$?
  case "$validation_status" in
  0)
    pass "Codex accepted the merged config in strict mode"
    ;;
  2)
    warn "Codex CLI is not installed; TOML validation passed and setup will not install Codex"
    ;;
  *)
    fail "$SETUP_CODEX_CONFIG_ERROR"
    rm -f -- "$candidate"
    ACTIVE_CODEX_CONFIG_TEMP=""
    return 1
    ;;
  esac

  if [[ "$DRY_RUN" == true ]]; then
    [[ -e "$destination" || -L "$destination" ]] && \
      dry "Back up $destination under $backup_dir"
    dry "Atomically merge managed settings into $destination"
    rm -f -- "$candidate"
    ACTIVE_CODEX_CONFIG_TEMP=""
    return 0
  fi

  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ ! -d "$backup_dir" ]]; then
      if ! mkdir -p "$backup_dir" || ! chmod 700 "$backup_dir"; then
        fail "Could not create Codex backup directory: $backup_dir"
        rm -f -- "$candidate"
        ACTIVE_CODEX_CONFIG_TEMP=""
        return 1
      fi
    fi
    backup_stamp="$(date +%Y%m%d%H%M%S)"
    backup_path="$backup_dir/config.toml.$backup_stamp"
    while [[ -e "$backup_path" || -L "$backup_path" ]]; do
      backup_suffix=$((backup_suffix + 1))
      backup_path="$backup_dir/config.toml.$backup_stamp.$backup_suffix"
    done
    if ! cp -Pp -- "$destination" "$backup_path"; then
      fail "Could not back up the existing Codex config: $destination"
      rm -f -- "$candidate"
      ACTIVE_CODEX_CONFIG_TEMP=""
      return 1
    fi
    pass "Backed up the existing Codex config to $backup_path"
  fi

  if ! chmod 600 "$candidate" || ! mv -f -- "$candidate" "$destination"; then
    fail "Could not atomically install the merged Codex config: $destination"
    rm -f -- "$candidate"
    ACTIVE_CODEX_CONFIG_TEMP=""
    return 1
  fi
  ACTIVE_CODEX_CONFIG_TEMP=""
  pass "Merged managed Codex settings into $destination"
}

# Keep the one encoder used for managed Codex TOML current without upgrading
# unrelated Homebrew packages. An offline upgrade is non-fatal only when the
# already installed encoder passes the real managed-document round trip.
prepare_codex_yq() {
  local source_file="$SETUP_DIR/$SETUP_CODEX_CONFIG_SOURCE"
  local action
  local action_label

  header "Preparing yq for Codex settings"
  if ! activate_brew; then
    fail "Homebrew is unavailable; yq cannot be prepared for Codex settings"
    return 1
  fi
  setup_reset_dependency_cache
  if setup_brew_package_installed yq; then
    action=upgrade
    action_label="Upgrading yq for Codex TOML compatibility"
  else
    action=install
    action_label="Installing yq for Codex TOML compatibility"
  fi

  if ! run_spinner "$action_label" "$BREW_BIN" "$action" yq; then
    setup_reset_dependency_cache
    hash -r
    if setup_codex_yq_supports_managed_toml "$source_file"; then
      warn "Homebrew could not $action yq; the active yq passed the managed Codex TOML check"
      return 0
    fi
    fail "Homebrew could not $action yq and the active encoder is incompatible: $SETUP_CODEX_CONFIG_ERROR"
    return 1
  fi

  setup_reset_dependency_cache
  hash -r
  if ! setup_codex_yq_supports_managed_toml "$source_file"; then
    fail "$SETUP_CODEX_CONFIG_ERROR"
    return 1
  fi
  pass "yq is ready for managed Codex TOML"
}

# =====[ Main Execution Flow ]=================================================

run_dependency_stages() {
  install_package_manager
  ((${#FAILED_TASKS[@]} == 0)) || return 1
  install_system_packages
  install_packages
  install_python_dependencies
  ((${#FAILED_TASKS[@]} == 0)) || return 1
  setup_reset_dependency_cache
  verify_dependencies
}

setup_repair_has_action() {
  local expected="$1"
  local action
  shift
  for action in "$@"; do
    [[ "$action" == "$expected" ]] && return 0
  done
  return 1
}

# Apply a deduplicated action list produced by setup/state.sh. The subshell owns
# the repair lock and signal cleanup so the caller can immediately rescan.
setup_repair_apply() (
  local requested_work="$1"
  local requested_job="$2"
  local repair_status=0
  shift 2

  DRY_RUN=false
  ALLOW_MISSING_EXTERNAL=true
  SETUP_REPAIR_COMPACT=true
  FAILED_TASKS=()
  WORK_ENV="$requested_work"
  JOB="$requested_job"

  detect_platform || return $?
  initialize_configuration
  validate_repo_sources || return 1

  trap cleanup EXIT
  trap 'handle_signal 130' INT
  trap 'handle_signal 143' TERM
  acquire_install_lock || return $?

  setup_status_start "Applying managed repairs"
  if setup_repair_has_action dependencies "$@"; then
    run_dependency_stages || repair_status=1
  else
    verify_dependencies || repair_status=1
  fi
  if (( ${#FAILED_TASKS[@]} > 0 || repair_status != 0 )); then
    return 1
  fi

  if setup_repair_has_action radar "$@"; then
    install_zj_radar || repair_status=1
  fi
  if (( ${#FAILED_TASKS[@]} > 0 || repair_status != 0 )); then
    return 1
  fi

  if setup_repair_has_action codex "$@"; then
    prepare_codex_yq && sync_codex_config || repair_status=1
  fi
  if (( ${#FAILED_TASKS[@]} > 0 || repair_status != 0 )); then
    return 1
  fi

  setup_repair_has_action work "$@" && create_work_dir
  setup_repair_has_action paths "$@" && ensure_managed_path_dirs
  setup_repair_has_action metadata "$@" && write_local_env_config
  if setup_repair_has_action links "$@"; then
    symlink_setup
    install_configs
  fi
  setup_repair_has_action hooks "$@" && configure_git_hooks
  setup_repair_has_action shell "$@" && configure_zsh_shell
  setup_repair_has_action fzf "$@" && install_fzf_tab
  if setup_repair_has_action platform "$@"; then
    install_apps
    install_fonts_linux
  fi

  (( ${#FAILED_TASKS[@]} == 0 ))
)

# This file intentionally has no command-line entry point.
