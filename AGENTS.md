# AGENTS.md

This file provides guidance to coding agents (Codex, Claude Code) working in this repository.

## Project overview
Dotfiles and system setup repo. Manages shell/editor configs, install automation, and macOS menu bar apps. Work tools live in a separate overlay checkout (`WORK_ROOT`), never in this repository; see "Work overlay" below.

## Structure
- `dotfiles/` — Shell configs (`.zshrc`, `.zprofile`, `.aliases`, `.p10k.zsh`), editor configs (`.vimrc` and `.vim/`, `nvim/` LazyVim), tmux (`.tmux.conf`, `.tmux.native-activity.conf`), Ghostty, btop, Zellij, the Atuin template in `atuin/`, shared Git settings in `git/`, the Codex config in `codex/`, Obsidian note templates in `Obsidian_templates/`, utility scripts in `.bin/`, the `toolbox` Python code in `lib/`, its saved catalog in `toolbox/`, and home shell functions in `functions/`
- `dotfiles/functions/` — One Zsh file per topic, such as `git.zsh` or `network.zsh`. `.zshrc` sources every `functions/*.zsh`, so a new topic file needs no other wiring. Each public function has a metadata comment block directly above its definition, starting with `# toolbox: CATEGORIES | Description.`; `toolbox` reads it for its description and filter words
- `bootstrap.sh` — First-machine bootstrap, downloaded raw from GitHub: only the steps that must happen before the repository exists: checks for Git, clones `~/dev/supernova` over SSH when a GitHub key can read it (otherwise read-only over HTTPS), asks for the scope (and the work overlay checkout and job in Work scope), and runs `./setup.sh --fix`. Anything setup can do belongs in `setup.sh`, not here. `BOOTSTRAP_OWNER`, `BOOTSTRAP_REPOSITORY`, and `BOOTSTRAP_DESTINATION` point it at a fork
- `setup.sh` — Single public command for repository tests, setup health checks, repair previews, and interactively confirmed repairs
- `setup/` — Internal dependency, health-check, repair, and symlink modules used by `setup.sh`. `setup_command_too_old` in `setup/dependencies.sh` names what an installed command must support (gitleaks version, `fzf --zsh`, `atuin init zsh --disable-ai`); `--check` fails on it and `--fix` runs `brew upgrade` for it, so add a case there when the dotfiles start using a newer option
- `tests/` — Regression tests run by `./setup.sh --test`:
  - `tests/setup/` covers `setup.sh`, `bootstrap.sh`, `setup/`, the Git hooks, and repository-wide rules such as no here-documents
  - `tests/dotfiles/` covers `dotfiles/` and the apps under `apps/`; a topic's functions are usually covered by `test_functions_<topic>.zsh`
  - `tests/github/` covers `.github/scripts/`, the ruleset, and the linter pins in `ci.yml`
  - `tests/fixtures/overlay/` is the fake `acme` work overlay the work-scope tests use
  - Put new tests here, never in a PATH directory such as `dotfiles/.bin`. Any `tests/*/test_*.{sh,zsh,py}` file is found automatically. Give it a `# setup-test: Label` header in its first five lines naming what it covers (for example `Git hooks`, shown as `Tests: Git hooks`), and add `# setup-test-scope: work` when it exercises Work scope (a work overlay's own `$WORK_ROOT/tests/$JOB/` tests always are)
  - New shell tests source `tests/lib/assert.sh` for `fail_test`, `assert_contains`, `assert_not_contains`, and `assert_equals` instead of defining their own. Python tests that need Textual must skip, not fail, when it is missing
- `apps/` — Source for the apps the dotfiles use; nothing here is linked into `$HOME`. Each Swift app is built and installed by its command in `dotfiles/.bin/` (`NAME --install`):
  - `codex-bal-bar/` — Codex Balance, a menu bar app for Codex and Claude usage
  - `agent-control-center/` — the agent menu bar app and conversation browser
  - `worktree-manager/` — Worktree Manager
  - `agent-workspace/` — Agent Workspace, which combines the agent and worktree views in one app
  - `awake/` — Awake, a menu bar app that keeps the Mac and displays awake, with an optional mouse jiggle; `apps/awake/build.sh` builds it for Apple Silicon on macOS 15 or newer
  - `setup-doctor/` — Setup Doctor, which shows `./setup.sh --check` results and drift
  - `gh-activity-bar/` — the GitHub Activity menu bar app; its event descriptions mirror the `ghactivity` function in `dotfiles/functions/github.zsh`, so change both together
  - `hardware-planner/` — Hardware Planner, for hardware projects, part revisions, and purchasing BOMs
- `apps/lib/` — Code the apps share. `agents/` is used by Agent Control Center and Agent Workspace, `worktrees/` by Worktree Manager and Agent Workspace, and the top-level `*.swift` files by whichever installers name them. Every installer except Codex Balance's and GitHub Activity's sources `quit-app.sh` to stop the running copy after a successful build
- `apps/lib/octicons/` — Vendored GitHub Octicons for GitHub Activity, Agent Control Center, Agent Workspace, Worktree Manager, and Hardware Planner: their installers compile its generated `Octicons.swift` and bundle its `LICENSE`. To add an icon, vendor its SVG there and rerun `generate-octicons.py` (see its README); `tests/dotfiles/test_octicons.sh` fails when an app names an icon that isn't vendored
- `dotfiles/.bin/reinstall-apps` rebuilds and restarts every app with an `Info.plist` under `apps/` (and under `$WORK_ROOT/apps` with a work overlay) by running each app's `--install` (or `NAME-app --install`) in parallel. A new Swift app is picked up automatically, and its `--install` must stop or quit the running copy before replacing it; `--list` prints what it would run
- `apps/zellij-tab-picker/` — Rust source of `dotfiles/zellij/plugins/tab-picker.wasm`. Rebuild with `cargo build --release --locked --target wasm32-wasip1` there and copy `target/wasm32-wasip1/release/zellij-tab-picker.wasm` over the tracked `.wasm`
- `apps/zj-radar/keyboard-navigation.patch` — Applied to upstream zj-radar to build `dotfiles/zellij/plugins/zj_radar.wasm`; the base commit and build command are in the patch header
- `dotfiles/zellij/plugins/` — The built Zellij plugin `.wasm` files Zellij loads; their source is under `apps/`
- `.local/` — Machine-local and gitignored except `env.zsh.example`: fix mode writes `.local/.env.zsh` and work setups get `.local/<job>-venv`
- `ruff.toml` — Ruff settings: a pinned rule set and `extend-include` for Python commands without a `.py` suffix; add new extensionless Python commands there
- `CLAUDE.md` — Points Claude Code at this file; keep the rules here
- `LICENSE` — MIT. Vendored files keep their own licenses (Octicons, `dotfiles/nvim/LICENSE`, the Vim colour schemes)
- `.githooks/` — Tracked Git hooks, enabled by fix mode through `core.hooksPath`:
  - `pre-commit` scans staged changes with gitleaks through `dotfiles/lib/toolbox_secrets.py`, so it needs `python3`. gitleaks must be 8.29.0 or newer (`SETUP_GITLEAKS_MIN_VERSION` in `setup/dependencies.sh`, which `--check` enforces and `--fix` upgrades)
  - `commit-msg` checks each commit message, and `pre-push` checks every commit a push adds, both through `.github/scripts/check_pr.sh`
  - `pre-commit` and `pre-push` also run `check-denylist`, which refuses added lines matching the untracked `.local/denylist` (minus `.local/denylist.allow`). `tests/setup/test_independence.sh` runs it on every tracked file and fails on any fixed overlay name or path
- `.github/workflows/ci.yml` — CI for every push to `main` and every pull request, on GitHub-hosted runners: gitleaks on new commits, then `./setup.sh --test` twice. "Lint and test on Ubuntu" installs the Ruff and ShellCheck versions pinned as `RUFF_VERSION` and `SHELLCHECK_VERSION` in `ci.yml`, so it also lints (`tests/github/test_linter_versions.py` checks the pins). "Test on macOS" skips the lint rows and keeps Swift compiles between runs in `~/Library/Caches/setup-swiftc-cache` with `actions/cache`. Add new checks to `./setup.sh --test`, not as separate workflow steps, so local runs and CI stay the same
- `.github/dependabot.yml` — Monthly Dependabot PR that bumps GitHub Actions versions; `.github/pull_request_template.md` pre-fills new PR descriptions
- `.github/workflows/pr-format.yml` — Runs `.github/scripts/check_pr.sh` on every PR except Dependabot's to check the title, that the template's `What changed` and `Why` sections hold real sentences, and each commit's first line, and on every push to `main` to check the pushed commits. It runs as `pull_request_target`, so the check comes from the default branch and a PR can't loosen it
- `.github/rulesets/main.json` — Ruleset for `main`: rebase-merged PRs only, with the PR format check and CI required. GitHub doesn't read it from the repo; apply it as shown under Pull requests. `tests/github/test_branch_ruleset.py` checks that its required checks match the workflow job names and that every `ci.yml` job is required

## Work overlay
- A work overlay is a separate checkout at `WORK_ROOT` holding `$JOB/` (`WORK_DIR`). This repository never names a particular overlay, job, or employer, and never depends on overlay files: it only reads `$WORK_ROOT`/`$WORK_DIR` through the hook points below, and every hook skips a missing file silently
- Hook points: `.zshrc` (`.env.zsh`, `bin-$JOB/` on PATH, `.aliases-$JOB`, `bin-$JOB/functions-$JOB.sh`, `functions/*.zsh`, then `zshrc.zsh` last), `.zprofile` (`zprofile.zsh`), `.tmux.conf` (`tmux.conf`, last; `@setup_dashboard` and `command-alias[108]` add a status bar dashboard), `dotfiles/git/config` (includes `work.config`, the link fix mode makes to `git/config`), `toolbox`, `setup/dependencies.sh` (`dependencies.sh` appends rows; python rows name their requirements file by absolute path), `setup.sh --test` (`$WORK_ROOT/tests/$JOB/test_*`, Syntax and Help rows), `--check`/`--fix`, and `reinstall-apps` (`$WORK_ROOT/apps/*/Info.plist`)
- Adding a hook means adding a row to the README's overlay table, filling it in the fixture overlay under `tests/fixtures/overlay/`, and checking it on and off in `tests/setup/test_overlay.sh`
- `./setup.sh --fix --work --job NAME --work-root PATH` saves `WORK_ROOT`; later runs reuse it. `SETUP_WORK_ROOT` overrides the saved value for any mode, which tests rely on
- Test fixtures use the neutral job `acme`; keep employer names, internal hosts, and personal usernames out of fixtures and examples

## Where to make common changes
- New shell function: put it in the matching `dotfiles/functions/<topic>.zsh` (or a new topic file) with a `# toolbox: CATEGORIES | Description.` line directly above it, and cover it in `tests/dotfiles/test_functions_<topic>.zsh`. If it takes options, give it a `_<name>_help` function and handle `--help`; the `Help: home shell functions` row then checks it automatically
- New command on PATH: add it to `dotfiles/.bin/` (work commands belong in the overlay's `bin-$JOB/`) with a `--help` screen and a test under `tests/`; `./setup.sh --test` gives every executable there its own `Help:` row automatically. A background helper that takes no options (run by tmux, Zellij, or Codex) opts out with a `# setup-help: none (why)` line in its first five lines instead. Add commands people type to the README command index; Python ones without a `.py` suffix also go in `ruff.toml` `extend-include`
- New managed dependency, link, or app: declare it in `setup/dependencies.sh` and extend `tests/setup/test_dependencies.sh`
- New repository check: add it to `run_repository_tests` in `setup.sh` so `./setup.sh --test` and CI both run it; don't add separate workflow steps
- New test: drop a `tests/<area>/test_*.{sh,zsh,py}` file with a `# setup-test:` header; it is picked up automatically

## Common commands
- Run all repository tests: `./setup.sh --test`
- Check local setup health: `./setup.sh --check`
- Preview repairs: `./setup.sh --fix --dry-run`
- Repair interactively: `./setup.sh --fix`
- Check a PR title and description locally: `PR_TITLE='fix: x' PR_BODY="$(cat body.md)" .github/scripts/check_pr.sh`
- Check a branch's commit messages: `.github/scripts/check_pr.sh --commits origin/main..HEAD`

## Key tools and languages
- **Bash** — install scripts and command-line tools
- **Zsh** — shell config, aliases, and shell functions
- **Python** — the `dotfiles/.bin` commands `codex-sessions`, `claude-sessions`, `tmux-fzf`, `zellij-fzf`, and `tmux-codex-status`, the `toolbox` modules in `dotfiles/lib/` (which also back the pre-commit secret scan), and app helper scripts under `apps/` (installer support, session streams, signing, the Claude status line, and the Octicons generator)
- **Lua** — Neovim config (LazyVim)
- **Swift** — Codex Balance, Agent Control Center, Agent Workspace, Setup Doctor, Worktree Manager, GitHub Activity, Hardware Planner, and Awake apps (`apps/codex-bal-bar/`, `apps/agent-control-center/`, `apps/agent-workspace/`, `apps/setup-doctor/`, `apps/worktree-manager/`, `apps/gh-activity-bar/`, `apps/hardware-planner/`, `apps/awake/`), plus shared sources in `apps/lib/`
- **Rust** — Zellij tab picker plugin (`apps/zellij-tab-picker/`)
- **Perl** — The PR description check (`.github/scripts/check_pr_description.pl`)

## Pull requests
- Title: `type: summary` (optional `type(scope): summary`, both in lowercase), at most 72 characters, where type is one of `feat`, `fix`, `docs`, `test`, `ci`, `refactor`, `perf`, `style`, `chore`, `revert`. No period or space at the end, and no placeholder summary such as `fix: wip`. Example: `fix: keep SSH sockets short`
- Description: use `.github/pull_request_template.md` and fill in `## What changed` and `## Why` with a sentence or two each, in plain language. Placeholders such as TODO or N/A, links, images, code blocks, checklists, the template's hints, and agent footers don't count; `## Checked` is optional. `.github/scripts/check_pr.sh` fails the PR otherwise
- The type list lives in `TYPES` in `check_pr.sh`; the PR template comment and this section repeat it, and `tests/github/test_check_pr.sh` fails when they differ
- With the ruleset applied, `main` takes changes only through rebase-merged PRs whose checks pass. A repository admin applies it once: `gh api --method POST repos/ghostnet-labs/supernova/rulesets --input .github/rulesets/main.json`. Apply it only after the `pull_request_target` workflow is on `main`, or the required check never reports.
- To change the live ruleset after editing `main.json`, or to pause it in an emergency with `"enforcement": "disabled"`, use PUT; POST would add a second ruleset, and the stricter of the two applies: `id=$(gh api repos/ghostnet-labs/supernova/rulesets --jq '.[] | select(.name == "main") | .id'); gh api --method PUT "repos/ghostnet-labs/supernova/rulesets/$id" --input .github/rulesets/main.json`. Keep the required check names equal to the job names, and rename a required job only together with that PUT
- Agent-written descriptions end with one attribution footer; if your tooling already appends one, don't add another

## Commit messages
- First line: `type: summary` with the same types as PR titles, at most 72 characters. PRs are rebase-merged, so commits land on `main` exactly as written
- One logical change per commit
- No `wip`, `fix review comments`, or similar fixup commits; fold them into the commit they fix before the PR is ready
- Add a short body explaining why when it isn't obvious; tool-added trailers such as `Co-Authored-By:` are fine
- The `commit-msg` hook checks each message as you commit. `fixup!`, `squash!`, and `amend!` commits pass it so `git rebase -i --autosquash origin/main` can fold them in. The `pre-push` hook then checks every commit the push adds, including clean cherry-picks and reverts and rebased commits, which usually skip `commit-msg`; the PR check repeats this on GitHub. Reword a `git revert` subject to `revert: <original subject>`
- Never skip the hooks with `--no-verify` or `-n`; fix the message instead. Sessions that didn't run `./setup.sh --fix`, such as cloud agents, run `git config core.hooksPath .githooks` first
- Keep git's `[branch sha] subject` line in agent command output: don't run `git commit` or `git cherry-pick` with `-q`, and don't pipe or redirect their output away. Agent Control Center and Claude Code find a session's commits from that line
- After a merge, rebase, or any commit whose output was cut short, print `git log --oneline -1` so the new commit's hash still appears

## CLI help conventions
- New or modified Python CLIs use standard-library `argparse.ArgumentParser` help (`usage`, description, and `options`) unless a custom UI is explicitly requested.
- New or modified shell helpers with flags provide `--help` in the same `usage`/`options` structure; argument-free aliases are exempt.
- Help screens must match the established layout: Usage, Description, Options, Examples, then Environment when applicable. Align option descriptions and include several representative examples for non-trivial commands.
- `--help` must exit successfully without contacting external systems, changing state, or launching an interactive UI.
- Bash and sh scripts don't use here-documents (`<<EOF`): print help and write files with `printf '%s\n' '...'`, and pipe `printf` into commands that read stdin. Bash 5 writes a here-document into a pipe before starting the command that reads it, and on a busy macOS system that write can block forever. Here-strings (`<<<`) of a few bytes are fine. `tests/setup/test_heredocs.sh` enforces this.
- Verify `--help` and the changed command behavior for every CLI-interface change.

## Architecture notes
- `setup.sh` is the only public setup entry point; keep `--test`, `--check`, and `--fix` mutually exclusive and keep all three modes represented in `tests/setup/test_setup.sh`
- Keep test, health, and repair output on the shared one-row status renderer. In a terminal, a cyan Braille spinner settles to green `✓` (pass), cyan `•` (information, including healthy no-ops), yellow `!` (warning: working but degraded), or red `✗` (failure). Color only those markers, honor `NO_COLOR` and `TERM=dumb`, and keep redirected output plain. `→` marks actions, `──` marks sections, and summaries have one blank line above them
- The internal repair module uses `run_spinner()` to run tasks in the background and return their status; privileged tasks must refresh sudo in the foreground through `run_sudo_spinner()`
- `setup/dependencies.sh` is the shared setup contract for the internal state and repair modules; declare managed links, installable apps, pinned plugins, external commands, sourced Homebrew files, and Python requirements there and extend `tests/setup/test_dependencies.sh`
- Keep general tracked commands in `dotfiles/.bin`, machine-local commands in `~/.local/bin`, and job-specific commands in the overlay's `$WORK_DIR/bin-$JOB`; `~/.bin` and `~/bin` are not managed PATH entries
- Keep the managed `fzf-tab` checkout free of group/other write access; state and repair checks must enforce the same compaudit-safe permission contract
- `setup/state.sh` and `setup/repair.sh` are sourced modules, not standalone CLIs; `setup.sh` owns argument parsing, reporting, planning, confirmation, and summaries
- Collect state once for `--check` and `--fix --dry-run`. A confirmed repair may re-check individual items just before changing them, plus exactly one final state scan
- `setup.sh --fix` must show the health report and dry-run plan first, require explicit `y` or `yes` from an interactive terminal, refuse live non-interactive execution, and recheck afterward; `--fix --dry-run` remains read-only
- Treat an explicit `--personal` or `--job NAME` repair scope as desired state even when the current health check passes; reuse a saved job for `--work` only when saved work mode is enabled
- The repair lock and signal cleanup must cover spinner child processes and temporary output
- Dependencies must be installed and verified before setup links any files
- `setup.sh --test` groups rows by kind (Syntax, Lint, Tests, Help, then one Whitespace row that runs `git diff --check` on unstaged changes) and, within each kind, by area: setup, dotfiles, other repository tooling, then the work overlay. Syntax rows check each script with the shell its shebang names. Lint rows run Ruff and ShellCheck (error severity, bash and sh scripts) when installed and are skipped otherwise; CI installs both
- `Help:` rows are discovered, not listed: one row per executable in `dotfiles/.bin/` and the work overlay's `bin-$JOB/` (unless it has a `# setup-help: none` header), one row per functions area that runs `--help` on every function with a matching `_<name>_help`, and fixed rows for `setup.sh` and `bootstrap.sh`. Each must exit 0 and print a usage section
- `setup.sh --test` runs every check with empty stdin and a time limit: `SETUP_HELP_TIMEOUT` (default 30 s) for Help rows and `SETUP_TEST_TIMEOUT` (default 300 s) for everything else. A row that times out fails with exit 124, lists the processes still running and what each waits on, and on macOS saves `sample` stack traces, so a hang names its cause instead of stalling the run
- `setup.sh --test` runs the `tests/*/test_*` files `SETUP_TEST_JOBS` at a time (default: one per CPU) and still prints their rows in order, so a test must keep everything it writes in its own `mktemp` directory, never use a fixed path, process name, or socket another run could share, and stub `launchctl`, `pkill`, and `open` instead of touching the real user's apps. Swift window tests set `alphaValue = 0` on every window they order front and replace `AppDelegate.presentWindow`, so CI never shows a window or takes focus (`tests/dotfiles/test_agent_window_lifecycle.sh` checks this). Another run of the suite, such as a work overlay's CI or a local run, may share the machine and user
- With `SETUP_SWIFTC_CACHE` set, `setup.sh --test` puts `tests/lib/swiftc-cache/swiftc` first on PATH: it replays a successful `-o` or `-typecheck` compile keyed on the compiler, SDK, arguments, and file contents (not paths), so checkouts share entries, and prunes the least recently used ones above `SETUP_SWIFTC_CACHE_MB` (default 2048). The Clang module cache goes in the same directory. The macOS CI job uses `~/Library/Caches/setup-swiftc-cache`
- `setup.sh --test` must run all checks before summarizing failures; `setup.sh --check` mirrors the normally managed full-install state, including dependencies, links, PATH directories, metadata, login-shell registration, pinned shell plugins, fonts or macOS casks, Codex config (where Codex is in use, or as `SETUP_CODEX_SYNC` says), and work scaffolding
- Vim themes and application configs are tracked repository assets; validate them before provisioning instead of downloading replacements into the checkout
- `.zshrc` auto-detects the setup dir via symlink: `SETUP_DIR="${$(readlink "$HOME/.zshrc"):h:h}"`, and exports it, falling back to the checkout holding the sourced `.zshrc` when it isn't a symlink. Tracked configs (tmux, aliases, helpers) reference `$SETUP_DIR`; tmux derives it from the `~/.tmux.conf` link when started without it, and the Swift apps try `SETUP_DIR` before `~/dev/supernova`. New configs must not hard-code the path
- `.zshrc` loads `.aliases`, every `dotfiles/functions/*.zsh`, and the job's aliases and functions through `_setup_source`, which keeps a compiled `.zwc` copy beside each file (gitignored) and recompiles it when stale; this cut helper loading from about 11 ms to under 1 ms
- `dotfiles/git/` is linked to `~/.config/git` for shared Git settings; `~/.gitconfig` stays machine-local and fix mode creates it when missing so global writes never edit the tracked file
- Tmux prefix is `Ctrl+A` (not the default `Ctrl+B`)

## Things to know
- The Python TUI (`codex-sessions --tui`) uses the **Textual** framework, not curses or blessed
- `setup.sh --fix --dry-run` previews repair behavior — always test with it before modifying repair logic
- Dotfiles are **symlinked** from this repo to `$HOME` by fix mode, not copied
- `.zshrc` reads `WORK_ENV`, `JOB`, and `WORK_ROOT` from `.local/.env.zsh` (`SETUP_LOCAL_ENV_FILE` overrides the path) and exports `WORK_DIR=$WORK_ROOT/$JOB`; see "Work overlay"
- Don't just claim changes work without actually running and testing them
- Before making a change, verify functionality and gather base metrics such as speed and line count
- For each change, tell me the number of line increases or decreases
- All changes should be performance aware - the faster the better
