#!/usr/bin/env bash
# First-machine bootstrap: clone this repository, then hand off to setup.sh.
set -u -o pipefail

# A fork sets BOOTSTRAP_OWNER (and BOOTSTRAP_REPOSITORY) in the environment.
[[ -n "${BOOTSTRAP_OWNER:-}" ]] || BOOTSTRAP_OWNER="ghostnet-labs"
BOOTSTRAP_REPOSITORY="${BOOTSTRAP_REPOSITORY:-supernova}"
BOOTSTRAP_DESTINATION="${BOOTSTRAP_DESTINATION:-$HOME/dev/$BOOTSTRAP_REPOSITORY}"
BOOTSTRAP_URL=""
BOOTSTRAP_SETUP_ARGS=()

bootstrap_usage() {
  printf '%s\n' 'Usage:
  bash ~/Downloads/bootstrap.sh
  bash ~/Downloads/bootstrap.sh --help

Description:
  Clone this repository on a new macOS or Linux machine and run
  ./setup.sh --fix in it. It clones over SSH when a GitHub key works, and
  otherwise read-only over HTTPS. It asks for Personal or Work scope; Work
  also asks for the work overlay checkout (a path, or a Git URL to clone next
  to this checkout) and the job. Bootstrap itself installs no packages.

Options:
  -h, --help  Show this help menu and exit without changing the machine.

Examples:
  bash ~/Downloads/bootstrap.sh
  BOOTSTRAP_OWNER=you bash ~/Downloads/bootstrap.sh

Environment:
  BOOTSTRAP_OWNER        GitHub owner to clone from, for a fork (default:
                         the upstream owner).
  BOOTSTRAP_REPOSITORY   Repository name to clone (default: supernova).
  BOOTSTRAP_DESTINATION  Checkout path (default: ~/dev/REPOSITORY).'
}

bootstrap_fail() {
  printf '✗  %s\n' "$1" >&2
  [[ -z "${2:-}" ]] || printf '   %s\n' "$2" >&2
  return 1
}

bootstrap_check_prerequisites() {
  if [[ "${OSTYPE:-}" == darwin* ]]; then
    # /usr/bin/git exists without the Command Line Tools but only opens their installer.
    xcode-select -p >/dev/null 2>&1 ||
      bootstrap_fail "Apple Command Line Tools are required." "Run: xcode-select --install, then rerun bootstrap."
  elif ! command -v git >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      bootstrap_fail "Git is required." "Run: sudo apt-get update && sudo apt-get install -y git, then rerun bootstrap."
    else
      bootstrap_fail "Git is required." "Run: sudo dnf install -y git, then rerun bootstrap."
    fi
  fi
}

bootstrap_ssh_url() {
  printf 'git@%s:%s/%s.git\n' "$1" "$BOOTSTRAP_OWNER" "$BOOTSTRAP_REPOSITORY"
}

bootstrap_https_url() {
  printf 'https://github.com/%s/%s.git\n' "$BOOTSTRAP_OWNER" "$BOOTSTRAP_REPOSITORY"
}

bootstrap_can_read() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=8" \
    git -c credential.helper= ls-remote "$1" HEAD >/dev/null 2>&1
}

# Use the first SSH host that can read the repository, else public HTTPS.
bootstrap_choose_url() {
  local host
  for host in github-personal github.com; do
    BOOTSTRAP_URL="$(bootstrap_ssh_url "$host")"
    bootstrap_can_read "$BOOTSTRAP_URL" && return 0
  done
  BOOTSTRAP_URL="$(bootstrap_https_url)"
  if bootstrap_can_read "$BOOTSTRAP_URL"; then
    printf '•  No GitHub SSH key can read %s/%s; cloning read-only over HTTPS.\n' "$BOOTSTRAP_OWNER" "$BOOTSTRAP_REPOSITORY"
    return 0
  fi
  bootstrap_fail "No GitHub SSH key can read $BOOTSTRAP_OWNER/$BOOTSTRAP_REPOSITORY." \
    "Add a key at https://github.com/settings/keys (ssh-keygen -t ed25519 makes one), then rerun bootstrap."
}

# Reuse an existing checkout unchanged; git clone refuses a non-empty directory.
bootstrap_clone() {
  if [[ -f "$BOOTSTRAP_DESTINATION/setup.sh" ]]; then
    printf '•  Using the existing checkout at %s\n' "$BOOTSTRAP_DESTINATION"
    return 0
  fi
  bootstrap_choose_url || return 1
  mkdir -p "$(dirname "$BOOTSTRAP_DESTINATION")" &&
    git clone "$BOOTSTRAP_URL" "$BOOTSTRAP_DESTINATION" ||
    bootstrap_fail "Could not clone $BOOTSTRAP_URL into $BOOTSTRAP_DESTINATION."
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

# Print the overlay checkout's path: an existing directory, or a Git URL cloned
# (or already cloned) next to this checkout.
bootstrap_prepare_work_root() {
  local destination
  case "$1" in
    *://* | *@*:*)
      destination="$(dirname "$BOOTSTRAP_DESTINATION")/$(basename "${1%.git}")"
      [[ -d "$destination/.git" ]] || git clone "$1" "$destination" >&2 || return 1
      ;;
    *) destination="${1/#\~/$HOME}" ;;
  esac
  [[ -d "$destination" ]] || { printf '•  Not a directory: %s\n' "$destination" >&2; return 1; }
  (cd -- "$destination" && pwd)
}

# Set BOOTSTRAP_SETUP_ARGS to the scope flags for ./setup.sh --fix.
bootstrap_select_scope() {
  local response work_root jobs default_job=""

  while :; do
    printf 'Choose a setup scope: [1] Personal  [2] Work: '
    IFS= read -r response || return 1
    case "$response" in
      1|p|P|personal|Personal) BOOTSTRAP_SETUP_ARGS=(--personal); return 0 ;;
      2|w|W|work|Work) break ;;
    esac
  done

  while :; do
    printf 'Work overlay checkout (path or Git URL): '
    IFS= read -r response || return 1
    [[ -n "$response" ]] && work_root="$(bootstrap_prepare_work_root "$response")" && break
  done

  jobs="$(bootstrap_discover_work_jobs "$work_root")"
  # Suggest a job only when the overlay has exactly one; with several, the
  # first by name may be an old one, so ask for it by name.
  [[ -n "$jobs" && "$jobs" != *$'\n'* ]] && default_job="$jobs"
  [[ -z "$jobs" ]] || printf 'Overlay work jobs: %s\n' "$(printf '%s' "$jobs" | tr '\n' ' ')"
  while :; do
    printf 'Work job%s: ' "${default_job:+ [$default_job]}"
    IFS= read -r response || return 1
    response="${response:-$default_job}"
    if [[ "$response" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      BOOTSTRAP_SETUP_ARGS=(--work --job "$response" --work-root "$work_root")
      return 0
    fi
    printf '•  Job names start with a letter or number and use letters, numbers, dots, underscores, or hyphens\n'
  done
}

bootstrap_run_setup() {
  if ! (cd "$BOOTSTRAP_DESTINATION" && ./setup.sh --fix "${BOOTSTRAP_SETUP_ARGS[@]}"); then
    bootstrap_fail "Setup did not finish." "Rerun it with: cd $BOOTSTRAP_DESTINATION && ./setup.sh --fix ${BOOTSTRAP_SETUP_ARGS[*]}"
    return 1
  fi
  printf '✓  Done. Open a new terminal window to start the configured shell.\n'
}

bootstrap_main() {
  case "$#:${1:-}" in
    1:-h|1:--help) bootstrap_usage; return 0 ;;
    0:) ;;
    *) bootstrap_usage >&2; return 2 ;;
  esac
  [[ -t 0 && -t 1 ]] || { bootstrap_fail "Bootstrap needs an interactive terminal."; return 2; }

  bootstrap_check_prerequisites || return 1
  bootstrap_clone || return 1
  bootstrap_select_scope || return 1
  bootstrap_run_setup
}

if [[ "${BOOTSTRAP_SOURCE_ONLY:-false}" != true ]]; then
  bootstrap_main "$@"
fi
