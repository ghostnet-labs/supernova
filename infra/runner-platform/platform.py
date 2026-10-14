#!/usr/bin/env python3
"""Provision a bounded local CI cluster and inventory runner migration."""
import argparse
import base64
import datetime as dt
import json
from pathlib import Path
import re
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

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
    return json.loads(run(args + [endpoint], capture=True, timeout=120))


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
        "portForwards": [
            {"guestPort": 6443, "hostPort": cfg["api_host_port"],
             "hostIP": "127.0.0.1", "proto": "tcp"},
            {"guestPortRange": [1, 65535], "ignore": True},
        ],
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


def monitoring_values(cfg):
    jobs = [{
        "job_name": "arc-metrics", "kubernetes_sd_configs": [
            {"role": "pod", "namespaces": {"names": ["arc-system"]}}],
        "relabel_configs": [
            {"source_labels": ["__meta_kubernetes_pod_container_port_name"],
             "regex": "metrics", "action": "keep"},
            {"source_labels": ["__meta_kubernetes_namespace"], "target_label": "namespace"},
            {"source_labels": ["__meta_kubernetes_pod_name"], "target_label": "pod"},
        ],
    }]
    for target in cfg.get("host_exporters", []):
        jobs.append({"job_name": target["name"],
                     "static_configs": [{"targets": [target["address"]],
                                         "labels": {"os": target.get("os", "darwin")}}]})
    return {
        "defaultRules": {"rules": {"kubeScheduler": False, "kubeControllerManager": False}},
        "kubeScheduler": {"enabled": False}, "kubeControllerManager": {"enabled": False},
        "kubeEtcd": {"enabled": False}, "kubeProxy": {"enabled": False},
        "alertmanager": {"enabled": True, "alertmanagerSpec": {
            "resources": {"requests": {"cpu": "50m", "memory": "128Mi"},
                          "limits": {"memory": "256Mi"}}}},
        "prometheusOperator": {"resources": {"requests": {"cpu": "100m", "memory": "128Mi"},
                                            "limits": {"memory": "256Mi"}}},
        "grafana": {
            "admin": {"existingSecret": "grafana-admin", "userKey": "admin-user",
                      "passwordKey": "admin-password"},
            "persistence": {"enabled": True, "storageClassName": "local-path", "size": "2Gi"},
            "resources": {"requests": {"cpu": "100m", "memory": "256Mi"},
                          "limits": {"memory": "512Mi"}},
            "nodeSelector": {"ci.platform/persistent": "true"},
            "service": {"type": "ClusterIP"},
        },
        "prometheus": {"prometheusSpec": {
            "retention": "7d", "retentionSize": "10GB",
            "resources": {"requests": {"cpu": "500m", "memory": "1Gi"},
                          "limits": {"memory": "2Gi"}},
            "nodeSelector": {"ci.platform/persistent": "true"},
            "serviceMonitorSelectorNilUsesHelmValues": False,
            "podMonitorSelectorNilUsesHelmValues": False,
            "additionalScrapeConfigs": jobs,
            "storageSpec": {"volumeClaimTemplate": {"spec": {
                "storageClassName": "local-path", "accessModes": ["ReadWriteOnce"],
                "resources": {"requests": {"storage": "20Gi"}}}}},
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
    save(output / "monitoring.yaml", monitoring_values(cfg))
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
    for repo in repos:
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
            tree = gh_json(repo_scope + f"/git/trees/{sha}?recursive=1")
            if tree.get("truncated"):
                raise PlatformError("Truncated repository tree; inventory is incomplete.")
            for entry in tree["tree"]:
                if entry["type"] == "blob" and re.fullmatch(r"[.]github/workflows/[^/]+[.]ya?ml", entry["path"]):
                    blob = gh_json(repo_scope + "/git/blobs/" + entry["sha"])
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
    kube(state, "wait", "--for=condition=Ready", "node", "--all", "--timeout=180s")
    save(state / "deployment.json", {"profile": profile, "vm": cfg["vm_name"],
                                    "started_at": dt.datetime.now(dt.timezone.utc).isoformat()})


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


def monitor(cfg, profile, state):
    if profile != "full":
        raise PlatformError("Full monitoring requires the full profile; keep the 6 GiB pilot small.")
    check_deployment(cfg, profile, state)
    apply_object(state, namespace("monitoring"))
    # Existing password survives reruns and is never printed.
    secrets = json.loads(kube(state, "get", "secrets", "-n", "monitoring", "-o", "json", capture=True))
    if not any(s["metadata"]["name"] == "grafana-admin" for s in secrets["items"]):
        import secrets as secrets_module
        secret(state, "grafana-admin", "monitoring",
               {"admin-user": "admin", "admin-password": secrets_module.token_urlsafe(32)})
    output = render(cfg, profile, state)
    helm(state, "repo", "add", "prometheus-community", "https://prometheus-community.github.io/helm-charts")
    helm(state, "repo", "update", "prometheus-community")
    install_release(state, "ci-monitoring", "monitoring",
                    "prometheus-community/kube-prometheus-stack",
                    cfg["versions"]["monitoring"], output / "monitoring.yaml")
    for path in (ROOT / "monitoring").glob("*.json"):
        obj = json.loads(path.read_text())
        if obj.get("kind") == "ConfigMap":
            apply_object(state, obj)
        else:
            apply_object(state, obj)
    kube(state, "get", "pods", "-n", "monitoring")


def verify_canary(cfg, state, repository, run_id):
    identity(cfg)
    record = gh_json(f"repos/{repository}/actions/runs/{run_id}")
    if record["status"] != "completed" or record["conclusion"] != "success":
        raise PlatformError("Canary has not completed successfully.")
    jobs = gh_pages(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100", "jobs")
    expected = cfg["general_scale_set"]
    if not jobs or not all(expected in j.get("labels", []) and j["conclusion"] == "success" for j in jobs):
        raise PlatformError("Canary did not run successfully on the intended scale set.")
    # Require observable cleanup, not just a workflow success.
    for _ in range(30):
        pods = json.loads(kube(state, "get", "pods", "-n", "arc-runners",
                              "-l", "ci-platform-runner=true", "-o", "json", capture=True))
        if not pods["items"]:
            save(state / "canary-evidence.json", {
                "run_id": run_id, "url": record["html_url"], "scale_set": expected,
                "verified_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "ephemeral_cleanup": True})
            print("Canary success and ephemeral cleanup verified.")
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
    registry.add_argument("--token-file", type=Path, required=True)
    for name in ("preflight", "render", "start", "deploy-arc", "monitor"):
        child = sub.add_parser(name)
        child.add_argument("--profile", choices=["pilot", "full"], default="pilot")
        if name == "deploy-arc":
            child.add_argument("--app-file", type=Path, required=True)
    child = sub.add_parser("verify-canary")
    child.add_argument("--repository", required=True)
    child.add_argument("--run-id", type=int, required=True)
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
            if args.token_file.stat().st_mode & 0o077:
                raise PlatformError("Registry token file must be mode 0600.")
            if not cfg.get("image_pull_secret"):
                raise PlatformError("Configure image_pull_secret first.")
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
        elif args.command == "verify-canary":
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
                raise PlatformError("Invalid repository name.")
            verify_canary(cfg, state, args.repository, args.run_id)
        elif args.command == "dashboard":
            kube(state, "-n", "monitoring", "port-forward", "--address", "127.0.0.1",
                 "service/ci-monitoring-grafana", f"{args.port}:80", timeout=None)
        return 0
    except (PlatformError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

