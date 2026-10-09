#!/usr/bin/env bash
# setup-test: setup.sh commands
# setup-test-scope: work
# Regression checks for the unified setup.sh command; no live repairs.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$REPO_DIR/setup.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-command-test.XXXXXX")"
ENV_FILE="$TMP_ROOT/env.zsh"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

assert_count() {
  local count
  count="$(grep -Foc -- "$2" <<<"$1" || true)"
  [[ "$count" -eq "$3" ]] || fail_test "expected $3 occurrence(s) of '$2', found $count"
}

assert_plain_output() {
  assert_not_contains "$1" $'\033'
  assert_not_contains "$1" $'\r'
  assert_not_contains "$1" '[CHECK]'
  assert_not_contains "$1" '[PASS]'
  assert_not_contains "$1" '[FAIL]'
}

PARSE_OUTPUT=""
SETUP_SOURCE_ONLY=true
source "$SETUP"

capture_parse() {
  local status=0
  MODE=""
  CLI_WORK_ENV=""
  CLI_JOB=""
  CLI_WORK_ROOT=""
  WORK_FLAG_REQUESTED=false
  DRY_RUN=false
  HELP_REQUESTED=false
  parse_args "$@" >/dev/null 2>&1 || status=$?
  PARSE_OUTPUT="status=$status mode=$MODE work=$CLI_WORK_ENV job=$CLI_JOB dry=$DRY_RUN help=$HELP_REQUESTED"
}

help_output="$("$SETUP" --help)"
assert_contains "$help_output" 'Usage:'
assert_contains "$help_output" '--test'
assert_contains "$help_output" '--check'
assert_contains "$help_output" '--fix'
assert_contains "$help_output" 'requires explicit interactive confirmation'
assert_not_contains "$help_output" '--yes'
assert_not_contains "$help_output" '--dependencies-only'
assert_not_contains "$help_output" '--upgrade'
assert_not_contains "$help_output" 'SETUP_DOCTOR_COMMAND'
assert_not_contains "$help_output" 'SETUP_REPAIR_COMMAND'

capture_parse --test
assert_contains "$PARSE_OUTPUT" 'status=0 mode=--test'
capture_parse --test --personal
assert_contains "$PARSE_OUTPUT" 'status=0 mode=--test work=false'
capture_parse --check --work
assert_contains "$PARSE_OUTPUT" 'status=0 mode=--check work=true'
capture_parse --fix --personal --dry-run
assert_contains "$PARSE_OUTPUT" 'status=0 mode=--fix work=false'
assert_contains "$PARSE_OUTPUT" 'dry=true'
capture_parse --fix --job acme
assert_contains "$PARSE_OUTPUT" 'status=0 mode=--fix work=true job=acme'
capture_parse --fix --job acme --work-root "$REPO_DIR/tests/fixtures/overlay"
assert_contains "$PARSE_OUTPUT" 'status=0 mode=--fix work=true job=acme'
[[ "$CLI_WORK_ROOT" == "$REPO_DIR/tests/fixtures/overlay" ]] || fail_test "--work-root was not recorded: $CLI_WORK_ROOT"
capture_parse --fix --job acme --work-root "$TMP_ROOT/missing-overlay"
assert_contains "$PARSE_OUTPUT" 'status=2'
capture_parse --fix --personal --work-root "$REPO_DIR/tests/fixtures/overlay"
assert_contains "$PARSE_OUTPUT" 'status=2'
capture_parse --test --work-root "$REPO_DIR/tests/fixtures/overlay"
assert_contains "$PARSE_OUTPUT" 'status=2'
capture_parse --test --check
assert_contains "$PARSE_OUTPUT" 'status=2'
capture_parse --check --personal
assert_contains "$PARSE_OUTPUT" 'status=2'
capture_parse --test --dry-run
assert_contains "$PARSE_OUTPUT" 'status=2'
for invalid_job in . .. _acme bad/name; do
  capture_parse --fix --job "$invalid_job"
  assert_contains "$PARSE_OUTPUT" 'status=2'
done

# Personal repository tests run only suites that do not exercise Work scope;
# the default developer/work suite retains mixed and Work-only coverage and
# adds the configured work overlay's rows (here the acme fixture overlay).
printf '%s\n' 'WORK_ENV=true' 'JOB=acme' "WORK_ROOT=$REPO_DIR/tests/fixtures/overlay" >"$ENV_FILE"
export SETUP_LOCAL_ENV_FILE="$ENV_FILE"
personal_test_plan="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  CLI_WORK_ENV=false
  run_test_check() { printf "%s|" "$1"; shift; printf "%s " "$@"; printf "\n"; }
  run_repository_tests
' _ "$SETUP")"
assert_contains "$personal_test_plan" 'Tests: Status output'
assert_contains "$personal_test_plan" 'Tests: Codex config'
assert_contains "$personal_test_plan" 'Help: home shell functions'
assert_contains "$personal_test_plan" 'Tests: Shell functions'
assert_contains "$personal_test_plan" 'Tests: Git functions'
assert_not_contains "$personal_test_plan" 'Tests: .zshrc reload'
assert_not_contains "$personal_test_plan" 'Tests: Setup dependency contract'
assert_not_contains "$personal_test_plan" 'Tests: Repair module'
assert_not_contains "$personal_test_plan" 'Tests: Setup state'
assert_not_contains "$personal_test_plan" 'Tests: setup.sh commands'
assert_not_contains "$personal_test_plan" 'Tests: bootstrap.sh'
assert_contains "$personal_test_plan" 'Help: tmux-fzf'
assert_not_contains "$personal_test_plan" 'Help: tmux-git-status'
assert_not_contains "$personal_test_plan" 'acme'
assert_not_contains "$personal_test_plan" 'Work overlay hooks'

full_test_plan="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  CLI_WORK_ENV=""
  run_test_check() { printf "%s|" "$1"; shift; printf "%s " "$@"; printf "\n"; }
  run_repository_tests
' _ "$SETUP")"
assert_contains "$full_test_plan" 'Syntax: acme tools and tests'
assert_contains "$full_test_plan" 'Tests: .zshrc reload'
assert_contains "$full_test_plan" 'Tests: Setup dependency contract'
assert_contains "$full_test_plan" 'Tests: Repair module'
assert_contains "$full_test_plan" 'Tests: Setup state'
assert_contains "$full_test_plan" 'Tests: setup.sh commands'
assert_contains "$full_test_plan" 'Tests: bootstrap.sh'
assert_contains "$full_test_plan" 'Tests: Work overlay hooks'
assert_contains "$full_test_plan" 'Tests: Acme fixture overlay'
assert_contains "$full_test_plan" 'Help: acme-hello'
assert_contains "$full_test_plan" 'Help: acme shell functions'
no_overlay_plan="$(SETUP_LOCAL_ENV_FILE="$TMP_ROOT/absent.zsh" /bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  CLI_WORK_ENV=""
  run_test_check() { printf "%s|" "$1"; shift; printf "%s " "$@"; printf "\n"; }
  run_repository_tests
' _ "$SETUP")"
assert_contains "$no_overlay_plan" 'Tests: Work overlay hooks'
assert_not_contains "$no_overlay_plan" 'acme'

# Every test file is discovered, and scope headers keep Work coverage out of
# the personal plan.
cd "$REPO_DIR"
for discovered_test in tests/*/test_*; do
  assert_contains "$full_test_plan" "$discovered_test"
done
assert_contains "$personal_test_plan" 'tests/dotfiles/test_codex_sessions.py'
assert_not_contains "$personal_test_plan" '/bin/bash tests/setup/test_repair.sh'
assert_contains "$full_test_plan" 'Syntax: Git hooks and PR check'
assert_contains "$full_test_plan" 'dotfiles/.bin/tmux-git-status'
assert_contains "$full_test_plan" 'dotfiles/functions/git.zsh'

# Each kind of row lists setup first, then dotfiles, then the work overlay.
row_order="$(printf '%s\n' "$full_test_plan" | cut -d'|' -f1 | grep -nxE 'Syntax: (setup scripts|dotfiles|acme tools and tests)|Tests: (setup.sh commands|Zellij config|Acme fixture overlay)|Help: (setup.sh|home shell functions|acme shell functions)' | cut -d: -f2- | tr '\n' ',')"
[[ "$row_order" == 'Syntax: setup scripts,Syntax: dotfiles,Syntax: acme tools and tests,Tests: setup.sh commands,Tests: Zellij config,Tests: Acme fixture overlay,Help: setup.sh,Help: home shell functions,Help: acme shell functions,' ]] ||
  fail_test "test rows are out of order: $row_order"

# Help rows find commands and functions without a list: every executable gets
# one unless it opts out, and every function with a _NAME_help is checked.
help_dir="$TMP_ROOT/help"
mkdir -p "$help_dir"
printf '#!/bin/sh\necho "Usage: good"\n' >"$help_dir/good"
printf '#!/bin/sh\n# setup-help: none (background helper)\nexit 1\n' >"$help_dir/quiet"
printf '#!/bin/sh\necho nothing\n' >"$help_dir/no-usage"
printf 'not a command\n' >"$help_dir/data"
chmod +x "$help_dir/good" "$help_dir/quiet" "$help_dir/no-usage"
help_rows="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  run_test_check() { printf "%s|" "$1"; shift; "$@" >/dev/null 2>&1 && echo pass || echo fail; }
  run_command_help_checks run_test_check "$2"/*
' _ "$SETUP" "$help_dir")"
[[ "$help_rows" == $'Help: good|pass\nHelp: no-usage|fail' ]] || fail_test "unexpected command help rows: $help_rows"
printf '%s\n' '_good_fn_help() { print '\''Usage: good_fn'\''; }
good_fn() { [[ "$1" == --help ]] && _good_fn_help; }
no_options_fn() { exit 3; }' >"$help_dir/functions.zsh"
function_help() {
  /bin/bash -c 'SETUP_SOURCE_ONLY=true; source "$1"; check_function_help "$2"' _ "$SETUP" "$1"
}
function_help "$help_dir/functions.zsh" >/dev/null 2>&1 || fail_test "function help check failed on good helpers"
printf '_broken_fn_help() { :; }\nbroken_fn() { return 4; }\n' >>"$help_dir/functions.zsh"
help_output="$(function_help "$help_dir/functions.zsh" 2>&1)" && fail_test "broken function help passed"
assert_contains "$help_output" 'FAIL: broken_fn --help exited non-zero'

# Lint rows run when the linter is installed and say so when it is skipped.
lint_plan="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  PATH="$2"
  run_test_check() { printf "%s|%s\n" "$1" "$2"; }
  setup_status_info() { printf "info|%s\n" "$1"; }
  run_lint_checks
  ruff() { :; }
  shellcheck() { :; }
  run_lint_checks
' _ "$SETUP" "$TMP_ROOT/no-linters")"
assert_contains "$lint_plan" 'info|Lint: Python skipped (ruff not installed)'
assert_contains "$lint_plan" 'info|Lint: shell scripts skipped (shellcheck not installed)'
assert_contains "$lint_plan" 'Lint: Python (Ruff)|ruff'
assert_contains "$lint_plan" 'Lint: shell scripts (ShellCheck)|lint_shell_scripts'

# Syntax checks cover every script, not only the first one passed in.
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/good.sh"
printf '#!/usr/bin/env bash\nif then\n' >"$TMP_ROOT/broken.sh"
if syntax_output="$(check_shell_syntax "$TMP_ROOT/good.sh" "$TMP_ROOT/broken.sh" 2>&1)"; then
  fail_test "a syntax error in the second script was not reported"
fi
assert_contains "$syntax_output" "FAIL: $TMP_ROOT/broken.sh has a bash syntax error"

# A test without a label header still runs, under its path.
mkdir -p "$TMP_ROOT/discovery/tests/extra"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/discovery/tests/extra/test_new.sh"
unlabeled_plan="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  cd "$2"
  CLI_WORK_ENV=""
  run_test_check() { printf "%s|" "$1"; shift; printf "%s " "$@"; printf "\n"; }
  run_discovered_tests
' _ "$SETUP" "$TMP_ROOT/discovery")"
assert_contains "$unlabeled_plan" 'Tests: tests/extra/test_new.sh|/bin/bash tests/extra/test_new.sh'

FAILED_CHECK_LABELS=()
CLI_WORK_ENV=false
personal_test_summary="$(print_test_summary)"
assert_contains "$personal_test_summary" 'All personal-scope repository tests passed.'

missing_mode_status=0
missing_mode_output="$("$SETUP" 2>&1)" || missing_mode_status=$?
[[ "$missing_mode_status" -eq 2 ]] || fail_test "missing mode returned $missing_mode_status"
assert_contains "$missing_mode_output" 'Choose one mode'
assert_plain_output "$missing_mode_output"

# Check mode scans once and reports each finding only once beneath its area.
check_status=0
check_output="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  scans=0
  setup_state_scan() {
    scans=$((scans + 1))
    SETUP_FINDING_IDS=(dependency-missing)
    SETUP_FINDING_AREAS=(Dependencies)
    SETUP_FINDING_SEVERITIES=(fail)
    SETUP_FINDING_MESSAGES=("managed package is missing")
    SETUP_FINDING_REPAIR_IDS=(dependencies)
    FAILURES=1
    WARNINGS=0
    MANUAL_FOLLOWUPS=0
    return 1
  }
  main --check
  status=$?
  printf "SCANS=%s\n" "$scans"
  exit "$status"
' _ "$SETUP" 2>&1)" || check_status=$?
[[ "$check_status" -eq 1 ]] || fail_test "check returned $check_status"
assert_contains "$check_output" '✗  Dependencies — 1 failure(s), 0 warning(s), 0 manual follow-up(s)'
assert_count "$check_output" 'managed package is missing' 1
assert_contains "$check_output" 'SCANS=1'
assert_contains "$check_output" '[SUMMARY] 1 failure(s), 0 warning(s), 0 manual follow-up(s)'
assert_plain_output "$check_output"

printf '%s\n' 'WORK_ENV=false' >"$ENV_FILE"

# Dry-run reuses its single scan for health and a deduplicated action plan.
dry_output="$(SETUP_LOCAL_ENV_FILE="$ENV_FILE" /bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  scans=0
  setup_state_scan() {
    scans=$((scans + 1))
    SETUP_FINDING_IDS=(one two)
    SETUP_FINDING_AREAS=("Files and Paths" "Files and Paths")
    SETUP_FINDING_SEVERITIES=(warning fail)
    SETUP_FINDING_MESSAGES=("first repairable detail" "second repairable detail")
    SETUP_FINDING_REPAIR_IDS=(metadata metadata)
    FAILURES=1
    WARNINGS=1
    MANUAL_FOLLOWUPS=0
    return 1
  }
  setup_repair_apply() { printf "REPAIR_RAN\n"; }
  main --fix --personal --dry-run
  printf "SCANS=%s\n" "$scans"
' _ "$SETUP")"
assert_contains "$dry_output" '── Setup health'
assert_contains "$dry_output" '✗  1 failure(s), 1 warning(s)'
assert_count "$dry_output" 'Record the selected scope and platform metadata' 1
assert_count "$dry_output" 'first repairable detail' 1
assert_count "$dry_output" 'second repairable detail' 1
assert_not_contains "$dry_output" 'REPAIR_RAN'
assert_contains "$dry_output" 'SCANS=1'
assert_contains "$dry_output" '[SUMMARY] Repair preview complete; 1 action(s), no changes made.'

# Manual findings appear separately, succeed, and do not produce fake actions.
manual_status=0
manual_output="$(SETUP_LOCAL_ENV_FILE="$ENV_FILE" /bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  setup_state_scan() {
    SETUP_FINDING_IDS=(external)
    SETUP_FINDING_AREAS=(Dependencies)
    SETUP_FINDING_SEVERITIES=(manual)
    SETUP_FINDING_MESSAGES=("external tool must be provided manually")
    SETUP_FINDING_REPAIR_IDS=("")
    FAILURES=0
    WARNINGS=0
    MANUAL_FOLLOWUPS=1
    return 0
  }
  main --fix --personal --dry-run
' _ "$SETUP" 2>&1)" || manual_status=$?
[[ "$manual_status" -eq 0 ]] || fail_test "manual-only preview returned $manual_status"
assert_count "$manual_output" 'external tool must be provided manually' 1
assert_contains "$manual_output" 'No managed setup issues; 1 manual follow-up(s)'
assert_contains "$manual_output" 'Manual follow-up:'
assert_contains "$manual_output" 'Setup-managed state is healthy; 1 manual follow-up(s) remain.'
assert_not_contains "$manual_output" '── Repair plan'

manual_check_output="$(/bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  setup_state_scan() {
    SETUP_FINDING_IDS=(external)
    SETUP_FINDING_AREAS=(Dependencies)
    SETUP_FINDING_SEVERITIES=(manual)
    SETUP_FINDING_MESSAGES=("external tool must be provided manually")
    SETUP_FINDING_REPAIR_IDS=("")
    FAILURES=0; WARNINGS=0; MANUAL_FOLLOWUPS=1
    return 0
  }
  main --check
' _ "$SETUP")"
assert_contains "$manual_check_output" '•  Dependencies — 1 manual follow-up(s)'
assert_contains "$manual_check_output" '[SUMMARY] 0 failure(s), 0 warning(s), 1 manual follow-up(s)'
assert_count "$manual_check_output" 'external tool must be provided manually' 1

# A live non-interactive fix shows one plan and refuses before repair.
noninteractive_status=0
noninteractive_output="$(SETUP_LOCAL_ENV_FILE="$ENV_FILE" /bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  setup_state_scan() {
    SETUP_FINDING_IDS=(metadata)
    SETUP_FINDING_AREAS=("Files and Paths")
    SETUP_FINDING_SEVERITIES=(warning)
    SETUP_FINDING_MESSAGES=("metadata differs")
    SETUP_FINDING_REPAIR_IDS=(metadata)
    FAILURES=0
    WARNINGS=1
    MANUAL_FOLLOWUPS=0
    return 1
  }
  setup_repair_apply() { printf "REPAIR_RAN\n"; }
  main --fix --personal
' _ "$SETUP" </dev/null 2>&1)" || noninteractive_status=$?
[[ "$noninteractive_status" -eq 2 ]] || fail_test "non-interactive fix returned $noninteractive_status"
assert_contains "$noninteractive_output" '--fix requires interactive confirmation'
assert_count "$noninteractive_output" 'Record the selected scope and platform metadata' 1
assert_not_contains "$noninteractive_output" 'REPAIR_RAN'

# Confirmed repair scans exactly twice and reports only the final delta.
confirmed_output="$(SETUP_LOCAL_ENV_FILE="$ENV_FILE" /bin/bash -c '
  SETUP_SOURCE_ONLY=true
  source "$1"
  scans=0
  repaired=false
  is_interactive() { return 0; }
  setup_state_scan() {
    scans=$((scans + 1))
    if [[ "$repaired" == true ]]; then
      SETUP_FINDING_IDS=()
      SETUP_FINDING_AREAS=()
      SETUP_FINDING_SEVERITIES=()
      SETUP_FINDING_MESSAGES=()
      SETUP_FINDING_REPAIR_IDS=()
      FAILURES=0
      WARNINGS=0
      MANUAL_FOLLOWUPS=0
      return 0
    fi
    SETUP_FINDING_IDS=(metadata)
    SETUP_FINDING_AREAS=("Files and Paths")
    SETUP_FINDING_SEVERITIES=(warning)
    SETUP_FINDING_MESSAGES=("metadata differs")
    SETUP_FINDING_REPAIR_IDS=(metadata)
    FAILURES=0
    WARNINGS=1
    MANUAL_FOLLOWUPS=0
    return 1
  }
  setup_repair_apply() {
    repaired=true
    printf "APPLY=%s,%s,%s\n" "$1" "$2" "$3"
  }
  main --fix --personal <<<yes
  printf "SCANS=%s\n" "$scans"
' _ "$SETUP")"
assert_contains "$confirmed_output" '→  Apply these managed repairs? [y/N]'
assert_contains "$confirmed_output" 'APPLY=false,,metadata'
assert_contains "$confirmed_output" '[SUMMARY] 1 resolved, 0 remaining, 0 new.'
assert_contains "$confirmed_output" 'SCANS=2'
assert_count "$confirmed_output" 'metadata differs' 1

# The command no longer exposes subprocess override seams.
if grep -Eq 'SETUP_(DOCTOR|REPAIR)_COMMAND|setup/(doctor|install)\.sh' "$SETUP"; then
  fail_test "setup.sh still references an obsolete subprocess engine"
fi

# Time limits: a quick check keeps its status, and a stalled one is stopped
# with 124, named in the output, and leaves nothing running.
status=0
run_with_timeout 5 sh -c 'exit 3' >/dev/null 2>&1 || status=$?
assert_equals "$status" 3
status=0
timeout_output="$(run_with_timeout 1 bash -c 'sleep 31.7 & wait' 2>&1)" || status=$?
assert_equals "$status" 124
assert_contains "$timeout_output" 'timed out after 1s; still running:'
assert_contains "$timeout_output" 'sleep 31.7'
if pgrep -f 'sleep 31.7' >/dev/null; then fail_test "timed-out check left its processes running"; fi
if [[ "$(uname -s)" == Darwin ]]; then
  sample_file="$(sed -n 's/^Stack samples: //p' <<<"$timeout_output")"
  [[ -s "$sample_file" ]] || fail_test "timed-out check saved no stack samples"
  rm -f -- "$sample_file"
fi
assert_equals "$(SETUP_HELP_TIMEOUT=7 SETUP_TEST_TIMEOUT=9 check_timeout_seconds 'Help: x') $(SETUP_TEST_TIMEOUT=9 check_timeout_seconds 'Tests: x')" '7 9'

# Checks get empty stdin, so a command that reads it can't take the runner's input or wait on it.
stdin_output="$(printf 'runner input\n' | (
  FAILED_CHECK_LABELS=()
  run_test_check "stdin check" sh -c 'if read -r line; then echo "read: $line"; exit 1; fi'
  printf 'failures=%s\n' "${#FAILED_CHECK_LABELS[@]}"
) 2>&1)"
assert_contains "$stdin_output" 'failures=0'
assert_not_contains "$stdin_output" 'runner input'

printf '[PASS] unified setup command checks\n'
