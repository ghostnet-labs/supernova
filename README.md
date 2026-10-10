# supernova

A macOS/Linux Zsh setup: dotfiles symlinked into the home directory, one setup
command, a first-machine bootstrap, a set of macOS menu bar apps, and an
optional [work overlay](#work-overlays) that layers a separate checkout of
work tools on top. Coding agents should read [AGENTS.md](AGENTS.md), which
holds the design rules.

For a plain-language walkthrough of Toolbox, Atuin, the shell functions,
Agent Control Center's project workspace, and Hardware Planner, start with
[Your tooling guide](docs/tooling-guide.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `setup.sh` | The single public setup command (`--test`, `--check`, `--fix`) |
| `bootstrap.sh` | First-machine bootstrap, downloaded from the browser |
| `setup/` | Internal modules sourced by `setup.sh` |
| `tests/` | Tests run by `./setup.sh --test`, grouped as `setup/`, `dotfiles/`, and `github/`; `fixtures/overlay/` is a fake work overlay |
| `dotfiles/` | Configs symlinked into `$HOME` and `~/.config`, general commands in `.bin/`, and shell functions in `functions/` (one file per topic) |
| `apps/` | Source for the macOS apps the dotfiles install (Codex Balance, Agent Control Center, Agent Workspace, Setup Doctor, Worktree Manager, GitHub Activity, and Awake), the Swift code they share in `apps/lib/`, and the Zellij plugins |
| `docs/` | The tooling guide |
| `.githooks/` | Secret scan and commit message checks, enabled by `./setup.sh --fix` |
| `.github/workflows/` | CI: secret scan, lint, the test suite, and pull request format checks |

## First machine setup

Open this repository on GitHub in a browser, select `bootstrap.sh`, choose
**Download raw file**, and run it from a terminal:

```sh
bash ~/Downloads/bootstrap.sh
```

Bootstrap checks for Git, OpenSSH, and (on macOS) the Command Line Tools and
prints the install command for anything missing. It then sets up GitHub SSH
access, offering to create an Ed25519 key and opening GitHub's Add SSH Key page
if needed. After that it clones `~/dev/supernova` (or reuses an existing
checkout), asks for Personal or Work scope (Work also asks for the overlay
checkout, a path or a Git URL to clone), runs `./setup.sh --fix`, verifies the result,
and opens Ghostty on macOS or a login Zsh on Linux. It never pulls, resets, or
replaces an existing checkout, and `bash bootstrap.sh --help` explains every step.

## Everyday commands

```sh
./setup.sh --test               # run all repository tests
./setup.sh --test --personal    # skip Work-scope tests
./setup.sh --check              # read-only health check
./setup.sh --check --work       # include work setup
./setup.sh --fix --dry-run      # preview repairs
./setup.sh --fix                # repair, after showing the plan and asking
./setup.sh --fix --work --job acme --work-root ~/dev/acme-overlay
```

`--test` also lints with Ruff and ShellCheck when they are installed
(`brew install ruff shellcheck`), the same way CI does; without them those two
rows are skipped.

Test and check modes are read-only and never contact remote services or
telemetry. Fix mode shows the health report and repair plan, requires a typed
`y` or `yes` in an interactive terminal, and rechecks afterward. It only
repairs managed state: it installs missing Homebrew or system packages, links
dotfiles, enables the Git hook, pins shell plugins, and creates work
scaffolding. It upgrades a Homebrew package only when the installed one lacks
what setup needs: gitleaks older than 8.29.0, fzf without `--zsh` (0.48.0 or
newer), Atuin without `init zsh --disable-ai`, or a yq that cannot round-trip
the Codex TOML. `--check` fails on each of these. It does not upgrade unrelated
software.

`--check` also warns about links in `~`, `~/.config` and `~/.local/bin` that
dangle or point into another setup checkout, and counts the
`~/.config/NAME.bak.TIMESTAMP` backups `--fix` made of replaced configs. It
never removes them.

After a repair, open a new shell or run `source_zsh`.

## What setup manages

- **Dependencies** are declared in `setup/dependencies.sh`: Homebrew formulae,
  Linux packages, macOS apps, the pinned `fzf-tab` checkout and `zj-radar`
  binary. A work overlay adds its own rows (packages, Python requirements that
  go into `.local/JOB-venv`, and external commands that setup only reports as
  manual follow-up).
- **Links**: the files in `dotfiles/` are symlinked into `$HOME`, and app
  configs (Neovim, Ghostty, btop, Zellij, Git) into `~/.config`. Anything they
  replace is backed up first.
- **Git**: shared settings live in `dotfiles/git/config`. Put identity,
  credentials, and machine-specific settings in `~/.gitconfig`, which overrides
  the shared file. Setup keeps `~/.gitconfig` present so `git config --global`
  never edits the tracked file.
- **Codex**: where Codex is in use (the `codex` command is installed or
  `~/.codex` exists), `dotfiles/codex/config.toml` is merged into
  `~/.codex/config.toml` (not symlinked), keeping machine-local trust and state.
  The previous file is saved under `~/.dotfiles-backup/codex/` before any
  change. The tracked file holds opinionated defaults (model, reasoning effort,
  plugins); edit it in a fork, or set `SETUP_CODEX_SYNC=false` to leave
  `~/.codex` alone (`true` manages it even before Codex is installed).
- **Secret scanning**: `.githooks/pre-commit` runs `gitleaks` on staged changes
  and blocks commits that contain credentials. Setup requires gitleaks 8.29.0
  or newer: `./setup.sh --check` fails when it is missing or older, and
  `./setup.sh --fix` installs or upgrades it (`brew install gitleaks`).
- **Commit messages**: `.githooks/commit-msg` and `.githooks/pre-push` check
  each commit's first line with `.github/scripts/check_pr.sh`, the same check
  pull requests get.
- **Private terms**: to keep words such as an employer or internal host names
  out of a public fork, list them in the untracked `.local/denylist`, one
  case-insensitive regular expression per line. `pre-commit` and `pre-push`
  then refuse any added line that matches, `.local/denylist.allow` accepts
  lines that also match it, and `.githooks/check-denylist --tree` checks every
  tracked file, as `./setup.sh --test` does.

## Work overlays

Work tools live in a separate checkout, the work overlay, so this repository
stays free of them. Fix mode writes `.local/.env.zsh` with the selected scope
(`WORK_ENV`, `JOB`, and `WORK_ROOT`, the overlay checkout) and platform
(`SETUP_OS`, `SETUP_PLATFORM`, `SETUP_INSTALL_METHOD`):

```sh
./setup.sh --fix --work --job acme --work-root ~/dev/acme-overlay
```

With work scope, `WORK_DIR` is `$WORK_ROOT/$JOB`, and each shared config also
loads the overlay's version of it. Every file is optional; a missing one is
skipped silently, and with no overlay configured nothing extra loads.

| This repository | Loads from the overlay |
| --- | --- |
| `dotfiles/.zshrc` | `$WORK_DIR/.env.zsh` (credentials, never committed), `bin-$JOB/` on PATH, `.aliases-$JOB`, `bin-$JOB/functions-$JOB.sh`, `functions/*.zsh`, then `zshrc.zsh` last |
| `dotfiles/.zprofile` | `zprofile.zsh` |
| `dotfiles/.tmux.conf` | `tmux.conf`, last; it can add a status bar dashboard by setting `@setup_dashboard` and `command-alias[108]` |
| `dotfiles/git/config` | `git/config`, through the `dotfiles/git/work.config` link fix mode creates |
| `toolbox` | Functions and commands from the overlay files above |
| `setup/dependencies.sh` | `dependencies.sh`, which appends rows to `SETUP_DEPENDENCIES` |
| `./setup.sh --test` | `$WORK_ROOT/tests/$JOB/test_*` as Work scope, plus Syntax and Help rows for `bin-$JOB/` and the overlay functions |
| `./setup.sh --check`, `--fix` | Work checks and scaffolding in `$WORK_DIR` |
| `reinstall-apps` | `$WORK_ROOT/apps/*/Info.plist`, installed by the matching command in `bin-$JOB/` |

`tests/fixtures/overlay/` is a complete example with job `acme`, and
`tests/setup/test_overlay.sh` checks every hook with it on and off. Put
credentials in the overlay's `$JOB/.env.zsh`; fix mode creates it from
`$JOB/env.zsh.example`. `.env*` files and `.local/` are never committed.
Tracked general commands live in `dotfiles/.bin`, machine-local commands in
`~/.local/bin`, and job commands in `$WORK_DIR/bin-$JOB`.

## Command index

Every command below has a side-effect-free `--help` screen, and
`./setup.sh --test` checks each one. The app commands are macOS only; run with no option, each shows whether its
app is installed, and `--install` builds it from `apps/` and starts it.

| Task | Command |
| --- | --- |
| Codex messages and sessions | `codex-sessions --tui` |
| Live Codex and Claude agents menu bar app, and its conversation browser | `agent-control-center --install`, `agent-control-center --open` |
| Agents, conversations, and Git worktrees in one app | `agent-workspace --install`, `agent-workspace --open` |
| Codex and Claude usage menu bar app | `codex-bal-bar --install` |
| Claude Code sessions | `claude-sessions` |
| Focus the Ghostty split showing a process | `ghostty-focus --pid PID` |
| Setup health and drift app | `setup-doctor --install`, `setup-doctor --open` |
| Keep the Mac and displays awake; optional mouse jiggle | `awake --install` |
| Cloned GitHub repo activity menu bar app | `gh-activity-bar --install` |
| Git worktree manager | `worktree-manager --install`, `worktree-manager --open` |
| Hardware projects, exact part revisions and purchasing BOMs | `hardware-planner --install`, `hardware-planner --open` |
| Rebuild and restart every macOS app, including a work overlay's | `reinstall-apps`, `reinstall-apps --list` |
| Find available helpers and commands; insert an editable example | `toolbox`, `toolbox --pick` |

Shell functions (Git state, ports and processes, disk usage, archives, network
and SSH diagnostics, tmux and Zellij sessions, Homebrew and repo updates,
Kubernetes contexts, nodes and pods, and Codex usage, plus a work overlay's
helpers) are listed by `toolbox` with a one-line description each. Filter with
any word: `toolbox git`, `toolbox network`, `toolbox kubernetes`, or the job name (work helpers appear in a work shell). The description and filter words come
from a contiguous metadata comment block above each function. Executables in
the managed command directories appear when their directory is on PATH and
the command is usable. Work commands require `WORK_ENV=true` and the selected
`JOB`; discovery never loads another environment or executes a command.

Use `toolbox --describe NAME` for source locations, examples, argument hints,
and shadowed alternatives. `toolbox --json [FILTER]` returns a versioned
`schema_version: 1` object with a `commands` array, including effective
resolution and `shadowed` managed alternatives. No matches produces an empty
array (the table interface still exits 1). An alias or external command that
shadows a managed command is identified explicitly; its shadowed examples
are not offered as if they belonged to the effective command.

`toolbox --pick [FILTER]` uses fzf to choose an example and place it at the next
editable prompt. Ctrl+X then Ctrl+T opens the same picker from the current ZLE
buffer, when that key is free. Enter selects text without executing it; Escape
preserves the original buffer and cursor. Existing bindings, fzf file search,
and tab completion remain available. Missing fzf produces an error; listing,
describing, and JSON output need only Python 3. Reloading the shell is safe.

Optional metadata (also supported in executable header comments):

```zsh
# toolbox: git review | Inspect a repository change.
# toolbox-args: [REVISION]
# toolbox-example: review HEAD
# toolbox-example: review main
review() { ... }
```

Examples are literal, single-line shell text intended for inspection and
editing. Metadata is never evaluated or obtained by running `--help`.

Toolbox searches every distinct command in the enabled local Atuin history as
well as loaded helpers and saved catalog entries. There is no history collection
or approval step. Personal shells read only Personal history; Work shells also
read their active job's history. Raw commands stay local and are never written
to the tracked catalog. Exact spelling, arguments, and multiline text are retained.

Common patterns from history are now ordinary functions with positional arguments:

| Task | Helpers |
| --- | --- |
| Git diffs, logs, upstream comparison, and file history | `gdiff`, `gstaged`, `glog`, `gahead`, `gbehind`, `gfiles`, `gfilelog` |
| Text search, file finding, and line counts | `rfind`, `rcontext`, `rcount`, `ffind`, `flines` |
| HTTP inspection and SSH tunnels | `httpstatus`, `httpjson`, `sshproxy`, `sshtunnel` |

```zsh
glog
gstaged --check
rfind TODO
toolbox --pick                    # Helpers first, plus complete local history
toolbox --pick 'git diff'          # Find an exact prior invocation or a helper
toolbox --json history:            # Inspect only local history entries
```

Use a helper's `--help` for arguments and defaults. The picker inserts the selected command for editing; it does not run it. History
may contain old commands or tools that are no longer installed.

Optional catalogs are still available through `toolbox --save`, `--collect-history`,
`--review`, `--accept`, and `--reject`. They are not needed for history search.
Saving a catalog entry requires a successful secret scan; raw history is not
published. `newdev` updates tools without creating another review queue.
See [catalog usage and local storage](dotfiles/toolbox/README.md) for these optional
operations and their Personal/Work boundaries.

Some `dotfiles/.bin` commands are launched for you rather than typed.
`dotfiles/.tmux.conf` runs `tmux-git-status` in the status bar and opens
`tmux-git-popup` and `tmux-fzf` in popups. `dotfiles/.tmux.native-activity.conf`
starts `tmux-codex-status`. `tw` runs `tmux-fzf` inside tmux and `zellij-fzf`
inside Zellij, whose keybindings also open `tmux-git-popup` and
`zellij-close-tab`. Codex runs `codex-turn-bell` after each turn.

Atuin is a managed dependency for local command history. In a new shell,
**Ctrl+R** opens history search; Enter inserts the selected command for editing.
Up-arrow, fzf file search, tab completion, and autosuggestions keep their existing
bindings. In Zellij, use Locked mode (**Ctrl+G**) first so Ctrl+R reaches the shell;
Normal mode retains Zellij's Resize shortcut. Set `SETUP_ATUIN_ENABLED=false`
before `source_zsh` to restore the previous fzf/Zsh history search. A missing
Atuin executable also leaves the previous binding available.

History follows the shell's selected environment, not the current directory:
Personal uses `personal`, and each enabled Work job uses `work-JOB`, beneath
`${XDG_CONFIG_HOME:-~/.config}/atuin/scopes/` for configuration and
`${XDG_DATA_HOME:-~/.local/share}/atuin/scopes/` for databases and metadata.
`print -r -- "$_SETUP_ATUIN_ACTIVE: $ATUIN_DB_PATH"` shows the active destination.
The template in `dotfiles/atuin/config.toml` refreshes setup-managed scoped copies
on shell initialization. An existing unmarked config is preserved and disables
the integration until moved aside. Sync, update checks, AI integration, and the
daemon are disabled. Reloading cancels an unfinished history recording before
switching scope, so its ID cannot be completed in another database.

Existing shell history is never imported automatically. For an explicit import,
open the intended scoped shell, verify the destination above, and import only a
file already separated into that scope: `HISTFILE=/path/to/personal-history atuin
import zsh`. Do not point it at a mixed `~/.zsh_history`. The normal Zsh history
file and Up-arrow history continue working independently of Atuin.

## Pull requests

Pull requests are merged by rebase, so each commit lands on `main` exactly as
written. Titles and commit messages use `type: summary` (for example
`fix: keep SSH sockets short`); [AGENTS.md](AGENTS.md) has the full rules.
The PR format check fails a pull request whose title or commits break them, or
whose description doesn't answer `What changed` and `Why` in a sentence or two.

`.github/rulesets/main.json` records the ruleset that makes those checks block
merging. A fork applies it once with an admin account, after the PR format
workflow is on `main`; AGENTS.md shows how to update or pause it.

```sh
gh api --method POST repos/OWNER/REPO/rulesets --input .github/rulesets/main.json
```

## Manual macOS preferences

Setup does not manage these. Set them by hand on a new Mac:

- Enable Touch ID.
- Switch to dark mode.
- Set key repeat to fast and delay until repeat to none.
- Move the Dock to the right and turn on automatic hiding.
- Sign in with your Apple ID, then install Amphetamine from the App Store.

## License

[MIT](LICENSE). Vendored third-party files keep their own licenses, such as
the GitHub Octicons in `apps/lib/octicons/LICENSE` and the Vim colour schemes
named in their headers.
