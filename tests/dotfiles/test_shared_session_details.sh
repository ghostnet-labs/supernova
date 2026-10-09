#!/usr/bin/env bash
# setup-test: Shared agent session details
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Shared session details require macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/shared-session-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
shared="$repo_root/apps/lib"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$scratch/check-shared-session-details" \
  "$shared/GitStatus.swift" "$shared/SessionPresentation.swift" "$shared/BranchRef.swift" \
  "$shared/octicons/Octicons.swift" "$repo_root/tests/dotfiles/fixtures/shared_session_details.swift"

git -c init.defaultBranch=main init -q "$scratch/repo"
printf '%s\n' initial > "$scratch/repo/tracked"
git -C "$scratch/repo" add tracked
git -C "$scratch/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm initial
git -C "$scratch/repo" -c core.hooksPath=/dev/null worktree add -qb details-worktree "$scratch/worktree"
printf '%s\n' staged >> "$scratch/repo/tracked"
git -C "$scratch/repo" add tracked
printf '%s\n' unstaged >> "$scratch/repo/tracked"
printf '%s\n' untracked > "$scratch/repo/new"
touch "$scratch/repo/.git/index.lock"
mkdir -p "$scratch/repo/nested/deep" "$scratch/non-repo" "$scratch/bin"
real_git="$(command -v git)"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$GIT_STATUS_CALLS"' \
  'exec "$GIT_STATUS_REAL" "$@"' > "$scratch/bin/git"
chmod +x "$scratch/bin/git"
PATH="$scratch/bin:$PATH" GIT_STATUS_CALLS="$scratch/calls" GIT_STATUS_REAL="$real_git" \
  "$scratch/check-shared-session-details" "$scratch/repo" "$scratch/repo/nested/deep" "$scratch/worktree" "$scratch/non-repo" \
  || fail_test 'Shared session detail checks failed'
assert_equals 2 "$(wc -l < "$scratch/calls" | tr -d ' ')" 'one Git status per checkout'
