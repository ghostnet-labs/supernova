# Pro macOS runner

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
1. Install Xcode/Command Line Tools and the workflow's Homebrew dependencies.
2. Obtain a short-lived GitHub registration token at the intended scope.
3. Set RUNNER_SHA256 to the official osx-arm64 release asset digest.
4. Run guest-runner.sh with the organization/repository URL and a distinct name.
5. Route canaries to [self-hosted, macOS, ARM64, macos-vm].
6. Run representative Swift/test/build workflows before routing required jobs.

Keep the host plugged in and awake while jobs are accepted. Stop new
assignments and wait for current jobs before sleep/travel. Retain the old
macOS route until the guest passes acceptance. ARC cannot host macOS pods.

