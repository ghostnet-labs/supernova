# supernova

This repository has no project code yet. It holds only the tooling every
change goes through: a test runner, Git hooks, CI, and the commit and pull
request format checks. Coding agents should read [AGENTS.md](AGENTS.md).

## Getting started

```sh
git config core.hooksPath .githooks   # once per clone
./test.sh                              # run every check
```

The `pre-commit` hook scans staged changes with
[gitleaks](https://github.com/gitleaks/gitleaks) and skips the scan when it
is not installed. `./test.sh` lints with ShellCheck when it is installed and
skips that row otherwise. CI runs both on every pull request and every push to
`main`: gitleaks on the new commits, then `./test.sh` with ShellCheck on Ubuntu.

## Pull requests

Pull requests are merged by rebase, so each commit lands on `main` exactly as
written. Titles and commit messages use `type: summary` (for example
`docs: explain the release steps`), and the description answers `What changed`
and `Why` in a sentence or two. [AGENTS.md](AGENTS.md) has the full rules, and
the "Commit and PR format" check reports on every pull request except Dependabot's.
