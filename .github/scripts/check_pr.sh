#!/usr/bin/env bash
# Check commit messages, and a pull request's title and description, against the
# rules in AGENTS.md. CI runs it on every pull request and every push to main; the
# commit-msg and pre-push hooks in .githooks run it on each commit and push.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage:
  PR_TITLE=... PR_BODY=... [PR_BASE=... PR_HEAD=...] .github/scripts/check_pr.sh
  .github/scripts/check_pr.sh --message FILE
  .github/scripts/check_pr.sh --commits REVISION...

Description:
  Fail when the pull request title is not "type: summary", or when the
  description does not fill in "## What changed" and "## Why" with a sentence
  or two of its own: placeholders such as TODO or N/A, links, images, code
  blocks, checklists, the template'\''s hints, and agent footers do not count. With
  PR_BASE and PR_HEAD set, also check the first line of each commit in
  PR_BASE..PR_HEAD; merge commits are skipped, and wip, fixup!, squash!, and
  amend! commits fail.

  --message checks one commit message the way git will record it; the
  commit-msg hook runs it. It skips merges and allows fixup!, squash!, and
  amend! commits, which "git rebase -i --autosquash" folds away.
  --commits checks each non-merge commit that "git log REVISION..." lists;
  the pre-push hook and CI on pushes to main run it.

Options:
  --message FILE     Check the commit message in FILE.
  --commits REV...   Check the commits that git log REV... lists.
  -h, --help         Show this help and exit.

Examples:
  PR_TITLE='\''fix: keep SSH sockets short'\'' PR_BODY="$(cat body.md)" .github/scripts/check_pr.sh
  PR_TITLE='\''docs(readme): explain --check'\'' PR_BODY="$(cat body.md)" .github/scripts/check_pr.sh
  PR_TITLE='\''fix: x'\'' PR_BODY="$(cat body.md)" PR_BASE=origin/main PR_HEAD=HEAD .github/scripts/check_pr.sh
  .github/scripts/check_pr.sh --message .git/COMMIT_EDITMSG
  .github/scripts/check_pr.sh --commits origin/main..HEAD

Environment:
  PR_TITLE         Pull request title.
  PR_BODY          Pull request description (Markdown).
  PR_BASE          Base commit or branch; with PR_HEAD, check commits in PR_BASE..PR_HEAD.
  PR_HEAD          Head commit of the pull request.
  GITHUB_ACTIONS   When "true", problems are also printed as CI annotations.'
}

mode=pr
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --message) [[ $# -eq 2 ]] || { usage >&2; exit 2; }; mode=message ;;
  --commits) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; mode=commits; shift ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

# The PR template comment and AGENTS.md list the same types;
# tests/github/test_check_pr.sh fails when they drift apart.
TYPES='feat|fix|docs|test|ci|refactor|perf|style|chore|revert'
MAX_SUMMARY=72

problems=0
problem() {
  problems=$((problems + 1))
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    # Escape the text as workflow commands expect, so a carriage return in a title or
    # commit subject can't end the annotation and start a command of its own.
    local text="${2//%/%25}"
    text="${text//$'\r'/%0D}"
    printf '::error title=%s::%s\n' "$1" "${text//$'\n'/%0A}"
  else
    printf '✗ %s: %s\n' "$1" "$2"
  fi
}

# Set length to the number of characters in $1 whatever the locale: hooks that GUI
# apps start run under macOS /bin/bash 3.2 with no locale, where ${#x} counts bytes.
char_count() {
  local LC_ALL=C s="$1"
  s="${s//[$'\x80'-$'\xbf']/}"
  length=${#s}
}

# Set why to the reason a "type: summary" line is malformed, or to "" when it is
# fine. It sets a variable rather than printing, so checking commits forks nothing.
check_summary() {
  local line="$1" summary length
  why=
  if [[ "$line" =~ ^Revert\ \"(.+)\"$ ]]; then
    summary="revert: ${BASH_REMATCH[1]}"
    char_count "$summary"
    if ((length <= MAX_SUMMARY)); then
      why="Write git's revert subject \"$line\" as \"$summary\"."
    else
      why="Write git's revert subject \"$line\" as \"revert: ...\" in $MAX_SUMMARY characters or fewer."
    fi
  elif [[ ! "$line" =~ ^($TYPES)(\([a-z0-9._/-]+\))?!?:\ [^[:space:]] ]]; then
    shopt -s nocasematch
    if [[ "$line" =~ ^($TYPES)(\([a-z0-9._/-]+\))?!?:\ [^[:space:]] ]]; then
      why="Write the type and scope of \"$line\" in lowercase."
    else
      why="\"$line\" should look like \"type: summary\", where type is one of ${TYPES//|/, } (for example \"fix: keep SSH sockets short\")."
    fi
    shopt -u nocasematch
  elif [[ "$line" == *[[:space:]] ]]; then
    why="Remove the space at the end of \"$line\"."
  elif [[ "$line" == *. ]]; then
    why="Drop the period at the end of \"$line\"."
  else
    summary="${line#*: }"
    shopt -s nocasematch
    if [[ "$summary" =~ ^(wip|todo|tbd|tmp|stuff|changes|updates?|misc|(address\ )?review\ comments)$ ]]; then
      why="Say what \"$line\" changes; \"$summary\" is a placeholder."
    fi
    shopt -u nocasematch
    [[ -z "$why" ]] || return 0
    char_count "$line"
    ((length <= MAX_SUMMARY)) || why="Keep \"$line\" to $MAX_SUMMARY characters or fewer (it is $length)."
  fi
}

# Check the first line of each non-merge commit that "git log ARGS..." lists.
check_commits() {
  local commits line sha subject why
  commits="$(git log --no-show-signature --no-merges --reverse --format='%h %s' "$@")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sha="${line%% *}" subject="${line#* }"
    if [[ "$subject" =~ ^(fixup!|squash!|amend!|[Ww][Ii][Pp]([^[:alnum:]]|$)) ]]; then
      problem "Commit $sha" "\"$subject\" is a work-in-progress or fixup commit; fold it into the commit it fixes."
    else
      check_summary "$subject"
      [[ -z "$why" ]] || problem "Commit $sha" "$why"
    fi
  done < <(printf '%s\n' "$commits")
}

fix_commits_hint() {
  echo "Fix commits with \"git rebase -i ${PR_BASE:-origin/main}\" (mark them reword, or fixup to fold them in), then \"git push --force-with-lease\"."
}

# Print the subject git will record from a commit message file, as
# "git log --format=%s" shows it: stop at the scissors line "git commit -v" adds,
# drop comment lines, skip leading blank lines, and join the first paragraph,
# keeping each line's leading spaces.
message_subject() {
  local comment
  # git uses whichever of core.commentChar and core.commentString (git 2.45) is set last.
  comment="$(git config --get-regexp '^core[.]comment(char|string)$' 2>/dev/null | tail -n 1)"
  comment="${comment#* }"
  case "$comment" in '' | auto | core.*) comment='#' ;; esac
  awk -v c="$comment" '
    index($0, c " ------------------------ >8 ------------------------") == 1 { exit }
    index($0, c) == 1 { next }
    /^[[:space:]]*$/ { if (subject != "") exit; next }
    { sub(/[[:space:]]+$/, ""); subject = (subject == "" ? $0 : subject " " $0) }
    END { print subject }' "$1"
}

if [[ $mode == message ]]; then
  # git merge, git pull, and concluding a merge: merge commits are not checked.
  git rev-parse -q --verify MERGE_HEAD >/dev/null && exit 0
  subject="$(message_subject "$2")"
  # git aborts an empty message itself, as when the editor quits without saving. git's
  # own merge subjects pass too, for "git commit --amend" on a merge; --no-merges in
  # pre-push and CI still catches them on anything that isn't a merge.
  if [[ -z "$subject" || "$subject" =~ ^Merge\ (branch|branches|remote-tracking\ branch|tag|commit|pull\ request)\  ]]; then
    exit 0
  elif [[ "$subject" =~ ^(fixup|squash|amend)!\  ]]; then
    exit 0
  elif [[ "$subject" =~ ^[Ww][Ii][Pp]([^[:alnum:]]|$) ]]; then
    problem 'Commit message' "\"$subject\" is a work-in-progress message; describe the change as \"type: summary\"."
  else
    check_summary "$subject"
    [[ -z "$why" ]] || problem 'Commit message' "$why"
  fi
  ((problems == 0)) || { echo "Commit again with a fixed first line; the message is saved in $2."; exit 1; }
  exit 0
fi

if [[ $mode == commits ]]; then
  check_commits "$@"
  ((problems == 0)) && exit 0
  [[ "${GITHUB_ACTIONS:-}" == true ]] || fix_commits_hint
  exit 1
fi

check_summary "${PR_TITLE:-}"
[[ -z "$why" ]] || problem 'PR title' "$why"

here="$(dirname -- "${BASH_SOURCE[0]}")"
if ! report="$(PR_BODY="${PR_BODY:-}" PR_TEMPLATE="$here/../pull_request_template.md" perl "$here/check_pr_description.pl")"; then
  report='The description check itself failed; see the error above.'
fi
while IFS= read -r line; do
  [[ -z "$line" ]] || problem 'PR description' "$line"
done < <(printf '%s\n' "$report")

pr_problems=$problems
if [[ -n "${PR_BASE:-}" && -n "${PR_HEAD:-}" ]]; then
  check_commits "$PR_BASE..$PR_HEAD"
fi

if ((problems)); then
  ((pr_problems == 0)) ||
    echo 'Edit the pull request title or description on GitHub; this check reruns on its own.'
  ((problems == pr_problems)) || fix_commits_hint
  exit 1
fi
echo '✓ PR title, description, and commits look good.'
