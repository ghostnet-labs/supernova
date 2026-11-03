#!/usr/bin/env bash
# Open a pull request only after its title, description, and commits pass
# check_pr.sh, so a PR never opens with a placeholder title or an empty template.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage:
  .github/scripts/pr-create.sh --title TITLE --body-file FILE [--base BRANCH] [--draft] [--check]

Description:
  Check the pull request title, description, and every commit on the current
  branch with .github/scripts/check_pr.sh, the same check CI runs, and only
  then push the branch and open the pull request with gh. Start the
  description from .github/pull_request_template.md and fill in
  "## What changed" and "## Why". Nothing is pushed or opened when the check
  fails.

Options:
  --title TITLE      Pull request title, "type: summary".
  --body-file FILE   File holding the description; - reads standard input.
  --base BRANCH      Branch to merge into (default: main).
  --draft            Open the pull request as a draft.
  --check            Only run the check; push and open nothing.
  -h, --help         Show this help message and exit.

Examples:
  .github/scripts/pr-create.sh --title "fix: keep SSH sockets short" --body-file pr.md
  .github/scripts/pr-create.sh --check --title "feat: add a picker" --body-file pr.md'
}

title='' body_file='' base=main draft=false check_only=false
while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --title) title="${2-}"; shift 2 || { usage >&2; exit 2; } ;;
    --body-file) body_file="${2-}"; shift 2 || { usage >&2; exit 2; } ;;
    --base) base="${2-}"; shift 2 || { usage >&2; exit 2; } ;;
    --draft) draft=true; shift ;;
    --check) check_only=true; shift ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -z "$title" || -z "$body_file" || -z "$base" ]]; then
  printf 'error: --title and --body-file are required\n' >&2
  usage >&2
  exit 2
fi
if [[ "$body_file" == - ]]; then
  body="$(cat)"
elif [[ -f "$body_file" ]]; then
  body="$(cat -- "$body_file")"
else
  printf 'error: no such description file: %s\n' "$body_file" >&2
  exit 2
fi

check="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/check_pr.sh"
branch="$(git branch --show-current)"
if [[ -z "$branch" || "$branch" == "$base" ]]; then
  printf 'error: switch to a feature branch first; pull requests merge it into %s\n' "$base" >&2
  exit 2
fi

# Compare against the current base so the commit check sees exactly what the PR will hold.
git fetch --quiet origin "$base" 2>/dev/null || printf 'warning: could not fetch origin/%s; checking against the local copy\n' "$base" >&2
if ! PR_TITLE="$title" PR_BODY="$body" PR_BASE="origin/$base" PR_HEAD=HEAD "$check"; then
  printf 'Nothing was pushed or opened. Fix the above, then run this again.\n' >&2
  exit 1
fi
[[ "$check_only" == true ]] && exit 0

if [[ "$(git rev-parse HEAD)" != "$(git rev-parse --verify --quiet "origin/$branch" || true)" ]]; then
  git push -u origin HEAD
fi
args=(pr create --base "$base" --head "$branch" --title "$title" --body "$body")
[[ "$draft" == true ]] && args+=(--draft)
exec gh "${args[@]}"
