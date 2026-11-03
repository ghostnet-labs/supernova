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

The sidebar has a **Sessions / Repositories** switch beneath compact navigation
controls next to the native window buttons. The sidebar toggle hides the whole
sidebar; the controls move into the main header so it can always be reopened.
**Back** (⌘[) and **Forward** (⌘]) restore the page, selection, and filters. Opening
a new page after going back starts a new navigation path. Search (⌘K) opens and
focuses the sidebar search field. Drag the divider to resize the sidebar; its width
and collapsed state are remembered. Switching modes and collapsing preserve the
open page, scroll positions, and expanded folders. The slide animation respects
the macOS Reduce Motion setting.

The **Appearance** button at the bottom of the sidebar opens a theme and font
picker; it moves to the main header when collapsed. Choose **Tokyo Night**, **VS Code**,
**GitHub Dark**, **Dracula**, **Nord**, **Catppuccin Mocha**, **Gruvbox Dark**,
**Obsidian**, **One Dark**, or **Rosé Pine**. Colors apply immediately without
leaving the current page, and the choice is remembered across launches. **System**
(the default) follows macOS appearance and accent preferences, with softer gray text in dark mode.
Named themes use muted, hue-matched text with 4.5–9:1 contrast on conversation and code surfaces.
Each named theme keeps the sidebar's hue in the conversation at 10% higher brightness, with no
neutral gray overlay. Header controls live in the native title bar so mouse clicks
reach the buttons, and the transcript stays below them. Inline code
uses warm text on a contrasting background, keeping commands and paths distinct
from prose without changing selection, copying, or wrapping.
Fenced code uses theme-specific syntax colors for Swift, Python, JavaScript/TypeScript,
C/C++/C#, Java, Go, Rust, shell scripts, JSON, YAML, TOML, SQL, CSS, HTML/XML, and Markdown.
Keywords, strings, numbers, types, functions, and comments stay readable on each theme's
code background. Diffs retain green additions and red removals. Highlighting is lexical,
with cached tokens and rendered colors; unknown languages, blocks over 100 KB, and blocks
requiring over 5,000 colored runs remain plain text. Copy always keeps the original source.
The **Font** section offers **System**, **Rounded**, **Serif**, **Monospaced**,
**ChatGPT** (OpenAI Sans), **Claude** (Anthropic Serif), **Claude UI** (Anthropic Sans),
and **GitHub** (Mona Sans), with a live preview. The selection applies across the workspace, menu bar popover,
and settings, while code and diffs stay monospaced. Font and theme choices are saved
independently. Saved GitHub Light and Solarized Light choices migrate to GitHub Dark
and Obsidian respectively.
Mona Sans is bundled with its open-font license. OpenAI and Anthropic fonts load
from their installed desktop apps (or fonts already available to macOS); the picker
reports a System fallback if those fonts are unavailable. OpenAI font assets are
cached under `~/Library/Caches/Agent Workspace/Fonts`. Fonts are registered only
inside Agent Workspace, with no system-wide installation.

Navigation controls and the mode switch stay visible while the sidebar's list scrolls.
Sessions shows **All Sessions**, **Mission Control**, live sessions, and the 20 latest
inactive **Recent** sessions. Repositories shows **All Repositories**
and expandable repositories and worktrees. Clicking a repository row opens its page
and toggles its worktrees open or closed, just like the arrow. The current selection is
highlighted with a soft neutral fill when focus moves elsewhere. Recent and subagent
groups also toggle when clicking their label or empty row space, as well as their
arrow. Switching keeps each list's scroll and
expansion state and leaves the open page in place; the selected button is remembered
across launches. Search matches sessions, repository names, branches, and paths
across the app. Full history has archive and pin filters, expandable subagents,
and terminal jumps.

Sidebar sessions show only the title and a compact status badge with time in the current
state (such as Busy 3m or Idle 12m). Durations use seconds, minutes, hours, or days.
Idle means the session is open with no active work;
Waiting is reserved for an explicit input or permission request reported by the provider.
Recent sessions show just the title; stale sessions
show Stale without an elapsed time so disconnected agents do not appear busy. Hover reveals the full title.
The sidebar starts at 330 points wide and remembers resizing; its context menu
retains session actions. Click the conversation title in the main header and choose
**Session details** to reveal full metadata, subagents, and resume options.
Resume, Inspector, worktree, Changes, and Refresh are also available
as compact header buttons. Detailed session rows remain on overview and history pages.
Claude desktop and Claude Code sessions both show expandable subagents, including
finished children marked Closed. Unfinished children stay visible as Idle after
five minutes without transcript activity. Only live children count toward running
agents and worktree protection; unchanged transcripts reuse cached summaries. A
Cowork session archived from inside the Claude desktop app is read as archived
here too, the same as an archived Codex session, though only Codex sessions can
be archived or unarchived from this app.

The top header's **Refresh** updates sessions, reloads the open conversation, and
refreshes repositories, worktrees, and pull requests. Session, repository, and worktree
details all use this shared button (⌘R). While loading, a spinner replaces its arrows
in the same space and the button is disabled.

The window remembers its size and position across restarts. The first window opens
on All Repositories. Later openings restore the last page;
missing targets fall back to All Repositories. Repository pages retain Worktree
Manager's selection, batch actions, branch cleanup, and GitHub PR presentation.
Pending Codex desktop follow-ups and Claude messages appear under **Queued messages**
in the conversation pane and disappear when delivered or removed. Claude messages
delivered during a running turn also appear in the conversation history.
Delivery timestamps and IDs clear those messages from the queue even when Claude
omits the enqueue text. Truly pending messages without recorded text show a
preview-unavailable placeholder until they are delivered or removed.
A selected repository opens directly to its worktrees, branches, and pull requests.
Use a worktree's **Overview** button or the sidebar to open its status, action bar,
live sessions, recent conversations, and PRs. Conversations and **Changes** open
in the main area. **Back** and **Forward** restore the page, selection, filter, and
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

### Remote SSH sessions

Open **Settings → Remote SSH sessions**, enter host aliases from your SSH config
(or `user@hostname`), one per line, and choose **Apply hosts**. The list starts
empty. Connections use your existing SSH keys and known hosts; first connect in
Terminal with `ssh HOST` if a host needs authentication or its host key accepted.
Monitoring never prompts for passwords or accepts unknown host keys.

Each host needs Python 3.10 or newer on its non-interactive SSH PATH. The app sends
its matching Codex and Claude session readers over SSH and runs them in memory;
no setup checkout or helper installation is needed on the host. Readers use the
remote user's `CODEX_HOME` / `CLAUDE_CONFIG_DIR` when set in the SSH environment,
otherwise `~/.codex` / `~/.claude`. Only configured hosts are contacted.

Remote conversations appear in Sessions with their host name and are searchable
by host. Each provider keeps one SSH connection, retries failures with backoff,
and retains disconnected rows marked **Stale**. Settings shows connection status
for each provider; a host with no history for a provider is reported separately.
On launch, a saved remote conversation waits for its host, including reconnects,
before deciding whether that conversation is still available. Other hosts do not
delay local navigation.
Opening a conversation downloads its transcript in bounded incremental chunks
to a private temporary cache, removed when monitoring stops. Unopened transcripts
are not downloaded.

**Open SSH Terminal** opens Ghostty on that host and attaches to the recorded
tmux pane or Zellij session when available; otherwise it opens a shell in the
remote working directory. On Linux hosts, as on macOS, Codex sessions held by its
background app-server are credited to the terminal showing them when that match is
unambiguous; otherwise they open a shell, never the pane that launched the daemon. **Resume over SSH** is available for inactive,
connected sessions. Remote sessions cannot be archived from this app, opened as
local folders, or associated with local worktrees. Their Git metadata comes from
the session reader; remote repository/worktree management is not included.

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
Set `AGENT_WORKSPACE_TEST_ARTIFACTS` to a temporary directory to exercise the mounted
controls and save offscreen light, dark, theme, and font snapshots there, including
on failure. Test windows stay invisible and never take focus. Run the Personal
suite with `./setup.sh --test --personal`.
Offscreen snapshots cover layout and colors; macOS may omit virtualized transcript
rows and native titlebar content. Transcript text and controls are checked through
accessibility.
`tests/dotfiles/test_agent_window_lifecycle.sh` covers quiet login, early opens,
Dock visibility, hiding, minimizing, and reopening native windows.
