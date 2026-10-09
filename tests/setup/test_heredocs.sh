#!/usr/bin/env bash
# setup-test: Bash scripts without here-documents
# Bash 5 writes a here-document into a pipe before starting the command that
# reads it. On a busy macOS system that write can block forever: it hung
# `setup.sh --help`, `check_pr.sh --help`, and the Agent Control Center
# installer inside the test suite. Bash and sh scripts write files and feed
# commands with printf instead; this keeps it that way. Here-strings (<<<) of a
# few bytes are allowed.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
cd "$root"

# Built from pieces so this file does not match its own pattern.
lt="<"
heredoc_pattern="${lt}${lt}-?[[:space:]]*[\"']?[A-Za-z_][A-Za-z0-9_]*[\"']?[[:space:]]*$"

checked=0
offenders=""
while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  first_line=""
  IFS= read -r first_line <"$file" || true
  case "$first_line" in
    *bash* | "#!/bin/sh" | "#!/usr/bin/env sh") ;;
    *) [[ "$file" == setup/*.sh || "$file" == tests/lib/*.sh ]] || continue ;;
  esac
  checked=$((checked + 1))
  found="$(grep -nE -- "$heredoc_pattern" "$file" | grep -v "${lt}${lt}${lt}" | grep -vE "^[0-9]+:[[:space:]]*#" || true)"
  [[ -z "$found" ]] || offenders+="$(sed "s|^|$file:|" <<<"$found")"$'\n'
done < <(git ls-files --cached --others --exclude-standard)

[[ -z "$offenders" ]] || fail_test "use printf instead of a here-document:"$'\n'"$offenders"
(( checked > 50 )) || fail_test "expected to check more than 50 scripts, checked $checked"

printf 'PASS: Bash scripts without here-documents\n'
