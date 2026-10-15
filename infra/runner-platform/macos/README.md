# Pro macOS runner

For the active Studio migration, use [MIGRATION.md](MIGRATION.md) and the
read-only `preflight.py report` / `preflight.py render --output PATH` commands.
`host-runner.py start` checks capacity twice before creating a new guest.
`host-runner.py run-one --organization OWNER --expected-login LOGIN` verifies
guest isolation and tools, verifies the official runner checksum and runs one
JIT canary. It mints the JIT configuration on the host and passes it through
stdin; it never copies host GitHub credentials or keys to the guest.
The Pro work below remains deferred by the user.

Run the baseline macOS VM with 12 GiB RAM and 4 vCPU. First inspect the
Pro chip, host OS, disk and existing workloads. Keep at least 12 GB for the
host in this baseline. Do not also allocate an 8 GiB Linux worker unless
the operating profile is changed.

Use a maintained macOS virtualization tool after checking its current
license and guest compatibility. With Tart, the host operations are:
clone a verified pinned macOS image to a new named VM, set CPU/memory,
and start it without host-home or host-credential sharing. Image cloning
is deliberately not automated before those inputs are verified.

Inside the guest:
0. Provision the root-owned `/etc/ci-runner-vm` marker through the reviewed
   Lima configuration. `guest-runner.sh` refuses an unmarked guest or host.
1. Install Xcode/Command Line Tools and the workflow's Homebrew dependencies.
2. Obtain a short-lived GitHub registration token at the intended scope.
3. Set RUNNER_SHA256 to the official osx-arm64 release asset digest.
4. Run guest-runner.sh with the organization/repository URL and a distinct name.
5. Route canaries to macos-vm, then check guest OS and architecture inside the
   job. Generic self-hosted/macOS/ARM64 labels are omitted during validation.
6. Run representative Swift/test/build workflows before routing required jobs.

The fallback guest installer registers an ephemeral runner and runs one job in
the foreground. Both paths clean work and runner registration files on exit.
They do not implement VM recycling, which must be separately accepted before
using a reused guest for untrusted pull requests.
The registration token is read without echo and supplied to runner configuration
through its environment, never as a command-line argument.

Keep the host plugged in and awake while jobs are accepted. Stop new
assignments and wait for current jobs before sleep/travel. Retain the old
macOS route until the guest passes acceptance. ARC cannot host macOS pods.

