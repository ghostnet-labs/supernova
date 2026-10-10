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

file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

# Help is complete and has no filesystem side effects.
help_home="$TMP_ROOT/help-home"
mkdir "$help_home"
help_output="$(HOME="$help_home" /bin/bash "$BOOTSTRAP" --help)"
assert_contains "$help_output" 'Usage:'
assert_contains "$help_output" 'bash ~/Downloads/bootstrap.sh'
assert_contains "$help_output" 'installs no packages'
[[ ! -e "$help_home/.local" ]] || fail_test "--help created bootstrap state"

# The tracked script is executable; a mode-less browser copy self-corrects only
# after the first bash launch, while --help remains side-effect-free.
[[ -x "$BOOTSTRAP" ]] || fail_test "tracked bootstrap is not executable"
downloaded_bootstrap="$TMP_ROOT/downloaded-bootstrap.sh"
cp "$BOOTSTRAP" "$downloaded_bootstrap"
chmod 644 "$downloaded_bootstrap"
HOME="$help_home" /bin/bash "$downloaded_bootstrap" --help >/dev/null
[[ "$(file_mode "$downloaded_bootstrap")" == 644 ]] || fail_test "--help changed the downloaded bootstrap mode"
prepare_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_SCRIPT_PATH_OVERRIDE="$downloaded_bootstrap" /bin/bash -c '
  source "$1"
  bootstrap_prepare_downloaded_script
' _ "$BOOTSTRAP")"
[[ -x "$downloaded_bootstrap" ]] || fail_test "downloaded bootstrap was not marked executable"
assert_contains "$prepare_output" "executable for future reruns"

# Platform and prerequisite stops print exact rerun commands.
unsupported_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$TMP_ROOT" /bin/bash -c '
  source "$1"
  BOOTSTRAP_PLATFORM_OVERRIDE=debian
  bootstrap_detect_platform
' _ "$BOOTSTRAP" 2>&1 || true)"
[[ -z "$unsupported_output" ]] || fail_test "platform detection emitted unexpected output"

mac_prereq_output="$(BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c '
  source "$1"
  BOOTSTRAP_PLATFORM=macos
  command() {
    if [[ "$1" == -v && "$2" == xcode-select ]]; then return 1; fi
    builtin command "$@"
  }
  bootstrap_check_prerequisites
' _ "$BOOTSTRAP" 2>&1 || true)"
assert_contains "$mac_prereq_output" 'xcode-select --install'

ubuntu_prereq_output="$(BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c '
  source "$1"
  BOOTSTRAP_PLATFORM=ubuntu
  command() {
    if [[ "$1" == -v && ( "$2" == git || "$2" == ssh ) ]]; then return 1; fi
    builtin command "$@"
  }
  bootstrap_check_prerequisites
' _ "$BOOTSTRAP" 2>&1 || true)"
assert_contains "$ubuntu_prereq_output" 'sudo apt-get update && sudo apt-get install -y git openssh-client'

redhat_prereq_output="$(BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c '
  source "$1"
  BOOTSTRAP_PLATFORM=rocky
  command() {
    if [[ "$1" == -v && ( "$2" == git || "$2" == ssh ) ]]; then return 1; fi
    builtin command "$@"
  }
  bootstrap_check_prerequisites
' _ "$BOOTSTRAP" 2>&1 || true)"
assert_contains "$redhat_prereq_output" 'sudo dnf install -y git openssh-clients'

# Existing SSH aliases are tried in the documented order and the first success wins.
alias_output="$(BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c '
  source "$1"
  seen=""
  bootstrap_test_repository_alias() {
    seen="${seen}${seen:+,}$1"
    [[ "$1" == github.com ]]
  }
  bootstrap_verify_repository_access
  printf "%s|%s|%s\n" "$seen" "$BOOTSTRAP_VERIFIED_ALIAS" "$BOOTSTRAP_VERIFIED_URL"
' _ "$BOOTSTRAP")"
assert_contains "$alias_output" 'github-personal,github.com|github.com|git@github.com:ghostnet-labs/supernova.git'

github_dot_com_output="$(BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c '
  source "$1"
  bootstrap_test_repository_alias() { [[ "$1" == github.com ]]; }
  bootstrap_verify_repository_access
  printf "%s\n" "$BOOTSTRAP_VERIFIED_ALIAS"
' _ "$BOOTSTRAP")"
[[ "$github_dot_com_output" == github.com ]] || fail_test "github.com fallback was not selected"
personal_alias_output="$(BOOTSTRAP_SOURCE_ONLY=true /bin/bash -c '
  source "$1"
  bootstrap_test_repository_alias() { [[ "$1" == github-personal ]]; }
  bootstrap_verify_repository_access
  printf "%s\n" "$BOOTSTRAP_VERIFIED_ALIAS"
' _ "$BOOTSTRAP")"
[[ "$personal_alias_output" == github-personal ]] || fail_test "github-personal was not selected first"

# Managed SSH configuration preserves the main config, backs it up, and refuses conflicts.
ssh_home="$TMP_ROOT/ssh-home"
mkdir -p "$ssh_home/.ssh"
printf 'Host work-github\n  HostName github.com\n' >"$ssh_home/.ssh/config"
ssh_config_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$ssh_home" BOOTSTRAP_SSH_DIR="$ssh_home/.ssh" /bin/bash -c '
  source "$1"
  bootstrap_install_personal_ssh_config "$HOME/.ssh/id_ed25519_github_personal"
' _ "$BOOTSTRAP")"
assert_contains "$ssh_config_output" 'Backed up the existing SSH config'
grep -Fqx 'Include ~/.ssh/config.d/*.conf' "$ssh_home/.ssh/config" || fail_test "SSH include was not added"
grep -Fq 'Host work-github' "$ssh_home/.ssh/config" || fail_test "existing SSH config was not preserved"
grep -Fq 'IdentityFile '"$ssh_home/.ssh/id_ed25519_github_personal" "$ssh_home/.ssh/config.d/setup-bootstrap.conf" || fail_test "managed identity path is wrong"
[[ "$(file_mode "$ssh_home/.ssh/config")" == 600 ]] || fail_test "SSH config mode is not 600"
[[ "$(find "$ssh_home/.ssh" -name 'config.bootstrap-backup-*' | wc -l | tr -d ' ')" -eq 1 ]] || fail_test "SSH config backup was not created exactly once"

conflict_home="$TMP_ROOT/conflict-home"
mkdir -p "$conflict_home/.ssh"
printf 'Host github-personal\n  IdentityFile ~/.ssh/work-key\n' >"$conflict_home/.ssh/config"
conflict_status=0
conflict_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$conflict_home" BOOTSTRAP_SSH_DIR="$conflict_home/.ssh" /bin/bash -c '
  source "$1"
  bootstrap_install_personal_ssh_config "$HOME/.ssh/id_ed25519_github_personal"
' _ "$BOOTSTRAP" 2>&1)" || conflict_status=$?
[[ "$conflict_status" -ne 0 ]] || fail_test "conflicting github-personal config was accepted"
assert_contains "$conflict_output" 'conflicting github-personal SSH definition'

# Guided key creation uses Ed25519 with an empty passphrase and verifies registration.
key_home="$TMP_ROOT/key-home"
mkdir "$key_home"
key_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$key_home" BOOTSTRAP_SSH_DIR="$key_home/.ssh" BOOTSTRAP_NO_OPEN=true /bin/bash -c '
  source "$1"
  checks=0
  bootstrap_test_https_access() { return 1; }
  bootstrap_verify_repository_access() {
    checks=$((checks + 1))
    if (( checks > 1 )); then
      BOOTSTRAP_VERIFIED_ALIAS=github-personal
      BOOTSTRAP_VERIFIED_URL="$(bootstrap_repo_url github-personal)"
      return 0
    fi
    return 1
  }
  ssh-keygen() {
    local destination=""
    while (( $# > 0 )); do
      [[ "$1" == -f ]] && { destination="$2"; shift 2; continue; }
      shift
    done
    printf private >"$destination"
    printf "ssh-ed25519 public test\\n" >"$destination.pub"
  }
  bootstrap_establish_github_access <<< "yes"
' _ "$BOOTSTRAP")"
assert_contains "$key_output" 'Created a no-passphrase Ed25519 key'
[[ "$(file_mode "$key_home/.ssh/id_ed25519_github_personal")" == 600 ]] || fail_test "generated private key mode is not 600"
grep -Fq 'Host github-personal' "$key_home/.ssh/config.d/setup-bootstrap.conf" || fail_test "generated key was not configured"

failed_registration_home="$TMP_ROOT/failed-registration"
mkdir "$failed_registration_home"
registration_status=0
registration_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$failed_registration_home" BOOTSTRAP_SSH_DIR="$failed_registration_home/.ssh" BOOTSTRAP_NO_OPEN=true /bin/bash -c '
  source "$1"
  bootstrap_verify_repository_access() { return 1; }
  bootstrap_test_https_access() { return 1; }
  ssh-keygen() {
    local destination=""
    while (( $# > 0 )); do [[ "$1" == -f ]] && { destination="$2"; shift 2; continue; }; shift; done
    printf private >"$destination"; printf "ssh-ed25519 public test\\n" >"$destination.pub"
  }
  bootstrap_establish_github_access <<< "yes"
' _ "$BOOTSTRAP" 2>&1)" || registration_status=$?
[[ "$registration_status" -ne 0 ]] || fail_test "failed GitHub registration unexpectedly passed"
assert_contains "$registration_output" 'GitHub still cannot authenticate'

# A public repository without a working SSH key clones read-only over HTTPS by
# default, and still offers the SSH key; a private one cancels on no.
https_home="$TMP_ROOT/https-home"
mkdir "$https_home"
https_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$https_home" BOOTSTRAP_SSH_DIR="$https_home/.ssh" /bin/bash -c '
  source "$1"
  bootstrap_verify_repository_access() { return 1; }
  bootstrap_test_https_access() { return 0; }
  ssh-keygen() { printf "UNEXPECTED_KEYGEN\\n"; return 99; }
  bootstrap_establish_github_access <<< ""
  printf "%s|%s\\n" "$BOOTSTRAP_VERIFIED_ALIAS" "$BOOTSTRAP_VERIFIED_URL"
' _ "$BOOTSTRAP")"
assert_contains "$https_output" 'Cloning read-only over HTTPS'
assert_contains "$https_output" 'HTTPS|https://github.com/ghostnet-labs/supernova.git'
assert_not_contains "$https_output" 'UNEXPECTED_KEYGEN'
[[ ! -e "$https_home/.ssh" ]] || fail_test "HTTPS clone changed SSH state"

https_key_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$https_home" BOOTSTRAP_SSH_DIR="$https_home/.ssh" BOOTSTRAP_NO_OPEN=true /bin/bash -c '
  source "$1"
  bootstrap_verify_repository_access() { return 1; }
  bootstrap_test_https_access() { return 0; }
  bootstrap_install_personal_ssh_config() { printf "SSH_CONFIGURED\\n"; }
  ssh-keygen() { printf "KEYGEN\\n"; return 1; }
  bootstrap_establish_github_access <<< "yes"
' _ "$BOOTSTRAP" 2>&1)" || true
assert_contains "$https_key_output" 'KEYGEN'

private_status=0
private_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$https_home" BOOTSTRAP_SSH_DIR="$https_home/.ssh" /bin/bash -c '
  source "$1"
  bootstrap_verify_repository_access() { return 1; }
  bootstrap_test_https_access() { return 1; }
  bootstrap_establish_github_access <<< ""
' _ "$BOOTSTRAP" 2>&1)" || private_status=$?
[[ "$private_status" -ne 0 ]] || fail_test "private repository without SSH access unexpectedly passed"
assert_contains "$private_output" 'GitHub SSH setup was cancelled'

# A fork names its own owner and repository, and the default checkout follows it.
fork_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$https_home" BOOTSTRAP_OWNER=someone BOOTSTRAP_REPOSITORY=dots /bin/bash -c '
  source "$1"
  printf "%s|%s|%s\\n" "$(bootstrap_repo_url github.com)" "$(bootstrap_https_url)" "$BOOTSTRAP_DESTINATION"
' _ "$BOOTSTRAP")"
[[ "$fork_output" == "git@github.com:someone/dots.git|https://github.com/someone/dots.git|$https_home/dev/dots" ]] ||
  fail_test "fork owner and repository were not used: $fork_output"

# Fresh clone, empty destination, unchanged reuse, and unrelated-directory refusal.
clone_root="$TMP_ROOT/clones"
mkdir "$clone_root"
clone_output="$(BOOTSTRAP_SOURCE_ONLY=true HOME="$TMP_ROOT" BOOTSTRAP_DESTINATION="$clone_root/fresh" /bin/bash -c '
  source "$1"
  BOOTSTRAP_VERIFIED_URL="git@github-personal:ghostnet-labs/supernova.git"
  git() {
    [[ "$1" == clone ]] || return 99
    mkdir -p "$3/.git" "$3/setup"
    touch "$3/setup.sh" "$3/setup/dependencies.sh" "$3/setup/state.sh" "$3/setup/repair.sh" "$3/setup/status_output.sh"
  }
  bootstrap_clone_or_resume
' _ "$BOOTSTRAP")"
assert_contains "$clone_output" 'Cloned the setup repository'

interrupted_destination="$clone_root/interrupted"
mkdir "$interrupted_destination"
interrupted_status=0
BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$interrupted_destination" /bin/bash -c '
  source "$1"; BOOTSTRAP_VERIFIED_URL="git@github-personal:ghostnet-labs/supernova.git"
  git() { mkdir -p "$3"; touch "$3/partial"; return 1; }
  bootstrap_clone_or_resume >/dev/null 2>&1
  status=$?
  bootstrap_cleanup
  [[ -z "$(ls -A "$BOOTSTRAP_DESTINATION")" ]]
  exit "$status"
' _ "$BOOTSTRAP" || interrupted_status=$?
[[ "$interrupted_status" -ne 0 ]] || fail_test "interrupted clone unexpectedly passed"
[[ -z "$(find "$clone_root" -maxdepth 1 -name '.setup-bootstrap-clone-*' -print -quit)" ]] || fail_test "interrupted clone staging was not cleaned"

empty_destination="$clone_root/empty"
mkdir "$empty_destination"
BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$empty_destination" /bin/bash -c '
  source "$1"; BOOTSTRAP_VERIFIED_URL="git@github-personal:ghostnet-labs/supernova.git"
  git() { mkdir -p "$3/.git" "$3/setup"; touch "$3/setup.sh" "$3/setup/dependencies.sh" "$3/setup/state.sh" "$3/setup/repair.sh" "$3/setup/status_output.sh"; }
  bootstrap_clone_or_resume >/dev/null
' _ "$BOOTSTRAP" || fail_test "empty destination was not reusable"

reuse_destination="$clone_root/reuse"
mkdir -p "$reuse_destination/.git" "$reuse_destination/setup"
touch "$reuse_destination/setup.sh" "$reuse_destination/setup/dependencies.sh" "$reuse_destination/setup/state.sh" "$reuse_destination/setup/repair.sh" "$reuse_destination/setup/status_output.sh"
reuse_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$reuse_destination" /bin/bash -c '
  source "$1"
  git() {
    if [[ "$1" == -C && "$3" == config ]]; then printf "git@github-personal:ghostnet-labs/supernova.git\\n"; return 0; fi
    printf "UNEXPECTED_GIT:%s\\n" "$*"; return 99
  }
  bootstrap_clone_or_resume
' _ "$BOOTSTRAP")"
assert_contains "$reuse_output" 'Reusing the existing setup checkout unchanged'
assert_not_contains "$reuse_output" 'UNEXPECTED_GIT'
BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$reuse_destination" /bin/bash -c '
  source "$1"
  git() { [[ "$1" == -C && "$3" == config ]] && printf "https://github.com/ghostnet-labs/supernova.git\\n"; }
  bootstrap_clone_or_resume >/dev/null
' _ "$BOOTSTRAP" || fail_test "correct HTTPS checkout origin was not reusable"
BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$reuse_destination" /bin/bash -c '
  source "$1"
  git() { [[ "$1" == -C && "$3" == config ]] && printf "git@github-personal:someone-else/supernova.git\\n"; }
  bootstrap_clone_or_resume >/dev/null 2>&1
' _ "$BOOTSTRAP" && fail_test "checkout with an unrelated owner was reused"

unrelated_destination="$clone_root/unrelated"
mkdir "$unrelated_destination"
printf keep >"$unrelated_destination/file"
unrelated_status=0
unrelated_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$unrelated_destination" /bin/bash -c 'source "$1"; bootstrap_clone_or_resume' _ "$BOOTSTRAP" 2>&1)" || unrelated_status=$?
[[ "$unrelated_status" -ne 0 ]] || fail_test "unrelated destination was accepted"
assert_contains "$unrelated_output" 'unrelated non-empty directory'

# Scope selection asks for the work overlay checkout, discovers its jobs,
# defaults to the first, and rejects bad names.
scope_checkout="$TMP_ROOT/scope-checkout"
scope_overlay="$TMP_ROOT/scope-overlay"
mkdir -p "$scope_checkout/setup" "$scope_overlay/acme/bin-acme" "$scope_overlay/zeta/bin-zeta" "$scope_overlay/notes"
# bootstrap reports the overlay as cd and pwd resolve it, without a doubled slash
# from a TMPDIR that ends in one (as on macOS).
scope_overlay="$(cd -- "$scope_overlay" && pwd)"
personal_scope="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$scope_checkout" /bin/bash -c 'source "$1"; bootstrap_select_scope <<<1; printf "%s|%s|%s\n" "$BOOTSTRAP_SCOPE" "$BOOTSTRAP_JOB" "$BOOTSTRAP_RERUN_COMMAND"' _ "$BOOTSTRAP")"
assert_contains "$personal_scope" 'personal||./setup.sh --fix --personal'
work_scope="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$scope_checkout" /bin/bash -c 'source "$1"; bootstrap_select_scope <<< "2
$3
$2
"; printf "%s|%s|%s|%s\n" "$BOOTSTRAP_SCOPE" "$BOOTSTRAP_JOB" "$BOOTSTRAP_WORK_ROOT" "$BOOTSTRAP_RERUN_COMMAND"' _ "$BOOTSTRAP" "$scope_overlay" "$TMP_ROOT/missing-overlay")"
assert_contains "$work_scope" "work|acme|$scope_overlay|./setup.sh --fix --work --job acme --work-root $scope_overlay"
assert_contains "$work_scope" 'Overlay work jobs: acme zeta'
assert_contains "$work_scope" "Not a directory: $TMP_ROOT/missing-overlay"
custom_scope="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$scope_checkout" /bin/bash -c 'source "$1"; bootstrap_select_scope <<< "2
$2
.bad
custom-job"; printf "%s\n" "$BOOTSTRAP_JOB"' _ "$BOOTSTRAP" "$scope_overlay")"
assert_contains "$custom_scope" 'custom-job'
assert_contains "$custom_scope" 'Job names must start'

# Setup cancellation/failure reports an exact rerun command.
setup_checkout="$TMP_ROOT/setup-run"
mkdir "$setup_checkout"
printf '#!/bin/sh\nexit "${FAKE_SETUP_STATUS:-0}"\n' >"$setup_checkout/setup.sh"
chmod +x "$setup_checkout/setup.sh"
setup_failure_status=0
setup_failure_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$setup_checkout" FAKE_SETUP_STATUS=7 /bin/bash -c '
  source "$1"; BOOTSTRAP_SCOPE=work; BOOTSTRAP_JOB=acme; BOOTSTRAP_WORK_ROOT=/overlay; BOOTSTRAP_RERUN_COMMAND="./setup.sh --fix --work --job acme --work-root /overlay"; bootstrap_run_setup
' _ "$BOOTSTRAP" 2>&1)" || setup_failure_status=$?
[[ "$setup_failure_status" -eq 7 ]] || fail_test "setup failure status was not preserved"
assert_contains "$setup_failure_output" './setup.sh --fix --work --job acme --work-root /overlay'

# Managed-shell verification distinguishes check failures from test failures.
verify_checkout="$TMP_ROOT/verify"
mkdir "$verify_checkout"
verify_calls="$TMP_ROOT/verify-calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$VERIFY_CALLS"\ncase "$*" in *--check*) exit "${VERIFY_CHECK_STATUS:-0}";; *--test*) exit "${VERIFY_TEST_STATUS:-0}";; esac\n' >"$verify_checkout/setup.sh"
chmod +x "$verify_checkout/setup.sh"
fake_zsh="$TMP_ROOT/fake-zsh"
printf '#!/bin/sh\nexec /bin/bash -c "$2"\n' >"$fake_zsh"
chmod +x "$fake_zsh"
manual_verify_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$verify_checkout" VERIFY_CALLS="$verify_calls" FAKE_ZSH="$fake_zsh" /bin/bash -c '
  source "$1"; BOOTSTRAP_SCOPE=work; bootstrap_resolve_managed_zsh() { BOOTSTRAP_MANAGED_ZSH="$FAKE_ZSH"; }; bootstrap_verify_setup
' _ "$BOOTSTRAP")"
assert_contains "$manual_verify_output" 'Scope-appropriate repository test suite passed'
grep -Fxq -- '--check --work' "$verify_calls" || fail_test "work verification was not scope-aware"
grep -Fxq -- '--test' "$verify_calls" || fail_test "work verification did not run the full repository tests"

managed_status=0
managed_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$verify_checkout" VERIFY_CALLS="$verify_calls" VERIFY_CHECK_STATUS=1 FAKE_ZSH="$fake_zsh" /bin/bash -c '
  source "$1"; BOOTSTRAP_SCOPE=personal; bootstrap_resolve_managed_zsh() { BOOTSTRAP_MANAGED_ZSH="$FAKE_ZSH"; }; bootstrap_verify_setup
' _ "$BOOTSTRAP" 2>&1)" || managed_status=$?
[[ "$managed_status" -ne 0 ]] || fail_test "managed health failure unexpectedly passed"
assert_contains "$managed_output" 'health check still has managed findings'

test_status=0
test_output="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_DESTINATION="$verify_checkout" VERIFY_CALLS="$verify_calls" VERIFY_TEST_STATUS=1 FAKE_ZSH="$fake_zsh" /bin/bash -c '
  source "$1"; BOOTSTRAP_SCOPE=personal; bootstrap_resolve_managed_zsh() { BOOTSTRAP_MANAGED_ZSH="$FAKE_ZSH"; }; bootstrap_verify_setup
' _ "$BOOTSTRAP" 2>&1)" || test_status=$?
[[ "$test_status" -ne 0 ]] || fail_test "repository test failure unexpectedly passed"
assert_contains "$test_output" 'Repository regression tests failed'
assert_contains "$test_output" './setup.sh --test --personal'
grep -Fxq -- '--test --personal' "$verify_calls" || fail_test "personal verification was not scope-aware"

# macOS verification and handoff use the system shell without consulting Brew.
system_zsh="$TMP_ROOT/system-zsh"
printf '#!/bin/sh\nexit 0\n' >"$system_zsh"
chmod +x "$system_zsh"
resolved_macos_zsh="$(BOOTSTRAP_SOURCE_ONLY=true BOOTSTRAP_SYSTEM_ZSH="$system_zsh" /bin/bash -c '
  source "$1"
  BOOTSTRAP_PLATFORM=macos
  bootstrap_resolve_managed_zsh
  printf "%s\n" "$BOOTSTRAP_MANAGED_ZSH"
' _ "$BOOTSTRAP")"
[[ "$resolved_macos_zsh" == "$system_zsh" ]] || fail_test "macOS did not resolve the system Zsh"

# Private logging and idempotent reruns create distinct 600 logs in a 700 directory.
log_home="$TMP_ROOT/log-home"
mkdir "$log_home"
BOOTSTRAP_SOURCE_ONLY=true HOME="$log_home" /bin/bash -c 'source "$1"; bootstrap_initialize_log; printf "%s\n" "$BOOTSTRAP_LOG_FILE"' _ "$BOOTSTRAP" >"$TMP_ROOT/log-one"
BOOTSTRAP_SOURCE_ONLY=true HOME="$log_home" /bin/bash -c 'source "$1"; bootstrap_initialize_log; printf "%s\n" "$BOOTSTRAP_LOG_FILE"' _ "$BOOTSTRAP" >"$TMP_ROOT/log-two"
[[ "$(file_mode "$log_home/.local/state/setup-bootstrap")" == 700 ]] || fail_test "bootstrap log directory mode is not 700"
while IFS= read -r log_file; do [[ "$(file_mode "$log_file")" == 600 ]] || fail_test "bootstrap log mode is not 600"; done < <(find "$log_home/.local/state/setup-bootstrap" -type f)
[[ "$(find "$log_home/.local/state/setup-bootstrap" -type f | wc -l | tr -d ' ')" -eq 2 ]] || fail_test "bootstrap rerun did not create two distinct logs"

# Ghostty launch and Linux/current-terminal handoffs use managed Zsh correctly.
handoff_record="$TMP_ROOT/handoff-record"
open_bin="$TMP_ROOT/open-bin"
mkdir "$open_bin"
printf '#!/bin/sh\nprintf "open:%%s\\n" "$*" >>"$HANDOFF_RECORD"\nexit "${OPEN_STATUS:-0}"\n' >"$open_bin/open"
printf '#!/bin/sh\nprintf "zsh:%%s\\n" "$*" >>"$HANDOFF_RECORD"\n' >"$open_bin/zsh"
chmod +x "$open_bin/open" "$open_bin/zsh"
BOOTSTRAP_SOURCE_ONLY=true PATH="$open_bin:$PATH" HANDOFF_RECORD="$handoff_record" /bin/bash -c 'source "$1"; BOOTSTRAP_PLATFORM=macos; BOOTSTRAP_MANAGED_ZSH="$2/zsh"; BOOTSTRAP_LOG_FILE=/tmp/test.log; TERM_PROGRAM=Terminal; bootstrap_handoff' _ "$BOOTSTRAP" "$open_bin" >/dev/null
grep -Fq 'open:-na Ghostty' "$handoff_record" || fail_test "Ghostty was not launched from another macOS terminal"
BOOTSTRAP_SOURCE_ONLY=true PATH="$open_bin:$PATH" HANDOFF_RECORD="$handoff_record" /bin/bash -c 'source "$1"; BOOTSTRAP_PLATFORM=linux; BOOTSTRAP_MANAGED_ZSH="$2/zsh"; BOOTSTRAP_LOG_FILE=/tmp/test.log; bootstrap_handoff' _ "$BOOTSTRAP" "$open_bin" >/dev/null
grep -Fq 'zsh:-l' "$handoff_record" || fail_test "Linux did not hand off to login Zsh"
OPEN_STATUS=1 BOOTSTRAP_SOURCE_ONLY=true PATH="$open_bin:$PATH" HANDOFF_RECORD="$handoff_record" /bin/bash -c 'source "$1"; BOOTSTRAP_PLATFORM=macos; BOOTSTRAP_MANAGED_ZSH="$2/zsh"; BOOTSTRAP_LOG_FILE=/tmp/test.log; TERM_PROGRAM=Terminal; bootstrap_handoff' _ "$BOOTSTRAP" "$open_bin" >/dev/null
[[ "$(grep -Fc 'zsh:-l' "$handoff_record")" -eq 2 ]] || fail_test "failed Ghostty launch did not fall back to login Zsh"

printf '[PASS] bootstrap regression checks\n'
