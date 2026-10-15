# Guarded pilot completion

Run this in the macOS host terminal after the success, intentional-failure and
running-job-cancellation canaries have passed cleanup verification:

```console
python3 "$runner_platform/rollout.py" run --repository OWNER/REPO --validation-run RUN_ID
```

Use a successful representative workflow run that executed on the configured
ARC scale set. The command checks the saved lifecycle evidence, verifies the real
run through GitHub, inventories all organization repositories for queued/running/
waiting workflows, checks every running Lima guest and the host for
`Runner.Worker`, and records live ARC runner pods. Inspection errors stop the
command before installation. API inventory includes pending/requested states.
The Kubernetes stack can install during builds because it changes no VM or
runner routes. Initial legacy VM exporter installation waits for guest workers
to finish before downloading packages or starting its managed service.
Retirement requires a separate idle guard immediately before draining.

It installs official Homebrew `node_exporter` if missing and two owned user
LaunchAgents for host and GitHub Actions metrics. Both bind only `127.0.0.1`.
The collector uses existing `gh` authentication without copying a token. It
proves the listener bindings and scrapes both endpoints from the actual Lima
guest at `192.168.5.2`, then records those verified Prometheus targets in config.
Running legacy Ubuntu VMs receive separate loopback-only exporters with unique
forwarded ports. Their package payload is verified through signed Ubuntu apt
metadata and extracted without running package installation hooks; an unrelated
exporter service is never replaced. Guest identity and private forwarding must
verify before targets are added. Stopped VMs are excluded from active targets.
It then installs the bounded monitoring profile through `platform.py monitor`.
The monitoring installer uses an atomic Helm upgrade, waits for readiness and
verifies Prometheus targets and the Grafana API. Rerunning reconciles the same
release. It preserves VM allocations, existing VM disks, runner routes, JIT
services and credentials. It never restores the stopped builder automatically:
doing so while the pilot is running could exceed host RAM headroom.

Results are private JSON files beside the selected config:

| File | Meaning |
|---|---|
| `rollout-inventory.json` | Live VM, runner, queue and worker observations |
| `rollout-progress.json` | Installation phase, verification and remaining gates |
| `host-services-evidence.json` | Private binds, successful collection and guest reachability |

Exit `2` means supported pilot monitoring completed and further migration has
explicit gates. Exit `1` means a guard, inspection or install failed; inspect the
error, resolve it and retry. Exit `0` is used for `status`. These codes deliberately
prevent automation from treating monitoring installation as full migration.

```console
python3 "$runner_platform/rollout.py" status
```

Do not use `pilot.py rollback` as monitoring rollback. That command exchanges the
pilot VM for the old builder and is a separate guarded infrastructure operation.
If an atomic monitoring upgrade fails, inspect Helm status/history and retained
PVCs before retrying; preserve ARC and all old runner services. This command does
not uninstall releases or delete data on failure.

For host-only installation or inspection:

```console
python3 "$runner_platform/host-services.py" --install --repository OWNER/REPO
python3 "$runner_platform/host-services.py" --verify
```

The installer refuses unrelated or modified LaunchAgents and occupied ports.
It pins resolved executable paths and a hash-named private copy of the collector,
preserves previous definitions if a service upgrade cannot bootstrap, and uses
the standard Homebrew formula instead of an arbitrary exporter found on PATH.
[Lima's default user network](https://lima-vm.io/docs/config/network/user/)
exposes Mac loopback at `192.168.5.2`; the additional `vzNAT` NIC retains that
default network in installed Lima 2.2.1. Runtime probes and actual Prometheus
target health remain required. Other local Lima guests can also reach host
loopback; these bindings keep exporters off the LAN.

After monitoring passes, rollout installs a third owned LaunchAgent that keeps
Grafana available at `http://127.0.0.1:3000`. It verifies the unauthenticated
health endpoint and private bind. An unrelated listener on port 3000 stops this
step without terminating it. The Grafana admin credential stays in its existing
Kubernetes secret and is never written into the forwarding service.

Use an existing trusted SSH connection for remote access:

```console
ssh -N -L 3000:127.0.0.1:3000 USER@TRUSTED_HOST
```

Open `http://127.0.0.1:3000` on the connecting computer. This does not require
publishing Grafana or enabling a public tunnel. It assumes SSH access to the
Studio is already configured.

## Remaining migration gates

| Workload | Required acceptance before retiring its old route |
|---|---|
| Legacy Linux | Inventory every repository/ref route, migrate it, then freeze each JIT listener and recheck queues/workers before draining |
| Firmware | Retain the existing isolated VM and monitor it; require build evidence before any optional replacement |
| Native macOS | Provision an isolated macOS VM, install Xcode/dependencies, pass Swift/build and lifecycle tests, then drain host registrations |
| Pro | Remains deferred until explicitly resumed; inspect its capacity first |

The Studio's 32 GiB cannot simultaneously provide an 8 GiB host reserve, both
remaining legacy VMs (9 + 6 GiB), a 20 GiB full Kubernetes VM and a macOS guest.
Keep the 6 GiB pilot while gathering representative workload evidence. Expanding
requires retiring validated old allocations first; the stopped second-builder
disk remains a rollback asset, not an invitation to start it alongside the pilot.

## macOS feasibility

Read-only inspection on the Studio found Lima 2.2.1 and no Tart/Parallels/UTM CLI.
[Lima supports macOS guests experimentally from 2.1](https://lima-vm.io/docs/usage/guests/macos/),
on ARM hosts running an OS at least as new as the guest. Automatic port forwarding
and containerd are unavailable for macOS guests. The first-login suppression
feature documented for Lima 2.3 must not be assumed available in 2.2.1.
[Apple's Virtualization framework supports macOS guests on Apple silicon](https://developer.apple.com/documentation/virtualization/virtualize-macos-on-a-mac).
These facts establish feasibility; they do not establish a provisioned, tested
replacement or capacity for ten concurrent native runner jobs. Select and verify
the guest image, host/guest OS compatibility, isolation and allocation before
creating it. ARC runs Linux pods and does not turn a macOS runner into a pod.
Use [the macOS migration checklist](macos/MIGRATION.md) for the pinned image,
read-only capacity preflight and representative-workload gates.
