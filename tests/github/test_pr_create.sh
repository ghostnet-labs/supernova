#!/usr/bin/env bash
# setup-test: PR create
# Runs .github/scripts/pr-create.sh against a scratch repository with a fake gh,
# checking that nothing is pushed or opened until the PR passes check_pr.sh.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pr-create-test.XXXXXX")"
# Git exports GIT_DIR to hooks in linked worktrees; never let it point these fixtures at a real repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
trap 'rm -rf -- "$TMP_ROOT"' EXIT

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

assert_contains "$("$REPO_DIR/.github/scripts/pr-create.sh" --help)" "Usage:"

repo="$TMP_ROOT/repo" remote="$TMP_ROOT/remote.git" bin="$TMP_ROOT/bin"
mkdir -p "$repo/.github/scripts" "$bin"
cp "$REPO_DIR"/.github/scripts/* "$repo/.github/scripts/"
cp "$REPO_DIR/.github/pull_request_template.md" "$repo/.github/"
git init -q --bare "$remote"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$remote"
git -C "$repo" add -A
git -C "$repo" commit -qm "chore: start the fixture"
git -C "$repo" push -q origin main
export GH_CALLS="$TMP_ROOT/gh-calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"$GH_CALLS"\necho https://github.com/example/repo/pull/1\n' >"$bin/gh"
chmod +x "$bin/gh"
run() { (cd "$repo" && PATH="$bin:$PATH" GITHUB_ACTIONS='' .github/scripts/pr-create.sh "$@"); }

good="$TMP_ROOT/good.md" template="$TMP_ROOT/template.md"
printf '## What changed\nTests run faster.\n\n## Why\nCI was slow.\n' >"$good"
cp "$REPO_DIR/.github/pull_request_template.md" "$template"

# On main there is nothing to open.
status=0
run --title "fix: keep SSH sockets short" --body-file "$good" >/dev/null 2>&1 || status=$?
assert_equals "$status" 2

git -C "$repo" switch -q -c feature
echo change >"$repo/file"
git -C "$repo" add file
git -C "$repo" commit -qm "fix: keep SSH sockets short"

# A default title or an untouched template is refused before anything leaves the machine.
for args in "--title|Feature|$good" "--title|fix: keep SSH sockets short|$template"; do
  IFS='|' read -r _ t f <<<"$args"
  status=0
  output="$(run --title "$t" --body-file "$f" 2>&1)" || status=$?
  assert_equals "$status" 1
  assert_contains "$output" "Nothing was pushed or opened"
done
[[ ! -e "$GH_CALLS" ]] || fail_test "gh ran for a failing PR"
git -C "$remote" rev-parse --verify --quiet refs/heads/feature >/dev/null && fail_test "a failing PR was pushed"

# A bad commit on the branch is refused too.
git -C "$repo" commit -q --allow-empty -m "wip"
status=0
run --title "fix: keep SSH sockets short" --body-file "$good" >/dev/null 2>&1 || status=$?
assert_equals "$status" 1
git -C "$repo" reset -q --hard HEAD~1

# --check only checks.
run --check --title "fix: keep SSH sockets short" --body-file "$good" >/dev/null 2>&1
[[ ! -e "$GH_CALLS" ]] || fail_test "--check opened a PR"

# A passing PR is pushed and opened with exactly the checked title and description.
output="$(run --title "fix: keep SSH sockets short" --body-file - --draft <"$good" 2>&1)"
assert_contains "$output" "https://github.com/example/repo/pull/1"
assert_equals "$(git -C "$remote" rev-parse refs/heads/feature)" "$(git -C "$repo" rev-parse HEAD)"
calls="$(cat "$GH_CALLS")"
assert_contains "$calls" $'pr\ncreate\n--base\nmain\n--head\nfeature\n--title\nfix: keep SSH sockets short\n--body'
assert_contains "$calls" "CI was slow."
assert_contains "$calls" "--draft"

printf 'PASS: PR create\n'
