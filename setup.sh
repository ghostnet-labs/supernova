#!/usr/bin/env bash
# Single public entry point for repository tests, setup health, and repairs.
set -u -o pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/setup/status_output.sh"
source "$REPO_DIR/setup/state.sh"
LOCAL_ENV_FILE="${SETUP_LOCAL_ENV_FILE:-$REPO_DIR/.local/.env.zsh}"
MODE=""
CLI_WORK_ENV=""
CLI_JOB=""
CLI_WORK_ROOT=""
WORK_FLAG_REQUESTED=false
DRY_RUN=false
HELP_REQUESTED=false
FAILED_CHECK_LABELS=()
FAILED_CHECK_DETAILS=()
SAVED_WORK_ENV=""
SAVED_JOB=""
SAVED_WORK_ROOT=""
FIX_WORK_ENV=""
FIX_JOB=""
FIX_WORK_ROOT=""
TEST_WORK_ROOT=""
TEST_JOB=""

usage() {
  printf '%s\n' 'Usage:
  ./setup.sh (--test | --check | --fix) [options]

Description:
  Use one command to test this repository, inspect the active machine setup,
  or repair observed setup issues. Test and check modes are read-only. Fix mode
  previews the managed repairs and requires explicit interactive confirmation
  before changing the machine.

Modes:
  --test         Run repository syntax, lint, regression, CLI, and dry-run tests.
  --check        Report missing dependencies and incorrect setup configuration.
  --fix          Check, preview, confirm, repair, and recheck the active setup.

Options:
  --personal     Select personal-only tests with --test, or repairs with --fix.
  --work         Require work checks with --check, or select repairs with --fix.
  --job NAME     Select a work repair job; implies --work and requires --fix.
                 NAME must start with a letter or number.
  --work-root PATH
                 Work overlay checkout that holds PATH/NAME; implies --work and
                 requires --fix. Saved as WORK_ROOT for later runs.
  --dry-run      Preview --fix repairs without prompting or changing the machine.
  -h, --help     Show this help menu and exit.

Examples:
  ./setup.sh --test
  ./setup.sh --test --personal
  ./setup.sh --check
  ./setup.sh --check --work
  ./setup.sh --fix
  ./setup.sh --fix --dry-run
  ./setup.sh --fix --personal
  ./setup.sh --fix --work --job acme --work-root ~/dev/acme-overlay

Environment:
  HOME                  Home directory inspected or repaired.
  PATH                  Used to resolve commands and run repository tests.
  SETUP_LOCAL_ENV_FILE  Override the saved local setup configuration.
  SETUP_WORK_ROOT       Override the saved work overlay checkout (WORK_ROOT).
  SETUP_TEST_TIMEOUT    Seconds before a test check is stopped (default: 300).
  SETUP_HELP_TIMEOUT    Seconds before a Help check is stopped (default: 30).
  SETUP_TEST_JOBS       Test files run at once by --test (default: one per CPU).'
}

set_mode() {
  local requested="$1"

  if [[ -n "$MODE" && "$MODE" != "$requested" ]]; then
    setup_status_fail "Choose exactly one mode: --test, --check, or --fix." >&2
    return 2
  fi
  MODE="$requested"
}

valid_job_identifier() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --test|--check|--fix)
        set_mode "$1" || return $?
        shift
        ;;
      --personal)
        if [[ "$CLI_WORK_ENV" == true || -n "$CLI_JOB" ]]; then
          setup_status_fail "--personal cannot be combined with --work, --job, or --work-root." >&2
          return 2
        fi
        CLI_WORK_ENV=false
        shift
        ;;
      --work)
        if [[ "$CLI_WORK_ENV" == false ]]; then
          setup_status_fail "--work cannot be combined with --personal." >&2
          return 2
        fi
        CLI_WORK_ENV=true
        WORK_FLAG_REQUESTED=true
        shift
        ;;
      --job)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
          setup_status_fail "--job requires an identifier." >&2
          return 2
        fi
        if [[ "$CLI_WORK_ENV" == false ]]; then
          setup_status_fail "--job cannot be combined with --personal." >&2
          return 2
        fi
        CLI_WORK_ENV=true
        CLI_JOB="$2"
        shift 2
        ;;
      --work-root)
        if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
          setup_status_fail "--work-root requires a path." >&2
          return 2
        fi
        if [[ "$CLI_WORK_ENV" == false ]]; then
          setup_status_fail "--work-root cannot be combined with --personal." >&2
          return 2
        fi
        CLI_WORK_ENV=true
        CLI_WORK_ROOT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        HELP_REQUESTED=true
        shift
        ;;
      *)
        setup_status_fail "Unknown option: $1" >&2
        setup_status_info "Run './setup.sh --help' for usage." >&2
        return 2
        ;;
    esac
  done

  if [[ "$HELP_REQUESTED" == true ]]; then
    return 0
  fi
  if [[ -z "$MODE" ]]; then
    setup_status_fail "Choose one mode: --test, --check, or --fix." >&2
    setup_status_info "Run './setup.sh --help' for usage." >&2
    return 2
  fi
  local invalid_options=()
  if [[ "$MODE" == --test ]]; then
    [[ "$WORK_FLAG_REQUESTED" == true ]] && invalid_options+=(--work)
    [[ -n "$CLI_JOB" ]] && invalid_options+=(--job)
    [[ -n "$CLI_WORK_ROOT" ]] && invalid_options+=(--work-root)
    [[ "$DRY_RUN" == true ]] && invalid_options+=(--dry-run)
  elif [[ "$MODE" == --check ]]; then
    [[ "$CLI_WORK_ENV" == false ]] && invalid_options+=(--personal)
    [[ -n "$CLI_JOB" ]] && invalid_options+=(--job)
    [[ -n "$CLI_WORK_ROOT" ]] && invalid_options+=(--work-root)
    [[ "$DRY_RUN" == true ]] && invalid_options+=(--dry-run)
  fi
  if (( ${#invalid_options[@]} > 0 )); then
    setup_status_fail "$MODE cannot be combined with: ${invalid_options[*]}." >&2
    return 2
  fi
  if [[ -n "$CLI_JOB" ]] && ! valid_job_identifier "$CLI_JOB"; then
    setup_status_fail "Job identifiers must start with a letter or number and contain only letters, numbers, dots, underscores, and hyphens." >&2
    return 2
  fi
  if [[ -n "$CLI_WORK_ROOT" ]]; then
    if [[ ! -d "$CLI_WORK_ROOT" ]]; then
      setup_status_fail "--work-root is not a directory: $CLI_WORK_ROOT" >&2
      return 2
    fi
    CLI_WORK_ROOT="$(cd -- "$CLI_WORK_ROOT" && pwd)" || return 2
  fi
}

extract_actionable_details() {
  local output_file="$1"

  awk '
    /^\[(FAIL|WARNING)\][[:space:]]/ ||
    /^(✗|!)[[:space:]][[:space:]]/ ||
    /^(Missing dependency|FAIL:|ERROR:|Error:|fatal:)/ ||
    /^FAILED([[:space:](]|$)/ {
      detail = $0
      sub(/^\[(FAIL|WARNING)\][[:space:]]+/, "", detail)
      sub(/^(FAIL:|PASS:)[[:space:]]+/, "", detail)
      sub(/^(✗|!)[[:space:]]+/, "", detail)
      print detail
      found = 1
    }
    NF && $0 !~ /warning: setlocale:/ {
      last = $0
    }
    END {
      if (!found && last != "") print last
    }
  ' "$output_file"
}

print_captured_failure_output() {
  local output_file="$1"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '[CHECK] '*) line="${line#\[CHECK\] }" ;;
      '[FAIL] '*) line="${line#\[FAIL\] }" ;;
      '[PASS] '*) line="${line#\[PASS\] }" ;;
      '[WARNING] '*) line="${line#\[WARNING\] }" ;;
      'FAIL: '*) line="${line#FAIL: }" ;;
      'PASS: '*) line="${line#PASS: }" ;;
      'WARNING: '*) line="${line#WARNING: }" ;;
      '✗  '*) line="${line#✗  }" ;;
      '✓  '*) line="${line#✓  }" ;;
      '!  '*) line="${line#!  }" ;;
      '•  '*) line="${line#•  }" ;;
    esac
    [[ -n "$line" ]] && printf '   %s\n' "$line"
  done <"$output_file"
}

record_check_failure() {
  local label="$1"
  local status="$2"
  local details="$3"

  FAILED_CHECK_LABELS+=("$label (exit $status)")
  FAILED_CHECK_DETAILS+=("$details")
  setup_status_fail "$label"
}

# Print PID and every process it started, parents before children.
process_tree() {
  local child
  printf '%s\n' "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do
    process_tree "$child"
  done
}

# Name what a timed-out check left running and what each process waits on; on
# macOS also save a stack sample of each, so a hang shows its cause.
report_stuck_processes() {
  local root="$1"
  local seconds="$2"
  local pid sample_file
  printf 'FAIL: timed out after %ss; still running:\n' "$seconds"
  for pid in $(process_tree "$root"); do
    ps -o pid=,stat=,wchan=,etime=,command= -p "$pid" 2>/dev/null | cut -c1-200
  done
  command -v sample >/dev/null 2>&1 || return 0
  sample_file="$(mktemp "${TMPDIR:-/tmp}/setup-test-hang.XXXXXX")" || return 0
  for pid in $(process_tree "$root"); do
    sample "$pid" 1 >>"$sample_file" 2>&1 || true
  done
  printf 'Stack samples: %s\n' "$sample_file"
}

stop_process_tree() {
  local pid
  local -a pids=()
  for pid in $(process_tree "$1"); do
    pids+=("$pid")
  done
  kill -TERM "${pids[@]}" 2>/dev/null || true
  sleep 1
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

# Run COMMAND, stopping it and everything it started after SECONDS. A timeout
# reports the stuck processes and returns 124, like timeout(1), which macOS
# lacks. Bash 3.2 compatible: no wait -n.
run_with_timeout() {
  local seconds="$1"
  local marker pid watcher status
  shift
  marker="$(mktemp "${TMPDIR:-/tmp}/setup-test-timeout.XXXXXX")" || return 1
  rm -f -- "$marker"
  "$@" &
  pid=$!
  (
    sleeper=""
    trap '[[ -n "$sleeper" ]] && kill "$sleeper" 2>/dev/null; exit 0' TERM
    sleep "$seconds" &
    sleeper=$!
    wait "$sleeper"
    kill -0 "$pid" 2>/dev/null || exit 0
    : >"$marker"
    report_stuck_processes "$pid" "$seconds"
    stop_process_tree "$pid"
  ) &
  watcher=$!
  status=0
  wait "$pid" || status=$?
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  [[ -e "$marker" ]] && status=124
  rm -f -- "$marker"
  return "$status"
}

# Help screens print and exit, so they get a much shorter limit than tests.
check_timeout_seconds() {
  case "$1" in
    Help:*) printf '%s\n' "${SETUP_HELP_TIMEOUT:-30}" ;;
    *) printf '%s\n' "${SETUP_TEST_TIMEOUT:-300}" ;;
  esac
}

# Print a finished check's row from its exit status and captured output.
finish_test_check() {
  local label="$1"
  local status="$2"
  local output_file="$3"
  local details

  if [[ "$status" == 0 ]]; then
    setup_status_pass "$label"
  else
    details="$(extract_actionable_details "$output_file")"
    record_check_failure "$label" "$status" "$details"
    print_captured_failure_output "$output_file" >&2
  fi
}

# Every check gets empty stdin and a time limit, so one stalled command fails
# its own row instead of stalling the whole run.
run_test_check() {
  local label="$1"
  local output_file
  local status=0
  shift

  setup_status_start "$label"
  output_file="$(mktemp "${TMPDIR:-/tmp}/setup-test-output.XXXXXX")" || {
    record_check_failure "$label" 1 'test output could not be captured'
    return
  }
  run_with_timeout "$(check_timeout_seconds "$label")" "$@" >"$output_file" 2>&1 </dev/null || status=$?
  finish_test_check "$label" "$status" "$output_file"
  rm -f -- "$output_file"
}

run_work_test_check() {
  [[ "$CLI_WORK_ENV" == false ]] && return 0
  run_test_check "$@"
}

# Work rows test the configured work overlay: WORK_ROOT and JOB from the saved
# local environment (or SETUP_WORK_ROOT). With no overlay there are no Work rows.
resolve_test_overlay() {
  TEST_WORK_ROOT=""
  TEST_JOB=""
  [[ "$CLI_WORK_ENV" == false ]] && return 0
  load_saved_scope
  [[ "$SAVED_WORK_ENV" == true && -n "$SAVED_JOB" ]] || return 0
  valid_job_identifier "$SAVED_JOB" || return 0
  TEST_WORK_ROOT="${SETUP_WORK_ROOT:-$SAVED_WORK_ROOT}"
  [[ -n "$TEST_WORK_ROOT" && -d "$TEST_WORK_ROOT/$SAVED_JOB" ]] || { TEST_WORK_ROOT=""; return 0; }
  TEST_JOB="$SAVED_JOB"
}

# Print the files among the arguments whose shebang names the given shell.
shell_scripts_for() {
  local shell_name="$1"
  local file first_line
  shift
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    case "$shell_name:$file" in
      zsh:*.zsh | zsh:*/.zshrc | zsh:*/.zprofile) printf '%s\n' "$file"; continue ;;
    esac
    first_line=""
    IFS= read -r first_line <"$file" || true
    case "$first_line" in
      "#!/usr/bin/env $shell_name" | "#!/bin/$shell_name") printf '%s\n' "$file" ;;
    esac
  done
}

# Syntax-check each file with the shell that shell_scripts_for picks for it;
# files with no zsh, bash, or sh shebang are skipped. Each file needs its own
# run: "bash -n a b" checks a and passes b as $1. Bash scripts are checked by
# /bin/bash, which is Bash 3.2 on macOS.
check_shell_syntax() {
  local shell_name shell_bin file output
  local status=0
  for shell_name in zsh bash sh; do
    shell_bin="$shell_name"
    [[ "$shell_name" == bash ]] && shell_bin=/bin/bash
    while IFS= read -r file; do
      # Keep stderr only for failures: zsh -n warns about $(<file) reads.
      output="$("$shell_bin" -n "$file" 2>&1)" || {
        printf '%s\nFAIL: %s has a %s syntax error\n' "$output" "$file" "$shell_name"
        status=1
      }
    done < <(shell_scripts_for "$shell_name" "$@")
  done
  return "$status"
}

# ShellCheck every tracked or new bash and sh script (ShellCheck has no zsh
# support), four files per run in parallel.
lint_shell_scripts() {
  local file
  local -a files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(git ls-files --cached --others --exclude-standard |
    while IFS= read -r file; do
      shell_scripts_for bash "$file"
      shell_scripts_for sh "$file"
    done)
  (( ${#files[@]} > 0 )) || return 0
  printf '%s\0' "${files[@]}" | xargs -0 -n 4 -P 4 shellcheck --severity=error
}

# Lint rows run only when the linter is installed; CI installs both.
run_lint_checks() {
  if command -v ruff >/dev/null 2>&1; then
    run_test_check "Lint: Python (Ruff)" ruff check --quiet --no-cache .
  else
    setup_status_info "Lint: Python skipped (ruff not installed)"
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    run_test_check "Lint: shell scripts (ShellCheck)" lint_shell_scripts
  else
    setup_status_info "Lint: shell scripts skipped (shellcheck not installed)"
  fi
}

# Read a "# setup-test: VALUE" style header from the first lines of a test.
test_header_value() {
  local file="$1"
  local key="$2"
  local line
  local -i count=0
  while IFS= read -r line && (( count < 5 )); do
    count+=1
    case "$line" in
      "# $key: "*) printf '%s\n' "${line#"# $key: "}"; return 0 ;;
    esac
  done <"$file"
  return 1
}

# How many test files run at once: SETUP_TEST_JOBS, or one per CPU.
test_job_limit() {
  local jobs="${SETUP_TEST_JOBS:-}"
  if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)" || jobs=1
  fi
  printf '%s\n' "$jobs"
}

# Set TEST_COMMAND to the command that runs one test file.
test_command_for() {
  case "$1" in
    *.sh) TEST_COMMAND=(/bin/bash "$1") ;;
    *.zsh) TEST_COMMAND=(zsh -f "$1") ;;
    *.py) TEST_COMMAND=(env PYTHONDONTWRITEBYTECODE=1 python3 "$1") ;;
    *) return 1 ;;
  esac
}

# Run LABEL's check in the background with run_test_check's stdin and time
# limit; DIR/status appears once it finishes, next to its DIR/output.
start_background_check() {
  local dir="$1"
  local label="$2"
  shift 2
  (
    status=0
    run_with_timeout "$(check_timeout_seconds "$label")" "$@" >"$dir/output" 2>&1 </dev/null || status=$?
    printf '%s\n' "$status" >"$dir/status.tmp" && mv -f -- "$dir/status.tmp" "$dir/status"
  ) &
  BACKGROUND_CHECK_PIDS+=("$!")
}

stop_background_checks() {
  local pid
  for pid in ${BACKGROUND_CHECK_PIDS[@]+"${BACKGROUND_CHECK_PIDS[@]}"}; do
    stop_process_tree "$pid"
  done
}

# Add one test file to the queue run_queued_test_checks runs.
queue_test_check() {
  QUEUED_TEST_LABELS+=("$1")
  QUEUED_TEST_FILES+=("$2")
}

# Run the queued test files, up to test_job_limit at once: each test keeps its
# state in its own temporary directory. Rows print in queue order, each as
# soon as it and every row above it have finished.
run_queued_test_checks() {
  local root limit
  local -i index next=0 shown=0 running total=${#QUEUED_TEST_FILES[@]}
  (( total > 0 )) || return 0
  root="$(mktemp -d "${TMPDIR:-/tmp}/setup-tests.XXXXXX")" || {
    record_check_failure "Tests" 1 'test output could not be captured'
    return
  }
  limit="$(test_job_limit)"
  BACKGROUND_CHECK_PIDS=()
  trap 'stop_background_checks; rm -rf -- "$root"; exit 130' INT TERM
  while (( shown < total )); do
    running=0
    for (( index = shown; index < next; index++ )); do
      [[ -e "$root/$index/status" ]] || running+=1
    done
    if (( next < total && running < limit )); then
      mkdir "$root/$next"
      test_command_for "${QUEUED_TEST_FILES[$next]}"
      start_background_check "$root/$next" "${QUEUED_TEST_LABELS[$next]}" "${TEST_COMMAND[@]}"
      next+=1
    elif [[ -e "$root/$shown/status" ]]; then
      finish_test_check "${QUEUED_TEST_LABELS[$shown]}" "$(<"$root/$shown/status")" "$root/$shown/output"
      shown+=1
    else
      [[ "$SETUP_STATUS_ACTIVE" == true ]] || setup_status_start "${QUEUED_TEST_LABELS[$shown]}"
      sleep 0.1
    fi
  done
  wait
  trap - INT TERM
  rm -rf -- "$root"
  QUEUED_TEST_LABELS=()
  QUEUED_TEST_FILES=()
}

# Run every tests/*/test_* file, then the work overlay's
# WORK_ROOT/tests/JOB/test_* files. Each test names itself with a
# "# setup-test: LABEL" header and marks Work-scope coverage with
# "# setup-test-scope: work"; every overlay test is Work scope.
run_discovered_tests() {
  local file label scope
  local -a files=(tests/setup/test_* tests/dotfiles/test_*)
  # Setup first and the work overlay last, matching the Syntax and Help rows.
  for file in tests/*/test_*; do
    case "$file" in
      tests/setup/* | tests/dotfiles/*) ;;
      *) files+=("$file") ;;
    esac
  done
  [[ -n "$TEST_JOB" ]] && files+=("$TEST_WORK_ROOT/tests/$TEST_JOB"/test_*)
  QUEUED_TEST_LABELS=()
  QUEUED_TEST_FILES=()
  for file in "${files[@]}"; do
    [[ -f "$file" ]] && test_command_for "$file" || continue
    label="Tests: $(test_header_value "$file" setup-test || printf '%s' "$file")"
    scope="$(test_header_value "$file" setup-test-scope)" || scope=personal
    [[ -n "$TEST_JOB" && "$file" == "$TEST_WORK_ROOT"/* ]] && scope=work
    [[ "$scope" == work && "$CLI_WORK_ENV" == false ]] && continue
    queue_test_check "$label" "$file"
  done
  run_queued_test_checks
}

# Run COMMAND --help and require a zero exit and a usage section.
check_help_output() {
  local output
  output="$("$@" --help 2>&1 </dev/null)" || {
    printf '%s\nFAIL: %s --help exited non-zero\n' "$output" "${*: -1}"
    return 1
  }
  case "$output" in
    *Usage:* | *usage:*) ;;
    *) printf 'FAIL: %s --help printed no usage\n' "${*: -1}"; return 1 ;;
  esac
}

# One Help row per executable in a command folder, so new commands are covered
# without a list to update. A background helper that takes no options (run by
# tmux, Zellij, or Codex) opts out with a "# setup-help: none" header.
run_command_help_checks() {
  local runner="$1"
  local file
  shift
  for file in "$@"; do
    [[ -f "$file" && -x "$file" ]] || continue
    [[ "$(test_header_value "$file" setup-help)" == none* ]] && continue
    "$runner" "Help: ${file##*/}" check_help_output env PYTHONDONTWRITEBYTECODE=1 "$file"
  done
}

# Run --help on every function in FILES that has a matching _NAME_help, so a
# new helper is covered as soon as it has a help screen. Functions without one
# take no options.
check_function_help() {
  zsh -f -c '
    for file in "$@"; do source "$file" || exit 1; done
    integer failed=0
    for name in ${(ok)functions}; do
      [[ $name != _* ]] && (( $+functions[_${name}_help] )) || continue
      output="$("$name" --help 2>&1 </dev/null)" || {
        print -r -- "$output"
        print -r -- "FAIL: $name --help exited non-zero"
        failed=1
        continue
      }
      [[ $output == *Usage:* ]] || { print -r -- "FAIL: $name --help printed no Usage"; failed=1; }
    done
    exit $failed
  ' check_function_help "$@"
}

# Rows are grouped by kind (Syntax, Lint, Tests, Help) and, within each kind, by
# area: setup, dotfiles, other repository tooling, then the work overlay.
run_repository_tests() {
  local work_dir=""
  local -a work_functions=()
  resolve_test_overlay
  if [[ -n "$TEST_JOB" ]]; then
    work_dir="$TEST_WORK_ROOT/$TEST_JOB"
    work_functions=("$work_dir"/bin-"$TEST_JOB"/functions-"$TEST_JOB".sh "$work_dir"/functions/*.zsh)
  fi
  run_test_check "Syntax: setup scripts" check_shell_syntax setup.sh bootstrap.sh setup/*.sh
  run_test_check "Syntax: dotfiles" check_shell_syntax dotfiles/.zshrc dotfiles/.zprofile dotfiles/.bin/* dotfiles/functions/*
  run_test_check "Syntax: Git hooks and PR check" check_shell_syntax .githooks/* .github/scripts/*
  run_test_check "Syntax: tests" check_shell_syntax tests/*/*
  [[ -n "$TEST_JOB" ]] && run_work_test_check "Syntax: $TEST_JOB tools and tests" check_shell_syntax \
    "$work_dir/bin-$TEST_JOB"/* "${work_functions[@]}" "$TEST_WORK_ROOT/tests/$TEST_JOB"/*
  run_lint_checks
  run_discovered_tests
  run_test_check "Help: setup.sh" ./setup.sh --help
  run_test_check "Help: bootstrap.sh" ./bootstrap.sh --help
  run_command_help_checks run_test_check dotfiles/.bin/*
  run_test_check "Help: home shell functions" check_function_help dotfiles/functions/*.zsh
  if [[ -n "$TEST_JOB" ]]; then
    run_command_help_checks run_work_test_check "$work_dir/bin-$TEST_JOB"/*
    run_work_test_check "Help: $TEST_JOB shell functions" check_function_help "${work_functions[@]}"
  fi
  run_test_check "Whitespace: uncommitted changes" git diff --check
}

print_test_summary() {
  local index
  local detail

  if (( ${#FAILED_CHECK_LABELS[@]} == 0 )); then
    if [[ "$CLI_WORK_ENV" == false ]]; then
      setup_status_summary "All personal-scope repository tests passed."
    else
      setup_status_summary "All repository tests passed."
    fi
    return 0
  fi

  setup_status_summary "${#FAILED_CHECK_LABELS[@]} repository test(s) failed"
  for index in "${!FAILED_CHECK_LABELS[@]}"; do
    printf '  - %s\n' "${FAILED_CHECK_LABELS[$index]}" >&2
    while IFS= read -r detail; do
      [[ -n "$detail" ]] && printf '      %s\n' "$detail" >&2
    done <<<"${FAILED_CHECK_DETAILS[$index]}"
  done
  return 1
}

run_test_mode() {
  # Git exports GIT_DIR and friends to hooks and to "git rebase --exec" commands.
  # Tests run git in scratch repositories, so an inherited GIT_DIR would turn their
  # commits and config writes on this checkout instead.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  cd "$REPO_DIR" || return 1
  run_repository_tests
  print_test_summary
}

run_health_check() {
  local require_work=false
  local scan_status=0

  [[ "$CLI_WORK_ENV" == true ]] && require_work=true
  setup_state_scan "" "" "$require_work" || scan_status=$?
  render_check_report
  return "$scan_status"
}

finding_is_issue() {
  [[ "$1" == fail || "$1" == warning ]]
}

render_check_report() {
  local area
  local index
  local area_failures
  local area_warnings
  local area_manual
  local severity

  for area in "${SETUP_STATE_AREAS[@]}"; do
    area_failures=0
    area_warnings=0
    area_manual=0
    for index in "${!SETUP_FINDING_IDS[@]}"; do
      [[ "${SETUP_FINDING_AREAS[$index]}" == "$area" ]] || continue
      severity="${SETUP_FINDING_SEVERITIES[$index]}"
      [[ "$severity" == fail ]] && area_failures=$((area_failures + 1))
      [[ "$severity" == warning ]] && area_warnings=$((area_warnings + 1))
      [[ "$severity" == manual ]] && area_manual=$((area_manual + 1))
    done

    if (( area_failures > 0 )); then
      setup_status_fail "$area — $area_failures failure(s), $area_warnings warning(s), $area_manual manual follow-up(s)"
    elif (( area_warnings > 0 )); then
      setup_status_warning "$area — $area_warnings warning(s), $area_manual manual follow-up(s)"
    elif (( area_manual > 0 )); then
      setup_status_info "$area — $area_manual manual follow-up(s)"
    else
      setup_status_pass "$area"
    fi

    for index in "${!SETUP_FINDING_IDS[@]}"; do
      [[ "${SETUP_FINDING_AREAS[$index]}" == "$area" ]] || continue
      finding_is_issue "${SETUP_FINDING_SEVERITIES[$index]}" || continue
      setup_status_detail "${SETUP_FINDING_MESSAGES[$index]}"
    done
    if (( area_manual > 0 )); then
      setup_status_detail "Manual follow-up:"
      for index in "${!SETUP_FINDING_IDS[@]}"; do
        [[ "${SETUP_FINDING_AREAS[$index]}" == "$area" ]] || continue
        [[ "${SETUP_FINDING_SEVERITIES[$index]}" == manual ]] || continue
        setup_status_detail "${SETUP_FINDING_MESSAGES[$index]}"
      done
    fi
  done
  setup_status_summary "$FAILURES failure(s), $WARNINGS warning(s), $MANUAL_FOLLOWUPS manual follow-up(s)"
}

SETUP_PLAN_ACTION_IDS=()

plan_has_action() {
  local expected="$1"
  local action

  (( ${#SETUP_PLAN_ACTION_IDS[@]} > 0 )) || return 1
  for action in "${SETUP_PLAN_ACTION_IDS[@]}"; do
    [[ "$action" == "$expected" ]] && return 0
  done
  return 1
}

build_repair_plan() {
  local index
  local action
  local candidate
  local found
  local -a discovered=()
  local -a action_order=(dependencies radar codex work paths metadata links hooks shell fzf platform)

  SETUP_PLAN_ACTION_IDS=()
  (( ${#SETUP_FINDING_IDS[@]} > 0 )) || return 0
  for index in "${!SETUP_FINDING_IDS[@]}"; do
    finding_is_issue "${SETUP_FINDING_SEVERITIES[$index]}" || continue
    action="${SETUP_FINDING_REPAIR_IDS[$index]}"
    [[ -n "$action" ]] || continue
    found=false
    if (( ${#discovered[@]} > 0 )); then
      for candidate in "${discovered[@]}"; do
        [[ "$candidate" == "$action" ]] && found=true && break
      done
    fi
    [[ "$found" == true ]] || discovered+=("$action")
  done

  (( ${#discovered[@]} > 0 )) || return 0
  for candidate in "${action_order[@]}"; do
    for action in "${discovered[@]}"; do
      if [[ "$candidate" == "$action" ]]; then
        SETUP_PLAN_ACTION_IDS+=("$action")
        break
      fi
    done
  done
  for action in "${discovered[@]}"; do
    plan_has_action "$action" || SETUP_PLAN_ACTION_IDS+=("$action")
  done
}

repair_action_label() {
  case "$1" in
    dependencies) printf 'Provision and verify managed dependencies' ;;
    radar) printf 'Install the pinned zj-radar agent-sidebar helper' ;;
    codex) printf 'Upgrade yq and synchronize managed Codex settings' ;;
    paths) printf 'Create setup-managed directories' ;;
    metadata) printf 'Record the selected scope and platform metadata' ;;
    links) printf 'Link managed dotfiles and application configs' ;;
    hooks) printf 'Enable the repository Git hooks' ;;
    shell) printf 'Configure the managed Zsh login shell' ;;
    fzf) printf 'Install and secure the pinned fzf-tab checkout' ;;
    platform) printf 'Install platform-specific applications and fonts' ;;
    work) printf 'Create the selected work scaffolding' ;;
    *) printf '%s' "$1" ;;
  esac
}

render_fix_health() {
  local index

  setup_status_section "Setup health"
  if (( FAILURES > 0 )); then
    setup_status_fail "$FAILURES failure(s), $WARNINGS warning(s), $MANUAL_FOLLOWUPS manual follow-up(s)"
  elif (( WARNINGS > 0 )); then
    setup_status_warning "$WARNINGS warning(s), $MANUAL_FOLLOWUPS manual follow-up(s)"
  elif (( MANUAL_FOLLOWUPS > 0 )); then
    setup_status_info "No managed setup issues; $MANUAL_FOLLOWUPS manual follow-up(s)"
  else
    setup_status_pass "No setup issues found"
  fi

  if (( MANUAL_FOLLOWUPS > 0 )); then
    setup_status_detail "Manual follow-up:"
    for index in "${!SETUP_FINDING_IDS[@]}"; do
      [[ "${SETUP_FINDING_SEVERITIES[$index]}" == manual ]] || continue
      setup_status_detail "${SETUP_FINDING_MESSAGES[$index]}"
    done
  fi
}

prepend_runtime_path() {
  local entry="$1"
  [[ -d "$entry" ]] || return 0
  case ":${PATH:-}:" in
    *":$entry:"*) ;;
    *) PATH="$entry${PATH:+:$PATH}" ;;
  esac
}

refresh_runtime_environment() {
  local brew_prefix

  setup_reset_dependency_cache
  SETUP_BREW_BIN=""
  if setup_resolve_brew && brew_prefix="$("$SETUP_BREW_BIN" --prefix 2>/dev/null)"; then
    prepend_runtime_path "$brew_prefix/sbin"
    prepend_runtime_path "$brew_prefix/bin"
  fi
  prepend_runtime_path "$REPO_DIR/dotfiles/.bin"
  prepend_runtime_path "$HOME/.local/bin"
  if [[ "$FIX_WORK_ENV" == true && -n "$FIX_JOB" && -n "$FIX_WORK_ROOT" ]]; then
    prepend_runtime_path "$FIX_WORK_ROOT/$FIX_JOB/bin-$FIX_JOB"
    prepend_runtime_path "$(dirname "$LOCAL_ENV_FILE")/$FIX_JOB-venv/bin"
  fi
  export PATH
  hash -r
}

render_repair_plan() {
  local action
  local index

  setup_status_section "Repair plan"
  for action in "${SETUP_PLAN_ACTION_IDS[@]}"; do
    setup_status_action "$(repair_action_label "$action")"
    for index in "${!SETUP_FINDING_IDS[@]}"; do
      finding_is_issue "${SETUP_FINDING_SEVERITIES[$index]}" || continue
      [[ "${SETUP_FINDING_REPAIR_IDS[$index]}" == "$action" ]] || continue
      setup_status_detail "${SETUP_FINDING_MESSAGES[$index]}"
    done
  done
}

load_saved_scope() {
  local name
  local value

  SAVED_WORK_ENV=""
  SAVED_JOB=""
  SAVED_WORK_ROOT=""
  [[ -r "$LOCAL_ENV_FILE" ]] || return 0
  while IFS='=' read -r name value; do
    case "$name" in
      WORK_ENV) SAVED_WORK_ENV="$value" ;;
      JOB) SAVED_JOB="$value" ;;
      WORK_ROOT) SAVED_WORK_ROOT="$value" ;;
    esac
  done < <(
    sed -n -E \
      "s/^[[:space:]]*(export[[:space:]]+)?(WORK_ENV|JOB|WORK_ROOT)[[:space:]]*=[[:space:]]*[\"']?([^\"'[:space:]]+)[\"']?.*$/\2=\3/p" \
      "$LOCAL_ENV_FILE"
  )
}

resolve_fix_scope() {
  load_saved_scope
  FIX_WORK_ENV="$CLI_WORK_ENV"
  FIX_JOB="$CLI_JOB"
  FIX_WORK_ROOT="$CLI_WORK_ROOT"

  if [[ -z "$FIX_WORK_ENV" ]]; then
    FIX_WORK_ENV="$SAVED_WORK_ENV"
    FIX_JOB="$SAVED_JOB"
  elif [[ "$FIX_WORK_ENV" == true && -z "$FIX_JOB" && "$SAVED_WORK_ENV" == true ]]; then
    FIX_JOB="$SAVED_JOB"
  fi

  [[ "$FIX_WORK_ENV" == true && -z "$FIX_WORK_ROOT" ]] && FIX_WORK_ROOT="${SETUP_WORK_ROOT:-$SAVED_WORK_ROOT}"

  case "$FIX_WORK_ENV" in
    false)
      FIX_JOB=""
      FIX_WORK_ROOT=""
      ;;
    true)
      if [[ -z "$FIX_JOB" ]]; then
        setup_status_fail "Work repair requires --job NAME because no saved job is configured." >&2
        return 2
      fi
      if ! valid_job_identifier "$FIX_JOB"; then
        setup_status_fail "Invalid saved job identifier: $FIX_JOB" >&2
        return 2
      fi
      if [[ -z "$FIX_WORK_ROOT" ]]; then
        setup_status_fail "Work repair requires --work-root PATH because no work overlay checkout is saved." >&2
        return 2
      fi
      if [[ ! -d "$FIX_WORK_ROOT" ]]; then
        setup_status_fail "Work overlay checkout is missing: $FIX_WORK_ROOT; clone it or pass --work-root PATH." >&2
        return 2
      fi
      ;;
    *)
      setup_status_fail "Repair scope is unknown; pass --personal or --work --job NAME." >&2
      return 2
      ;;
  esac
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

confirm_repairs() {
  local response

  if ! is_interactive; then
    setup_status_fail "--fix requires interactive confirmation." >&2
    setup_status_info "Run './setup.sh --check' for a read-only report or './setup.sh --fix --dry-run' for a preview." >&2
    return 2
  fi
  setup_status_prompt "Apply these managed repairs? [y/N] "
  if ! IFS= read -r response; then
    printf '\n'
    setup_status_info "Fix cancelled; no changes were made."
    return 1
  fi
  setup_status_is_interactive || printf '\n'
  case "$response" in
    y|Y|yes|Yes|YES) return 0 ;;
    *)
      setup_status_info "Fix cancelled; no changes were made."
      return 1
      ;;
  esac
}

run_fix_mode() {
  local initial_status=0
  local repair_status=0
  local final_status=0
  local resolved_count=0
  local remaining_count=0
  local new_count=0
  local finding_id
  local other_id
  local found
  local -a initial_issue_ids=()
  local -a final_issue_ids=()

  resolve_fix_scope || return $?
  setup_state_scan "$FIX_WORK_ENV" "$FIX_JOB" "$FIX_WORK_ENV" "$FIX_WORK_ROOT" || initial_status=$?
  render_fix_health
  build_repair_plan

  if (( ${#SETUP_PLAN_ACTION_IDS[@]} == 0 )); then
    if (( initial_status == 0 )); then
      if (( MANUAL_FOLLOWUPS > 0 )); then
        setup_status_summary "Setup-managed state is healthy; $MANUAL_FOLLOWUPS manual follow-up(s) remain."
      else
        setup_status_summary "Setup is healthy; no repairs are needed."
      fi
      return 0
    fi
    setup_status_summary "No managed repairs are available; manual action is required."
    return 1
  fi

  render_repair_plan
  if [[ "$DRY_RUN" == true ]]; then
    setup_status_summary "Repair preview complete; ${#SETUP_PLAN_ACTION_IDS[@]} action(s), no changes made."
    return 0
  fi

  confirm_repairs || return $?
  for finding_id in "${!SETUP_FINDING_IDS[@]}"; do
    finding_is_issue "${SETUP_FINDING_SEVERITIES[$finding_id]}" && initial_issue_ids+=("${SETUP_FINDING_IDS[$finding_id]}")
  done

  declare -F setup_repair_apply >/dev/null || source "$REPO_DIR/setup/repair.sh"
  SETUP_REPAIR_WORK_ROOT="$FIX_WORK_ROOT" setup_repair_apply "$FIX_WORK_ENV" "$FIX_JOB" "${SETUP_PLAN_ACTION_IDS[@]}" || repair_status=$?

  setup_status_start "Verifying the repaired setup"
  refresh_runtime_environment
  setup_state_scan "$FIX_WORK_ENV" "$FIX_JOB" "$FIX_WORK_ENV" "$FIX_WORK_ROOT" || final_status=$?
  for finding_id in "${!SETUP_FINDING_IDS[@]}"; do
    finding_is_issue "${SETUP_FINDING_SEVERITIES[$finding_id]}" && final_issue_ids+=("${SETUP_FINDING_IDS[$finding_id]}")
  done

  for finding_id in ${initial_issue_ids[@]+"${initial_issue_ids[@]}"}; do
    found=false
    for other_id in ${final_issue_ids[@]+"${final_issue_ids[@]}"}; do
      [[ "$finding_id" == "$other_id" ]] && found=true && break
    done
    [[ "$found" == true ]] || resolved_count=$((resolved_count + 1))
  done
  for finding_id in ${final_issue_ids[@]+"${final_issue_ids[@]}"}; do
    found=false
    for other_id in ${initial_issue_ids[@]+"${initial_issue_ids[@]}"}; do
      [[ "$finding_id" == "$other_id" ]] && found=true && break
    done
    [[ "$found" == true ]] || new_count=$((new_count + 1))
  done
  remaining_count=${#final_issue_ids[@]}
  setup_status_summary "$resolved_count resolved, $remaining_count remaining, $new_count new."

  if [[ $repair_status -ne 0 ]]; then
    return "$repair_status"
  fi
  return "$final_status"
}

main() {
  parse_args "$@" || return $?
  if [[ "$HELP_REQUESTED" == true ]]; then
    usage
    return 0
  fi

  case "$MODE" in
    --test) run_test_mode ;;
    --check) run_health_check ;;
    --fix) run_fix_mode ;;
  esac
}

if [[ "${SETUP_SOURCE_ONLY:-false}" != true ]]; then
  main "$@"
fi
