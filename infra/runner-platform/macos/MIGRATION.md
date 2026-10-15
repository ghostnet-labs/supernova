# Move the Studio macOS runners into a guest

The Studio has a supported local virtualization path: Lima 2.2.1 is installed,
its macOS 27.0.1 restore image matches the observed host 27.0.1, and its ARM64
macOS templates require Lima 2.1 or later. Lima documents macOS support as
experimental. Tart is not installed and is not required for this path.

This is a provisioning plan, not evidence of a booted or accepted macOS runner.
The ten native Studio runners remain the rollback route. The Pro remains
deferred by the user; the earlier Pro sizing note is not a Studio allocation.

## Capacity sequence

Use allocated VM memory rather than current guest usage. Retain at least 8 GiB
for macOS and its applications. Recheck actual memory pressure during builds;
the reserve is an allocation rule, not a measured performance guarantee.

| Stage | ci-k3s | Firmware VM | Legacy Linux VM | New macOS VM | Total VM RAM | Host remainder |
|---|---:|---:|---:|---:|---:|---:|
| Validated pilot | 6 GiB | 9 GiB | 6 GiB | 0 | 21 GiB | 11 GiB |
| macOS cannot yet be added | 6 GiB | 9 GiB | 6 GiB | 6 GiB | 27 GiB | 5 GiB |
| After all legacy Linux routes migrate and drain | 6 GiB | 9 GiB | 0 | 6 GiB | 21 GiB | 11 GiB |
| Full cluster with one macOS guest, firmware retired | 20 GiB | 0 | 0 | 6 GiB | 26 GiB | 6 GiB |

The 20 GiB cluster and a 6 GiB macOS guest cannot run together while preserving
the 8 GiB reserve on this 32 GiB host. Keep the compact cluster profile, or
measure and adopt a smaller explicitly budgeted full profile. Do not retire the
firmware VM merely to create room. The stopped second firmware VM keeps its disk.

Start the guest at 2 vCPU, 6 GiB RAM, and an 80 GiB disk with one runner slot.
At the third stage, 4 + 6 + 2 = 12 configured vCPU matches the Studio's 12 CPU
cores. This is an initial test budget; a successful Swift build with measured
memory, CPU, disk and queue time determines production sizing. Ten native
registration slots do not imply ten guest VMs or ten simultaneous builds.

## Prepare and provision

1. Inventory every organization workflow using the old Linux labels. Validate
   each replacement route. Freeze the five old Linux JIT listeners, then check
   GitHub busy flags, queued jobs and guest `Runner.Worker` processes again before
   stopping that VM. Keep launchd definitions, VM disk and a rollback record.
   A passing single-repository canary does not complete this organization audit.
2. Run the read-only capacity report from the normal host terminal:

   ```bash
   python3 "$runner_platform/macos/preflight.py" report
   python3 "$runner_platform/macos/preflight.py" render \
     --output "$runner_platform/.local/macos-vm.yaml"
   limactl validate "$runner_platform/.local/macos-vm.yaml"
   ```

   Exit 2 means prerequisites or capacity are blocked. Rendering can still create
   an inactive configuration for review, but never starts a VM. The command
   refuses to overwrite files. A sandbox `Broken` inventory is unknown state;
   it must not be counted as a stopped VM. A fresh normal-terminal report must
   return `ready_to_provision: true` immediately before creation.
3. Review the applicable Apple software license. The restore image URL and
   checksum are pinned to the installed Lima 2.2.1 macOS image metadata. The
   generated configuration deliberately omits the stock template's host-home
   mount, disables host SSH key discovery/agent forwarding and proxy environment
   propagation, and provisions a root-owned guest marker. No GitHub App key,
   registry password, personal SSH key or personal host directory enters the VM.
4. When the report passes, create the new guest:

   ```bash
   python3 "$runner_platform/macos/host-runner.py" start
   limactl shell ci-macos -- sw_vers
   limactl shell ci-macos -- uname -m
   limactl shell ci-macos -- cat /etc/ci-runner-vm
   ```

   Keep its display enabled: Lima currently requires the macOS installer display.
   Do not assume the Linux automatic port-forwarding behavior; Lima documents
   that it is unavailable for macOS guests. The generated guest is private and
   uses Lima's SSH connection. Do not expose Remote Login to the LAN.
5. Complete any installer, setup or license screens in the guest. Install the
   Xcode/Command Line Tools version required by the actual Swift targets. The
   operator reviews and accepts Apple's/Xcode's terms when requested; these
   scripts neither accept them silently nor bypass the prompts. Homebrew's
   macOS installer needs guest administrator authorization. Use a dedicated
   guest account, and do not sign in to personal iCloud or copy host credentials.
6. Install the workflow dependencies inside the guest (`git`, `yq`, Python,
   `rich`, `textual` and the repository's Swift toolchain requirements), then
   run `./setup.sh --test` locally in the guest. From the host, run
   `host-runner.py run-one --organization OWNER --expected-login LOGIN`.
   The driver verifies host capacity and guest isolation/tools, downloads the
   runner using the official release asset digest, mints a one-job JIT config
   on the host and sends it into the guest through stdin. It refuses a second
   live runner and never supplies host credentials to the guest. Dispatch the
   scoped macOS canary while the foreground driver waits. Its default one-hour
   timeout is a ceiling for the canary, not a production build duration limit.

## Acceptance before native retirement

Use a separate manually dispatched canary route
`macos-vm`. The canary registration deliberately omits generic
`self-hosted`/`macOS`/`ARM64` labels so existing native routes do not select it.
Audit existing uses of the unique label before starting the listener, and use
a restricted canary runner group when available. Verify the job's runner name and
labels in GitHub, the guest OS/architecture, Swift compilation, representative
app builds, tests and artifact upload/download. A GitHub-hosted `macos-latest`
pass validates repository compatibility only; it does not validate this guest.

Exercise success, intentional failure and cancellation after work starts.
Check registration and work-directory cleanup as well as job conclusion. The
host driver creates one JIT registration, runs one job, removes work and runner
credential files and verifies the guest is idle afterward. It retains a busy
registration when timeout makes cleanup uncertain. The fallback guest installer
also runs one ephemeral job in the foreground. Neither path reimages the guest:
a proven clean-image recycling policy remains a gate before reusing it for
untrusted pull requests. Do not call this gate complete based on the Linux ARC
cleanup tests. Record run URLs, runner identity, measured resources and rollback.

Only then stop new assignments to the native route, wait for all active jobs,
freeze/recheck the selected native listeners and retire one slot at a time.
Retain a tested restore route. Do not bulk-delete native registrations or disks.

## Firmware migration is a separate build contract

The observed firmware default branch is `24.10`. Its reusable
`build-firmware.yml` runs on GitHub-hosted `ubuntu-24.04`, has a four-hour
timeout, installs `gcc-multilib`/`g++-multilib` and many native development
packages, runs `make download`, then a full board build. It also deletes
hosted-image directories and prunes Docker images. Those steps must not be
copied unmodified onto a shared persistent machine. The general ARM64 runner
image and its small ephemeral volume have not been validated for this contract.

The old local firmware slot remains `gh-build`,
`/home/runner/actions-runner`, label `self-hosted,openwrt-build`. The host JIT
loop mints a one-job configuration and launches the guest runner. Preserving
this working builder is safer than assuming the current hosted workflow is a
local-builder test. Check which repository refs actually use `openwrt-build`.

The smallest real replacement proof is one manually dispatched **board build**
(for example `ekh-bcm2711`, target `bcm27xx`, subtarget `bcm2711`) against a pinned
commit, in a dedicated replacement environment with a fresh work directory,
one build at a time and no release/signing secrets. Use a unique canary route;
do not replace all firmware `runs-on` values. Capture the build log, actual
runner/architecture, peak resident memory and disk usage, firmware image and
checksum. Validate the architecture's dependency set before spending hours on
the build: Ubuntu's multilib package list cannot simply be transplanted to an
ARM64 image. A tools check, Docker build, dependency download or green unrelated
package test is insufficient. After the board build and lifecycle/isolation
checks pass, migrate one route and drain the remaining old builder with rollback.

## Primary references

- [Lima macOS guest requirements and caveats](https://lima-vm.io/docs/usage/guests/macos/)
- [Lima 2.2.1 pinned macOS 27 image metadata](https://github.com/lima-vm/lima/blob/v2.2.1/templates/_images/macos-27.yaml)
- [Lima stock macOS template](https://github.com/lima-vm/lima/blob/v2.2.1/templates/macos.yaml)
- [Apple software license agreements](https://www.apple.com/legal/sla/)
- [Apple macOS Tahoe license, section 2B(iii)](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf)
- [Actions runner releases](https://github.com/actions/runner/releases)
- [Firmware's observed build contract](https://github.com/ghostnet-labs/firmware/blob/24.10/.github/workflows/build-firmware.yml)

Apple's published Tahoe terms include up to two additional virtual macOS
instances for specified development/testing uses on qualifying Apple hardware,
subject to the agreement's conditions. Check the agreement applicable to the
installed host/guest and intended usage. This plan requires only one guest;
there is no requirement to buy another machine merely to test it.
