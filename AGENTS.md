# AGENTS.md

This file provides guidance to coding agents (Codex, Claude Code) working in this repository.

## Project overview
There is no project code yet: the repository holds only `README.md`, this file, `CLAUDE.md` (which points Claude Code here), and the tooling below. Update this file and `README.md` when real code lands.

## Layout
- `test.sh` — Runs every repository check: `bash -n` syntax on every tracked or new, unignored file whose shebang names bash or sh, ShellCheck (error severity, when installed), then each `tests/*/test_*.sh` (with bash) and `tests/*/test_*.py` (with python3; there is no Python lint). Every check runs before the summary, and it fails when no tests are found. Add new checks here or as test files, not as separate workflow steps, so local runs and CI stay the same
- `tests/` — Tests discovered by `./test.sh`; shell tests source `tests/lib/assert.sh` for `fail_test`, `assert_contains`, `assert_not_contains`, and `assert_equals`. `tests/github/` covers `.github/scripts/`
- `.github/workflows/ci.yml` — CI for every push to `main` and every pull request: gitleaks on new commits, then `./test.sh` on Ubuntu, whose runner image ships ShellCheck
- `.github/workflows/pr-format.yml` — Runs `.github/scripts/check_pr.sh` on every PR except Dependabot's to check the title, description, and commits, and on every push to `main` to check the pushed commits. It runs as `pull_request_target`, so the check comes from the default branch
- `.githooks/` — `pre-commit` runs `gitleaks` on staged changes (skipped with a warning when gitleaks is not installed); `commit-msg` and `pre-push` check commit messages through `.github/scripts/check_pr.sh`. Enable them once per clone with `git config core.hooksPath .githooks`
- `.github/dependabot.yml` — Monthly Dependabot PR that bumps GitHub Actions versions, titled with the `ci` prefix
- `.github/pull_request_template.md` — Pre-fills new PR descriptions with `What changed`, `Why`, and an optional `Checked` list

## Common commands
- Run all checks: `./test.sh`
- Check a PR title and description locally: `PR_TITLE='fix: x' PR_BODY="$(cat body.md)" .github/scripts/check_pr.sh`
- Check a branch's commit messages: `.github/scripts/check_pr.sh --commits origin/main..HEAD`

## Pull requests
- Title: `type: summary` (optional `type(scope): summary`, both in lowercase), at most 72 characters, where type is one of `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `perf`, `style`, `chore`, `revert`. No period or space at the end, and no placeholder summary such as `fix: wip`
- Description: use `.github/pull_request_template.md` and fill in `## What changed` and `## Why` with a sentence or two each, in plain language. Placeholders, links, code blocks, checklists, the template's hints, and agent footers don't count; `## Checked` is optional
- The type list lives in `TYPES` in `check_pr.sh`; the PR template comment and this section repeat it, and `tests/github/test_check_pr.sh` fails when they differ
- Agent-written descriptions end with one attribution footer

## Commit messages
- First line: `type: summary` with the same types as PR titles, at most 72 characters. PRs are rebase-merged, so commits land on `main` exactly as written
- One logical change per commit; fold fixups into the commit they fix before the PR is ready. Reword a `git revert` subject to `revert: <original subject>`
- Add a short body explaining why when it isn't obvious; tool-added trailers such as `Co-Authored-By:` are fine
- Never skip the hooks with `--no-verify` or `-n`; fix the message instead
- Don't run `git commit` or `git cherry-pick` with `-q` or pipe their output; after a merge or rebase, print `git log --oneline -1`

## Shell scripts
- Bash and sh scripts don't use here-documents (`<<EOF`): print help and write files with `printf '%s\n' '...'`
- Commands with flags provide `--help` (Usage, Description, Options, Examples) that exits 0 without side effects
