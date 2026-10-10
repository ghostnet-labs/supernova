#!/usr/bin/env bash
# setup-test: bootstrap.sh
# setup-test-scope: work
# Isolated regression checks for browser-downloaded first-machine bootstrap.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="$REPO_DIR/bootstrap.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-bootstrap-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

# Run a snippet with bootstrap's functions loaded; $1 inside it is bootstrap.sh.
in_bootstrap() {
  local snippet="$1"
  shift
  BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c 'source "$1"; shift; '"$snippet" _ "$BOOTSTRAP" "$@"
}

# Help is complete and has no side effects; the tracked script is executable.
help_home="$TMP_ROOT/help-home"
mkdir "$help_home"
help_output="$(HOME="$help_home" /bin/bash "$BOOTSTRAP" --help)"
assert_contains "$help_output" 'Usage:'
assert_contains "$help_output" 'bash ~/Downloads/bootstrap.sh'
assert_contains "$help_output" 'installs no packages'
assert_contains "$help_output" 'BOOTSTRAP_OWNER'
[[ -z "$(ls -A "$help_home")" ]] || fail_test "--help changed HOME"
[[ -x "$BOOTSTRAP" ]] || fail_test "tracked bootstrap is not executable"
bad_option_status=0
/bin/bash "$BOOTSTRAP" --bogus >/dev/null 2>&1 || bad_option_status=$?
[[ "$bad_option_status" -eq 2 ]] || fail_test "an unknown option did not exit 2"
not_interactive_status=0
not_interactive_output="$(/bin/bash "$BOOTSTRAP" </dev/null 2>&1)" || not_interactive_status=$?
[[ "$not_interactive_status" -eq 2 ]] || fail_test "a non-interactive run did not exit 2"
assert_contains "$not_interactive_output" 'interactive terminal'

# Missing prerequisites stop with the install command.
mac_prereq_output="$(in_bootstrap 'OSTYPE=darwin25; xcode-select() { return 1; }; bootstrap_check_prerequisites' 2>&1 || true)"
assert_contains "$mac_prereq_output" 'xcode-select --install'
apt_prereq_output="$(in_bootstrap '
  OSTYPE=linux-gnu
  command() { [[ "$2" == apt-get ]] && return 0; [[ "$2" == git ]] && return 1; builtin command "$@"; }
  bootstrap_check_prerequisites' 2>&1 || true)"
assert_contains "$apt_prereq_output" 'sudo apt-get update && sudo apt-get install -y git'
dnf_prereq_output="$(in_bootstrap '
  OSTYPE=linux-gnu
  command() { [[ "$2" == apt-get || "$2" == git ]] && return 1; builtin command "$@"; }
  bootstrap_check_prerequisites' 2>&1 || true)"
assert_contains "$dnf_prereq_output" 'sudo dnf install -y git'
in_bootstrap 'OSTYPE=linux-gnu; bootstrap_check_prerequisites' || fail_test "installed Git was reported missing"

# SSH hosts are tried in order and the first that reads the repository wins;
# without one, a public repository is cloned read-only over HTTPS.
ssh_output="$(in_bootstrap '
  bootstrap_can_read() { printf "tried %s\n" "$1"; [[ "$1" == git@github.com:* ]]; }
  bootstrap_choose_url; printf "url %s\n" "$BOOTSTRAP_URL"')"
assert_contains "$ssh_output" $'tried git@github-personal:ghostnet-labs/supernova.git\ntried git@github.com:ghostnet-labs/supernova.git\nurl git@github.com:ghostnet-labs/supernova.git'
https_output="$(in_bootstrap '
  bootstrap_can_read() { [[ "$1" == https://* ]]; }
  bootstrap_choose_url; printf "url %s\n" "$BOOTSTRAP_URL"')"
assert_contains "$https_output" 'cloning read-only over HTTPS'
assert_contains "$https_output" 'url https://github.com/ghostnet-labs/supernova.git'
private_status=0
private_output="$(in_bootstrap 'bootstrap_can_read() { return 1; }; bootstrap_choose_url' 2>&1)" || private_status=$?
[[ "$private_status" -ne 0 ]] || fail_test "an unreadable repository unexpectedly passed"
assert_contains "$private_output" 'https://github.com/settings/keys'

# A fork names its own owner and repository, and the default checkout follows it.
fork_output="$(HOME="$TMP_ROOT/fork-home" BOOTSTRAP_OWNER=someone BOOTSTRAP_REPOSITORY=dots \
  in_bootstrap 'printf "%s|%s|%s\n" "$(bootstrap_ssh_url github.com)" "$(bootstrap_https_url)" "$BOOTSTRAP_DESTINATION"')"
[[ "$fork_output" == "git@github.com:someone/dots.git|https://github.com/someone/dots.git|$TMP_ROOT/fork-home/dev/dots" ]] ||
  fail_test "fork owner and repository were not used: $fork_output"

# A fresh clone goes to the destination; an existing checkout is reused
# without touching the network; a failed clone reports the URL.
clone_root="$TMP_ROOT/clones"
fresh_output="$(BOOTSTRAP_DESTINATION="$clone_root/fresh" in_bootstrap '
  bootstrap_can_read() { return 0; }
  git() { printf "git %s\n" "$*"; }
  bootstrap_clone')"
assert_contains "$fresh_output" "git clone git@github-personal:ghostnet-labs/supernova.git $clone_root/fresh"
mkdir -p "$clone_root/existing"
touch "$clone_root/existing/setup.sh"
reuse_output="$(BOOTSTRAP_DESTINATION="$clone_root/existing" in_bootstrap '
  git() { printf "UNEXPECTED_GIT\n"; }
  bootstrap_clone')"
assert_contains "$reuse_output" 'Using the existing checkout'
assert_not_contains "$reuse_output" 'UNEXPECTED_GIT'
failed_clone_status=0
failed_clone_output="$(BOOTSTRAP_DESTINATION="$clone_root/failed" in_bootstrap '
  bootstrap_can_read() { return 0; }
  git() { return 128; }
  bootstrap_clone' 2>&1)" || failed_clone_status=$?
[[ "$failed_clone_status" -ne 0 ]] || fail_test "a failed clone unexpectedly passed"
assert_contains "$failed_clone_output" "Could not clone git@github-personal:ghostnet-labs/supernova.git"

# Scope selection asks for the work overlay checkout, discovers its jobs,
# suggests a job only when there is exactly one, and rejects bad names.
scope_overlay="$TMP_ROOT/scope-overlay"
mkdir -p "$scope_overlay/acme/bin-acme" "$scope_overlay/zeta/bin-zeta" "$scope_overlay/notes"
# bootstrap reports the overlay as cd and pwd resolve it, without a doubled slash
# from a TMPDIR that ends in one (as on macOS).
scope_overlay="$(cd -- "$scope_overlay" && pwd)"
show_args='printf "\nargs %s\n" "${BOOTSTRAP_SETUP_ARGS[*]}"'
personal_scope="$(in_bootstrap "bootstrap_select_scope <<<1; $show_args")"
assert_contains "$personal_scope" 'args --personal'
work_scope="$(in_bootstrap 'bootstrap_select_scope <<< "x
2
$2
$1

.bad
zeta
"; '"$show_args" "$scope_overlay" "$TMP_ROOT/missing-overlay" 2>&1)"
assert_contains "$work_scope" "Not a directory: $TMP_ROOT/missing-overlay"
assert_contains "$work_scope" 'Overlay work jobs: acme zeta'
assert_not_contains "$work_scope" 'Work job ['
assert_contains "$work_scope" 'Job names start'
assert_contains "$work_scope" "args --work --job zeta --work-root $scope_overlay"
single_overlay="$TMP_ROOT/single-overlay"
mkdir -p "$single_overlay/acme/bin-acme"
single_overlay="$(cd -- "$single_overlay" && pwd)"
single_scope="$(in_bootstrap 'bootstrap_select_scope <<< "2
$1
"; '"$show_args" "$single_overlay")"
assert_contains "$single_scope" 'Work job [acme]: '
assert_contains "$single_scope" "args --work --job acme --work-root $single_overlay"
in_bootstrap 'bootstrap_select_scope <<< "2"' >/dev/null && fail_test "end of input while choosing a scope did not stop"

# A Git URL overlay is cloned next to the checkout, or reused when already there.
url_root="$TMP_ROOT/url-root"
mkdir -p "$url_root/existing-overlay/.git"
url_reuse="$(BOOTSTRAP_DESTINATION="$url_root/supernova" in_bootstrap '
  git() { printf "UNEXPECTED_GIT\n"; }
  bootstrap_prepare_work_root git@example.com:me/existing-overlay.git')"
[[ "$url_reuse" == "$(cd -- "$url_root/existing-overlay" && pwd)" ]] || fail_test "an existing overlay clone was not reused: $url_reuse"
url_clone="$(BOOTSTRAP_DESTINATION="$url_root/supernova" in_bootstrap '
  git() { printf "git %s\n" "$*" >&2; mkdir -p "$3"; }
  bootstrap_prepare_work_root https://example.com/me/new-overlay.git' 2>&1)"
assert_contains "$url_clone" "git clone https://example.com/me/new-overlay.git $url_root/new-overlay"

# Setup gets the chosen scope; a failure prints the exact rerun command.
setup_checkout="$TMP_ROOT/setup-run"
mkdir "$setup_checkout"
printf '#!/bin/sh\nprintf "setup %%s\\n" "$*"\nexit "${FAKE_SETUP_STATUS:-0}"\n' >"$setup_checkout/setup.sh"
chmod +x "$setup_checkout/setup.sh"
setup_output="$(BOOTSTRAP_DESTINATION="$setup_checkout" in_bootstrap '
  BOOTSTRAP_SETUP_ARGS=(--work --job acme --work-root /overlay); bootstrap_run_setup')"
assert_contains "$setup_output" 'setup --fix --work --job acme --work-root /overlay'
assert_contains "$setup_output" 'Open a new terminal window'
setup_failure_status=0
setup_failure_output="$(BOOTSTRAP_DESTINATION="$setup_checkout" FAKE_SETUP_STATUS=7 in_bootstrap '
  BOOTSTRAP_SETUP_ARGS=(--personal); bootstrap_run_setup' 2>&1)" || setup_failure_status=$?
[[ "$setup_failure_status" -ne 0 ]] || fail_test "a setup failure unexpectedly passed"
assert_contains "$setup_failure_output" "Rerun it with: cd $setup_checkout && ./setup.sh --fix --personal"

printf '[PASS] bootstrap regression checks\n'
