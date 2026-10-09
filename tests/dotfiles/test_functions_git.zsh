#!/usr/bin/env zsh
# setup-test: Git functions
# Covers groot, changes, worktrees, branches, repos, and stashes in dotfiles/functions/git.zsh.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
original_path=("${path[@]}")
for functions_file in "$repo_dir"/dotfiles/functions/*.zsh; do source "$functions_file"; done

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")" || exit 1
# Helpers print resolved paths; macOS TMPDIR is a symlink with a trailing slash.
tmp_root="${tmp_root:A}"
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

expected_display_path() {
  local candidate="$1"

  if [[ "$candidate" == "$HOME" ]]; then
    REPLY="~"
  elif [[ "$candidate" == "$HOME/"* ]]; then
    REPLY="~/${candidate#"$HOME"/}"
  else
    REPLY="$candidate"
  fi
}

groot_repo="$tmp_root/groot-repo"
mkdir -p "$groot_repo/nested/deep"
command git init -q "$groot_repo" || fail_test "could not create groot repository fixture"
groot_result="$(cd "$groot_repo/nested/deep" >/dev/null && groot >/dev/null && print -r -- "$PWD")" || fail_test "groot failed"
[[ "$groot_result" == "${groot_repo:A}" ]] || fail_test "groot did not select the worktree root"

groot_status=0
groot_error="$(cd "$tmp_root" && groot 2>&1)" || groot_status=$?
[[ "$groot_status" == 1 ]] || fail_test "groot outside Git returned $groot_status"
assert_contains "$groot_error" "not inside a Git worktree"

groot_status=0
groot_error="$(groot unexpected 2>&1)" || groot_status=$?
[[ "$groot_status" == 2 ]] || fail_test "groot with an argument returned $groot_status"
assert_contains "$groot_error" "does not accept arguments"

changes_help="$(changes --help)" || fail_test "changes help failed"
[[ "${changes_help%%$'\n'*}" == "Usage:" ]] || fail_test "changes help does not begin with Usage"
assert_contains "$changes_help" $'\n\nDescription:'
assert_contains "$changes_help" $'\n\nOptions:'
assert_contains "$changes_help" $'\n\nExamples:'
assert_contains "$changes_help" "--stat"

changes_origin="$tmp_root/changes-origin.git"
changes_repo="$tmp_root/changes-repo"
changes_updater="$tmp_root/changes-updater"
command git init -q --bare -b main "$changes_origin" || fail_test "could not create changes origin fixture"
command git init -q -b main "$changes_repo" || fail_test "could not create changes repository fixture"
command git -C "$changes_repo" config user.name "Setup Test"
command git -C "$changes_repo" config user.email "setup-test@example.invalid"
print -r -- "initial" >"$changes_repo/tracked.txt"
print -r -- "conflict base" >"$changes_repo/conflict.txt"
command git -C "$changes_repo" add tracked.txt conflict.txt
command git -C "$changes_repo" commit -qm "initial"
command git -C "$changes_repo" remote add origin "$changes_origin"
command git -C "$changes_repo" push -qu origin main
print -r -- "stash fixture" >>"$changes_repo/tracked.txt"
command git -C "$changes_repo" stash push -qm "changes fixture"
command git clone -q "$changes_origin" "$changes_updater" || fail_test "could not clone changes updater fixture"
command git -C "$changes_updater" config user.name "Setup Test"
command git -C "$changes_updater" config user.email "setup-test@example.invalid"
print -r -- "remote" >"$changes_updater/remote.txt"
command git -C "$changes_updater" add remote.txt
command git -C "$changes_updater" commit -qm "remote change"
command git -C "$changes_updater" push -q origin main
print -r -- "local" >"$changes_repo/local.txt"
command git -C "$changes_repo" add local.txt
command git -C "$changes_repo" commit -qm "local change"
command git -C "$changes_repo" fetch -q origin
print -r -- "unstaged" >>"$changes_repo/tracked.txt"
print -r -- "staged" >"$changes_repo/staged file.txt"
command git -C "$changes_repo" add "staged file.txt"
print -r -- "untracked" >"$changes_repo/untracked file.txt"

changes_output="$(cd "$changes_repo" >/dev/null && changes 2>&1)" || fail_test "changes report failed"
assert_contains "$changes_output" "Repository: $changes_repo"
assert_contains "$changes_output" "Branch: main -> origin/main (ahead 1, behind 1)"
assert_contains "$changes_output" "Stashes: 1"
assert_contains "$changes_output" "Changes: 1 staged, 1 unstaged, 1 untracked, 0 conflicted"
assert_contains "$changes_output" "staged file.txt"
assert_contains "$changes_output" "tracked.txt"
assert_contains "$changes_output" "untracked file.txt"

changes_stat_output="$(cd "$changes_repo" >/dev/null && changes --stat 2>&1)" || fail_test "changes stat report failed"
assert_contains "$changes_stat_output" "Staged diff:"
assert_contains "$changes_stat_output" "Unstaged diff:"
assert_contains "$changes_stat_output" "staged file.txt"
assert_contains "$changes_stat_output" "tracked.txt"

command git -C "$changes_repo" switch -qc conflict-side
print -r -- "side" >"$changes_repo/conflict.txt"
command git -C "$changes_repo" commit -qam "side conflict"
command git -C "$changes_repo" switch -q main
print -r -- "main" >"$changes_repo/conflict.txt"
command git -C "$changes_repo" commit -qam "main conflict"
command git -C "$changes_repo" merge conflict-side >/dev/null 2>&1 || true
changes_conflict_output="$(cd "$changes_repo" >/dev/null && changes 2>&1)" || fail_test "changes conflict report failed"
assert_contains "$changes_conflict_output" "1 conflicted"
assert_contains "$changes_conflict_output" "UU"
assert_contains "$changes_conflict_output" "conflict.txt"

changes_status=0
changes_error="$(cd "$tmp_root" >/dev/null && changes 2>&1)" || changes_status=$?
[[ "$changes_status" == 1 ]] || fail_test "changes outside Git returned $changes_status"
assert_contains "$changes_error" "not inside a Git worktree"

changes_status=0
changes_error="$(changes unexpected 2>&1)" || changes_status=$?
[[ "$changes_status" == 2 ]] || fail_test "changes invalid option returned $changes_status"
assert_contains "$changes_error" "unknown option or argument"

worktrees_help="$(worktrees --help)" || fail_test "worktrees help failed"
[[ "${worktrees_help%%$'\n'*}" == "Usage:" ]] || fail_test "worktrees help does not begin with Usage"
assert_contains "$worktrees_help" $'\n\nDescription:'
assert_contains "$worktrees_help" $'\n\nOptions:'
assert_contains "$worktrees_help" $'\n\nExamples:'
assert_contains "$worktrees_help" "--cached"
assert_contains "$worktrees_help" "--prune"

worktrees_repo="$tmp_root/worktrees-repo"
worktrees_linked="$tmp_root/worktrees-feature"
worktrees_prunable="$tmp_root/worktrees-prunable"
worktrees_origin="$tmp_root/worktrees-origin.git"
worktrees_updater="$tmp_root/worktrees-updater"
expected_display_path "$worktrees_repo"
worktrees_repo_display="$REPLY"
expected_display_path "$worktrees_linked"
worktrees_linked_display="$REPLY"
expected_display_path "$worktrees_prunable"
worktrees_prunable_display="$REPLY"
command git init -q --bare -b main "$worktrees_origin" || fail_test "could not create worktrees origin fixture"
command git init -q -b main "$worktrees_repo" || fail_test "could not create worktrees repository fixture"
command git -C "$worktrees_repo" config user.name "Setup Test"
command git -C "$worktrees_repo" config user.email "setup-test@example.invalid"
print -r -- "tracked" >"$worktrees_repo/tracked.txt"
command git -C "$worktrees_repo" add tracked.txt
command git -C "$worktrees_repo" commit -qm "initial"
command git -C "$worktrees_repo" remote add origin "$worktrees_origin"
command git -C "$worktrees_repo" push -qu origin main
print -r -- "stash" >>"$worktrees_repo/tracked.txt"
command git -C "$worktrees_repo" stash push -qm "shared fixture"
command git -C "$worktrees_repo" worktree add -qb feature "$worktrees_linked"
print -r -- "modified" >>"$worktrees_linked/tracked.txt"
print -r -- "staged" >"$worktrees_linked/staged.txt"
command git -C "$worktrees_linked" add staged.txt
print -r -- "untracked" >"$worktrees_linked/untracked.txt"
command git -C "$worktrees_repo" worktree add -qb retired "$worktrees_prunable"
rm -rf -- "$worktrees_prunable"

command git clone -q "$worktrees_origin" "$worktrees_updater" || fail_test "could not clone worktrees updater fixture"
command git -C "$worktrees_updater" config user.name "Setup Test"
command git -C "$worktrees_updater" config user.email "setup-test@example.invalid"
print -r -- "remote" >>"$worktrees_updater/tracked.txt"
command git -C "$worktrees_updater" commit -qam "remote update"
command git -C "$worktrees_updater" push -q origin main

worktrees_cached_output="$(cd "$worktrees_repo" >/dev/null && worktrees --cached 2>&1)" || fail_test "worktrees cached report failed"
assert_contains "$worktrees_cached_output" "Origin refs: local cache"
worktrees_cached_main_row="$(print -r -- "$worktrees_cached_output" | command awk -v path="$worktrees_repo_display" '$NF == path { print }')"
assert_contains "$worktrees_cached_main_row" "synced"

worktrees_output="$(cd "$worktrees_repo" >/dev/null && worktrees 2>&1)" || fail_test "worktrees report failed"
assert_contains "$worktrees_output" "Refreshing origin metadata..."
assert_contains "$worktrees_output" "Stashes: 1 (shared by repository)"
assert_contains "$worktrees_output" "CHANGES"
print -r -- "$worktrees_output" | command grep -Eq '^STATE +CHANGES +ORIGIN +MAIN +BRANCH +PATH$' || fail_test "worktrees table header is missing"
assert_not_contains "$worktrees_output" "fatal:"
worktrees_main_row="$(print -r -- "$worktrees_output" | command awk -v path="$worktrees_repo_display" '$NF == path { print }')"
assert_contains "$worktrees_main_row" "clean"
assert_contains "$worktrees_main_row" "-"
assert_contains "$worktrees_main_row" "behind:1"
assert_contains "$worktrees_main_row" "merged"
worktrees_feature_row="$(print -r -- "$worktrees_output" | command awk -v path="$worktrees_linked_display" '$NF == path { print }')"
assert_contains "$worktrees_feature_row" "dirty"
assert_contains "$worktrees_feature_row" "M2 S1 U1"
assert_contains "$worktrees_feature_row" "no-branch"
assert_contains "$worktrees_feature_row" "merged"
worktrees_prunable_row="$(print -r -- "$worktrees_output" | command awk -v path="$worktrees_prunable_display" '$NF == path { print }')"
assert_contains "$worktrees_prunable_row" "prunable"
assert_contains "$worktrees_prunable_row" "retired"
assert_contains "$worktrees_prunable_row" "merged"

worktrees_prune_status=0
worktrees_prune_output="$(cd "$worktrees_repo" >/dev/null && worktrees --cached --prune <<<n 2>&1)" || worktrees_prune_status=$?
[[ "$worktrees_prune_status" == 1 ]] || fail_test "declined worktree prune returned $worktrees_prune_status"
assert_contains "$worktrees_prune_output" "Prunable worktree registrations:"
assert_contains "$worktrees_prune_output" "Aborted."
assert_contains "$(command git -C "$worktrees_repo" worktree list --porcelain)" "$worktrees_prunable"

worktrees_prune_output="$(cd "$worktrees_repo" >/dev/null && worktrees --prune --cached <<<y 2>&1)" || fail_test "confirmed worktree prune failed"
assert_contains "$worktrees_prune_output" "Prunable worktree registrations:"
assert_not_contains "$worktrees_prune_output" "fatal:"
if [[ "$(command git -C "$worktrees_repo" worktree list --porcelain)" == *"$worktrees_prunable"* ]]; then
  fail_test "confirmed prune retained the stale registration"
fi
command git -C "$worktrees_repo" show-ref --verify --quiet refs/heads/retired || fail_test "prune removed the branch"

command git -C "$worktrees_repo" config branch.retired.remote origin
command git -C "$worktrees_repo" config branch.retired.merge refs/heads/retired

branches_help="$(branches --help)" || fail_test "branches help failed"
[[ "${branches_help%%$'\n'*}" == "Usage:" ]] || fail_test "branches help does not begin with Usage"
assert_contains "$branches_help" $'\n\nDescription:'
assert_contains "$branches_help" $'\n\nOptions:'
assert_contains "$branches_help" $'\n\nExamples:'
assert_contains "$branches_help" "--cached"

branches_cached_output="$(cd "$worktrees_repo" >/dev/null && branches --cached 2>&1)" || fail_test "branches cached report failed"
assert_contains "$branches_cached_output" "Origin refs: local cache"
print -r -- "$branches_cached_output" | command grep -Eq '^STATE +MAIN +ORIGIN +AGE +BRANCH +WORKTREE$' || fail_test "branches table header is missing"
branches_main_row="$(print -r -- "$branches_cached_output" | command awk 'NF >= 2 && $(NF - 1) == "main" { print }')"
assert_contains "$branches_main_row" "current"
assert_contains "$branches_main_row" " main "
assert_contains "$branches_main_row" "behind:1"
branches_feature_row="$(print -r -- "$branches_cached_output" | command awk 'NF >= 2 && $(NF - 1) == "feature" { print }')"
assert_contains "$branches_feature_row" "worktree"
assert_contains "$branches_feature_row" "merged"
assert_contains "$branches_feature_row" "no-branch"
assert_contains "$branches_feature_row" "ago"
assert_contains "$branches_feature_row" "$worktrees_linked_display"
branches_retired_row="$(print -r -- "$branches_cached_output" | command awk 'NF >= 2 && $(NF - 1) == "retired" { print }')"
assert_contains "$branches_retired_row" "local"
assert_contains "$branches_retired_row" "merged"
assert_contains "$branches_retired_row" "gone"

branches_output="$(cd "$worktrees_repo" >/dev/null && branches 2>&1)" || fail_test "branches refreshed report failed"
assert_contains "$branches_output" "Refreshing origin metadata..."
assert_contains "$branches_output" "behind:1"
assert_contains "$branches_output" "gone"

command git -C "$worktrees_repo" remote set-url origin "$tmp_root/missing-origin.git"
branches_fetch_status=0
branches_fetch_error="$(cd "$worktrees_repo" >/dev/null && branches 2>&1)" || branches_fetch_status=$?
[[ "$branches_fetch_status" == 1 ]] || fail_test "branches failed fetch returned $branches_fetch_status"
assert_contains "$branches_fetch_error" "branches: could not fetch origin:"
assert_contains "$branches_fetch_error" "does not appear to be a git repository"
assert_contains "$branches_fetch_error" "Could not read from remote repository"
command git -C "$worktrees_repo" remote set-url origin "$worktrees_origin"

branches_status=0
branches_error="$(cd "$tmp_root" >/dev/null && branches --cached 2>&1)" || branches_status=$?
[[ "$branches_status" == 1 ]] || fail_test "branches outside Git returned $branches_status"
assert_contains "$branches_error" "not inside a Git repository"

worktrees_status=0
worktrees_error="$(cd "$tmp_root" >/dev/null && worktrees 2>&1)" || worktrees_status=$?
[[ "$worktrees_status" == 1 ]] || fail_test "worktrees outside Git returned $worktrees_status"
assert_contains "$worktrees_error" "not inside a Git repository"

repos_help="$(repos --help)" || fail_test "repos help failed"
[[ "${repos_help%%$'\n'*}" == "Usage:" ]] || fail_test "repos help does not begin with Usage"
assert_contains "$repos_help" $'\n\nDescription:'
assert_contains "$repos_help" $'\n\nOptions:'
assert_contains "$repos_help" $'\n\nExamples:'
assert_contains "$repos_help" $'\n\nEnvironment:'
assert_contains "$repos_help" "--cached"

repos_root="$tmp_root/repos-root"
repos_repo="$repos_root/team/project"
repos_linked="$tmp_root/repos-linked"
repos_origin="$tmp_root/repos-origin.git"
repos_updater="$tmp_root/repos-updater"
expected_display_path "$repos_repo"
repos_repo_display="$REPLY"
expected_display_path "$repos_linked"
repos_linked_display="$REPLY"
mkdir -p "$repos_repo"
command git init -q --bare -b main "$repos_origin" || fail_test "could not create repos origin fixture"
command git init -q -b main "$repos_repo" || fail_test "could not create repos repository fixture"
command git -C "$repos_repo" config user.name "Setup Test"
command git -C "$repos_repo" config user.email "setup-test@example.invalid"
print -r -- "tracked" >"$repos_repo/tracked.txt"
command git -C "$repos_repo" add tracked.txt
command git -C "$repos_repo" commit -qm "initial"
command git -C "$repos_repo" remote add origin "$repos_origin"
command git -C "$repos_repo" push -qu origin main
command git -C "$repos_repo" worktree add -qb feature "$repos_linked"
print -r -- "modified" >>"$repos_repo/tracked.txt"
print -r -- "untracked" >"$repos_linked/untracked.txt"

command git clone -q "$repos_origin" "$repos_updater" || fail_test "could not clone repos updater fixture"
command git -C "$repos_updater" config user.name "Setup Test"
command git -C "$repos_updater" config user.email "setup-test@example.invalid"
print -r -- "remote" >>"$repos_updater/tracked.txt"
command git -C "$repos_updater" commit -qam "remote update"
command git -C "$repos_updater" push -q origin main

repos_cached_output="$(repos --cached "$repos_root" 2>&1)" || fail_test "repos cached report failed"
assert_contains "$repos_cached_output" "Origin refs: local cache"
repos_cached_main_row="$(print -r -- "$repos_cached_output" | command awk -v path="$repos_repo_display" '$NF == path { print }')"
assert_contains "$repos_cached_main_row" "synced"

repos_output="$(repos "$repos_root" 2>&1)" || fail_test "repos report failed"
assert_contains "$repos_output" "Refreshing origin metadata..."
print -r -- "$repos_output" | command grep -Eq '^STATE +CHANGES +ORIGIN +AGE +' || fail_test "repos table header is missing"
assert_contains "$repos_output" "$repos_repo_display"
assert_contains "$repos_output" "$repos_linked_display"
[[ "$(print -r -- "$repos_output" | command grep -Fc "$repos_linked_display")" == 1 ]] || fail_test "repos duplicated a linked worktree"
repos_main_row="$(print -r -- "$repos_output" | command awk -v path="$repos_repo_display" '$NF == path { print }')"
assert_contains "$repos_main_row" "dirty"
assert_contains "$repos_main_row" "M1"
assert_contains "$repos_main_row" "behind:1"
repos_linked_row="$(print -r -- "$repos_output" | command awk -v path="$repos_linked_display" '$NF == path { print }')"
assert_contains "$repos_linked_row" "dirty"
assert_contains "$repos_linked_row" "U1"
assert_contains "$repos_linked_row" "no-branch"

repos_status=0
repos_error="$(repos "$tmp_root/missing-repos-root" 2>&1)" || repos_status=$?
[[ "$repos_status" == 1 ]] || fail_test "repos missing root returned $repos_status"
assert_contains "$repos_error" "directory not found"

stashes_help="$(stashes --help)" || fail_test "stashes help failed"
[[ "${stashes_help%%$'\n'*}" == "Usage:" ]] || fail_test "stashes help does not begin with Usage"
assert_contains "$stashes_help" $'\n\nDescription:'
assert_contains "$stashes_help" $'\n\nOptions:'
assert_contains "$stashes_help" $'\n\nExamples:'
assert_contains "$stashes_help" $'\n\nEnvironment:'

stashes_home="$tmp_root/stashes-home"
stashes_repo="$stashes_home/dev/project"
stashes_linked="$stashes_home/dev/project-worktrees/linked"
mkdir -p "$stashes_repo"
command git init -q -b main "$stashes_repo" || fail_test "could not create stashes repository fixture"
command git -C "$stashes_repo" config user.name "Setup Test"
command git -C "$stashes_repo" config user.email "setup-test@example.invalid"
print -r -- "tracked" >"$stashes_repo/tracked.txt"
command git -C "$stashes_repo" add tracked.txt
command git -C "$stashes_repo" commit -qm "initial"
print -r -- "main work" >>"$stashes_repo/tracked.txt"
command git -C "$stashes_repo" stash push -qm "main work"
command git -C "$stashes_repo" switch -qc feature
print -r -- "feature work" >>"$stashes_repo/tracked.txt"
command git -C "$stashes_repo" stash push -qm "feature work"
command git -C "$stashes_repo" worktree add -qb linked "$stashes_linked"

stashes_output="$(HOME="$stashes_home" stashes)" || fail_test "stashes report failed"
print -r -- "$stashes_output" | command grep -Eq '^AGE +REPOSITORY +STASH +BRANCH +MESSAGE$' || fail_test "stashes table header is missing"
assert_contains "$stashes_output" "~/dev/project"
assert_contains "$stashes_output" "stash@{0}"
assert_contains "$stashes_output" "stash@{1}"
assert_contains "$stashes_output" "feature work"
assert_contains "$stashes_output" "main work"
[[ "$(print -r -- "$stashes_output" | command grep -Fc 'stash@{')" == 2 ]] || fail_test "stashes duplicated shared worktree stashes"

stashes_status=0
stashes_error="$(HOME="$stashes_home" stashes unexpected 2>&1)" || stashes_status=$?
[[ "$stashes_status" == 2 ]] || fail_test "stashes with an argument returned $stashes_status"
assert_contains "$stashes_error" "does not accept arguments"

print -r -- "PASS: git functions checks"
