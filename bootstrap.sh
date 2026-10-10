#!/usr/bin/env bash
# Browser-downloaded first-machine bootstrap for this setup repository.
set -u -o pipefail

# A fork sets BOOTSTRAP_OWNER (and BOOTSTRAP_REPOSITORY) in the environment.
BOOTSTRAP_REQUESTED_OWNER="${BOOTSTRAP_OWNER:-}"
BOOTSTRAP_OWNER="ghostnet-labs"
BOOTSTRAP_OWNER="${BOOTSTRAP_REQUESTED_OWNER:-$BOOTSTRAP_OWNER}"
BOOTSTRAP_REPOSITORY="${BOOTSTRAP_REPOSITORY:-supernova}"
BOOTSTRAP_DESTINATION="${BOOTSTRAP_DESTINATION:-$HOME/dev/$BOOTSTRAP_REPOSITORY}"
BOOTSTRAP_SSH_DIR="${BOOTSTRAP_SSH_DIR:-$HOME/.ssh}"
BOOTSTRAP_LOG_DIR="${BOOTSTRAP_LOG_DIR:-$HOME/.local/state/setup-bootstrap}"
BOOTSTRAP_LOG_FILE=""
BOOTSTRAP_TEMP_FILES=()
BOOTSTRAP_TEMP_DIRS=()
BOOTSTRAP_PLATFORM=""
BOOTSTRAP_VERIFIED_ALIAS=""
BOOTSTRAP_VERIFIED_URL=""
BOOTSTRAP_SCOPE=""
BOOTSTRAP_JOB=""
BOOTSTRAP_WORK_ROOT=""
BOOTSTRAP_RERUN_COMMAND=""
BOOTSTRAP_MANAGED_ZSH=""

bootstrap_usage() {
  printf '%s\n' 'Usage:
  bash ~/Downloads/bootstrap.sh
  bash ~/Downloads/bootstrap.sh --help

Description:
  Bootstrap a new macOS, Ubuntu, Rocky, or RHEL machine from a browser-
  downloaded script. The interactive flow verifies prerequisites and GitHub
  access, safely clones ~/dev/supernova, runs setup, verifies it, and enters
  the managed login shell. Without a working GitHub SSH key it offers to
  create one, or clones a public repository read-only over HTTPS. A Work scope also asks for a work overlay
  checkout (a path, or a Git URL to clone next to it). Bootstrap itself
  installs no packages.

Options:
  -h, --help  Show this help menu and exit without changing the machine.

Examples:
  bash ~/Downloads/bootstrap.sh
  bash ~/Downloads/bootstrap.sh --help

Environment:
  HOME                   Home directory where SSH state, the checkout, and status
                         logs live.
  BOOTSTRAP_OWNER        GitHub owner to clone from, for a fork (default:
                         the upstream owner).
  BOOTSTRAP_REPOSITORY   Repository name to clone (default: supernova).
  BOOTSTRAP_DESTINATION  Checkout path (default: ~/dev/REPOSITORY).'
}

bootstrap_is_interactive() {
  [[ -t 0 && -t 1 ]]
}

bootstrap_cleanup() {
  local file
  local directory
  for file in ${BOOTSTRAP_TEMP_FILES[@]+"${BOOTSTRAP_TEMP_FILES[@]}"}; do
    [[ -n "$file" && -e "$file" ]] && rm -f -- "$file"
  done
  for directory in ${BOOTSTRAP_TEMP_DIRS[@]+"${BOOTSTRAP_TEMP_DIRS[@]}"}; do
    case "$directory" in
      */.setup-bootstrap-clone-[0-9]*) [[ -d "$directory" ]] && rm -rf -- "$directory" ;;
    esac
  done
}

bootstrap_log() {
  [[ -n "$BOOTSTRAP_LOG_FILE" ]] || return 0
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$BOOTSTRAP_LOG_FILE"
}

bootstrap_stage() {
  printf '\n── %s\n' "$1"
  bootstrap_log "STAGE: $1"
}

bootstrap_info() {
  printf '•  %s\n' "$1"
}

bootstrap_pass() {
  printf '✓  %s\n' "$1"
  bootstrap_log "PASS: $1"
}

bootstrap_fail() {
  printf '✗  %s\n' "$1" >&2
  bootstrap_log "FAIL: $1"
}

bootstrap_die() {
  bootstrap_fail "$1"
  [[ -n "${2:-}" ]] && printf '   %s\n' "$2" >&2
  [[ -n "$BOOTSTRAP_LOG_FILE" ]] && printf '   Status log: %s\n' "$BOOTSTRAP_LOG_FILE" >&2
  return 1
}

bootstrap_initialize_log() {
  local timestamp
  local original_umask

  original_umask="$(umask)"
  umask 077
  if ! mkdir -p "$BOOTSTRAP_LOG_DIR" || ! chmod 700 "$BOOTSTRAP_LOG_DIR"; then
    umask "$original_umask"
    bootstrap_fail "Could not create the private bootstrap status-log directory: $BOOTSTRAP_LOG_DIR"
    return 1
  fi
  timestamp="$(date '+%Y%m%dT%H%M%S')"
  BOOTSTRAP_LOG_FILE="$BOOTSTRAP_LOG_DIR/bootstrap-$timestamp-$$.log"
  if ! : >"$BOOTSTRAP_LOG_FILE" || ! chmod 600 "$BOOTSTRAP_LOG_FILE"; then
    umask "$original_umask"
    bootstrap_fail "Could not create the private bootstrap status log: $BOOTSTRAP_LOG_FILE"
    BOOTSTRAP_LOG_FILE=""
    return 1
  fi
  umask "$original_umask"
  bootstrap_log "Bootstrap started"
}

# Browser downloads do not carry Git's executable mode. The first documented
# `bash bootstrap.sh` launch marks this exact copy executable for later reruns.
bootstrap_prepare_downloaded_script() {
  local script_path="${BOOTSTRAP_SCRIPT_PATH_OVERRIDE:-${BASH_SOURCE[0]}}"

  [[ -f "$script_path" && ! -x "$script_path" ]] || return 0
  if chmod u+x "$script_path"; then
    bootstrap_pass "Marked $script_path executable for future reruns"
  else
    bootstrap_info "Could not mark $script_path executable; continue using: bash $script_path"
  fi
}

bootstrap_detect_platform() {
  if [[ -n "${BOOTSTRAP_PLATFORM_OVERRIDE:-}" ]]; then
    BOOTSTRAP_PLATFORM="$BOOTSTRAP_PLATFORM_OVERRIDE"
  elif [[ "${OSTYPE:-}" == darwin* ]]; then
    BOOTSTRAP_PLATFORM="macos"
  elif [[ -r /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release; then
    BOOTSTRAP_PLATFORM="ubuntu"
  elif [[ -r /etc/os-release ]] && grep -q '^ID=rocky' /etc/os-release; then
    BOOTSTRAP_PLATFORM="rocky"
  elif [[ -r /etc/os-release ]] && grep -Eq '^ID=(rhel|centos|almalinux)' /etc/os-release; then
    BOOTSTRAP_PLATFORM="rhel"
  else
    BOOTSTRAP_PLATFORM="unsupported"
  fi

  case "$BOOTSTRAP_PLATFORM" in
    macos|ubuntu|rocky|rhel) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_check_prerequisites() {
  local missing=false

  bootstrap_stage "Checking pre-clone prerequisites"
  case "$BOOTSTRAP_PLATFORM" in
    macos)
      if ! command -v xcode-select >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
        bootstrap_fail "Apple Command Line Tools are required."
        printf '   Run: xcode-select --install\n'
        printf '   Finish the Apple installer, then rerun this bootstrap command.\n'
        bootstrap_log "STOP: Apple Command Line Tools are missing"
        return 1
      fi
      command -v git >/dev/null 2>&1 || missing=true
      if [[ "$missing" == true ]]; then
        bootstrap_fail "Git is unavailable even though Command Line Tools were detected."
        printf '   Run: xcode-select --install\n'
        printf '   Finish or repair the Apple installer, then rerun bootstrap.\n'
        return 1
      fi
      ;;
    ubuntu)
      command -v git >/dev/null 2>&1 || missing=true
      command -v ssh >/dev/null 2>&1 || missing=true
      if [[ "$missing" == true ]]; then
        bootstrap_fail "Git and OpenSSH are required before cloning."
        printf '   Run: sudo apt-get update && sudo apt-get install -y git openssh-client\n'
        printf '   Then rerun this bootstrap command.\n'
        bootstrap_log "STOP: Ubuntu pre-clone prerequisites are missing"
        return 1
      fi
      ;;
    rocky|rhel)
      command -v git >/dev/null 2>&1 || missing=true
      command -v ssh >/dev/null 2>&1 || missing=true
      if [[ "$missing" == true ]]; then
        bootstrap_fail "Git and OpenSSH are required before cloning."
        printf '   Run: sudo dnf install -y git openssh-clients\n'
        printf '   Then rerun this bootstrap command.\n'
        bootstrap_log "STOP: Red Hat pre-clone prerequisites are missing"
        return 1
      fi
      ;;
  esac
  bootstrap_pass "Pre-clone prerequisites are available"
}

bootstrap_repo_url() {
  printf 'git@%s:%s/%s.git\n' "$1" "$BOOTSTRAP_OWNER" "$BOOTSTRAP_REPOSITORY"
}

bootstrap_https_url() {
  printf 'https://github.com/%s/%s.git\n' "$BOOTSTRAP_OWNER" "$BOOTSTRAP_REPOSITORY"
}

# A public repository can be cloned without any GitHub credentials.
bootstrap_test_https_access() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false \
    git -c credential.helper= ls-remote "$(bootstrap_https_url)" HEAD >/dev/null 2>&1
}

bootstrap_test_repository_alias() {
  local alias_name="$1"
  local repository_url
  repository_url="$(bootstrap_repo_url "$alias_name")"
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=8" \
    git ls-remote "$repository_url" HEAD >/dev/null 2>&1
}

bootstrap_verify_repository_access() {
  local alias_name

  BOOTSTRAP_VERIFIED_ALIAS=""
  BOOTSTRAP_VERIFIED_URL=""
  for alias_name in github-personal github.com; do
    if bootstrap_test_repository_alias "$alias_name"; then
      BOOTSTRAP_VERIFIED_ALIAS="$alias_name"
      BOOTSTRAP_VERIFIED_URL="$(bootstrap_repo_url "$alias_name")"
      return 0
    fi
  done
  return 1
}

bootstrap_file_defines_personal_host() {
  awk '
    tolower($1) == "host" {
      for (field = 2; field <= NF; field++) {
        if (tolower($field) == "github-personal") found = 1
      }
    }
    END { exit !found }
  ' "$1"
}

bootstrap_find_conflicting_personal_host() {
  local file
  local managed_file="$BOOTSTRAP_SSH_DIR/config.d/setup-bootstrap.conf"

  if [[ -f "$BOOTSTRAP_SSH_DIR/config" ]] && bootstrap_file_defines_personal_host "$BOOTSTRAP_SSH_DIR/config"; then
    printf '%s\n' "$BOOTSTRAP_SSH_DIR/config"
    return 0
  fi
  for file in "$BOOTSTRAP_SSH_DIR"/config.d/*; do
    [[ -f "$file" && "$file" != "$managed_file" ]] || continue
    if bootstrap_file_defines_personal_host "$file"; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

bootstrap_main_config_includes_managed_dir() {
  local config_file="$BOOTSTRAP_SSH_DIR/config"
  [[ -r "$config_file" ]] || return 1
  awk '
    tolower($1) == "include" {
      for (field = 2; field <= NF; field++) {
        if ($field == "~/.ssh/config.d/*" ||
            $field == "~/.ssh/config.d/*.conf" ||
            $field == "~/.ssh/config.d/setup-bootstrap.conf" ||
            $field == "config.d/*" ||
            $field == "config.d/*.conf" ||
            $field == "config.d/setup-bootstrap.conf") found = 1
      }
    }
    END { exit !found }
  ' "$config_file"
}

bootstrap_install_personal_ssh_config() {
  local key_file="$1"
  local conflict_file
  local config_dir="$BOOTSTRAP_SSH_DIR/config.d"
  local config_file="$BOOTSTRAP_SSH_DIR/config"
  local managed_file="$config_dir/setup-bootstrap.conf"
  local expected
  local temporary
  local backup

  if conflict_file="$(bootstrap_find_conflicting_personal_host)"; then
    bootstrap_die "A conflicting github-personal SSH definition already exists in $conflict_file." \
      "Preserve that identity and either correct it manually or use an existing working repository alias."
    return 1
  fi

  expected="Host github-personal
  HostName github.com
  User git
  IdentityFile $key_file
  IdentitiesOnly yes"
  if [[ -e "$managed_file" ]]; then
    if [[ -f "$managed_file" && "$(cat "$managed_file")" == "$expected" ]]; then
      bootstrap_info "Managed github-personal SSH configuration already matches"
    else
      bootstrap_die "The managed SSH include already exists with different content: $managed_file" \
        "Bootstrap will not overwrite a conflicting identity definition."
      return 1
    fi
  else
    mkdir -p "$config_dir" || return 1
    chmod 700 "$BOOTSTRAP_SSH_DIR" "$config_dir" || return 1
    temporary="$(mktemp "$config_dir/setup-bootstrap.conf.XXXXXX")" || return 1
    BOOTSTRAP_TEMP_FILES+=("$temporary")
    printf '%s\n' "$expected" >"$temporary" || return 1
    chmod 600 "$temporary" || return 1
    mv "$temporary" "$managed_file" || return 1
  fi

  if ! bootstrap_main_config_includes_managed_dir; then
    temporary="$(mktemp "$BOOTSTRAP_SSH_DIR/config.XXXXXX")" || return 1
    BOOTSTRAP_TEMP_FILES+=("$temporary")
    {
      printf 'Include ~/.ssh/config.d/*.conf\n'
      if [[ -f "$config_file" ]]; then
        cat "$config_file"
      fi
    } >"$temporary" || return 1
    chmod 600 "$temporary" || return 1
    if [[ -e "$config_file" ]]; then
      backup="$config_file.bootstrap-backup-$(date '+%Y%m%dT%H%M%S')-$$"
      cp -p "$config_file" "$backup" || return 1
      bootstrap_info "Backed up the existing SSH config to $backup"
    fi
    mv "$temporary" "$config_file" || return 1
  fi
  bootstrap_pass "Configured the narrowly scoped github-personal SSH alias"
}

bootstrap_show_public_key() {
  local public_key_file="$1"
  local github_url="https://github.com/settings/ssh/new"

  printf '\nAdd this public key to your personal GitHub account:\n\n'
  cat "$public_key_file"
  printf '\n%s\n' "$github_url"

  if [[ "$BOOTSTRAP_PLATFORM" == macos ]]; then
    if command -v pbcopy >/dev/null 2>&1; then
      pbcopy <"$public_key_file" && bootstrap_info "The public key was copied to the clipboard"
    fi
    if [[ "${BOOTSTRAP_NO_OPEN:-false}" != true ]] && command -v open >/dev/null 2>&1; then
      open "$github_url" >/dev/null 2>&1 || bootstrap_info "Open the printed GitHub URL manually"
    fi
  elif [[ "${BOOTSTRAP_NO_OPEN:-false}" != true ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$github_url" >/dev/null 2>&1 || true
    elif command -v gio >/dev/null 2>&1; then
      gio open "$github_url" >/dev/null 2>&1 || true
    fi
  fi
}

bootstrap_establish_github_access() {
  local response
  local key_file="$BOOTSTRAP_SSH_DIR/id_ed25519_github_personal"
  local public_key_file="$key_file.pub"

  bootstrap_stage "Verifying GitHub repository access"
  if bootstrap_verify_repository_access; then
    bootstrap_pass "Repository access works through $BOOTSTRAP_VERIFIED_ALIAS"
    return 0
  fi

  printf 'No existing GitHub SSH identity can read %s/%s.\n' "$BOOTSTRAP_OWNER" "$BOOTSTRAP_REPOSITORY"
  if bootstrap_test_https_access; then
    printf 'The repository is public, so it can also be cloned read-only over HTTPS.\n'
    printf 'Create and configure the no-passphrase key %s instead? [y/N] ' "$key_file"
    IFS= read -r response || response=""
    case "$response" in
      y|Y|yes|Yes|YES) ;;
      *)
        BOOTSTRAP_VERIFIED_ALIAS="HTTPS"
        BOOTSTRAP_VERIFIED_URL="$(bootstrap_https_url)"
        bootstrap_pass "Cloning read-only over HTTPS; add a GitHub SSH key later to push"
        return 0
        ;;
    esac
  else
    printf 'Create and configure the no-passphrase key %s? [y/N] ' "$key_file"
    IFS= read -r response || response=""
    case "$response" in
      y|Y|yes|Yes|YES) ;;
      *) bootstrap_die "GitHub SSH setup was cancelled." "Rerun bootstrap after configuring repository access."; return 1 ;;
    esac
  fi

  mkdir -p "$BOOTSTRAP_SSH_DIR" || return 1
  chmod 700 "$BOOTSTRAP_SSH_DIR" || return 1
  if [[ -e "$key_file" || -L "$key_file" ]]; then
    if [[ ! -f "$key_file" || ! -f "$public_key_file" ]]; then
      bootstrap_die "The requested SSH key path already exists but is incomplete: $key_file" \
        "Bootstrap will not overwrite it. Repair or move it, then rerun bootstrap."
      return 1
    fi
    bootstrap_info "Reusing the existing personal SSH key without changing it"
  elif ! ssh-keygen -q -t ed25519 -N "" -C "$BOOTSTRAP_OWNER setup bootstrap" -f "$key_file"; then
    bootstrap_die "Could not create the personal Ed25519 SSH key."
    return 1
  else
    chmod 600 "$key_file"
    chmod 644 "$public_key_file"
    bootstrap_pass "Created a no-passphrase Ed25519 key"
  fi

  bootstrap_install_personal_ssh_config "$key_file" || return 1
  bootstrap_show_public_key "$public_key_file"
  printf '\nPress Enter after GitHub reports that the key was added. '
  IFS= read -r response || response=""

  if ! bootstrap_verify_repository_access; then
    bootstrap_die "GitHub still cannot authenticate to the repository." \
      "Confirm the key is on the correct GitHub account, then run: ssh -T git@github-personal"
    return 1
  fi
  bootstrap_pass "Repository access works through $BOOTSTRAP_VERIFIED_ALIAS"
}

bootstrap_origin_is_expected() {
  local path="$BOOTSTRAP_OWNER/$BOOTSTRAP_REPOSITORY"
  case "$1" in
    git@github-personal:"$path".git|\
    git@github.com:"$path".git|\
    ssh://git@github-personal/"$path".git|\
    ssh://git@github.com/"$path".git|\
    https://github.com/"$path".git) return 0 ;;
  esac
  return 1
}

bootstrap_validate_checkout() {
  local required_file
  local checkout_dir="${1:-$BOOTSTRAP_DESTINATION}"
  for required_file in setup.sh setup/dependencies.sh setup/state.sh setup/repair.sh setup/status_output.sh; do
    if [[ ! -f "$checkout_dir/$required_file" ]]; then
      bootstrap_die "The setup checkout is incomplete: missing $required_file" \
        "No setup command was run. Repair the checkout or move it aside, then rerun bootstrap."
      return 1
    fi
  done
}

bootstrap_clone_or_resume() {
  local origin_url
  local clone_parent
  local clone_stage

  bootstrap_stage "Cloning or resuming the setup checkout"
  if [[ -e "$BOOTSTRAP_DESTINATION" || -L "$BOOTSTRAP_DESTINATION" ]]; then
    if [[ ! -d "$BOOTSTRAP_DESTINATION" ]]; then
      bootstrap_die "The setup destination exists and is not a directory: $BOOTSTRAP_DESTINATION"
      return 1
    fi
    if [[ -d "$BOOTSTRAP_DESTINATION/.git" ]]; then
      origin_url="$(git -C "$BOOTSTRAP_DESTINATION" config --get remote.origin.url 2>/dev/null || true)"
      if ! bootstrap_origin_is_expected "$origin_url"; then
        bootstrap_die "The existing checkout has an unexpected origin: ${origin_url:-not configured}" \
          "Bootstrap will not pull, reset, or replace $BOOTSTRAP_DESTINATION."
        return 1
      fi
      bootstrap_validate_checkout || return 1
      bootstrap_pass "Reusing the existing setup checkout unchanged"
      return 0
    fi
    if [[ -n "$(ls -A "$BOOTSTRAP_DESTINATION" 2>/dev/null)" ]]; then
      bootstrap_die "An unrelated non-empty directory already exists at $BOOTSTRAP_DESTINATION." \
        "Move it aside or choose how to preserve it before rerunning bootstrap."
      return 1
    fi
  else
    mkdir -p "$(dirname "$BOOTSTRAP_DESTINATION")" || return 1
  fi

  clone_parent="$(dirname "$BOOTSTRAP_DESTINATION")"
  clone_stage="$clone_parent/.setup-bootstrap-clone-$$"
  if [[ -e "$clone_stage" || -L "$clone_stage" ]]; then
    bootstrap_die "The owned clone staging path already exists: $clone_stage" \
      "Remove that stale staging directory after confirming its contents, then rerun bootstrap."
    return 1
  fi
  BOOTSTRAP_TEMP_DIRS+=("$clone_stage")
  if ! git clone "$BOOTSTRAP_VERIFIED_URL" "$clone_stage"; then
    bootstrap_die "Could not clone the setup repository." "Rerun bootstrap after resolving the Git or network diagnostic above."
    return 1
  fi
  bootstrap_validate_checkout "$clone_stage" || return 1
  if [[ -d "$BOOTSTRAP_DESTINATION" ]]; then
    rmdir "$BOOTSTRAP_DESTINATION" || {
      bootstrap_die "The setup destination changed while the repository was cloning: $BOOTSTRAP_DESTINATION"
      return 1
    }
  fi
  if ! mv "$clone_stage" "$BOOTSTRAP_DESTINATION"; then
    bootstrap_die "Could not atomically place the verified checkout at $BOOTSTRAP_DESTINATION"
    return 1
  fi
  bootstrap_pass "Cloned the setup repository to $BOOTSTRAP_DESTINATION"
}

# Jobs an overlay checkout provides: each JOB/bin-JOB directory in it.
bootstrap_discover_work_jobs() {
  local bin_dir job
  for bin_dir in "$1"/*/bin-*; do
    [[ -d "$bin_dir" ]] || continue
    job="${bin_dir%/bin-*}"
    job="${job##*/}"
    [[ "${bin_dir##*/}" == "bin-$job" ]] && printf '%s\n' "$job"
  done | sort -u
}

# Use an existing overlay checkout, or clone a Git URL next to the setup
# checkout; an existing clone at that path is reused unchanged.
bootstrap_prepare_work_root() {
  local source="$1"
  local destination

  case "$source" in
    *://* | *@*:*)
      destination="$(dirname "$BOOTSTRAP_DESTINATION")/$(basename "${source%.git}")"
      if [[ -d "$destination/.git" ]]; then
        bootstrap_info "Reusing the existing overlay checkout at $destination"
      elif [[ -e "$destination" ]]; then
        bootstrap_info "Not cloning over existing $destination"
        return 1
      elif ! git clone "$source" "$destination"; then
        bootstrap_info "Could not clone $source"
        return 1
      fi
      ;;
    *)
      destination="${source/#\~/$HOME}"
      [[ -d "$destination" ]] || { bootstrap_info "Not a directory: $destination"; return 1; }
      ;;
  esac
  BOOTSTRAP_WORK_ROOT="$(cd -- "$destination" && pwd)"
}

bootstrap_valid_job() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

bootstrap_select_scope() {
  local response
  local jobs
  local default_job

  bootstrap_stage "Selecting the setup scope"
  while :; do
    printf 'Choose a setup scope: [1] Personal  [2] Work: '
    IFS= read -r response || response=""
    case "$response" in
      1|p|P|personal|Personal)
        BOOTSTRAP_SCOPE="personal"
        BOOTSTRAP_JOB=""
        BOOTSTRAP_RERUN_COMMAND="./setup.sh --fix --personal"
        return 0
        ;;
      2|w|W|work|Work)
        BOOTSTRAP_SCOPE="work"
        break
        ;;
      *) bootstrap_info "Enter 1 for Personal or 2 for Work" ;;
    esac
  done

  while :; do
    printf 'Work overlay checkout (path or Git URL): '
    IFS= read -r response || response=""
    [[ -n "$response" ]] && bootstrap_prepare_work_root "$response" && break
    bootstrap_info "Enter the path of a work overlay checkout, or a Git URL to clone"
  done

  jobs="$(bootstrap_discover_work_jobs "$BOOTSTRAP_WORK_ROOT")"
  # Suggest a job only when the overlay has exactly one; with several, the
  # first by name may be an old one, so ask for it by name.
  default_job=""
  [[ -n "$jobs" && "$jobs" != *$'\n'* ]] && default_job="$jobs"
  if [[ -n "$jobs" ]]; then
    printf 'Overlay work jobs: %s\n' "$(printf '%s\n' "$jobs" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
  while :; do
    if [[ -n "$default_job" ]]; then
      printf 'Work job [%s]: ' "$default_job"
    else
      printf 'Work job: '
    fi
    IFS= read -r response || response=""
    [[ -n "$response" ]] || response="$default_job"
    if bootstrap_valid_job "$response"; then
      BOOTSTRAP_JOB="$response"
      BOOTSTRAP_RERUN_COMMAND="./setup.sh --fix --work --job $BOOTSTRAP_JOB --work-root $BOOTSTRAP_WORK_ROOT"
      return 0
    fi
    bootstrap_info "Job names must start with a letter or number and use only letters, numbers, dots, underscores, or hyphens"
  done
}

bootstrap_run_setup() {
  local status=0

  bootstrap_stage "Running the managed setup"
  cd "$BOOTSTRAP_DESTINATION" || return 1
  if [[ "$BOOTSTRAP_SCOPE" == personal ]]; then
    ./setup.sh --fix --personal || status=$?
  else
    ./setup.sh --fix --work --job "$BOOTSTRAP_JOB" --work-root "$BOOTSTRAP_WORK_ROOT" || status=$?
  fi
  if (( status != 0 )); then
    bootstrap_die "Setup was cancelled or failed (exit $status)." \
      "Rerun from $BOOTSTRAP_DESTINATION with: $BOOTSTRAP_RERUN_COMMAND"
    return "$status"
  fi
  bootstrap_pass "Managed setup completed"
}

bootstrap_resolve_managed_zsh() {
  local brew_command=""
  local brew_prefix=""
  local candidate
  local system_zsh="${BOOTSTRAP_SYSTEM_ZSH:-/bin/zsh}"

  if [[ "$BOOTSTRAP_PLATFORM" == macos ]]; then
    [[ -x "$system_zsh" ]] || return 1
    BOOTSTRAP_MANAGED_ZSH="$system_zsh"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    brew_command="$(command -v brew)"
  else
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
      if [[ -x "$candidate" ]]; then
        brew_command="$candidate"
        break
      fi
    done
  fi
  [[ -n "$brew_command" ]] && brew_prefix="$("$brew_command" --prefix 2>/dev/null || true)"
  if [[ -n "$brew_prefix" && -x "$brew_prefix/bin/zsh" ]]; then
    BOOTSTRAP_MANAGED_ZSH="$brew_prefix/bin/zsh"
  elif command -v zsh >/dev/null 2>&1; then
    BOOTSTRAP_MANAGED_ZSH="$(command -v zsh)"
  else
    return 1
  fi
}

bootstrap_verify_setup() {
  local check_command="./setup.sh --check"
  local test_command="./setup.sh --test"

  bootstrap_stage "Verifying the managed environment"
  bootstrap_resolve_managed_zsh || {
    bootstrap_die "The managed Zsh executable could not be located after setup."
    return 1
  }
  if [[ "$BOOTSTRAP_SCOPE" == work ]]; then
    check_command="./setup.sh --check --work"
  else
    test_command="./setup.sh --test --personal"
  fi
  if ! SETUP_BOOTSTRAP_REPO="$BOOTSTRAP_DESTINATION" SETUP_BOOTSTRAP_COMMAND="$check_command" \
    "$BOOTSTRAP_MANAGED_ZSH" -lic 'cd "$SETUP_BOOTSTRAP_REPO" && eval "$SETUP_BOOTSTRAP_COMMAND"'; then
    bootstrap_die "The scope-aware setup health check still has managed findings." \
      "Rerun from $BOOTSTRAP_DESTINATION with: $check_command"
    return 1
  fi
  bootstrap_pass "Scope-aware setup health check passed"

  if ! SETUP_BOOTSTRAP_REPO="$BOOTSTRAP_DESTINATION" SETUP_BOOTSTRAP_COMMAND="$test_command" \
    "$BOOTSTRAP_MANAGED_ZSH" -lic 'cd "$SETUP_BOOTSTRAP_REPO" && eval "$SETUP_BOOTSTRAP_COMMAND"'; then
    bootstrap_die "Repository regression tests failed after setup." \
      "Rerun from $BOOTSTRAP_DESTINATION with: $test_command"
    return 1
  fi
  bootstrap_pass "Scope-appropriate repository test suite passed"
}

bootstrap_handoff() {
  bootstrap_stage "Finishing bootstrap"
  bootstrap_info "Manual follow-up items, if any, are listed in the setup health report above."
  printf 'Status log: %s\n' "$BOOTSTRAP_LOG_FILE"
  bootstrap_log "Bootstrap verification completed"

  if [[ "${BOOTSTRAP_NO_HANDOFF:-false}" == true ]]; then
    bootstrap_pass "Shell handoff skipped by the isolated test harness"
    return 0
  fi
  if [[ "$BOOTSTRAP_PLATFORM" == macos && "${TERM_PROGRAM:-}" != ghostty ]]; then
    if command -v open >/dev/null 2>&1 && open -na Ghostty >/dev/null 2>&1; then
      bootstrap_pass "Opened Ghostty; this original terminal may now be closed"
      return 0
    fi
    bootstrap_info "Ghostty could not be launched; entering managed login Zsh here"
  fi
  bootstrap_info "Entering the managed login Zsh"
  exec "$BOOTSTRAP_MANAGED_ZSH" -l
}

bootstrap_main() {
  if (( $# > 1 )); then
    bootstrap_usage >&2
    return 2
  fi
  case "${1:-}" in
    -h|--help) bootstrap_usage; return 0 ;;
    "") ;;
    *) bootstrap_fail "Unknown option: $1"; bootstrap_usage >&2; return 2 ;;
  esac

  if ! bootstrap_is_interactive; then
    bootstrap_fail "Bootstrap requires an interactive terminal."
    printf '   Run it directly with: bash ~/Downloads/bootstrap.sh\n' >&2
    return 2
  fi
  bootstrap_initialize_log || return 1
  bootstrap_prepare_downloaded_script
  trap bootstrap_cleanup EXIT
  trap 'bootstrap_fail "Bootstrap was interrupted; rerun the same command to resume safely."; exit 130' INT TERM

  bootstrap_stage "Inspecting this machine"
  if ! bootstrap_detect_platform; then
    bootstrap_die "Unsupported operating system." "Supported platforms: macOS, Ubuntu, Rocky, and RHEL."
    return 1
  fi
  bootstrap_pass "Detected $BOOTSTRAP_PLATFORM"
  bootstrap_check_prerequisites || return 1
  bootstrap_establish_github_access || return 1
  bootstrap_clone_or_resume || return 1
  bootstrap_select_scope || return 1
  bootstrap_run_setup || return $?
  bootstrap_verify_setup || return 1
  bootstrap_handoff
}

if [[ "${BOOTSTRAP_SOURCE_ONLY:-false}" != true ]]; then
  bootstrap_main "$@"
fi
