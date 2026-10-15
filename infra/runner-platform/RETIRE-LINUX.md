# Retire the legacy Linux VM

The Studio helper retires only `gh-ubuntu`, its five `studio-ubuntu-1` through
`studio-ubuntu-5` JIT slots, and `com.ghostnet.lima-gh-ubuntu`. It preserves the
VM disk, configuration, LaunchAgent files and recovery evidence.

Run from the normal macOS host terminal after the three lifecycle cleanup
checks, the full Linux suite on ARC, and monitoring verification succeed:

```bash
python3 "$runner_platform/retire-linux.py" plan \
  --repository ghostnet-labs/supernova --validation-run RUN_ID
python3 "$runner_platform/retire-linux.py" retire \
  --repository ghostnet-labs/supernova --validation-run RUN_ID
```

`plan` performs live checks without changing services or VMs. The inventory
examines every organization repository branch and every open pull request head,
including forks, with workflow definitions reachable by manual dispatch. Existing historical tags are
not treated as active jobs. Reusable workflows and dynamic runner expressions
without a proven closed choice set block retirement and name their exact
repository, branch and path. Static routes matching any retiring runner's
labels also block retirement. An old registration name is never assumed to
be a working label route.

The audit resolves a bounded subset of Actions expressions, literal matrices,
closed dispatch choices, and local reusable workflows at the caller's exact
commit. SHA-pinned external reusable workflows are fetched and inspected.
Unknown conditions retain every possible route; unsupported routing values,
mutable external references, cycles, and excessive expansion remain blockers.
Repeated mutable-reference errors are summarized with reference counts.

Changing the default branch alone does not migrate retained dispatchable
branches or open PR heads. A closed PR does not make its retained workflow
unreachable. Keep the old VM until those routes have a documented migration
or archival disposition; do not delete branches just to clear the audit.
Before selecting ARC, validate each job's dependencies and memory needs against
the runner image and profile. A safely parsed route is not evidence that its
workload will run successfully on the replacement.

`retire` writes and syncs `.local/linux-retirement.json` with mode `0600`
before pausing any process. It validates the exact host process and guest
executable paths, freezes all five listeners, rechecks GitHub queues and busy
flags plus guest workers, then disables and unloads only the six named agents.
It verifies listeners have exited and workers are absent before stopping the
VM. Any failed check resumes the inspected slots and restores their services;
an interrupted recovery retains the record for inspection. Successful repeated
runs do nothing when the VM remains stopped and those agents remain unloaded.

Restore the old slots with:

```bash
python3 "$runner_platform/retire-linux.py" rollback
```

Rollback preserves at least 8 GiB for the host. When necessary, it first drains
and stops `ci-macos` only if the matching managed creation record proves it is
the new 6 GiB, 2 CPU, 80 GiB guest and all workers and queues are idle. An
unowned guest or insufficient remaining capacity blocks restart. No unrelated
service is reloaded and no disk is deleted. Inspect GitHub after rollback to
confirm the replacement JIT registrations are online.
