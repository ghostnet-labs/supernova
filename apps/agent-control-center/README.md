# Agent Control Center

One macOS app for live Codex and Claude Code agents, their conversations, and local history. The compact menu bar popover and full conversation browser share one session store, Git status cache, and notification system.

For a step-by-step introduction to project memory, coordinator conversations,
delegation, and hardware reports, see [Your tooling guide](../../docs/tooling-guide.md).

Reusable Swift components live in `../lib/agents/` and are also compiled by
[Agent Workspace](../agent-workspace/README.md). This app retains its own entrypoint,
installation, preferences, and session-first browser.

## Install and open

```sh
agent-control-center --install
agent-control-center --open
agent-control-center --status
```

Installation builds and validates the replacement before stopping either installed app. It retains rollback copies of both bundles and the login configuration until signatures, the source manifest, and startup are verified. On success it removes the previous **Codex Sessions.app**. `codex-sessions-app` is retired; `codex-sessions` and `claude-sessions` remain terminal tools. The `codex_sessions_app` shell helper forwards to Agent Control Center for compatibility.

The bundle identifier and login agent remain `local.agent-control-center`. Login and `--start` launch quietly. `--open`, reopening the app, a notification, or a session link focuses the same browser window. The Dock icon appears while an application window is open. Closing the browser leaves the menu bar app running; **Quit** or `--stop` stops the app and its provider children.

## Interface

- Click a popover terminal session or subagent to jump to its terminal through the provider's `--jump` action. Desktop and IDE sessions open their conversation in the browser. A root session's context menu includes **Open Conversation**. The footer's **Open Agent Control Center** button opens the browser.
- Live sessions appear directly below search, ordered by status and recency. Pinned, Recently closed, Projects, and All sessions follow. Selection remains attached to the session ID during reordering.
- Mission Control is the dashboard inside the browser. The previous separate Mission Control window is replaced by the browser.
- The browser retains Markdown conversations, tool timelines, incremental transcript scrolling, transcript search, project groups, the aligned inspector, and explicit Ghostty/tmux/Zellij resume choices.
- Repository paths use `~/…`, with shared Octicons, branch/status pills, Git counts, context bars, and expandable subagents. Each checkout gets one Git check shared by both surfaces.
- Notifications fire once when a known session enters waiting or interrupted, or finishes a busy turn. Initial discovery, failed providers, and reconnection baselines are silent.
- Archive and unarchive apply only to Codex history. After confirmation, a uniquely identified refresh must freshly confirm that the same session is inactive before its transcript moves.

Keyboard shortcuts: `⌘1` dashboard, `⌘K` session search, `⌘F` transcript search, `⌘⌥↑/↓` previous/next session, `⌘Return` resume, `⌘⇧J` jump, `⌘⇧P` pin, `⌘⇧A` archive, `⌘⇧R` refresh, and `⌘I` inspector.

## Project memory

**Project workspace** opens a separate Conversation / Tasks / Memory / Hardware workspace while preserving the existing conversation browser. Add a directory explicitly, then choose **Index recent history** (the 50 most recent matching sessions) or **Backfill all project history**. Indexing pauses when the workspace closes or the selected project changes; starting an indexing action again continues from durable byte checkpoints. Coverage shows indexed sources and bytes, unavailable sources, and oversized or invalid records excluded. Quiet browsing never scans the entire transcript corpus.

Projects have app-owned UUIDs. Git worktrees resolve through their canonical common Git directory within a scope; unrelated repositories never merge by name. Personal is the default. Work projects require an explicit job selection and have a separate project list and search boundary. A missing directory retains its history and supports **Relink**. This scope controls memory association; it does not source shell environments or grant agent execution authority.

Search uses local SQLite FTS5 and returns bounded ranked excerpts from visible user and assistant messages in Codex and Claude Code. Internal reasoning and tool payloads are excluded. Each source records provider/session/item identity, timestamp, byte range, and SHA-256 fingerprint. Both returned search hits and **Open original message** validate the cited bytes against that fingerprint. Invalid hits are withheld and their source is marked for rebuilding. Archive moves preserve citations; replacement, truncation, or deletion invalidates stale references. Indexing reads at most 2 MiB per batch and skips records over 1 MiB without allocating their complete contents.

Prefix and trailing checkpoints detect common rewrites while keeping routine appends incremental. They do not certify every interior byte on each refresh: coverage reports bytes processed, and an interior edit missed by those boundaries is detected when its indexed message is searched or opened. A rebuilt source is required before newly rewritten interior text can be found. Independent repositories nested inside an attached directory remain separate projects.

Capture decisions from messages or create them manually. Proposed, Accepted, Rejected, and Superseded are independent of Planned, Implemented, and Verified. Saving Accepted is a direct user action. Verification requires a linked test or inspected artifact and records its date; generated summaries cannot promote a proposal or delivery status. The source viewer can attach additional or conflicting evidence to an existing decision. Revisions are retained transactionally. The structured summary reports saved states and index coverage without inferring implementation.

Import selected conversations from a ChatGPT JSON export, or explicitly import a UTF-8 text/Markdown document. The selection sheet copies only chosen conversations; documents retain section/line citations. Imports are immutable local snapshots, with original IDs/URLs when available. Files larger than 32 MB must be split into individual selected conversations/documents before import.

Durable records live in `~/Library/Application Support/local.agent-control-center/projects.sqlite`, independently of provider data and caches. The serialized SQLite store uses transactions, WAL, schema versions, and backups before upgrading an existing database. **Back up project data** creates a consistent SQLite backup beside the database. Keep the `imports/` directory with the database when transferring all imported source files; the database backup alone does not copy those files.

## Managed coordinator conversation

The project **Conversation** tab starts an on-demand `codex app-server --listen stdio://` process when you send a message or reconnect. Opening saved history does not start this process. It uses the installed Codex CLI's existing sign-in and effective model, effort and permission configuration. No separate API key or permission override is introduced. The protocol adapter targets the locally verified 0.160.1 experimental API; unsupported operations surface as errors.

**Send** starts a turn; **Steer** appends input to the observed active turn; **Interrupt** cancels that turn. User input and approvals stay associated with the native thread, turn and connection generation. Command approval choices preserve the exact decisions offered by Codex, including any explicit persistent rule amendment. File approvals show available change diffs. Closing the window leaves an active conversation running. Explicit **Quit** interrupts owned turns, saves state, and stops owned control processes before exiting.

Every dispatch and its client message ID is committed to the app database before sending. A lost acknowledgement is shown as **Outcome unknown** and blocks further sends until **Reconnect / reconcile** checks native history. Reconciliation never blindly repeats a dispatch. If the new-thread acknowledgement and notification were both lost, inspect Codex history before explicitly choosing **New conversation**. A turn finishing means the model stopped; it does not establish that a delegated task's acceptance checks passed.

The native transcript retains visible user/assistant messages only, capped at 500 messages and 65,536 characters per message. History loads in 100-item pages; reconciliation reads the latest 20 turn summaries. Older history remains in Codex. Retrieved memory and delivered task results are bounded, explicitly untrusted context, separate from the human instruction. Result IDs are persisted to prevent duplicate deliveries, and application-generated results do not change the user's delegation authority.

Transport frames are capped at 8 MiB, pending RPC requests at 128, queued writes at 16 MiB, cached callback responses at 512, and stderr diagnostics at 8,192 characters. Background stdin writes and bounded stdout delivery keep a blocked child from freezing the UI. Unexpected disconnection never automatically restarts work.

## Delegated project tasks

Enable **Delegate research** or **Delegate code changes** beside the composer before sending the instruction that authorizes that work. The choices are captured for that human instruction. Project search and decision proposals cannot turn retrieved content or a child result into new execution authority. The coordinator exposes five small tools: project search, decision proposal, task creation, task inspection, and saved results. Decision proposals remain Proposed / Planned until a direct user action changes them.

Children have separate native Codex threads and app-owned parent relationships. Research children use a read-only sandbox; permission requests retain the provider's configured review policy. Code children use distinct managed Git worktrees under `Application Support/local.agent-control-center/task-worktrees/`, created from the selected checkout's committed HEAD. Uncommitted edits are not copied. Worktrees and branches are retained with their results; cancellation does not discard files. The default limit is two active children and can be changed to 1–8 in **Tasks**. Relinking a project changes the directory for future parent turns and new tasks; existing children retain their saved checkout.

Task cards show the objective, provider, state, latest update, working directory, related files, deliverable and completion evidence. A child submits a structured report; an ordinary successful provider turn alone is **Needs input**, never Completed. Each predefined check must pass: required literal text in the delivered report, an observed successful native command with the exact requested command text, or an app-inspected file inside the task checkout. These checks establish delivery evidence, not the correctness of every claim. **Verify…** separately records the user's independent inspection or test evidence.

Dispatch intents, native IDs, tool-call deduplication, previous attempts and result deliveries are durable. Child results wait until the parent is idle and are sent once as untrusted context. Unknown acknowledgements are reconciled using native turn IDs or the persisted client message ID in a bounded recent history page. A missing match remains Unknown; the app never guesses that it is safe to repeat work. A new-thread acknowledgement lost before any native identity is recorded requires inspection of Codex history and an explicit new task.

**Pause all** stops dispatch and requests interruption of the coordinator and active children. **Continue…** resumes saved conversation context using a new explicit instruction; it does not restore an interrupted shell process. Restarted work is paused for reconciliation or continuation. Pending approvals and input requests appear on the specific task using the same native controls as the coordinator. Explicit Quit checkpoints tasks, interrupts owned turns and stops the owned control processes before the app exits. Claude history remains searchable; Claude execution and OpenCode execution are later extensions.

`test_agent_task_coordinator.sh` exercises scope validation, replay, concurrency, early completion events, blockers, failure, unknown dispatches, relinking and restart. `fixtures/agent_task_live.swift` is an opt-in disposable live test for two real child tasks and exactly-once parent delivery; normal repository tests never use authentication or model calls. `fixtures/agent_task_ui.swift` renders temporary light, dark, empty and narrow-window task views without opening user data.

## Providers

The application owns one persistent child for each provider:

```sh
codex-sessions --stream-json --interval 5
claude-sessions --stream-json --interval 5
```

Each stdout line is a versioned snapshot:

```json
{"version":1,"provider":"codex","sequence":1,"generated_at":0,"refresh_ids":[],"health":"ok","sessions":[],"active_subagents":[]}
```

`health` is `ok`, `loading`, `unavailable`, or `error`; error snapshots include `error`. `sessions` includes all root history and Codex archives, without a listing limit. `active_subagents` carries current hierarchy and terminal targets. Records extend the existing CLI JSON contract with `transcript_path`, `archived`, timestamps, `file_bytes`, `file_identity`, `file_modified_ns`, lifecycle timestamps, and context/token statistics including `context_window_is_estimated`.

Claude snapshots also include `subagents`, the full child history for desktop and CLI
sessions. The app uses it when present, falling back to `active_subagents` for older
providers. Completed children are Closed; unfinished children under a live parent
become Idle after five minutes without transcript activity, staying in the hierarchy.

Write `{"command":"refresh"}` followed by a newline to stdin for a coalesced immediate refresh. The snapshot collected after that request lists its `request_id` in `refresh_ids`, or `"refresh"` when the request had none. Closing stdin ends the stream. Diagnostics go to stderr. Existing listing, JSON, watch, TUI, resume, and jump interfaces remain available.

CLI providers own identities, saved titles, lifecycle, live-process attribution, hierarchy, and terminal targets. Codex names prefer SQLite `name`, then `session_index.jsonl` names, then a distinct saved title. Names refresh independently of transcript changes. Claude verifies PID start times, preserves user/custom title precedence, excludes meta/sidechain records, deduplicates response usage, and clears current-context usage after compaction. Inferred context capacities are marked estimated; ambiguous model variants leave capacity unknown.

Native readers only load the selected conversation and tool payloads; they do not discover sessions or override provider metadata. Quiet menu bar operation does not load any transcript. Provider failure retains the last successful state, marked stale. Malformed output or child exit triggers a bounded 1–30 second exponential restart backoff. Missing state directories are normal unavailable states.

## Performance and local data

The project Hardware tab accepts explicit `hardware-planner-report` v1 JSON exports. Each attachment retains its report/project/assembly/source IDs, export and import times, schema version, original filename and canonical SHA-256 fingerprint. Choose a report in the Coordinator context picker to include its bounded excerpt with the next new coordinator turn; imported reports are disabled as context by default. The full report remains available locally, including checks, unknowns, coverage and source citations. Context is untrusted evidence and cannot authorize actions. Steer messages during an active turn retain that turn's earlier context; send a new turn to supply a newly selected report.

Open assembly/source links to inspect the exact records in Hardware Planner. Missing local project data requires importing the matching lossless Planner project JSON. The coordinator may propose cited changes, but only Hardware Planner's explicit deterministic preview and acceptance saves them. Reports are immutable snapshots, not live compatibility status. Personal and Work project attachments remain separate; no Hardware Planner database or global hardware corpus is indexed.

Providers retain compact summaries rather than transcript contents. Complete appended JSONL records are processed incrementally; incomplete final lines wait for their newline. Inode, size, timestamp, and boundary fingerprints detect replacement, truncation, and truncate/regrow operations.

Versioned JSON summary caches also survive app restarts. They live under `$XDG_CACHE_HOME` when it is set, on any platform; otherwise under `~/Library/Caches/local.agent-control-center/` on macOS and `~/.cache` on Linux. Each provider/state-directory pair has its own private cache directory. Deleting this cache is safe and makes the next discovery scan history again. A corrupt cache file is rebuilt from its transcript. Large first scans emit loading heartbeats.

History indexes, decisions, and managed conversation records are stored locally. Sending a managed conversation transmits its instruction and selected context through the configured Codex service. The app does not add telemetry. Existing `codex-sessions://session/…` links remain registered alongside `agent-control-center://session/…`; session IDs and pin IDs remain unchanged. Existing Codex Sessions pin, notification, sound, and verbosity preferences are imported once, preserving explicit values already in the destination domain.

## Configuration and verification

- `AGENT_CONTROL_APP_DIR`: bundle installation directory, default `~/Applications`.
- `AGENT_CONTROL_INTERVAL`: provider interval, default five seconds, minimum two.
- `AGENT_CONTROL_SESSIONS_BIN` / `AGENT_CONTROL_CLAUDE_SESSIONS_BIN`: provider executable overrides.
- `CODEX_HOME` / `CLAUDE_CONFIG_DIR`: state-directory overrides.
- `CODEX_SESSIONS_APP_DIR`: previous browser installation directory during migration.

Installation preserves existing login-agent environment overrides unless replaced explicitly. `Contents/Resources/SourceHashes.json` records the exact Swift, shared-view, and provider sources used for a build. `install_support.py verify` compares that manifest with the checkout. The installer verifies the bundle signature before and after replacement.

Tests live under `tests/dotfiles/`: provider stream/cache fixtures, shared store and transport lifecycle checks, isolated fresh install/migration/rollback checks, and retained transcript/timeline/project/scrolling fixtures. Run them through `./setup.sh --test --personal`.
