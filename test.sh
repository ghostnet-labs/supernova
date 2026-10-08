#!/usr/bin/env bash
# Run every repository check: shell syntax, ShellCheck when installed, then each
# tests/*/test_*.sh and tests/*/test_*.py. CI runs exactly this.
set -uo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf '%s\n' 'Usage:
  ./test.sh

Description:
  Check the syntax of every tracked shell script, lint them with ShellCheck
  when it is installed, and run each tests/*/test_*.sh and tests/*/test_*.py.
  Every check runs before the summary; the exit status is 1 if any failed.

Options:
  -h, --help   Show this help and exit.

Examples:
  ./test.sh
  NO_COLOR=1 ./test.sh'
  exit 0
elif [[ $# -gt 0 ]]; then
  printf 'Unknown option: %s (see ./test.sh --help)\n' "$1" >&2
  exit 2
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
failed=()
row() { # row LABEL COMMAND...
  local label="$1" output
  shift
  if output="$("$@" </dev/null 2>&1)"; then
    printf '✓  %s\n' "$label"
  else
    printf '✗  %s\n' "$label"
    [[ -n "$output" ]] && printf '%s\n' "$output" | sed 's/^/   /'
    failed+=("$label")
  fi
}

scripts=()
while IFS= read -r file; do
  [[ -f "$file" ]] && head -1 "$file" | grep -qE '^#!.*\b(ba)?sh\b' && scripts+=("$file")
done < <(git ls-files --cached --others --exclude-standard)

syntax() { local f; for f in "$@"; do bash -n "$f" || return 1; done; }
row 'Syntax: shell scripts' syntax "${scripts[@]}"
if command -v shellcheck >/dev/null 2>&1; then
  row 'Lint: shell scripts (ShellCheck)' shellcheck --severity=error "${scripts[@]}"
else
  printf '•  Lint: shell scripts skipped (shellcheck not installed)\n'
fi

shopt -s nullglob
tests=(tests/*/test_*.sh tests/*/test_*.py)
count=0
for test in "${tests[@]}"; do
  count=$((count + 1))
  case "$test" in
    *.py) row "Tests: $test" python3 "$test" ;;
    *) row "Tests: $test" bash "$test" ;;
  esac
done
# An empty suite would pass silently, so treat it as a failure.
[[ $count -gt 0 ]] || { printf '✗  Tests: none found under tests/\n'; failed+=(Tests); }

printf '\n'
if [[ ${#failed[@]} -eq 0 ]]; then
  printf '[SUMMARY] All checks passed.\n'
else
  printf '[SUMMARY] %d check(s) failed: %s\n' "${#failed[@]}" "${failed[*]}"
  exit 1
fi
