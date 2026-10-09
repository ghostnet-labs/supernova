# Toolbox command catalogs

Catalogs are optional saved commands. Toolbox already searches every distinct
command in the enabled local Atuin databases alongside loaded helpers and usable
managed executables. Common history patterns have named functions with normal
positional arguments; no catalog review or environment placeholders are needed.
Saved entries remain available with names such as `catalog:personal:0123456789ab`.

`toolbox --pick` searches everything. `toolbox --json history:` selects history
entries only. Personal shells never open Work history; Work shells include
Personal plus the active job. Reading history does not modify it, copy it into
Git, or execute commands. A missing history database contributes no entries.
Malformed databases produce a visible error. Records with invalid text, NUL
bytes, or commands exceeding 1 MiB are omitted with an explicit count.

## Save and find a command

Quote command text so your shell passes it literally. Never paste a credential
into a command intended for the catalog.

```zsh
toolbox --save 'git log -5 --oneline' --description 'Review recent commits' --tag git
toolbox --pick 'recent commits'
toolbox --json catalog:
```

`--save` chooses the active shell's scope. Add `--scope personal` in a Work shell
to save a reviewed Personal command. `--scope work-JOB` is allowed only for the
currently enabled Work job. Discovery does not source another job's environment.

The picker previews the description, source, and exact command. Enter inserts
the selection into the editable prompt; it never executes it. Multiline commands
and trailing newlines are preserved. Review paths, arguments, and required tools
before running a saved command on a different machine. To inspect a complete
entry, use its name from the listing with `toolbox --describe NAME`.

## Collect and review history

```zsh
toolbox --collect-history --limit 200
toolbox --pending
toolbox --review
```

The collector reads only the chosen scope's local Atuin database and places a
bounded batch in that scope's private review queue. It deduplicates exact command
text within a scope; whitespace, quoting, and argument changes remain distinct.
Collection checkpoints and rejected entries prevent repeated suggestions.
Collection never runs command text or adds raw history to Git.

Collection is optional when deliberately curating a saved catalog. It is not
needed for Toolbox history search, which reads Atuin directly on every use.
`newdev` does not collect candidates or create a review backlog. Explicit
collection runs advance through a large archive in bounded batches.

`--review` requires an interactive terminal. The noninteractive operations also
work individually:

```zsh
toolbox --pending --json
toolbox --accept ID --description 'Inspect repository changes' --tag git
toolbox --accept ID --command 'git diff --stat' --description 'Summarize changes'
toolbox --reject ID
```

Acceptance requires a useful description. Edit machine-specific paths or values
before accepting. An imported archive can contain both Personal and Work
commands even when stored in `work-JOB`: the label cannot classify its contents.
Keep Work entries in the Work catalog. To promote a reviewed Personal command
from a mixed Work queue, save the edited text using `--scope personal`, then
reject the original Work candidate if it is no longer useful there.

## Secret screening and Git

Save and accept scan the command, description, and tags before writing a catalog.
Built-in screening blocks suspicious credential forms, private keys, and secret
assignments. Gitleaks supplies a second scan and must be installed and working;
missing scanners, scanner errors, or detected secrets fail closed. Error messages
identify the problem without printing the matching secret. Edit blocked content
and retry; there is no force-save bypass.

Screening reduces accidental disclosure; it does not establish whether company
data or a private hostname belongs in a Personal repository. Review that scope
decision yourself. No collector, save, accept, or review command stages, commits,
or pushes Git changes. Scan the full intended changes before staging. The setup
repository's pre-commit hook also runs Gitleaks on staged changes when its hooks
are enabled.

## Files and scopes

| File | Contents | Git behavior |
| --- | --- | --- |
| `dotfiles/toolbox/personal.jsonl` | Accepted Personal commands | Tracked in the setup repo |
| `~/.config/toolbox/config.json` | Optional catalog-location settings | Local; outside the repo |
| `~/.local/share/toolbox/personal/state.sqlite3` | Personal queue, rejections, and checkpoints | Local; outside the repo |
| `~/.local/share/toolbox/work-JOB/state.sqlite3` | Active job's queue, rejections, and checkpoints | Local; outside the repo |
| `~/.local/share/toolbox/work-JOB/catalog.jsonl` | Accepted Work commands | Local by default |

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` replace the defaults above. Each scope uses
its own queue and exact-text deduplication. Personal shells search the Personal
catalog; enabled Work shells search Personal plus their active job's catalog.
The tracked `.gitignore` also excludes toolbox config, state database sidecars,
and Work folders if those local files are accidentally placed beneath
`dotfiles/toolbox/`.

To share a Work catalog later, use an appropriate separate Work repository and
configure its absolute path in `~/.config/toolbox/config.json`:

```json
{"catalogs":{"work-acme":"/absolute/path/to/work-repository/catalog.jsonl"}}
```

Omitted scopes keep their default paths. Work catalog paths and local state must
remain outside the setup repository. Keeping Personal and Work in different files inside
one repository would still distribute both to every clone. Sharing the setup
repo distributes only its accepted Personal catalog; it does not synchronize
Atuin history or local review decisions.

## Record format

Each UTF-8 JSON line contains `id`, `scope`, `command`, `description`, and `tags`.
`id` is the hexadecimal SHA-256 of `scope`, a NUL separator, and the exact command
text. Commands remain data throughout collection, review, listing, and selection.
Descriptions and tags support search. Execution timestamps, counts, and raw
history stay out of the catalog.

Use the CLI to write optional catalog records so scope checks, validation, and
secret screening run before the write. The initial generic examples remain;
the generated history templates have been replaced by named helpers and direct
history search. Existing user-saved entries are preserved.
