#!/usr/bin/env bash
# setup-test: Overlay independence
# This repository reads a work overlay only through WORK_ROOT and WORK_DIR, so
# no tracked file may name a particular overlay checkout or its old home. With
# an untracked .local/denylist, every tracked file is also checked against it.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_DIR/tests/lib/assert.sh"
cd -- "$REPO_DIR"

# Fixed overlay names and paths. The acme fixture under tests/fixtures/overlay
# is the one overlay the tests use, through WORK_ROOT like any other.
pattern='\bnova\b|\b(dev|git)/(nova|setup)\b'
if hits="$(git grep -n -I -i -E "$pattern" -- . ':!tests/setup/test_independence.sh')"; then
  fail_test "fixed overlay references:"$'\n'"$hits"
fi

if git ls-files --error-unmatch .local/denylist .local/denylist.allow >/dev/null 2>&1; then
  fail_test ".local/denylist must stay untracked"
fi
if [[ -s .local/denylist ]]; then
  output="$(.githooks/check-denylist --tree 2>&1)" || fail_test "$output"
else
  printf 'SKIP: no .local/denylist, so only fixed overlay references were checked\n'
fi

printf 'PASS: overlay independence\n'
