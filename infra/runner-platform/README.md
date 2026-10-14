# Local runner platform

A staged ARM64 CI cluster for a 32 GB Apple Silicon host, with conventional
macOS builds in a separate VM. This directory is independent of the dotfile
repair entry point. It does not alter current workflow routing.

## Start safely

Prerequisites: Lima 2.2.1+, kubectl, Helm, Python 3, a working personal GitHub
CLI login, and enough RAM/disk headroom. Use an ordinary host terminal;
restricted execution sessions cannot start or inspect these VMs reliably.
The kubectl client must be within one minor version of the selected K3s
Kubernetes version; startup refuses an incompatible client. Install current
host tools with Homebrew and verify which kubectl is first on PATH.

1. Run `python3 infra/runner-platform/platform.py init`.
2. Edit `.local/config.json`: set `expected_github_login`, `github_url`,
   optional restricted `runner_group`, and scale-set names.
3. Run `python3 infra/runner-platform/platform.py inventory-host`, then
   `python3 infra/runner-platform/platform.py inventory`.
   The private output includes every organization's/repository's registration
   and workflow files across all branches. Map each registration to its VM
   and service before deciding to stop it.
4. Run `python3 infra/runner-platform/platform.py preflight --profile pilot`.
   Unknown/Broken VM states are blockers, not idle capacity. Drain and stop
   redundant old workloads, preserving at least one working rollback route.
5. Run `python3 infra/runner-platform/platform.py render --profile pilot`.
   JSON documents are valid YAML and have a .yaml extension for Lima/Helm.
   Review the generated values, then run `start --profile pilot`.

The pilot uses 4 vCPU/6 GiB and local-path storage, no host mounts or SSH agent
forwarding, encrypted Kubernetes Secrets, and a loopback-only API forward
on port 16443. It never deletes or stops old VMs automatically.
The dedicated kubeconfig stays private and does not overwrite the user's
existing kubeconfig. Host system sleep must be disabled.

## Runner image and ARC

The runner-image workflow builds, smoke-tests and publishes the ARM64 image
on relevant main-branch changes or manual dispatch. Pull requests build and
smoke-test without publishing. Its digest artifact is the immutable reference
to put in the private configuration. Alternatively, build/push using a trusted
builder with registry access. Verify the image manifest has ARM64 support
and set `runner_image` to its immutable digest (`image@sha256:...`).
The official runner base and yq tool are version pinned. Review/rebuild
regularly for runner updates; the Dockerfile is a general Linux CI base,
not a firmware SDK.

For a private GHCR image, configure `image_pull_secret` and supply a private
mode-0600 token file with read-packages access using
`registry-secret --username ACCOUNT --token-file /PRIVATE/registry-token`.
ARC deployment checks that the secret exists, and runner pods reference it.
The workflow's short-lived GITHUB_TOKEN cannot be reused for cluster pulls.
For an already-public image, set image_pull_secret to an empty string;
this tooling does not change package visibility.

Create an organization-owned ARC GitHub App with Self-hosted runners
read/write and Metadata read. Repository Administration read/write is only
needed for repository-scoped registration. Restrict authorized repositories
through the runner group where available. ARC App credentials are distinct
from an assistant's GitHub connector identity.

Put App credentials in a mode-0600 JSON file with the keys
`github_app_id`, `github_app_installation_id` and `github_app_private_key`.
Deploy with:
`python3 infra/runner-platform/platform.py deploy-arc --profile pilot --app-file /PRIVATE/app.json`.

Private key/password data go to Kubernetes through stdin; they are not
printed or included in argv. Keep the credential file outside git and
back it up encrypted. Host/cluster admin access can still read Secrets.

Copy `examples/canary.yml` to the chosen repository on a review branch.
Dispatch it against the exact scale-set name; test success, intentional
failure and cancellation. Verify success and pod cleanup with
`verify-canary --repository OWNER/REPO --run-id ID`.
Plain shell jobs are supported initially. Container/service jobs, Docker
builds and firmware jobs stay on their existing route until tested with an
appropriate isolated container-mode setup and dependency image.

## Grow and monitor

Drain the pilot, stop/back up the VM and resize its CPU/RAM/disk explicitly
with the installed Lima version's supported operations. Never recreate the
disk to resize it. The `start --profile full` command verifies that the
actual allocation matches the 8 vCPU/20 GiB/100 GiB profile before deployment.
The host must retain its reserve; existing VMs may have to be stopped first.

Run `monitor --profile full` for pinned kube-prometheus-stack, private Grafana,
20 GiB Prometheus and 2 GiB Grafana PVCs, dashboard and alert rules.
Use `dashboard` to forward Grafana to http://127.0.0.1:3000.
Read the admin-password from the monitoring/grafana-admin Secret privately;
it is generated once and preserved on reruns. Alert rules initially appear
in Grafana/Alertmanager; notification delivery needs an explicit destination.

ARC metrics are scraped from controller/listener ports. GitHub-wide metrics
and Mac host metrics need separate collection:
- On each Mac, run `metrics.py --mode host` bound to a private VPN address.
  It provides CPU-process usage, memory pages and disk capacity. It does not
  provide disk I/O or network throughput; use a verified Darwin exporter
  for those additional metrics.
- For GitHub metrics, run `metrics.py --mode github --listen PRIVATE_IP
  --token-file /PRIVATE/token --repository OWNER/REPO`.
  Use read-only Actions permission for selected repositories. It provides
  active/queued run counts and a bounded sample of completed job duration
  and outcomes, not lifetime counters.
- Add each address to private config `host_exporters` with `name` and
  `address`. Use an `os` field of `darwin` or `linux`.
  Prometheus needs private reachability to these endpoints.
- Collection success/timestamp metrics indicate API or host collection errors.

Monitoring does not retain runner logs itself. Forward ephemeral pod logs
to an external log sink before full cutover; Kubernetes log rotation alone
does not preserve deleted pod logs. Keep this as an explicit acceptance
blocker until configured. An external uptime check is also needed to
detect loss of the entire Studio.

## Pro and Air

See `macos/README.md` for the 12 GiB macOS guest and conventional ARM64
runner. The Pro remains optional to the Linux cluster; required macOS jobs
need a fallback when it is asleep. An optional 8 GiB Linux-worker profile
is a later change with private inter-node connectivity and drain testing,
not an automatic addition to the baseline.

On the Air, install SSH/kubectl/k9s/Helm and a private VPN. Start with
authenticated SSH tunnels to the Studio's loopback API/dashboard; keep
ports unexposed on the public network. Copy the required CA/client config
privately, or provision a least-privilege identity. The generated kubeconfig
is an administrator credential, not suitable for broad distribution.

## Cutover and retirement

Keep required job names stable. Change Linux `runs-on` only after canary
and representative real tests pass. Replace hand-installed VM dependencies
and OS-specific downloads/paths in the workflow or image. Review
`pull_request_target` and untrusted PR execution separately.

Observe real CI for 48 hours, including offline-Pro/restart tests. Then,
for each exact runner ID and scope in the ledger:
1. Route jobs away; stop new assignments and wait for active jobs.
2. Stop/disable its local service and restart automation.
3. Unregister using config.sh with a fresh removal token, or delete the exact
   offline registration at its proper GitHub scope.
4. Confirm it does not reconnect and no queued jobs need its labels.
5. Retain the stopped VM for seven days before deleting its disk.

No bulk runner deletion or VM destruction is automated. Preserve the
working native macOS and any hardware/x86-only routes until separately
validated. Back up K3s datastore/config/token, encrypted credentials and
persistent dashboard configuration off-host, and perform a restore test.

## Validation

Run `python3 tests/infra/test_runner_platform.py` and the repository's
`./setup.sh --test`. Tests stub external commands and prove capacity
refusals, profile isolation, credential handling, inventory pagination,
monitoring caps, canary identity checks and local-only access.
They do not claim a VM, runner image, Helm release or real workflow has
been deployed. Live canaries, native builds, logs, backups, reboot and
remote-access checks remain required.

