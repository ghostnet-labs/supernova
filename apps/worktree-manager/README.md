# Worktree Manager

Worktree Manager is a native macOS control surface for Git worktrees across the repositories under your development root.

Reusable Git, PR, diff, and list components live in `../lib/worktrees/` and are also
compiled by [Agent Workspace](../agent-workspace/README.md). Worktree Manager keeps
its own entrypoint, installation, preferences, and existing standalone interface.

## Killer features

- **Safe-to-remove classification:** a secondary worktree is removable only when removing it loses nothing: it is clean, unlocked, has no Claude Code or Codex agent running in it, sits on a commit some branch, remote branch, or tag contains, and has no ignored files except caches a build or test run recreates (`__pycache__`, `.pytest_cache`, `.ruff_cache`, `.mypy_cache`, `.venv`, `node_modules`, `.DS_Store`, `*.pyc`, `*.pyo`, `*.zwc`). `git worktree remove` deletes ignored files such as `.env` along with the folder, so any other ignored file protects the worktree and its IGNORED FILES badge names it. A detached HEAD whose commits no branch or tag has shows COMMITS ON NO BRANCH, since removing the worktree would leave them unreachable, and Prune refuses while a missing worktree is all that keeps such commits. Untracked files count even when the repository sets `status.showUntrackedFiles=no`, which also hides them from git's own check. Remove looks again right before deleting, so a file written after the last refresh is never lost.
- **Agent-aware protection:** a worktree where a Claude Code or Codex process is running, or where a live session started, shows an AGENT LIVE badge (2 AGENTS LIVE and so on when several are) and is never removed or rebased. Its tooltip names them, such as "1 Claude Code, 2 Codex". Each session names its process, so a session in a terminal and its process count once; a Codex session in the desktop app or an editor is only a session, and a process no session list names still counts.
- **Live agents:** each live session sits under its worktree with what Agent Control Center's menu bar shows, in three lines: its title, status and how long it has been in it, and subagents; the last request; then model, reasoning effort, tokens, and a short context bar with what is left. A process that no session list names shows as a bare line.
- **Continue work:** jump to a worktree's live Claude Code or Codex session, open the worktree in Ghostty, or start Codex or Claude Code there.
- **Grouped by repository:** each repository is a group headed by its name, worktree count, and how many agents are live across its worktrees. The primary worktree comes first, then worktrees with live agents. Click a header to collapse or expand its group. Collapsed groups stay collapsed across launches, and searching opens every matching group.
- **Branches without a worktree:** local branches not checked out anywhere follow the repository's worktrees, with upstream, ahead/behind, last commit, and pull requests. Branches with work still in them come first; merged ones (merged into origin's default branch, or deleted on origin after their pull request merged) follow, with MERGED or UPSTREAM GONE badges, until cleanup. Select one and press **New Worktree** to open the sheet filled in with the branch and a sibling path such as `~/dev/repo-feature-x`. **Remove** deletes a branch only when its work is provably on origin's default branch: the branch is merged into it, a merged pull request into it had the branch's exact tip (squash and rebase merges give commits new IDs), or, for a branch whose upstream is gone, every commit has a patch-identical twin there, as a rebase merge leaves them (`git rev-list --cherry-mark`; a merge commit never has one). An upstream deleted on origin isn't enough by itself: the pull request may have closed unmerged, or later commits may never have been pushed, so such a branch keeps its UPSTREAM GONE badge and stays. It never deletes the default branch, requires a known default branch, and the confirmation names its proof. Before deleting, it rechecks the branch tip and unmerged count; changed branches require a fresh confirmation.
- **Select, then act:** click a worktree, branch, or pull request to select it, and click it again to deselect it. Selected rows get a light tint of the system accent color instead of the solid list highlight; every color is a system color, so the app follows light and dark mode, Increase Contrast, and the accent color set in System Settings. ⌘-click adds or removes items, ⇧-click selects a range, and Esc clears the selection. One action bar under the search field (Open/Jump, Codex, Claude, Show Diff, Fetch, Pull, Rebase, Reveal in Finder, New Worktree, Prune, Remove) applies to the selected items each action fits, and disables what fits none of them, with a tooltip that says why. Fetch and Prune run once per repository. Remove and Rebase list what they'll touch and ask first. Double-click a worktree to open or jump to it, or a pull request to open it on GitHub. The bar uses short titles when the window is too narrow for full ones. Tooltips appear after 250 ms instead of the macOS default of about a second; override with `defaults write local.worktree-manager NSInitialToolTipDelay -int MS`.
- **Pins:** select rows and press **Pin** to keep their repositories at the top of the list; pinned repositories show a pin next to their name. Pins are remembered across launches.
- **Pull requests:** each worktree and branch lists its five most recent GitHub pull requests beneath it, newest first, whether open, draft, merged, or closed. The default branch, such as main, instead lists the three newest pull requests into it, so each repository shows what is landing there. Each reads like the top of its GitHub page, indented under its branch behind a faint ↳: the title and number, then the state and a line such as "bob merged 3 commits into main from feature-x on 07/02/2026". Every one is dated: when it merged or closed, or else when it was opened. A merged one also names its author after the number ("#121 by alice"), as GitHub's pull request list does. Review status, checks, and diff size follow the title. Click one to select it, like any row; double-click it, press Return, or use Open on GitHub to open it. With one selected, Show Diff shows its changes from GitHub in the diff viewer, New Worktree offers its branch so it can be checked out, and Fetch, Prune, and Pin apply to its repository. Pull requests are matched by the branch's name on origin, so a branch whose upstream was deleted still shows the pull request that merged it, and pull requests from forks are ignored except those into the default branch, which read "owner:branch" as on GitHub. State pills use GitHub's Octicons on system colors, darkened so their white text stays readable.
- **Open on GitHub:** opens each selected pull request, and each selected worktree's or branch's page on origin, or the repository page when the branch isn't on origin. SSH host aliases such as `git@github-personal:owner/repo` are resolved to their real host with `ssh -G`.
- **Sync:** fetch, fast-forward pull, and rebase onto origin's default branch. Rebase needs a clean worktree with no live agent, asks first, and aborts on conflict, so the worktree is never left mid-rebase.
- **Diff viewer:** for a selected pull request, its changes from GitHub (diffs GitHub calls too large open there instead); for a worktree, the full uncommitted diff against `HEAD`, including untracked files, beside a list of changed files with their kind and +/− counts. Clicking a file jumps to its section. The diff is a read-only `NSTextView` with exact line positions and selection across lines. Up to 50 untracked files are shown, and untracked files over 512 KB are listed without their contents.
- **Create worktrees:** add an existing branch or create a new branch and worktree from the GUI.
- **Git health:** each worktree shows its `git status` counts in the same p10k style as Agent Control Center: ⇣behind⇡ahead, *stashes, ~conflicted, +staged, !unstaged, and ?untracked. Each stash counts on the branch it was made on, so branches without a worktree show ⇣⇡ and *stashes. Repository headers show no counts, so every number belongs to the row it's on. One state badge, the most important of MISSING (its folder is gone; Prune cleans it up), NO STATUS, AGENT LIVE, LOCKED, COMMITS ON NO BRANCH, IGNORED FILES, or SAFE TO REMOVE, sits beside a neutral icon for what it is: a house for the primary worktree and a folder for linked ones. Hover the badge to see why Remove leaves a worktree alone. Status runs with `--no-optional-locks`, so it never takes the index lock an agent may need.
- **Maintenance actions:** prune stale worktree metadata, reveal paths in Finder, and safely remove clean worktrees after confirming.

## Architecture

The app discovers Git repositories one level below `WORKTREE_MANAGER_ROOT` (or `TW_PROJECT_ROOT`, then `~/dev`). Directories that are linked worktrees of the same repository share a common Git dir (`git rev-parse --git-common-dir`), so each repository is listed once, and the first `git worktree list` entry is its primary worktree. It uses standard Git commands:

```sh
git worktree list --porcelain
git status --porcelain=v2 --untracked-files=normal --ignored=matching
git stash list --format=%gs           # only when status reports stashes
git rev-list --left-right --count @{upstream}...HEAD
git fetch --prune
git pull --ff-only
git rebase origin/HEAD   # then git rebase --abort on conflict
git diff HEAD
git worktree add ...
git worktree remove ...
git for-each-ref --contains HEAD       # detached worktrees only, before Remove or Prune
git worktree prune --verbose
git for-each-ref refs/heads            # branches, upstream track, worktree path
git branch --merged origin/HEAD
git rev-list --cherry-mark --right-only origin/HEAD...BRANCH   # gone branches only
git branch -D BRANCH                   # after the checks above and a confirmation
```

Live-agent protection reads each Claude Code and Codex process's working directory from the kernel (`proc_pidinfo`), which takes a couple of milliseconds and covers agents the session list doesn't know, such as Claude Code, whose native build runs under its version number. `codex app-server` processes don't count: they host desktop and editor sessions, which the session list reports, and their own folder is just wherever they started. Each scan also runs `codex-sessions --json --live --all` and `claude-sessions --json --live --all` in parallel, for the details above and the sessions to jump to; a tool that is missing or takes more than five seconds adds nothing. Pane navigation uses `codex-sessions --jump SESSION_ID` or `claude-sessions --jump SESSION_ID`.

Pull requests come from GitHub's GraphQL API with the token from `gh auth token` (looked up on PATH, then in `/opt/homebrew/bin` and `/usr/local/bin`). After each scan the list appears first. Then one read-only request per repository on github.com, capped at 50 branches, runs in parallel, about a second in all. Branch names travel as GraphQL variables. Repositories elsewhere are skipped. When `gh` isn't signed in, or its account can't read a repository, a quiet line under the title says so and the rest of the list still loads; without pull requests, a branch needs one of the other proofs to be removed.

Git and session output is drained while the child runs so large diffs or session lists cannot fill a pipe and stall discovery. Git action batches run one at a time; the action bar is disabled while they run, and branch-removal preparation runs away from the UI thread.

Terminals open with `open -na Ghostty.app --args --window-save-state=never --quit-after-last-window-closed=true --working-directory=PATH --initial-command=...`. Ghostty's `-e` goes through `/usr/bin/login` and mangles arguments, and `--command=` would also run in every later window and tab of that instance. Without `--window-save-state=never`, the new instance restores saved windows and runs the command in each of them; without `--quit-after-last-window-closed=true`, it lingers after its window closes. Agent commands run in `$SHELL -lic` so PATH entries from `.zshrc`, such as `~/.local/bin`, are available.

## Install

```sh
worktree-manager --install
```

Use `--open`, `--status`, or `--uninstall` afterward.

Installation builds first, then stops the running copy before replacing its bundle. If the app does not exit within five seconds, installation fails and keeps the existing bundle.

## Safety

The GUI never offers normal removal for the primary worktree, dirty worktrees, locked worktrees, worktrees with ignored files that aren't caches, or worktrees a Claude Code or Codex agent is running in, and it checks each worktree again right before removing it. It intentionally does not expose `git worktree remove --force`.
