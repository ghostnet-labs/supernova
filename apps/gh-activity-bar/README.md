# GitHub Activity

GitHub Activity combines the 50 most recent events returned by GitHub for your
locally cloned repositories. The Feed, Summary, and open PRs tabs use the same
repositories. Install and start it with `gh-activity-bar --install`.

Discovery reads each immediate child's `origin` in `~/dev`, matching Worktree
Manager. Normal clones, bare clones, linked worktrees, HTTPS remotes, and SSH
aliases are supported; duplicate origins count once. The folder is rescanned
at each refresh. Each repo in the panel's menu has **Open in GitHub** and
**Reveal in Finder** actions. Finder selects all local checkouts of that repo.
The **All repos** filter opens a checklist that stays open for multiple selections,
with **Select All** and **Clear All** actions. All repositories are selected by
default; choices are remembered per clone folder and apply to Feed, Summary,
and PRs. Filtering uses cached pages and shows the newest 50 events across the
selected repos, without additional GitHub requests.
Use `gh-activity-bar --root PATH` to choose another folder. Before a folder is
chosen, `GH_ACTIVITY_BAR_ROOT`, `WORKTREE_MANAGER_ROOT`, and `TW_PROJECT_ROOT`
are checked in that order. Non-GitHub remotes are skipped.

The app uses saved `gh` credentials, including private repository access. A
repo owner's saved account takes precedence over the active account, without
switching the active CLI account. Inaccessible repositories are named in the
panel; other repositories still load. GitHub's Events API may delay or omit
activity, so this is a recent activity feed, not a complete audit log.

Activity and PRs load at startup and refresh in the background every 15 minutes,
regardless of the selected tab or whether the panel is open. Panel opens, wake,
failed checks, and manual refreshes share that cooldown. Set
`GH_ACTIVITY_BAR_INTERVAL` when installing to change the interval.
Each repository requests one page of up to 50 events,
with at most four feed requests in flight. ETags reuse unchanged responses.
Rate limits pause requests per account and API quota; secondary limits pause
all requests. Titles are searched only for repos needing title enrichment.

Historical badges use the status recorded in the event. Merge attribution is
verified against `merged_by` and matching `merged_at`, with up to four lookups
per refresh; unresolved rows show “Merge actor unavailable.” Shared GitHub
Octicons come from `../lib/octicons/`.
