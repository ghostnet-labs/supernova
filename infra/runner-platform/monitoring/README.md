# Unified runner monitoring

`dashboard.json` is a Grafana dashboard ConfigMap and `alerts.json` is a
PrometheusRule. The platform installs both with kube-prometheus-stack. Open the
**Local CI Fleet** dashboard after `platform.py dashboard` starts the local forward.
Every absent series displays **No data**. Check scrape inventory and collector
health before interpreting runner availability.

## Coverage and endpoints

| Layer | Collection | Evidence |
|---|---|---|
| macOS physical host | Official Prometheus node_exporter, port 9100 | CPU counters, memory states, filesystem space, disk operations/bytes, interface bytes |
| Legacy Linux VM | Official node_exporter inside each VM | Same Linux node metrics; each VM is its own instance |
| Kubernetes VM | Chart node_exporter DaemonSet | Node CPU, RAM, filesystem, disk I/O, network |
| Kubernetes workloads | kubelet/cAdvisor and kube-state-metrics | Container CPU/memory, readiness, pending pods, restarts, recent OOM evidence |
| ARC | Controller and listener native `/metrics` | Desired/min/max/registered/busy/idle capacity, startup/execution histograms, job results |
| Conventional runners | `metrics.py --mode github --organization ORG`, port 9108 | Registered runner count, online and busy status per runner |
| Repository builds | Same collector with repeatable `--repository OWNER/REPO` | Active workflow runs, actual active job statuses, recent duration/outcomes/start delay |

ARC gauges are separate queries. PromQL `desired or busy or idle` would discard
same-label series because `or` is a set union, so it cannot display all three.
Organization runner registration and ARC scale-set capacity are separate views;
do not sum them as a deduplicated fleet count.

## Native host collection

Use the official node_exporter Darwin build on Apple Silicon. CPU, diskstats,
filesystem, meminfo and netdev collectors support Darwin. A native exporter reads
the Mac rather than a container's Linux VM. A foreground example is:

```sh
node_exporter --web.listen-address=127.0.0.1:9100
python3 infra/runner-platform/metrics.py --mode github \
  --organization acme --repository acme/project --use-gh-auth \
  --listen 127.0.0.1 --port 9108
```

The host-services installer writes user LaunchAgents with explicit loopback
bindings. Avoid a default service configuration that binds every interface.
Lima documents host loopback access at `host.lima.internal` (normally
`192.168.5.2`) on its default user-mode network. The installer must verify a TCP
fetch from the actual guest before configuring either address. Kubernetes pods
may not resolve the special host name, so use the verified address in scrape
configuration. A failure is a deployment blocker, not a reason to expose ports
on the LAN. Custom Lima networks require their own verified route.

Each configured `host_exporters` entry is a distinct static target:

```json
[
  {"name":"mac-studio-node","address":"192.168.5.2:9100","os":"darwin"},
  {"name":"actions-metrics","address":"192.168.5.2:9108","os":"darwin"}
]
```

A legacy VM exporter needs a stable, reachable private guest address or an
explicit loopback forwarding port. The same `192.168.5.15` guest address can be
reused by isolated Lima networks and must not identify multiple VMs. Do not add
scrape targets until reachability is verified. Stopped/deferred machines remain
outside active monitoring coverage until configured and validated.

`metrics.py --mode host` remains a compatibility fallback. Its `ps` sum is a
process CPU estimate, its free-page count excludes reclaimable memory, and it
has no disk I/O or network counters. The dashboard labels those limitations;
this fallback does not satisfy full host monitoring.

## Authentication and sampling

`--use-gh-auth` explicitly uses the current user's existing `gh` login. It never
prints the token or includes it in a command argument, dashboard, log or metric.
The token is refreshed through `gh auth token` for each API request, so normal
credential rotation remains effective. A LaunchAgent needs the same user's
Keychain access and a PATH containing `gh`.

For unattended use, prefer a dedicated read-only fine-grained token supplied via
`--token-file /absolute/private/path` (owned by the service user, mode 0600).
Select only the required repositories with **Actions: read**. Conventional org
runner inventory additionally needs **Self-hosted runners: read** at organization
level. The ARC installation's runner write credential is not required for this
collector. A GitHub App installation token with those read permissions is also
accepted; a separate token refresher must rotate the file before expiry.
`--anonymous` supports public repository-only queries at GitHub's lower rate
limit and cannot read organization runners. No new broad classic PAT is needed.

The default interval is 120 seconds. Current run status and job endpoints are
paginated with a safety limit (`--max-pages`, default 10). Reaching that limit or
any API failure makes collection unhealthy and removes stale measurement data;
`ci_metrics_collection_success` and last-success age remain visible. Completed
job lists are cached by run ID and attempt, and pruned to the recent window.
At rest each repository costs six list requests per interval, plus uncached
completed runs, active runs' job pages, and org runner pages. Raise the interval
or reduce configured repositories if the credential's API budget is tight.

| Metric family | Meaning | Correct interpretation |
|---|---|---|
| `ci_actions_runs` | Current workflow runs by status | Workflow count, not job count |
| `ci_actions_active_jobs` | Current jobs in active runs by status | Polling snapshot; quick jobs can be missed |
| `ci_actions_recent_completed_runs` | Latest N completed runs, default 20 per repository | Rolling gauge sample; never `rate`/`increase` |
| `ci_actions_recent_job_duration_seconds_sum/count` | Jobs in that sample, latest attempt | Ratio gives execution mean; includes failures/cancellations with timestamps |
| `ci_actions_recent_run_start_delay_seconds_sum/count` | Creation to first job start for original attempts | Scheduling proxy; **not per-job queue time**, excludes retries |
| `gha_job_startup_duration_seconds` | ARC job startup histogram | ARC-owned job startup p95 via histogram_quantile |
| `gha_completed_jobs_total` | ARC listener completion counter | Counter resets on listener restart; use increase/rate |

Workflow labels use stable numeric workflow IDs to keep cardinality bounded.
GitHub REST job responses do not document job creation times, so a run creation
timestamp must not be presented as exact queue delay for each dependent job.
No completion samples yield No data, not a fabricated success rate. A rolling
sample is not a historical hourly build success/failure rate; ARC counters show
observed rates only for ARC jobs. Longer fleet-wide history requires a webhook
collector or durable job-event store beyond this read-only polling collector.

Linux `MemAvailable` and Darwin free pages have different semantics and appear
in separate panels. Disk and network panels preserve device/interface labels:
APFS containers or virtual interfaces can mirror physical activity, so summing
all devices can double-count traffic. OOM evidence combines the last reason
with recent restart increments; an ephemeral pod deleted between scrapes can
escape Kubernetes sampling, while its workflow outcome remains in GitHub.

## Resource budget and acceptance

Reserve approximately 128 MiB host RAM for both exporter processes together;
this is planning headroom, not a measurement or an enforced macOS limit. Start
with 30-60 second node scrapes and 120 second GitHub polling. Prometheus, Grafana,
operator, state metrics and node exporter resources are declared by the selected
platform monitoring profile. Check live memory after enabling all targets;
retention and cardinality determine actual Prometheus usage.

Acceptance requires each configured target up, successful host collectors,
fresh GitHub collection, ARC listener samples, node metrics and cAdvisor/state
metrics. Use dashboard health panels plus `platform.py verify-monitoring`.
An unconfigured Pro, legacy VM or repository is a coverage gap, not healthy.
Alerts currently enter local Alertmanager; configure a real receiver separately
if off-machine notifications are required.

## Primary references

- [ARC metrics and configuration](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets#enabling-metrics)
- [ARC0.15 metric definitions](https://github.com/actions/actions-runner-controller/blob/gha-runner-scale-set-0.15.0/charts/gha-runner-scale-set/values.yaml)
- [Official node_exporter collector/platform support](https://github.com/prometheus/node_exporter#enabled-by-default)
- [Darwin memory field definitions](https://github.com/prometheus/node_exporter/blob/v1.12.1/collector/meminfo_darwin.go)
- [Common disk counter definitions](https://github.com/prometheus/node_exporter/blob/v1.12.1/collector/diskstats_common.go)
- [GitHub workflow jobs API and read permissions](https://docs.github.com/en/rest/actions/workflow-jobs)
- [GitHub workflow run status filters](https://docs.github.com/en/rest/actions/workflow-runs)
- [Organization runner API permissions](https://docs.github.com/en/rest/actions/self-hosted-runners#list-self-hosted-runners-for-an-organization)
- [Lima host loopback addressing](https://lima-vm.io/docs/config/network/user/)
