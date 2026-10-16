#!/usr/bin/env python3
"""Provision a bounded local CI cluster and inventory runner migration."""
import argparse
import base64
import contextlib
import datetime as dt
import getpass
import json
import plistlib
import re
import selectors
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
GIB = 1024 ** 3
K3S_UNIT = """[Unit]
Description=K3s CI cluster
Wants=network-online.target
After=network-online.target
[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server
Restart=always
RestartSec=5s
KillMode=process
Delegate=yes
LimitNOFILE=1048576
TasksMax=infinity
[Install]
WantedBy=multi-user.target
"""


class PlatformError(Exception):
    """An unmet prerequisite or unsafe transition."""


def run(args, *, input_text=None, capture=False, timeout=600):
    result = subprocess.run(
        [str(a) for a in args], input=input_text, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        timeout=timeout, check=False,
    )
    if result.returncode:
        # Avoid echoing command arguments or stdin: they may contain a token.
        detail = (result.stderr or "").strip()[-1500:] if capture else ""
        raise PlatformError(f"{Path(str(args[0])).name} failed ({result.returncode}). {detail}")
    return result.stdout if capture else ""


def command_exists(name):
    if not shutil.which(name):
        raise PlatformError(f"Missing {name}; install it in the host terminal first.")


def save(path, obj, *, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")
    path.chmod(mode)


def github_path(url):
    match = re.fullmatch(r"https://github[.]com/([A-Za-z0-9_.-]+)(?:/([A-Za-z0-9_.-]+))?", url)
    if not match:
        raise PlatformError("github_url must be a GitHub organization or repository URL.")
    owner, repo = match.groups()
    return f"repos/{owner}/{repo}" if repo else f"orgs/{owner}"


def load_config(path):
    if not path.is_file():
        raise PlatformError("Run 'init', then fill in the local configuration.")
    cfg = json.loads(path.read_text(encoding="utf-8"))
    github_path(cfg["github_url"])
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", cfg["vm_name"]):
        raise PlatformError("Invalid VM name.")
    for field in ("general_scale_set", "heavy_scale_set"):
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", cfg[field]):
            raise PlatformError(f"Invalid {field}.")
    if cfg["general_scale_set"] == cfg["heavy_scale_set"]:
        raise PlatformError("Scale-set names must differ.")
    for p in ("pilot", "full"):
        profile = cfg[p]
        if not 4 <= profile["memory_gib"] <= 24 or not 1 <= profile["cpus"] <= 12:
            raise PlatformError("VM allocation is outside the supported host envelope.")
    if not re.fullmatch(r"v[0-9]+[.][0-9]+[.][0-9]+[+]k3s[0-9]+", cfg["versions"]["k3s"]):
        raise PlatformError("Pin a K3s release version.")
    return cfg


def gh_json(endpoint, *, paginate=False):
    args = ["gh", "api"]
    if paginate:
        args += ["--paginate", "--slurp"]
    for attempt in range(3):
        try:
            return json.loads(run(args + [endpoint], capture=True, timeout=120))
        except (PlatformError, subprocess.TimeoutExpired) as error:
            transient = isinstance(error, subprocess.TimeoutExpired) or any(
                marker in str(error).lower() for marker in (
                    "tls handshake timeout", "i/o timeout", "connection reset by peer",
                    "unexpected eof", "context deadline exceeded", "http 429", "http 502",
                    "http 503", "http 504"))
            if not transient or attempt == 2:
                raise
            delay = 2 ** (attempt + 1)
            print(f"GitHub API read temporarily failed; retrying ({attempt + 2}/3) in {delay}s…", flush=True)
            time.sleep(delay)


def gh_pages(endpoint, key=None):
    pages = gh_json(endpoint, paginate=True)
    result = []
    for page in pages:
        result.extend(page[key] if key else page)
    return result


def identity(cfg):
    command_exists("gh")
    login = gh_json("user")["login"]
    expected = cfg.get("expected_github_login")
    if not expected or login != expected:
        raise PlatformError("Set expected_github_login to the verified personal account; identity mismatch.")
    return login


def lima_state():
    command_exists("limactl")
    output = run(["limactl", "list", "--json"], capture=True, timeout=30)
    instances = [json.loads(line) for line in output.splitlines() if line.strip()]
    for vm in instances:
        if vm.get("status") not in ("Running", "Stopped"):
            raise PlatformError(f"Cannot verify state of VM {vm.get('name')}; refusing capacity decisions.")
        if vm.get("errors"):
            raise PlatformError(f"VM inspection errors for {vm.get('name')}.")
    return instances


def capacity(cfg, profile, instances, host_memory, free_disk):
    other = sum(vm["memory"] for vm in instances
                if vm["status"] == "Running" and vm["name"] != cfg["vm_name"])
    needed = (profile["memory_gib"] + cfg["reserve_host_gib"]) * GIB + other
    if needed > host_memory:
        raise PlatformError("Insufficient host RAM headroom. Drain idle old workloads first.")
    if free_disk < cfg["min_free_disk_gib"] * GIB:
        raise PlatformError("Insufficient physical disk headroom.")
    return {"other_running_vm_gib": round(other / GIB, 2),
            "new_vm_gib": profile["memory_gib"],
            "host_reserve_gib": cfg["reserve_host_gib"]}


def preflight(cfg, profile):
    if sys.platform != "darwin":
        raise PlatformError("The Studio host command requires macOS.")
    command_exists("sysctl")
    instances = lima_state()
    memory = int(run(["sysctl", "-n", "hw.memsize"], capture=True))
    if run(["uname", "-m"], capture=True).strip() != "arm64":
        raise PlatformError("This profile requires Apple Silicon.")
    return capacity(cfg, profile, instances, memory, shutil.disk_usage(ROOT).free)


def check_client_version(cfg):
    command_exists("kubectl")
    version = json.loads(run(["kubectl", "version", "--client", "-o", "json"], capture=True))["clientVersion"]
    client = re.match(r"v([0-9]+)[.]([0-9]+)", version["gitVersion"])
    server = re.match(r"v([0-9]+)[.]([0-9]+)", cfg["versions"]["k3s"])
    if (not client or not server or client[1] != server[1]
            or abs(int(client[2]) - int(server[2])) > 1):
        raise PlatformError("kubectl is outside the selected Kubernetes release's supported "
                            "minor-version range. Install a matching client before VM startup.")


def namespace(name):
    return {"apiVersion": "v1", "kind": "Namespace",
            "metadata": {"name": name, "labels": {"ci-platform": "true"}}}


def port_forwards(cfg):
    return [
        {"guestPort": 6443, "hostPort": cfg["api_host_port"],
         "hostIP": "127.0.0.1", "proto": "tcp"},
        # Ignore wildcard listeners as well as interface-specific ones. The
        # default guestIP=127.0.0.1 ignore rule skips wildcard bind addresses.
        {"guestIP": "0.0.0.0", "guestIPMustBeZero": False,
         "guestPortRange": [1, 65535], "proto": "any", "ignore": True},
    ]


def quota(cfg, profile):
    return {"apiVersion": "v1", "kind": "ResourceQuota",
            "metadata": {"name": "runner-budget", "namespace": "arc-runners"},
            "spec": {"hard": {"requests.cpu": "6" if profile == "full" else "2500m",
                             "requests.memory": cfg[profile]["quota_memory"],
                             "limits.memory": cfg[profile]["quota_memory"],
                             "pods": "12", "requests.ephemeral-storage": "30Gi",
                             "limits.ephemeral-storage": "40Gi"}}}


def lima_template(cfg, profile):
    p = cfg[profile]
    kconfig = {
        "node-name": cfg["vm_name"], "disable": ["traefik", "servicelb"],
        "secrets-encryption": True, "write-kubeconfig-mode": "0600",
        "tls-san": ["127.0.0.1", "localhost"],
        "kubelet-arg": [
            "system-reserved=cpu=500m,memory=512Mi",
            "kube-reserved=cpu=500m,memory=512Mi",
            "eviction-hard=memory.available<512Mi,nodefs.available<15%",
            "container-log-max-size=10Mi", "container-log-max-files=3",
        ],
        "node-label": ["ci.platform/host=studio", "ci.platform/persistent=true"],
    }
    script = (
        "#!/bin/bash\nset -euo pipefail\n"
        + "export K3S_VERSION=" + shlex.quote(cfg["versions"]["k3s"]) + "\n"
        + "export K3S_CONFIG_JSON=" + shlex.quote(json.dumps(kconfig)) + "\n"
        + "export K3S_UNIT=" + shlex.quote(K3S_UNIT) + "\n"
        + (ROOT / "guest-bootstrap.sh").read_text(encoding="utf-8")
    )
    return {
        "minimumLimaVersion": "2.2.1", "vmType": "vz", "arch": "aarch64",
        "images": [cfg["guest_image"]], "cpus": p["cpus"],
        "memory": f"{p['memory_gib']}GiB", "disk": f"{p['disk_gib']}GiB",
        "mounts": [], "containerd": {"system": False, "user": False},
        "ssh": {"localPort": cfg["ssh_host_port"], "forwardAgent": False,
                "loadDotSSHPubKeys": False},
        "networks": [{"vzNAT": True}],
        "portForwards": port_forwards(cfg),
        "provision": [{"mode": "system", "script": script}],
        "probes": [{
            "mode": "readiness", "description": "K3s API and node ready",
            "script": "#!/bin/bash\nset -e\nsudo k3s kubectl wait --for=condition=Ready node --all --timeout=180s\n",
        }],
    }


def runner_values(cfg, profile, *, heavy=False):
    p = cfg[profile]
    image = cfg["runner_image"] or f"ghcr.io/actions/actions-runner:{cfg['versions']['runner']}"
    name = cfg["heavy_scale_set"] if heavy else cfg["general_scale_set"]
    values = {
        "githubConfigUrl": cfg["github_url"], "githubConfigSecret": "arc-github-app",
        "runnerScaleSetName": name, "minRunners": 0,
        "maxRunners": 1 if heavy else p["max_runners"],
        "controllerServiceAccount": {"namespace": "arc-system", "name": "arc-controller"},
        "template": {"metadata": {"labels": {"ci-platform-runner": "true"}},
                     "spec": {"nodeSelector": {"ci.platform/host": "studio"},
                              "automountServiceAccountToken": False,
                              "securityContext": {"runAsUser": 1001, "runAsGroup": 1001,
                                                  "fsGroup": 1001},
                              "containers": [{
                                  "name": "runner", "image": image,
                                  "command": ["/home/runner/run.sh"],
                                  "securityContext": {"allowPrivilegeEscalation": False},
                                  "resources": {
                                      "requests": {"cpu": "4" if heavy else "1",
                                                   "memory": "6Gi" if heavy else "1Gi",
                                                   "ephemeral-storage": "2Gi"},
                                      "limits": {"memory": "8Gi" if heavy else p["runner_memory_limit"],
                                                 "ephemeral-storage": "20Gi" if heavy else "8Gi"},
                                  },
                                  "volumeMounts": [{"name": "work", "mountPath": "/home/runner/_work"}],
                              }],
                              "volumes": [{"name": "work", "emptyDir": {
                                  "sizeLimit": "16Gi" if heavy else "6Gi"}}]}},
        "listenerTemplate": {"spec": {"containers": [{
            "name": "listener", "resources": {"requests": {"cpu": "100m", "memory": "128Mi"},
                                              "limits": {"memory": "256Mi"}}}]}},
    }
    if cfg.get("runner_group"):
        values["runnerGroup"] = cfg["runner_group"]
    if cfg.get("image_pull_secret"):
        values["template"]["spec"]["imagePullSecrets"] = [{"name": cfg["image_pull_secret"]}]
    return values


def monitoring_resources(cpu, memory, cpu_limit, memory_limit):
    return {"requests": {"cpu": cpu, "memory": memory},
            "limits": {"cpu": cpu_limit, "memory": memory_limit}}


def monitoring_values(cfg, profile="full"):
    """Bound every enabled chart container, including hooks and sidecars.

    Values verified against kube-prometheus-stack 92.6.0 and its pinned
    Grafana 13.5.1 chart. Keep release/object names stable to retain PVCs.
    """
    pilot = profile == "pilot"
    small = monitoring_resources("10m", "16Mi", "100m", "32Mi" if pilot else "64Mi")
    reloader = monitoring_resources("10m", "16Mi", "100m", "32Mi")
    jobs = [{
        "job_name": "arc-metrics", "kubernetes_sd_configs": [
            {"role": "pod", "namespaces": {"names": ["arc-system", "arc-runners"]}}],
        "relabel_configs": [
            {"source_labels": ["__meta_kubernetes_pod_container_port_name"],
             "regex": "metrics", "action": "keep"},
            {"source_labels": ["__meta_kubernetes_namespace"], "target_label": "namespace"},
            {"source_labels": ["__meta_kubernetes_pod_name"], "target_label": "pod"},
            {"source_labels": ["__meta_kubernetes_pod_label_app_kubernetes_io_component"],
             "target_label": "component"},
        ],
    }]
    for target in cfg.get("host_exporters", []):
        jobs.append({"job_name": target["name"],
                     "static_configs": [{"targets": [target["address"]],
                                         "labels": {"os": target.get("os", "darwin")}}]})
    return {
        "defaultRules": {"rules": {"kubeSchedulerAlerting": False, "kubeSchedulerRecording": False,
                                    "kubeControllerManager": False, "kubeProxy": False, "etcd": False}},
        "kubeScheduler": {"enabled": False}, "kubeControllerManager": {"enabled": False},
        "kubeEtcd": {"enabled": False}, "kubeProxy": {"enabled": False},
        "kubelet": {"serviceMonitor": {"interval": "60s", "cAdvisor": True,
                                        "tlsConfig": {"insecureSkipVerify": False,
                                                      "ca": {"configMap": {"name": "kube-root-ca.crt", "key": "ca.crt"}}}}},
        "alertmanager": {"enabled": True, "alertmanagerSpec": {
            "persistentVolumeClaimRetentionPolicy": {"whenDeleted": "Retain", "whenScaled": "Retain"},
            "replicas": 1, "retention": "24h", "storage": {"volumeClaimTemplate": {"spec": {
                "storageClassName": "local-path", "accessModes": ["ReadWriteOnce"],
                "resources": {"requests": {"storage": "1Gi"}}}}},
            "resources": monitoring_resources("25m", "32Mi" if pilot else "128Mi", "200m", "64Mi" if pilot else "256Mi")}},
        "prometheusOperator": {
            "resources": monitoring_resources("50m", "64Mi" if pilot else "128Mi", "250m", "96Mi" if pilot else "256Mi"),
            "kubeletEndpointsEnabled": False, "kubeletEndpointSliceEnabled": True,
            "prometheusConfigReloader": {"resources": reloader},
            "admissionWebhooks": {"patch": {"resources": small}}},
        "kube-state-metrics": {"resources": monitoring_resources("25m", "32Mi", "200m", "64Mi" if pilot else "96Mi")},
        "prometheus-node-exporter": {
            "extraArgs": ["--collector.disable-defaults", "--collector.cpu", "--collector.meminfo",
                          "--collector.filesystem", "--collector.diskstats", "--collector.netdev",
                          "--collector.uname", "--collector.loadavg", "--collector.time"],
            "resources": monitoring_resources("25m", "32Mi", "200m", "48Mi" if pilot else "64Mi")},
        "grafana": {
            "admin": {"existingSecret": "grafana-admin", "userKey": "admin-user",
                      "passwordKey": "admin-password"},
            "persistence": {"enabled": True, "storageClassName": "local-path", "size": "2Gi",
                            "annotations": {"helm.sh/resource-policy": "keep"}},
            "resources": monitoring_resources("50m", "256Mi", "500m", "512Mi"),
            "sidecar": {"resources": monitoring_resources("10m", "64Mi", "100m", "128Mi")},
            "initChownData": {"resources": small},
            "downloadDashboards": {"resources": small}, "testFramework": {"resources": small},
            "grafana.ini": {"auth.anonymous": {"enabled": False}, "users": {"allow_sign_up": False}},
            "deploymentStrategy": {"type": "Recreate"},
            "nodeSelector": {"ci.platform/persistent": "true"},
            "service": {"type": "ClusterIP"},
        },
        "prometheus": {"prometheusSpec": {
            "persistentVolumeClaimRetentionPolicy": {"whenDeleted": "Retain", "whenScaled": "Retain"},
            "replicas": 1, "retention": "48h" if pilot else "7d", "retentionSize": "4GB" if pilot else "10GB",
            "serviceDiscoveryRole": "EndpointSlice",
            "scrapeInterval": "60s", "evaluationInterval": "60s",
            "resources": monitoring_resources("200m" if pilot else "500m", "256Mi" if pilot else "1Gi", "1", "512Mi" if pilot else "2Gi"),
            "nodeSelector": {"ci.platform/persistent": "true"},
            "serviceMonitorSelectorNilUsesHelmValues": False,
            "podMonitorSelectorNilUsesHelmValues": False,
            "additionalScrapeConfigs": jobs,
            "storageSpec": {"volumeClaimTemplate": {"spec": {
                "storageClassName": "local-path", "accessModes": ["ReadWriteOnce"],
                "resources": {"requests": {"storage": "8Gi" if pilot else "20Gi"}}}}},
        }},
    }


def render(cfg, profile, state):
    output = state / "rendered" / profile
    output.mkdir(parents=True, exist_ok=True)
    save(output / "lima.yaml", lima_template(cfg, profile))
    save(output / "quota.yaml", quota(cfg, profile))
    save(output / "controller.yaml", {
        "serviceAccount": {"create": True, "name": "arc-controller"},
        "metrics": {"controllerManagerAddr": ":8080", "listenerAddr": ":8080",
                    "listenerEndpoint": "/metrics"},
        "resources": {"requests": {"cpu": "100m", "memory": "128Mi"},
                      "limits": {"memory": "256Mi"}},
    })
    save(output / "general.yaml", runner_values(cfg, profile))
    save(output / "heavy.yaml", runner_values(cfg, profile, heavy=True))
    save(output / "monitoring.yaml", monitoring_values(cfg, profile))
    return output


def kube(state, *args, input_text=None, capture=False, timeout=600):
    command_exists("kubectl")
    return run(["kubectl", "--kubeconfig", state / "kubeconfig", *args],
               input_text=input_text, capture=capture, timeout=timeout)


def apply_object(state, obj):
    kube(state, "apply", "-f", "-", input_text=json.dumps(obj))


def get_kubeconfig(cfg, state):
    raw = run(["limactl", "shell", cfg["vm_name"], "sudo", "cat",
               "/etc/rancher/k3s/k3s.yaml"], capture=True)
    # Avoid a PyYAML dependency. kubectl can consume and emit JSON kubeconfig.
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / "kubeconfig"
        path.write_text(raw, encoding="utf-8")
        path.chmod(0o600)
        doc = json.loads(run(["kubectl", "--kubeconfig", path, "config", "view",
                              "--raw", "-o", "json"], capture=True))
    cluster = doc["clusters"][0]
    cluster["name"] = cfg["vm_name"]
    cluster["cluster"]["server"] = f"https://127.0.0.1:{cfg['api_host_port']}"
    doc["users"][0]["name"] = cfg["vm_name"] + "-admin"
    doc["contexts"][0] = {"name": cfg["vm_name"], "context": {
        "cluster": cluster["name"], "user": doc["users"][0]["name"]}}
    doc["current-context"] = cfg["vm_name"]
    save(state / "kubeconfig", doc)


def helm(state, *args):
    command_exists("helm")
    run(["helm", "--kubeconfig", state / "kubeconfig", *args], timeout=900)


def install_release(state, name, namespace_name, chart, version, values):
    helm(state, "upgrade", "--install", name, chart, "--namespace", namespace_name,
         "--create-namespace", "--version", version, "--values", values,
         "--wait", "--timeout", "10m")


def secret(state, name, ns, values, secret_type="Opaque"):
    # JSON via stdin keeps private key/password out of process arguments and disk.
    apply_object(state, {"apiVersion": "v1", "kind": "Secret",
                        "metadata": {"name": name, "namespace": ns},
                        "type": secret_type, "data": {
                            key: base64.b64encode(value.encode()).decode()
                            for key, value in values.items()}})


def inventory_host(state, host_home=None):
    host_home = Path(host_home) if host_home else Path.home()
    registrations = []
    for path in host_home.glob("actions-runner*/.runner"):
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        registrations.append({"id": data.get("agentId"),
                              "name": data.get("agentName"),
                              "scope": data.get("gitHubUrl"),
                              "directory": str(path.parent)})
    services = []
    for path in (host_home / "Library" / "LaunchAgents").glob("*.plist"):
        data = plistlib.loads(path.read_bytes())
        label = data.get("Label", "")
        if "runner" not in label and "jit" not in label and "lima" not in label:
            continue
        arguments = data.get("ProgramArguments", [])
        # Report labels and work directories only; argv/environment may hold tokens.
        services.append({"label": label, "plist": str(path),
                         "working_directory": data.get("WorkingDirectory"),
                         "vm": next((arg for arg in arguments
                                     if re.fullmatch(r"gh-(build(-2)?|ubuntu)", arg)), None)})
    save(state / "host-inventory.json",
         {"registrations": registrations, "launch_agents": services})
    print(f"Read {len(registrations)} local registrations and {len(services)} launch agents.")


def inventory(cfg, state):
    identity(cfg)
    scope = github_path(cfg["github_url"])
    runners = gh_pages(scope + "/actions/runners?per_page=100", "runners")
    repos = (gh_pages(scope + "/repos?per_page=100&type=all")
             if scope.startswith("orgs/") else [gh_json(scope)])
    groups = gh_pages(scope + "/actions/runner-groups?per_page=100", "runner_groups") if scope.startswith("orgs/") else []
    ledger = []
    for r in runners:
        ledger.append({"scope": scope, "id": r["id"], "name": r["name"],
                       "os": r["os"], "status": r["status"], "busy": r["busy"],
                       "labels": [label["name"] for label in r["labels"]],
                       "host_vm": None, "replacement": None, "retire": False})
    workflows = []
    # Git objects are immutable. Reuse them only within this audit, while still
    # visiting every live branch and recording every workflow/ref relationship.
    objects = {}
    def object_json(endpoint):
        if endpoint not in objects:
            objects[endpoint] = gh_json(endpoint)
        return objects[endpoint]
    for repo in repos:
        print(f"Auditing workflow routes: {repo['full_name']}…", flush=True)
        repo_scope = "repos/" + repo["full_name"]
        if scope.startswith("orgs/"):
            for r in gh_pages(repo_scope + "/actions/runners?per_page=100", "runners"):
                ledger.append({"scope": repo_scope, "id": r["id"], "name": r["name"],
                               "os": r["os"], "status": r["status"], "busy": r["busy"],
                               "labels": [label["name"] for label in r["labels"]],
                               "host_vm": None, "replacement": None, "retire": False})
        branches = gh_pages(repo_scope + "/branches?per_page=100")
        for branch in branches:
            sha = branch["commit"]["sha"]
            tree = object_json(repo_scope + f"/git/trees/{sha}?recursive=1")
            if tree.get("truncated"):
                raise PlatformError("Truncated repository tree; inventory is incomplete.")
            for entry in tree["tree"]:
                if entry["type"] == "blob" and re.fullmatch(r"[.]github/workflows/[^/]+[.]ya?ml", entry["path"]):
                    blob = object_json(repo_scope + "/git/blobs/" + entry["sha"])
                    text = base64.b64decode(blob["content"]).decode()
                    workflows.append({"repository": repo["full_name"], "branch": branch["name"],
                                      "commit": sha, "path": entry["path"], "content": text})
    save(state / "migration-ledger.json", ledger)
    save(state / "runner-groups.json", groups)
    save(state / "workflow-inventory.json", workflows)
    save(state / "inventory-metadata.json", {
        "completed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "repository_count": len(repos), "workflow_count": len(workflows)})
    print(f"Inventoried {len(ledger)} registrations and {len(workflows)} workflow/ref entries.")


def start(cfg, profile, state):
    check_client_version(cfg)
    print(json.dumps(preflight(cfg, cfg[profile]), indent=2))
    output = render(cfg, profile, state)
    instances = lima_state()
    existing = next((v for v in instances if v["name"] == cfg["vm_name"]), None)
    if existing:
        if (existing["cpus"] != cfg[profile]["cpus"]
                or existing["memory"] != cfg[profile]["memory_gib"] * GIB
                or existing["disk"] != cfg[profile]["disk_gib"] * GIB):
            raise PlatformError("Existing VM differs. Drain/stop, back up and explicitly resize it first.")
        run(["limactl", "start", "--tty=false", cfg["vm_name"]])
    else:
        run(["limactl", "validate", output / "lima.yaml"])
        run(["limactl", "start", "--tty=false", "--name", cfg["vm_name"], output / "lima.yaml"],
            timeout=1200)
    get_kubeconfig(cfg, state)
    wait_cluster(state)
    save(state / "deployment.json", {"profile": profile, "vm": cfg["vm_name"],
                                    "started_at": dt.datetime.now(dt.timezone.utc).isoformat()})


def wait_cluster(state):
    kube(state, "wait", "--for=condition=Ready", "node", "--all", "--timeout=180s")
    required = {"coredns", "local-path-provisioner", "metrics-server"}
    # K3s can report a Ready node before its bundled manifests are applied.
    deadline = time.monotonic() + 90
    while True:
        deployments = json.loads(kube(state, "get", "deployments", "-n", "kube-system", "-o", "json", capture=True))
        existing = {item["metadata"]["name"] for item in deployments["items"]}
        if required <= existing:
            break
        if time.monotonic() >= deadline:
            raise PlatformError("K3s system deployments are missing: " + ", ".join(sorted(required - existing)))
        time.sleep(2)
    for name in sorted(required):
        kube(state, "rollout", "status", "deployment/" + name, "-n", "kube-system", "--timeout=180s")


def check_deployment(cfg, profile, state):
    path = state / "deployment.json"
    if not path.exists():
        raise PlatformError("Start and verify the managed cluster first.")
    deployment = json.loads(path.read_text())
    if deployment["vm"] != cfg["vm_name"] or deployment["profile"] != profile:
        raise PlatformError("Deployment profile differs from requested values.")
    nodes = json.loads(kube(state, "get", "nodes", "-o", "json", capture=True))
    if not any(n["metadata"]["name"] == cfg["vm_name"] and any(
            c["type"] == "Ready" and c["status"] == "True"
            for c in n["status"]["conditions"]) for n in nodes["items"]):
        raise PlatformError("Managed node is not Ready.")


def deploy_arc(cfg, profile, state, app_file):
    check_deployment(cfg, profile, state)
    if not re.fullmatch(r".+@sha256:[0-9a-f]{64}", cfg["runner_image"]):
        raise PlatformError("Set runner_image to the built custom image's immutable ARM64 digest.")
    if app_file.stat().st_mode & 0o077:
        raise PlatformError("ARC App credential file must be mode 0600.")
    app = json.loads(app_file.read_text())
    values = {k: str(app[k]) for k in (
        "github_app_id", "github_app_installation_id", "github_app_private_key")}
    if not values["github_app_id"] or "PRIVATE KEY" not in values["github_app_private_key"]:
        raise PlatformError("Invalid App credentials.")
    scope = github_path(cfg["github_url"])
    run([sys.executable, ROOT / "check_app.py", "--app-file", app_file,
         "--organization", scope.split("/")[1], "--scope",
         "organization" if scope.startswith("orgs/") else "repository"])
    for ns in ("arc-system", "arc-runners"):
        apply_object(state, namespace(ns))
    if cfg.get("image_pull_secret"):
        kube(state, "get", "secret", cfg["image_pull_secret"], "-n", "arc-runners", capture=True)
    secret(state, "arc-github-app", "arc-runners", values)
    output = render(cfg, profile, state)
    apply_object(state, quota(cfg, profile))
    install_release(state, "arc", "arc-system",
                    "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller",
                    cfg["versions"]["arc"], output / "controller.yaml")
    install_release(state, cfg["general_scale_set"], "arc-runners",
                    "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set",
                    cfg["versions"]["arc"], output / "general.yaml")
    kube(state, "get", "autoscalingrunnersets", "-n", "arc-runners")
    print("ARC installed. Run the canary workflow before routing real jobs.")


def memory_bytes(value):
    match = re.fullmatch(r"([0-9]+(?:[.][0-9]+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?", str(value))
    if not match:
        raise PlatformError("Unsupported Kubernetes memory quantity.")
    units = {None: 1, "Ki": 1024, "Mi": 1024 ** 2, "Gi": GIB, "Ti": 1024 ** 4,
             "K": 1000, "M": 1000 ** 2, "G": 1000 ** 3, "T": 1000 ** 4}
    return int(float(match[1]) * units[match[2]])


def monitoring_capacity(cfg, profile, state):
    """Reserve room for every runner even when ARC is currently scaled to zero."""
    nodes = json.loads(kube(state, "get", "nodes", "-o", "json", capture=True))["items"]
    node = next((n for n in nodes if n["metadata"]["name"] == cfg["vm_name"]), None)
    if not node:
        raise PlatformError("Managed node was not found.")
    if any(c["status"] == "True" and c["type"] in ("MemoryPressure", "DiskPressure", "PIDPressure")
           for c in node["status"]["conditions"]):
        raise PlatformError("Managed node is under resource pressure; monitoring install refused.")
    allocatable = memory_bytes(node["status"]["allocatable"]["memory"])
    pods = json.loads(kube(state, "get", "pods", "-A", "-o", "json", capture=True))["items"]
    other = 0
    active_runners = 0
    for pod in pods:
        if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        if pod["metadata"]["namespace"] == "monitoring":
            continue
        if pod["spec"].get("nodeName") != cfg["vm_name"]:
            continue
        if pod["metadata"].get("labels", {}).get("actions.github.com/scale-set-name") == cfg["general_scale_set"]:
            active_runners += 1
        # K3s system pods may omit limits. Reserve at least 128 MiB per such
        # container, on top of the kubelet's system/kube-reserved allocation.
        def container_memory(container):
            resources = container.get("resources", {})
            return memory_bytes(resources.get("limits", {}).get("memory")
                                or resources.get("requests", {}).get("memory") or "128Mi")
        steady = sum(container_memory(c) for c in pod["spec"]["containers"])
        init = max((container_memory(c) for c in pod["spec"].get("initContainers", [])), default=0)
        other += max(steady, init)
    budget = memory_bytes("1792Mi" if profile == "pilot" else "5Gi")
    remaining = max(0, cfg[profile]["max_runners"] - active_runners)
    required = other + budget + remaining * memory_bytes(cfg[profile]["runner_memory_limit"])
    if required > allocatable:
        raise PlatformError(f"Monitoring needs {required // 1048576} MiB including runner headroom; "
                            f"node allocatable is {allocatable // 1048576} MiB. Keep the current VM allocation.")
    return {"allocatable_mib": allocatable // 1048576, "reserved_mib": required // 1048576,
            "monitoring_limit_mib": budget // 1048576}


def check_monitoring_pvcs(state, values):
    claims = json.loads(kube(state, "get", "pvc", "-n", "monitoring", "-o", "json", capture=True))["items"]
    expected = {"ci-monitoring-grafana": values["grafana"]["persistence"]["size"]}
    for claim in claims:
        name = claim["metadata"]["name"]
        if "ci-monitoring" not in name:
            continue
        if name in expected:
            desired = expected[name]
        elif name.startswith("prometheus-"):
            desired = values["prometheus"]["prometheusSpec"]["storageSpec"]["volumeClaimTemplate"]["spec"]["resources"]["requests"]["storage"]
        elif name.startswith("alertmanager-"):
            desired = "1Gi"
        else:
            raise PlatformError("Unrecognized monitoring PVC; inspect existing release before changing it.")
        if memory_bytes(claim["spec"]["resources"]["requests"]["storage"]) != memory_bytes(desired):
            raise PlatformError("Monitoring PVC size differs from this profile; refusing to resize or replace stored data.")


def monitor(cfg, profile, state):
    check_deployment(cfg, profile, state)
    budget = monitoring_capacity(cfg, profile, state)
    values = monitoring_values(cfg, profile)
    apply_object(state, namespace("monitoring"))
    check_monitoring_pvcs(state, values)
    # Existing password survives reruns and is never printed.
    existing = kube(state, "get", "secret", "grafana-admin", "-n", "monitoring",
                    "--ignore-not-found", "-o", "json", capture=True)
    if not existing.strip():
        import secrets as secrets_module
        secret(state, "grafana-admin", "monitoring",
               {"admin-user": "admin", "admin-password": secrets_module.token_urlsafe(32)})
    elif not all(json.loads(existing).get("data", {}).get(key) for key in ("admin-user", "admin-password")):
        raise PlatformError("Existing Grafana credential is incomplete; refusing to replace it.")
    apply_object(state, {"apiVersion": "v1", "kind": "ResourceQuota",
                        "metadata": {"name": "monitoring-budget", "namespace": "monitoring"},
                        "spec": {"hard": {"requests.cpu": "1500m", "limits.cpu": "4",
                                          "requests.memory": "1Gi" if profile == "pilot" else "3Gi",
                                          "limits.memory": "1792Mi" if profile == "pilot" else "5Gi",
                                          "requests.storage": "11Gi" if profile == "pilot" else "23Gi",
                                          "persistentvolumeclaims": "3", "pods": "12"}}})
    output = render(cfg, profile, state)
    helm(state, "repo", "add", "prometheus-community", "https://prometheus-community.github.io/helm-charts")
    helm(state, "repo", "update", "prometheus-community")
    # Helm 4 renamed --atomic; use the supported rollback flag for each major.
    version = run(["helm", "version", "--short"], capture=True)
    rollback = "--rollback-on-failure" if re.match(r"v4[.]", version) else "--atomic"
    helm(state, "upgrade", "--install", "ci-monitoring", "prometheus-community/kube-prometheus-stack",
         "--namespace", "monitoring", "--version", cfg["versions"]["monitoring"],
         "--values", output / "monitoring.yaml", rollback, "--wait", "--timeout", "10m")
    for path in (ROOT / "monitoring").glob("*.json"):
        obj = json.loads(path.read_text())
        apply_object(state, obj)
    verify_monitoring(cfg, state)
    save(state / "monitoring-deployment.json", {"profile": profile, "budget": budget,
                                              "chart_version": cfg["versions"]["monitoring"]})


@contextlib.contextmanager
def monitoring_forward(state, service, port):
    """Private ephemeral localhost forwarding; no password in argv or logs."""
    command_exists("kubectl")
    process = subprocess.Popen(["kubectl", "--kubeconfig", str(state / "kubeconfig"),
                                "-n", "monitoring", "port-forward", "--address", "127.0.0.1",
                                "service/" + service, ":" + str(port)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and process.poll() is None:
            if selector.select(timeout=0.25):
                line = process.stdout.readline()
                match = re.match(r"Forwarding from 127[.]0[.]0[.]1:([0-9]+) ->", line)
                if match:
                    yield "http://127.0.0.1:" + match[1]
                    return
        raise PlatformError("Monitoring service forwarding did not become ready.")
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()


def monitoring_request(base, path, authorization=None):
    headers = {"Authorization": authorization} if authorization else {}
    request = urllib.request.Request(base + path, headers=headers)
    # Never send a loopback request (and its credential) through a host proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=10) as response:
            return response.read().decode()
    except (urllib.error.URLError, OSError) as error:
        raise PlatformError("Monitoring HTTP health/authentication check failed.") from error


def monitoring_target_gaps(cfg, targets):
    healthy = [t for t in targets if t.get("health") == "up"]
    checks = {
        "apiserver": lambda t: t.get("labels", {}).get("job") == "apiserver",
        "node-exporter": lambda t: t.get("labels", {}).get("job") == "node-exporter",
        "kube-state-metrics": lambda t: "kube-state-metrics" in t.get("labels", {}).get("job", ""),
        "kubelet": lambda t: t.get("scrapeUrl", "").endswith("/metrics") and t.get("labels", {}).get("job") == "kubelet",
        "cadvisor": lambda t: t.get("scrapeUrl", "").endswith("/metrics/cadvisor"),
        "arc-controller": lambda t: t.get("labels", {}).get("job") == "arc-metrics"
                                   and t.get("labels", {}).get("component") == "controller-manager",
        "arc-listener": lambda t: t.get("labels", {}).get("job") == "arc-metrics"
                                 and t.get("labels", {}).get("component") == "runner-scale-set-listener",
    }
    for exporter in cfg.get("host_exporters", []):
        name = exporter["name"]
        checks[name] = lambda t, name=name: t.get("labels", {}).get("job") == name
    gaps = [name for name, predicate in checks.items() if not any(predicate(t) for t in healthy)]
    # A single healthy replica must not hide a failed scrape for another node.
    gaps += sorted({"down:" + t.get("labels", {}).get("job", "unknown") for t in targets
                    if t.get("health") != "up"})
    return gaps


def verify_actions_collectors(cfg, base):
    for exporter in cfg.get("host_exporters", []):
        if exporter.get("kind") != "actions" and not exporter["address"].endswith(":9108"):
            continue
        matcher = "{job=" + json.dumps(exporter["name"]) + "}"
        for query, condition in (
                ("ci_metrics_collection_success" + matcher, lambda value: value == 1),
                ("time() - ci_metrics_last_success_timestamp_seconds" + matcher,
                 lambda value: -60 <= value <= 300)):
            response = json.loads(monitoring_request(base, "/api/v1/query?" + urllib.parse.urlencode({"query": query})))
            results = response.get("data", {}).get("result", [])
            if response.get("status") != "success" or not results or not all(
                    condition(float(item["value"][1])) for item in results):
                raise PlatformError("Actions metrics collector is failing or stale: " + exporter["name"])


def verify_monitoring_metrics(base):
    required = ["node_cpu_seconds_total", "node_memory_MemAvailable_bytes", "node_filesystem_avail_bytes",
                "node_disk_read_bytes_total", "node_network_receive_bytes_total",
                'container_memory_working_set_bytes{container!=""}',
                'kube_node_status_condition{condition="Ready",status="true"} == 1',
                "gha_desired_runners", "gha_busy_runners", "gha_idle_runners", "gha_max_runners"]
    for query in required:
        response = json.loads(monitoring_request(base, "/api/v1/query?" + urllib.parse.urlencode({"query": query})))
        if response.get("status") != "success" or not response.get("data", {}).get("result"):
            raise PlatformError("Required monitoring metric has no data: " + query)


def verify_grafana_dashboards(base, authorization):
    configmap = json.loads((ROOT / "monitoring" / "dashboard.json").read_text())
    expected_dashboards = [json.loads(raw) for raw in configmap["data"].values()]
    verified = []
    for expected in expected_dashboards:
        uid = expected["uid"]
        path = "/api/dashboards/uid/" + urllib.parse.quote(uid, safe="")
        for attempt in range(30):
            try:
                result = json.loads(monitoring_request(base, path, authorization))
                actual = result.get("dashboard", {})
                if (result.get("meta", {}).get("provisioned") is True
                        and actual.get("uid") == uid and actual.get("title") == expected["title"]
                        and len(actual.get("panels", [])) == len(expected["panels"])):
                    verified.append(uid)
                    break
            except PlatformError:
                # The sidecar provisions asynchronously after Grafana is ready.
                pass
            if attempt == 29:
                raise PlatformError("Expected provisioned Grafana dashboard is missing or incomplete: " + uid)
            time.sleep(2)
    if not verified:
        raise PlatformError("No expected Grafana dashboards are configured.")
    return verified


def verify_monitoring(cfg, state):
    for attempt in range(60):
        claims = json.loads(kube(state, "get", "pvc", "-n", "monitoring", "-o", "json", capture=True))["items"]
        if len(claims) == 3 and all(p.get("status", {}).get("phase") == "Bound" for p in claims):
            break
        if attempt == 59:
            raise PlatformError("Monitoring storage is not fully Bound.")
        time.sleep(2)
    for kind in ("deployment", "statefulset", "daemonset"):
        items = json.loads(kube(state, "get", kind, "-n", "monitoring", "-o", "json", capture=True))["items"]
        if not items:
            raise PlatformError("Monitoring is missing an expected workload type: " + kind)
        for item in items:
            kube(state, "rollout", "status", kind + "/" + item["metadata"]["name"],
                 "-n", "monitoring", "--timeout=180s")
    services = json.loads(kube(state, "get", "services", "-n", "monitoring", "-o", "json", capture=True))["items"]
    prometheus = next((s["metadata"]["name"] for s in services if
                       s["spec"].get("selector", {}).get("app.kubernetes.io/name") == "prometheus"
                       and s["spec"].get("type") == "ClusterIP"
                       and s["metadata"].get("labels", {}).get("release") == "ci-monitoring"), None)
    if not prometheus:
        raise PlatformError("Managed Prometheus service was not found.")
    credential = json.loads(kube(state, "get", "secret", "grafana-admin", "-n", "monitoring", "-o", "json", capture=True))["data"]
    auth = "Basic " + base64.b64encode(base64.b64decode(credential["admin-user"]) + b":"
                                     + base64.b64decode(credential["admin-password"])).decode()
    with monitoring_forward(state, "ci-monitoring-grafana", 80) as base:
        health = json.loads(monitoring_request(base, "/api/health"))
        user = json.loads(monitoring_request(base, "/api/user", auth))
        if health.get("database") != "ok" or not user.get("isGrafanaAdmin"):
            raise PlatformError("Grafana database or authenticated admin login is not healthy.")
        dashboards = verify_grafana_dashboards(base, auth)
    with monitoring_forward(state, prometheus, 9090) as base:
        monitoring_request(base, "/-/ready")
        for attempt in range(30):
            response = json.loads(monitoring_request(base, "/api/v1/targets?state=active"))
            if response.get("status") != "success":
                raise PlatformError("Prometheus target API did not report success.")
            targets = response["data"]["activeTargets"]
            gaps = monitoring_target_gaps(cfg, targets)
            problem = "Monitoring scrape targets are missing or unhealthy: " + ", ".join(gaps)
            if not gaps:
                try:
                    verify_actions_collectors(cfg, base)
                    verify_monitoring_metrics(base)
                    break
                except PlatformError as error:
                    # A newly healthy endpoint can precede its first complete
                    # GitHub poll or metric sample. Give it a bounded warm-up.
                    problem = str(error)
            if attempt == 29:
                raise PlatformError(problem)
            time.sleep(5)
    evidence = {"verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "grafana_authenticated": True, "grafana_dashboard_uids": dashboards, "storage_bound": True,
                "healthy_target_jobs": sorted({t["labels"]["job"] for t in targets})}
    save(state / "monitoring-evidence.json", evidence)
    print("Monitoring ready: authenticated Grafana, persistent storage and required scrapes verified.")


def verify_canary(cfg, state, repository, run_id, expected_conclusion="success"):
    identity(cfg)
    record = gh_json(f"repos/{repository}/actions/runs/{run_id}")
    if record["status"] != "completed" or record["conclusion"] != expected_conclusion:
        raise PlatformError("Canary has not completed with the expected " + expected_conclusion + " result.")
    jobs = gh_pages(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100", "jobs")
    expected = cfg["general_scale_set"]
    if not jobs or not all(expected in j.get("labels", []) and j["conclusion"] == expected_conclusion for j in jobs):
        raise PlatformError("Canary did not run with the expected result on the intended scale set.")
    if expected_conclusion == "failure":
        for job in jobs:
            failed = [step["name"] for step in job.get("steps", []) if step.get("conclusion") == "failure"]
            if failed != ["Optional failure"]:
                raise PlatformError("Failure was not confined to the intentional canary failure step.")
    elif expected_conclusion == "cancelled":
        if not all(job.get("runner_name") and any(
                step["name"] == "Set up job" and step.get("conclusion") == "success"
                for step in job.get("steps", [])) for job in jobs):
            raise PlatformError("Canary was cancelled before a runner started; this does not test running-job cleanup.")
    # Require observable cleanup, not just a workflow success.
    for _ in range(30):
        pods = json.loads(kube(state, "get", "pods", "-n", "arc-runners",
                              "-l", "ci-platform-runner=true", "-o", "json", capture=True))
        if not pods["items"]:
            evidence = {
                "run_id": run_id, "url": record["html_url"], "scale_set": expected,
                "expected_conclusion": expected_conclusion,
                "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "ephemeral_cleanup": True}
            latest = state / "canary-evidence.json"
            if latest.exists():
                previous = json.loads(latest.read_text())
                if "run_id" in previous:
                    save(state / f"canary-evidence-{int(previous['run_id'])}.json", previous)
            save(state / f"canary-evidence-{run_id}.json", evidence)
            save(latest, evidence)
            print("Canary " + expected_conclusion + " and ephemeral cleanup verified.")
            return
        time.sleep(2)
    raise PlatformError("Runner pods are still present; cleanup/scale-to-zero unverified.")


def parser():
    p = argparse.ArgumentParser(
        description="Deploy local ARM64 K3s CI infrastructure in staged profiles.",
        epilog="Examples: platform.py init; platform.py --config PATH preflight; "
               "platform.py --config PATH render --profile pilot")
    p.add_argument("--config", type=Path, default=ROOT / ".local" / "config.json")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("init", help="Create an editable private configuration.")
    sub.add_parser("inventory-host", help="Read local registrations and startup services without credentials.")
    sub.add_parser("inventory", help="Read GitHub runner registrations and all branch workflows.")
    registry = sub.add_parser("registry-secret", help="Store a private registry read credential via stdin.")
    registry.add_argument("--username", required=True)
    token_source = registry.add_mutually_exclusive_group(required=True)
    token_source.add_argument("--token-file", type=Path)
    token_source.add_argument("--prompt", action="store_true", help="Read the token from a hidden terminal prompt.")
    for name in ("preflight", "render", "start", "deploy-arc", "monitor"):
        child = sub.add_parser(name)
        child.add_argument("--profile", choices=["pilot", "full"], default="pilot")
        if name == "deploy-arc":
            child.add_argument("--app-file", type=Path, required=True)
    sub.add_parser("verify-monitoring", help="Verify storage, authenticated Grafana and Prometheus scrape health.")
    child = sub.add_parser("verify-canary")
    child.add_argument("--repository", required=True)
    child.add_argument("--run-id", type=int, required=True)
    child.add_argument("--expected-conclusion", choices=("success", "failure", "cancelled"), default="success",
                       help="Expected lifecycle test result; cancellations must have started a runner.")
    child = sub.add_parser("dashboard", help="Forward private Grafana to localhost:3000.")
    child.add_argument("--port", type=int, default=3000)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    state = args.config.resolve().parent
    try:
        if args.command == "init":
            if args.config.exists():
                raise PlatformError("Configuration already exists; refusing to overwrite it.")
            save(args.config, json.loads((ROOT / "config.example.json").read_text()))
            print(f"Fill in {args.config}; do not commit it.")
            return 0
        cfg = load_config(args.config)
        if args.command == "registry-secret":
            if not cfg.get("image_pull_secret"):
                raise PlatformError("Configure image_pull_secret first.")
            if args.prompt:
                if not sys.stdin.isatty():
                    raise PlatformError("Hidden token prompt requires an interactive terminal.")
                token = getpass.getpass("Registry PAT (read:packages only): ").strip()
            else:
                if args.token_file.stat().st_mode & 0o077:
                    raise PlatformError("Registry token file must be mode 0600.")
                token = args.token_file.read_text().strip()
            if not token:
                raise PlatformError("Empty registry token.")
            auth = base64.b64encode((args.username + ":" + token).encode()).decode()
            apply_object(state, namespace("arc-runners"))
            secret(state, cfg["image_pull_secret"], "arc-runners",
                   {".dockerconfigjson": json.dumps({"auths": {"ghcr.io": {"auth": auth}}})},
                   "kubernetes.io/dockerconfigjson")
        elif args.command == "inventory-host":
            inventory_host(state)
        elif args.command == "inventory":
            inventory(cfg, state)
        elif args.command == "preflight":
            print(json.dumps(preflight(cfg, cfg[args.profile]), indent=2))
        elif args.command == "render":
            print(render(cfg, args.profile, state))
        elif args.command == "start":
            start(cfg, args.profile, state)
        elif args.command == "deploy-arc":
            deploy_arc(cfg, args.profile, state, args.app_file)
        elif args.command == "monitor":
            monitor(cfg, args.profile, state)
        elif args.command == "verify-monitoring":
            verify_monitoring(cfg, state)
        elif args.command == "verify-canary":
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
                raise PlatformError("Invalid repository name.")
            verify_canary(cfg, state, args.repository, args.run_id, args.expected_conclusion)
        elif args.command == "dashboard":
            kube(state, "-n", "monitoring", "port-forward", "--address", "127.0.0.1",
                 "service/ci-monitoring-grafana", f"{args.port}:80", timeout=None)
        return 0
    except (PlatformError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

