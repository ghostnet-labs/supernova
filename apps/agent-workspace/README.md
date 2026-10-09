# Agent Workspace

A native macOS app for repositories, Git worktrees, live Codex and Claude agents,
conversations, pull requests, and diffs. Agent Control Center and Worktree Manager
remain separate supported apps; installing this app does not replace either one.

```sh
agent-workspace --install
agent-workspace --open
agent-workspace --status
```

## Navigation

The far-left rail always shows stacked **Sessions** and **Repositories** buttons.
Click either button to switch the sidebar's contents or reopen it when collapsed.
The sidebar button beside **Back** in the main header slides the sidebar closed or
reopens it while the rail stays in place. The open page, scroll positions,
and expanded folders stay in place. Drag the sidebar divider to resize it; its width
and collapsed state are remembered. ⌘K also reopens the sidebar and focuses search.
The slide animation respects the macOS Reduce Motion setting.

The rail buttons stay visible while the sidebar's list scrolls. Active sessions
appear directly at the top of Sessions whenever
available, followed by the 20 latest inactive **Recent** sessions,
**All Sessions**, and **Mission Control**. Repositories shows **All Repositories**
and expandable repositories and worktrees. Clicking a repository row opens its page
and toggles its worktrees open or closed, just like the arrow. The current selection is
highlighted with the same accent tint when focus moves elsewhere. Recent and subagent
groups also toggle when clicking their label or empty row space, as well as their
arrow. Switching keeps each list's scroll and
expansion state and leaves the open page in place; the selected button is remembered
across launches. Search matches sessions, repository names, branches, and paths
across the app. Full history has archive and pin filters. Live agents retain
expandable subagents and terminal jumps.

Sidebar sessions use the menu bar's detailed rows: status and elapsed time, last
request, repository and branch, Git changes, model and reasoning effort, tokens,
and context usage. Pinned sessions show a pin; clicking opens the
conversation, and the context menu retains session actions.
Claude desktop and Claude Code sessions both show expandable subagents, including
finished children marked Closed. Unfinished children stay visible as Idle after
five minutes without transcript activity. Only live children count toward running
agents and worktree protection; unchanged transcripts reuse cached summaries.

The top header's **Refresh** updates sessions, reloads the open conversation, and
refreshes repositories, worktrees, and pull requests. Session, repository, and worktree
details all use this shared button (⌘R). While loading, a spinner replaces its arrows
in the same space and the button is disabled.

The first window opens on All Repositories. Later openings restore the last page;
missing targets fall back to All Repositories. Repository pages retain Worktree
Manager's selection, batch actions, branch cleanup, and GitHub PR presentation.
A selected repository opens directly to its worktrees, branches, and pull requests.
Use a worktree's **Overview** button or the sidebar to open its status, action bar,
live sessions, recent conversations, and PRs. Conversations and **Changes** open
in the main area. **Back** restores the preceding page, selection, filter, and
list/overview scroll position. A conversation links back to its worktree.
Double-click a worktree in the sidebar to open a new Ghostty window in that directory.
Sidebar worktrees show their name on the first line, then the branch and Git counts
together on a smaller, dimmer second line. Counts retain their status colors and
include staged, unstaged, untracked, and conflicted files. Search results also put
the worktree name before its branch, matching the repository page.

The action bar applies each action to eligible selected items. Command-click
toggles rows, Shift-click selects a range, and Escape clears selection. Fetch and
Prune run once per repository. Double-click a worktree to open/jump to its terminal;
double-click a PR to open GitHub. Select a PR to show its diff or create its worktree.
Repository and session pins are independent of the older apps' pins.

New Worktree offers **None**, **Codex**, or **Claude** after creation, defaulting to
None. Launch failures preserve the new checkout and offer Retry Launch. Creation
failures never launch an agent.

## Monitoring and safety

The menu bar popover jumps to live terminals and opens conversations. Closing the
window leaves monitoring running; Quit or `--stop` ends the app and its owned
provider children. Installation enables quiet launch at login. Once you open the
app, it stays in the Dock and Cmd+Tab until you quit, even after closing its window.
Click its Dock icon or choose Open Agent Workspace in the menu bar to reopen it.

Notifications start **off**, with independent settings, to avoid duplicate alerts
when Agent Control Center also runs. Enable them in Settings. Session transcripts
are shared underlying data: archiving a Codex session affects other history readers.
No settings or pins are imported from either existing app.

Live Codex **and Claude** agents protect their worktrees from removal and rebase.
Both provider streams must freshly confirm a requested refresh before a protected
batch proceeds. A failed, unavailable, or timed-out provider blocks it. Git then
rechecks the worktree's identity, HEAD, branch, cleanliness, and lock state against
the confirmation. Removal never forces a worktree; branch deletion retains its
tip/upstream/unmerged-commit checks, and conflicting rebases are aborted.

## Architecture and configuration

Sources live here; shared agent components are in `../lib/agents/`, and shared Git,
PR, and diff components are in `../lib/worktrees/`. All three apps compile shared
sources directly. Agent Workspace owns one persistent stream per provider and
shares one Git snapshot across its menu bar, sessions, and worktree views.
Unselected transcripts are not loaded. Provider updates do not rescan Git unless
the discovered project inventory changes. Git refreshes every 10 seconds with a
window open and every 60 seconds in the background; PR lookups are coalesced to
once per minute unless explicitly refreshed. Git and PR work runs off the UI thread.
Running multiple apps still means separate provider processes per app.

Repositories are discovered one level below the configured development root,
plus existing repositories referenced by agent history elsewhere. Linked worktrees
are grouped by their canonical common Git directory. Sessions in subdirectories or
symlinked paths attach to their containing worktree. Missing-directory and non-Git
sessions remain accessible through session history.

| Variable | Default / purpose |
| --- | --- |
| `AGENT_WORKSPACE_APP_DIR` | `~/Applications` |
| `AGENT_WORKSPACE_ROOT` | `TW_PROJECT_ROOT`, then `~/dev` |
| `AGENT_WORKSPACE_INTERVAL` | Provider interval: 5 seconds, minimum 2 |
| `AGENT_WORKSPACE_SESSIONS_BIN` | `codex-sessions` executable override |
| `AGENT_WORKSPACE_CLAUDE_SESSIONS_BIN` | `claude-sessions` executable override |
| `CODEX_HOME` / `CLAUDE_CONFIG_DIR` | Provider state-directory overrides |

Bundle and login identity: `local.agent-workspace`. Links use
`agent-workspace://open` or `agent-workspace://session/SESSION_ID`, with `claude:`
before Claude IDs. Existing apps retain their own URL schemes. The installer
builds, checks the signature and source manifest, then replaces only this app;
startup failure restores the previous bundle and login configuration.

Local builds reuse a private signing identity in
`~/Library/Application Support/Agent Workspace/Signing`. This lets macOS retain
folder permissions across rebuilds. Upgrading from an older ad hoc build can ask
once more for each folder. The signing identity stays on this Mac, is retained on
uninstall, and does not change system certificate trust or grant folder access.
Keep this directory to preserve the identity; deleting it creates a new identity
on the next install and macOS will request permissions again.

Shortcuts retain Agent Control Center's bindings: ⌘1 dashboard, ⌘K global search,
⌘F transcript search, ⌘⌥↑/↓ sessions, ⌘Return resume, ⌘⇧J terminal jump, ⌘⇧P pin,
⌘⇧A archive, ⌘⇧R refresh, ⌘I inspector. ⌘[ goes Back.

## Verification

`tests/dotfiles/test_agent_workspace.sh` checks association, history, navigation,
provider freshness, destructive-action revalidation, creation and launch failure,
and an isolated real build/install/rollback with stubbed system lifecycle commands.
Set `AGENT_WORKSPACE_TEST_ARTIFACTS` to a temporary directory to render light and
dark fixture windows there. Run the Personal suite with `./setup.sh --test --personal`.
`tests/dotfiles/test_agent_window_lifecycle.sh` covers quiet login, early opens,
Dock visibility, hiding, minimizing, and reopening native windows.
