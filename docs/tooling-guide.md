# Your tooling guide

This guide explains the Toolbox, history, Agent Control Center, and Hardware Planner tools, how to use them,
and what happens to your data. Start with the first two sections; use the rest
when you need a particular workflow.

Jump to [terminal history](#toolbox-and-atuin-what-is-automatic),
[the shell functions](#the-shell-functions),
[project memory and tasks](#agent-control-center-remember-and-coordinate-a-project),
[hardware planning](#hardware-planner-parts-boms-compatibility-and-changes),
[storage and Git](#what-is-in-git-and-what-stays-on-the-machine), or
[updates and other machines](#updates-and-other-machines).

## What each thing does

| Tool | Use it when you want to… | Open it with |
| --- | --- | --- |
| **Toolbox** | Find a helper, a saved recipe, or an old command and put it into your terminal for editing | `toolbox --pick` |
| **Atuin** | Find something you previously typed in a terminal | **Ctrl+R** |
| **Shell functions** | Do a common job with a short command and normal arguments | For example, `glog` or `rfind TODO` |
| **Agent Control Center** | Browse agent chats, remember project decisions, and coordinate delegated work | `agent-control-center --open` |
| **Hardware Planner** | Record exact parts, build a bill of materials, check documented compatibility, and compare changes | `hardware-planner --open` |

Toolbox and Atuin overlap deliberately. Atuin supplies searchable local command
history. Toolbox reads that history and also knows about the helpers currently
loaded in your shell, available managed commands, and optional saved recipes.
A function is the actual reusable command; Toolbox helps you discover it.

Agent Control Center and Hardware Planner are separate macOS apps. They exchange
hardware report snapshots when you explicitly export and attach one. The memory,
managed conversation, and delegation features described here are in the existing
**Agent Control Center** app. **Agent Workspace** remains a separate app.

## Start here

In a terminal using this setup checkout:

```zsh
source_zsh
toolbox --pick
```

Type `git`, choose a result, and press Enter. The selected text appears in your
prompt. Edit it if needed, then press Enter again to run it. **Selecting a result
does not run it.** Escape cancels the picker and preserves your original input.

Try these ordinary functions inside a Git repository:

```zsh
glog                  # Recent commits
gdiff                 # Unstaged changes
gstaged --check       # Check staged changes for whitespace errors
```

Press **Ctrl+R** to search Atuin. Enter also inserts its selection for editing.
In Zellij, first use **Ctrl+G** to enter Locked mode so Ctrl+R reaches the shell.

On macOS, open the apps with:

```zsh
agent-control-center --open
hardware-planner --open
```

If an app is absent or needs rebuilding from your current checkout, use its
`--install` command. This builds and installs that app and starts it. Updating
repository files alone does not rebuild an already installed app.

## Toolbox and Atuin: what is automatic

| Action | What happens |
| --- | --- |
| Run a command in an interactive shell with Atuin enabled | Atuin records it in that shell's active scope |
| Open Toolbox | It reads available helpers, optional catalogs, and the enabled local Atuin history |
| Run the same command repeatedly | Toolbox offers one history entry per exact command text within each scope |
| Change arguments, whitespace, or quoting | That variation remains a separate history entry |
| Run `source_zsh`, or open a new shell | Updated function definitions and managed Atuin configuration are loaded |
| Use a command frequently | It remains searchable; a new named function is **not** generated automatically |

There is no model to train on your Bash or Zsh history. We inspected the existing
history and turned common patterns into the functions listed below. Future
commands appear through history automatically; creating more named functions is
a separate code change.

An existing Zsh archive that mixes Personal and Work commands belongs in the
Work history scope, not Personal. Helper names can also be imported as
suggestions without executing them. Both are one-time local operations, not
imports that run on every machine or every shell startup.

Raw history has its original text, including multiline commands. It may refer
to an old directory, a different cluster, or an unavailable tool. Toolbox checks
availability for its managed-command inventory; it does not validate every old
history command. Malformed history databases produce a visible error. Invalid
text, NUL bytes, and individual commands over 1 MiB produce explicit omission
counts; none were omitted from the verified source archive.

### Find and inspect commands

```zsh
toolbox git                    # List matching helpers and history
toolbox --pick 'git diff'      # Choose an example or previous invocation
toolbox --describe glog        # Description, arguments, examples, and source
glog --help                   # The function's own help
toolbox --json history:        # Structured output containing local history
```

**Ctrl+X, then Ctrl+T** opens Toolbox from the current terminal input when that
binding is available. Existing bindings are preserved. Helpers appear before
catalog entries and history. History and catalog results have generated names;
their preview shows the command text you will insert.

### Personal and Work are separate

Scope comes from the shell's setup configuration, not the directory you `cd`
into. Work requires `WORK_ENV=true` and the selected `JOB`, such as `acme`.
Use the normal setup scope controls when configuring a machine.

| Current shell | Atuin Ctrl+R searches | Toolbox includes |
| --- | --- | --- |
| Personal | Personal history | Personal helpers, managed commands, catalog, and history |
| Work (`JOB`) | Work history for that job | Personal tools/catalog/history plus the job's overlay tools and its catalog/history |

One-time helper suggestions can be added to both Atuin scopes, so Personal
helper names are also discoverable in the Work Ctrl+R search. Other
future Personal commands are not automatically copied into Work history.

To inspect the active destination:

```zsh
print -r -- "$_SETUP_ATUIN_ACTIVE: $ATUIN_DB_PATH"
```

A Personal computer does not load work helpers or receive another machine's
Work history. Work helper source code lives in the separate work overlay
checkout, never in this repository, and Personal mode leaves it unloaded. Cloning the repo does not copy any Atuin database.
Normal Zsh history and Up-arrow recall continue independently. Atuin's scope
separation does not rewrite or separate an existing mixed `~/.zsh_history` file.

## The shell functions

These accept normal arguments. You do not need to define placeholder variables
before every use. Replace example paths and targets with your own, and use
`NAME --help` for details. Optional arguments appear in square brackets here;
do not type the brackets.

### Personal functions

| Function | What it does | Example |
| --- | --- | --- |
| `gdiff [PATH ...]` | Show unstaged changes, optionally for literal paths | `gdiff README.md` |
| `gstaged [--stat or --check] [PATH ...]` | Show staged changes, a file summary, or whitespace checks | `gstaged --stat` |
| `glog [COUNT]` | Show a commit graph; default 20 commits | `glog 50` |
| `gahead [REF]` | Show local commits missing from a reference; default upstream | `gahead origin/main` |
| `gbehind [REF]` | Show reference commits missing locally; default upstream | `gbehind` |
| `gfiles [REF]` | List branch files changed since the merge base; default upstream | `gfiles origin/main` |
| `gfilelog PATH ...` | Show commit history and statistics for literal paths | `gfilelog README.md` |
| `rfind PATTERN [PATH ...]` | Search file contents with line numbers | `rfind TODO` |
| `rcontext PATTERN [PATH ...]` | Search with five surrounding lines | `rcontext timeout logs` |
| `rcount PATTERN [PATH ...]` | Count matching lines per file | `rcount TODO` |
| `ffind PATTERN [DIRECTORY]` | Find filenames, including hidden and ignored files except `.git` | `ffind readme` |
| `flines [DIRECTORY]` | Count lines in visible, non-ignored files within five directory levels | `flines dotfiles/functions` |
| `httpstatus URL` | Print an HTTP status code with a 30-second timeout | `httpstatus https://example.com` |
| `httpjson URL` | Fetch and format JSON, reporting HTTP failures | `httpjson https://api.github.com` |
| `sshproxy HOST [LOCAL_PORT]` | Open a localhost SOCKS proxy; default port 1080 | `sshproxy example-host` |
| `sshtunnel HOST LOCAL_PORT [REMOTE_PORT] [REMOTE_HOST]` | Forward a localhost port through SSH | `sshtunnel example-host 8080` |

Git comparisons use locally cached references; they do not fetch remote changes.
Search patterns use the underlying `rg`/`fd` pattern syntax. The three `r*`
searches include hidden files, exclude `.git`, and otherwise respect ignore
rules. SSH helpers run in the foreground until you stop them with Ctrl+C;
`sshtunnel` defaults the remote port to the local port and remote host to
`localhost`; it listens locally on `127.0.0.1`. HTTP helpers make a request when
run; selecting them in Toolbox does not make that request.

A work overlay adds its own functions in `$WORK_DIR/bin-$JOB/functions-$JOB.sh`
and `$WORK_DIR/functions/*.zsh`; they appear in Toolbox in a Work shell.

## Do I still need a command catalog?

Usually, no. Functions cover reusable workflows, and history covers previous
commands. The earlier generated recipes with required environment placeholders
were replaced by named functions and direct history search. Existing user-saved
entries were preserved.

A catalog is useful when you want to keep a particular recipe with a description:

```zsh
toolbox --save 'git log -5 --oneline' --description 'Review recent commits' --tag git
toolbox --pick 'recent commits'
```

Saving uses the active shell's scope. In a Work shell, add `--scope personal`
only when intentionally saving a Personal recipe. Saving scans the complete
resulting catalog, including decoded command text, before writing it.

`--collect-history`, `--pending`, `--review`, `--accept`, and `--reject` remain
available for deliberate catalog curation. You do not need them to see history.
`newdev` no longer creates a review backlog. Saving a catalog entry does not
stage, commit, push, or add that entry to Atuin automatically.

See the [catalog reference](../dotfiles/toolbox/README.md) for optional workflows.

## Agent Control Center: remember and coordinate a project

### Open the project workspace

1. Run `agent-control-center --open`.
2. Click **Project workspace** in the left sidebar below **Search sessions**.
3. Choose **Personal**, or choose **Work**, enter **Work job**, and click
   **Open Work projects**.
4. Click **Add project…**, select its working directory, then select the project.

The workspace has **Conversation**, **Tasks**, **Memory**, and **Hardware** tabs.
Use **Back to conversations** to return to the existing session browser.
Git worktrees of the same repository share a project within a scope. Use
**Relink…** if a folder moves. Project scope separates memory; it does not switch
your shell environment or itself authorize agent execution.

### Build useful memory

In **Memory**, click **Index recent history** for the 50 most recent matching
Codex/Claude sessions, or **Backfill all project history** for all matching
sessions. Search with **Search visible project messages**, then use
**Open original message** to inspect a result and its source.

Indexing starts when you request it. Closing the workspace or changing projects
pauses it; clicking an indexing action again continues from saved checkpoints.
Coverage shows what was processed, what was unavailable, and what was excluded.
This searches visible user/assistant messages, excluding hidden reasoning and
tool payloads. It does not automatically read every chat across every service.

For other material, use **Import → Selected ChatGPT conversations…** with a JSON
export and select the conversations you want, or **Import → Text or Markdown
document…**. These are local snapshots, not live synchronization with ChatGPT.
Split import files that exceed the 32 MiB limit.

Use **Capture decision** on a message or **New decision** to record a choice.
Each decision has two independent states:

| Question | Saved choices |
| --- | --- |
| Have we agreed to this? | Proposed, Accepted, Rejected, Superseded |
| How far has it been delivered? | Planned, Implemented, Verified |

For example, “Use controller revision B” can be **Accepted / Planned** while
implementation is still pending. **Verified** requires linked test or inspected
artifact evidence. Agent proposals do not automatically become accepted or
verified. **Structured project summary** reports these saved states and coverage.

To supply verification evidence, open a message or imported document containing
the test result or artifact inspection and use **Attach to decision**. In the
decision editor, mark that evidence as **Test** or **Artifact** and describe what
it establishes, then select **Verified** and **Save**.

### Talk to the coordinator and delegate

In **Conversation**, enter a message and click **Send**. This creates or uses a
project coordinator chat; it does not turn an old browsed chat into the
coordinator. It uses the installed Codex CLI's existing sign-in and effective
model, effort, and permission settings. **Settings** displays them.

To delegate, enable **Delegate research**, **Delegate code changes**, or both
before sending the instruction authorizing that work. For example:

> Research the two approaches, then implement the selected change in separate
> tasks. Include a focused test result and a short report for each task.

Research children use a read-only sandbox. Code children use separate Git
worktrees based on the selected checkout's **committed HEAD**. Uncommitted edits
are not copied. Their worktrees and results are retained; completed changes are
not automatically merged into your main checkout.

In **Tasks**, inspect objectives, updates, working directories, and
**Deliverable and completion evidence**. **Open checkout** takes you to the code.
The default concurrency is two children; **Concurrent tasks** supports 1–8.
Completed child results are delivered to the coordinator once it is idle.

A model finishing a turn does not by itself complete a task. Completion needs
the structured report and predefined evidence checks. Missing evidence can leave
the task at **Needs input**. **Verify…** records your independent verification.
Managed execution currently uses Codex; Claude history is searchable, but
managed Claude/OpenCode execution is not implemented.

### Stop, steer, and recover

| Situation | Control and effect |
| --- | --- |
| Add direction during an active coordinator turn | **Steer** |
| Stop that turn | **Interrupt** |
| Pause scheduling and request interruption of current work | **Pause all** in Tasks, or **Pause coordinator** |
| Allow queued task dispatch again | **Resume dispatch**; this does not individually continue every interrupted task |
| Coordinator reports **Outcome unknown** | **Reconnect / reconcile** before sending more |
| A task has uncertain execution state | **Reconcile** on that task |
| Continue an interrupted task after resolving its state | **Continue…**, provide an additional instruction, then **Continue** |

Continuation resumes conversation context, not a half-finished shell process.
After an app restart, unfinished work stays paused for reconciliation or explicit
continuation. The app does not automatically repeat an uncertain dispatch.
Closing the window leaves active work running. Use **Quit** to checkpoint and
interrupt owned work before exiting. `agent-control-center --stop` stops the
app; reconcile unfinished work after restarting.

The coordinator receives bounded project context, not every historical message.
A newly selected hardware report is supplied with a new turn; steering an
already active turn retains that turn's earlier context.

## Hardware Planner: parts, BOMs, compatibility, and changes

Hardware Planner requires macOS 14 or newer.

A **part revision** is an exact recorded version of a component. An **assembly**
selects part revisions, quantities, offers, and connections. Its **BOM** (bill of
materials) is the list to purchase. **Compatibility** checks the recorded facts
and evidence about that assembly. A costed BOM alone does not prove a build works.

### Build your first assembly

1. Run `hardware-planner --open`, click **New project**, give it a name, and click
   **Create**.
2. In **Project → Edit project and evidence**, add requirements. Under
   **New source observation**, record document URLs or use **Attach document…**,
   including the revision, page/section, retrieval date, and confidence. Click
   **Add source to project**, then **Save**.
3. In **Parts → Add part**, record each component's exact **Board revision**,
   interfaces, power rails, software support, and linked evidence. Click
   **Save revision**. Leave unknown values blank.
4. Optionally use **Record offer** for a dated seller, currency, price,
   availability, and minimum quantity.
5. In **Assemblies → New assembly**, use **Add selected part**. Choose the exact
   **Part revision**, **Quantity**, **Role / reference**, and **Price observation**.
   Use **Add connection** to link real From/To interfaces and specify required
   protocol and lanes. Click **Save assembly**.
6. Open **BOM**. It uses the selected assembly and offers. Unpriced lines stay
   unknown, currencies have separate subtotals, and tax/shipping stay separate.
7. Open **Compatibility**, inspect the checks, and click **Save check** to retain
   that run. Use **Recheck** to assess current evidence and **Saved checks** to
   revisit previous runs.

For a generic controller/sensor/power-supply project, record the actual connector,
voltage, protocol, pin mapping, and peak power evidence before expecting a pass.
The optional field-node worksheet contains chat-derived candidates, not verified
purchase choices. The app does not fetch specifications or prices automatically.

### Understand the result

| Result | Meaning |
| --- | --- |
| **Compatible** | The evaluated rules have sufficient evidence and pass |
| **Conditional** | Recorded conditions, such as software or adapter requirements, still apply |
| **Incompatible** | A recorded fact violates an evaluated rule |
| **Unknown** | Required facts or suitable evidence are missing, ambiguous, or stale |

Coverage reports how many checks have sufficient inputs and evidence. The engine
checks documented connector details, voltage ranges, protocols, pins, mating
dimensions, port/lane capacity, software support, power supply paths, peak power,
headroom, and adapter transformations. Evidence must meet the recorded source
requirements; the default freshness window is 365 days. Chat candidates cannot
substitute for manufacturer or measured evidence.

These results depend on the facts you enter. They do not authenticate a document
or certify a physical build. Enclosure clearance, electrical transients, RF,
thermal behavior, battery endurance, and field performance need appropriate
separate analysis or testing. The engine specifically requires **measured
evidence** for RF, thermal, battery/runtime, and field requirement checks;
analysis alone does not satisfy those checks. See the [compatibility reference](../apps/hardware-planner/COMPATIBILITY.md)
for exact rules.

### Compare a replacement without changing the original

Use **Alternatives** for a side-by-side comparison; it does not change the
assembly. To assess and accept a replacement:

1. Add the replacement as a part revision.
2. In **Compatibility**, click **Preview change…**.
3. Select **Assembly item**, **Replacement revision**, **Quantity**, and **Offer**.
4. Map every used interface with the **Map …** selectors.
5. Click **Calculate impact**. Inspect changed checks, dependent items,
   connections, requirements, adapters, quantities, and costs.
6. Choose **Accept new revision** to save it, or **Cancel** to leave the project
   unchanged.

The original assembly remains available. Hardware changes reset affected
requirement assessments to **Unknown**; price-only changes preserve hardware
assessments. **Record override…** adds an author and reason beside a finding;
it does not change the machine result or coverage. **Changes** is revision
history, not the location of the change-preview action.

### Export, share, and connect to the coordinator

| Export choice | Use it for |
| --- | --- |
| **Project JSON (lossless)** | Transfer a whole project with exact revisions, evidence, and attachment bytes |
| **Purchasing BOM CSV** | Purchasing rows; it does not preserve the complete connection graph |
| **Review report Markdown** | BOM, costs, requirements, sources, and saved findings; save a current check first |
| **Compatibility → Export report…** | The currently displayed check, including an older saved check if selected |
| **Coordinator report JSON** | A fresh check and bounded evidence for the selected assembly |
| **Back up database** | A consistent backup of the full local database |

To discuss an assembly with an agent:

1. Select it in Hardware Planner and choose **Export → Coordinator report JSON**.
2. In Agent Control Center, select the intended project, open **Hardware**, and
   click **Attach report…**.
3. Select that report under **Coordinator context**; the default is **None**.
4. Send a new coordinator message about the assembly.

Attaching alone does not send a report to the coordinator. Use **View report**,
**Open assembly in Planner**, and cited source links to inspect it. The report is
an immutable snapshot. After an assembly changes, export and attach a fresh one.
Coordinator prose cannot edit the Planner project; accept changes through the
Planner's explicit preview. On another Mac, import the lossless project JSON
before expecting assembly/source links to resolve.

## What is in Git, and what stays on the machine?

| Data | Default location | Shared by pulling this repo? |
| --- | --- | --- |
| Personal function definitions | `dotfiles/functions/history_helpers.zsh` | Yes |
| Work function definitions | `$WORK_DIR/bin-$JOB/functions-$JOB.sh` in the work overlay | No; they travel with the overlay checkout and load only in the matching Work scope |
| Managed Atuin configuration template | `dotfiles/atuin/config.toml` | Yes |
| Optional Personal recipes | `dotfiles/toolbox/personal.jsonl` | Yes |
| Raw Atuin history | `~/.local/share/atuin/scopes/SCOPE/` | No |
| Normal Zsh history | `~/.zsh_history` (or your configured `HISTFILE`) | No |
| Scoped Atuin configuration | `~/.config/atuin/scopes/SCOPE/config.toml` | Locally refreshed from the tracked template |
| Work recipes and optional review state | `~/.local/share/toolbox/SCOPE/` | No |
| Optional catalog-location configuration | `~/.config/toolbox/config.json` | No |
| Agent projects, decisions, tasks, and imports | `~/Library/Application Support/local.agent-control-center/` | No |
| Hardware projects and attachments | `~/Library/Application Support/Hardware Planner/` | No |

`SCOPE` is `personal` or `work-JOB`. `XDG_DATA_HOME` and `XDG_CONFIG_HOME` can
override the terminal-tool defaults above. Work catalogs and local state remain
outside the setup repo. Ignore rules also exclude local Toolbox config, state
sidecars, and Work folders if placed under `dotfiles/toolbox/`.

Before publishing changes, scan the intended files. Catalog writes require
built-in screening and working Gitleaks; setup's pre-commit hook checks staged
changes again. These checks reduce accidental secret disclosure; they do not
make an arbitrary Work command appropriate for a Personal repository. Listing
or exporting history can include its original sensitive text, so raw history
does not belong in the shared catalog or documentation.

Use **Back up project data** in Agent Control Center for its `projects.sqlite`
database. Preserve the separate `imports/` directory when transferring imported
sources; that database backup alone does not copy those files. Task checkouts
live separately under `task-worktrees/` and should be preserved if needed.
Hardware Planner's **Back up database** and lossless project JSON include its
stored attachment data. Neither app automatically synchronizes projects across
machines.

## Updates and other machines

You do not need to maintain a second command-history file by hand. Each machine
records its own new commands through Atuin. Toolbox sees them on its next use.
Automatic Atuin cloud synchronization is disabled in this setup.

For software updates, `newdev` updates Homebrew packages and eligible ordinary
clones directly under `~/dev`. Linked worktrees are not included in its repository
scan. It skips repositories with conditions such as tracked changes,
detached HEAD, or an unavailable upstream. It does not switch branches, merge
branches, rebuild the native apps, reload your existing shell, or
create a catalog review queue. Check its output for skipped updates.

On each machine where you want these features:

1. Update the checkout to the latest `main`.
2. Use the normal setup workflow to install missing dependencies and select
   Personal or the appropriate Work scope. `./setup.sh --check` is read-only;
   `./setup.sh --fix --dry-run` previews repairs; `./setup.sh --fix` applies them
   after its interactive confirmation. Use `--personal` for a Personal machine.
3. Open a new shell or run `source_zsh` after updating functions.
4. On macOS, use `agent-control-center --install` and/or
   `hardware-planner --install` when their installed builds need updating.

Functions and tracked Personal recipes travel with Git. Old raw history,
one-time helper-name imports, local Work recipes, project memory, and hardware
projects do not. A fresh machine can discover functions in Toolbox immediately
after loading them; Atuin learns their invocations as you use them. Old history
requires an explicit import into the intended scope. Never automatically treat
a mixed legacy history file as Personal history.

## If something seems missing

| Symptom | First thing to check |
| --- | --- |
| A new function is unknown | Run `source_zsh`; confirm the checkout is on the latest `main` |
| No work helpers on a Personal machine | Expected: they require the matching configured Work scope and overlay |
| Ctrl+R resizes a Zellij pane | Press Ctrl+G for Locked mode, then Ctrl+R |
| Old history is absent on a second machine | History is local; Git did not transfer it |
| Toolbox lists commands but the picker fails | Check that `fzf` is installed; rendering also needs Python 3 |
| Atuin is disabled | Check `SETUP_ATUIN_ENABLED`, `atuin --version`, and the active destination; an existing unmarked scoped config is preserved rather than overwritten |
| Project memory search is empty | Select the correct project/scope and explicitly start an indexing action or import |
| An old citation cannot open | Its source may have moved, changed, or disappeared; inspect coverage and rebuild its index |
| A coordinator/task outcome is unknown | Reconcile before creating replacement work |
| Compatibility is Unknown | Supply the missing exact specifications and suitable evidence shown by the findings |
| A hardware report differs from the current assembly | It is a snapshot; export a fresh report from the selected revision |
| An app still has the old interface | Check its `--status`, then rebuild with `--install` from the intended checkout |

Setting `SETUP_ATUIN_ENABLED=false` before reloading disables Atuin recording and
its Ctrl+R integration. It does not erase history; Toolbox can still read the
existing scoped databases. Set it back to `true` and reload to resume recording.

For deeper details, see the [repository setup guide](../README.md),
[Toolbox catalog reference](../dotfiles/toolbox/README.md),
[Agent Control Center reference](../apps/agent-control-center/README.md), and
[Hardware Planner reference](../apps/hardware-planner/README.md).
