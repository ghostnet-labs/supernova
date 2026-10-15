#!/usr/bin/env python3
"""Complete the supported runner pilot and report remaining migration gates."""
import argparse
import datetime as dt
import fcntl
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("runner_platform_rollout", ROOT / "platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
host_spec = importlib.util.spec_from_file_location("runner_host_services", ROOT / "host-services.py")
host_services = importlib.util.module_from_spec(host_spec)
host_spec.loader.exec_module(host_services)
ACTIVE_STATES = ("queued", "in_progress", "waiting", "pending", "requested")
WORKERS = ('if pgrep -x Runner.Worker >/dev/null; then '
           'printf "busy\\n"; else result=$?; '
           '[ "$result" -eq 1 ] || exit "$result"; printf "idle\\n"; fi')


def lifecycle_evidence(cfg, state, repository):
    """Accept only this repository's observed cleanup evidence for all outcomes."""
    found = {}
    prefix = f"https://github.com/{repository}/actions/runs/"
    paths = sorted(state.glob("canary-evidence-*.json"))
    if (state / "canary-evidence.json").exists():
        paths.append(state / "canary-evidence.json")
    for path in paths:
        record = json.loads(path.read_text())
        run_id = record.get("run_id")
        if (isinstance(run_id, int) and record.get("url") == prefix + str(run_id)
                and record.get("scale_set") == cfg["general_scale_set"]
                and record.get("ephemeral_cleanup") is True and record.get("verified_at")):
            # The original success verifier predates expected_conclusion.
            conclusion = record.get("expected_conclusion", "success")
            if conclusion in ("success", "failure", "cancelled"):
                found[conclusion] = run_id
    missing = {"success", "failure", "cancelled"} - found.keys()
    if missing:
        raise platform.PlatformError("Missing lifecycle cleanup evidence: " + ", ".join(sorted(missing)))
    if len(set(found.values())) != 3:
        raise platform.PlatformError("Lifecycle outcomes must refer to three distinct runs.")
    return found


def real_workload(cfg, repository, run_id):
    record = platform.gh_json(f"repos/{repository}/actions/runs/{run_id}")
    if (record.get("status") != "completed" or record.get("conclusion") != "success"
            or record.get("repository", {}).get("full_name") != repository):
        raise platform.PlatformError("The real workload run is not a successful run in this repository.")
    jobs = platform.gh_pages(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100", "jobs")
    expected = cfg["general_scale_set"]
    selected = [job for job in jobs if expected in job.get("labels", [])]
    if not selected or not all(job.get("conclusion") == "success" and job.get("runner_name")
                               for job in selected):
        raise platform.PlatformError("No successful real workload job executed on the intended ARC scale set.")
    if record.get("path") != ".github/workflows/ci.yml" or not any(
            job.get("name") == "Lint and test on Ubuntu" and any(
                step.get("name") == "Run ./setup.sh --test" and step.get("conclusion") == "success"
                for step in job.get("steps", [])) for job in selected):
        raise platform.PlatformError("The full Linux CI suite must pass; a small canary is not representative workload proof.")
    return {"run_id": run_id, "url": record["html_url"], "head_sha": record["head_sha"],
            "arc_jobs": [job["id"] for job in selected]}


def repositories(cfg):
    scope = platform.github_path(cfg["github_url"])
    if scope.startswith("repos/"):
        return [scope.removeprefix("repos/")]
    # Include every organization repository so an old route cannot hide a queue.
    return sorted(repo["full_name"] for repo in platform.gh_pages(scope + "/repos?per_page=100&type=all")
                  if not repo.get("archived"))


def collect(cfg, state):
    platform.identity(cfg)
    vms = platform.lima_state()
    scope = platform.github_path(cfg["github_url"])
    runners = platform.gh_pages(scope + "/actions/runners?per_page=100", "runners")
    active = []
    repos = repositories(cfg)
    for repo in repos:
        for status in ACTIVE_STATES:
            runs = platform.gh_pages(f"repos/{repo}/actions/runs?status={status}&per_page=100", "workflow_runs")
            active.extend({"repository": repo, "id": run["id"], "status": run["status"]} for run in runs)
    workers = {}
    for vm in vms:
        if vm["status"] == "Running" and vm["name"] != cfg["vm_name"]:
            workers[vm["name"]] = platform.run(
                ["limactl", "shell", vm["name"], "--", "bash", "-lc", WORKERS],
                capture=True, timeout=30).strip()
    workers["host"] = platform.run(["/bin/bash", "-lc", WORKERS], capture=True, timeout=30).strip()
    pods = json.loads(platform.kube(state, "get", "pods", "-n", "arc-runners", "-l",
                                    "ci-platform-runner=true", "-o", "json", capture=True))
    snapshot = {"collected_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "vms": [{key: vm.get(key) for key in ("name", "status", "cpus", "memory", "disk")}
                        for vm in vms],
                "runners": [{key: runner.get(key) for key in ("id", "name", "status", "busy", "os")}
                            for runner in runners],
                "repositories": repos, "active_runs": active, "workers": workers,
                "launch_agents": sorted(host_services.loaded()),
                "arc_runner_pods": [pod["metadata"]["name"] for pod in pods["items"]]}
    platform.save(state / "rollout-inventory.json", snapshot)
    return snapshot


def require_idle(snapshot):
    if any(runner.get("busy") for runner in snapshot["runners"]):
        raise platform.PlatformError("GitHub reports a busy runner; retry after it finishes.")
    if snapshot["active_runs"]:
        blockers = "\n".join(f"{run.get('repository', 'unknown repository')} run {run['id']} ({run.get('status', 'unknown')})"
                             for run in snapshot["active_runs"])
        raise platform.PlatformError("GitHub has queued, running or waiting workflows; retry after they finish.\n" + blockers)
    if any(value != "idle" for value in snapshot["workers"].values()):
        raise platform.PlatformError("A Runner.Worker exists or guest worker state is unknown; refusing changes.")
    if snapshot["arc_runner_pods"]:
        raise platform.PlatformError("ARC runner pods still exist; retry after cleanup.")


def remaining_gates(state=None, snapshot=None):
    gates = [
        {"id": "legacy-linux-retirement", "status": "blocked",
         "requires": "Inventory and migrate every legacy Linux workflow route; freeze each JIT listener, "
                     "recheck GitHub queues and guest workers, then retire slots with rollback records."},
        {"id": "firmware-migration", "status": "retained_in_existing_vm",
         "requires": "Keep the existing isolated firmware VM monitored and its current route available. "
                     "A representative build is required only before replacing that VM or changing its route."},
        {"id": "macos-vm-migration", "status": "blocked",
         "requires": "Provision a compatible macOS guest with Xcode and isolated credentials, pass the "
                     "Swift/build suite and lifecycle cleanup, then drain native macOS runners."},
        {"id": "pro-migration", "status": "deferred_by_user",
         "requires": "Resume the deferred Pro host work and inspect its capacity before provisioning."},
    ]
    if state is not None and snapshot is not None:
        record = state / "linux-retirement.json"
        expected = {f"com.ghostnet.jit.studio-ubuntu-{index}" for index in range(1, 6)}
        if record.exists():
            data = json.loads(record.read_text())
            stopped = any(vm["name"] == "gh-ubuntu" and vm["status"] == "Stopped" for vm in snapshot["vms"])
            unloaded = not (expected | {"com.ghostnet.lima-gh-ubuntu"}) & set(snapshot.get("launch_agents", []))
            if (data.get("phase") == "stopped" and data.get("vm") == "gh-ubuntu" and stopped and unloaded
                    and {slot.get("label") for slot in data.get("slots", [])} == expected):
                gates = [gate for gate in gates if gate["id"] != "legacy-linux-retirement"]
    return gates


def install_guest_exporters(cfg, state):
    guest_spec = importlib.util.spec_from_file_location("runner_guest_exporters", ROOT / "guest-exporters.py")
    guest = importlib.util.module_from_spec(guest_spec)
    guest_spec.loader.exec_module(guest)
    try:
        return guest.install(cfg, state)
    except guest.platform.PlatformError as error:
        raise platform.PlatformError(str(error)) from error


def complete(cfg, profile, state, repository, validation_run, config_path=None):
    lifecycle = lifecycle_evidence(cfg, state, repository)
    workload = real_workload(cfg, repository, validation_run)
    snapshot = collect(cfg, state)
    platform.check_deployment(cfg, profile, state)
    platform.preflight(cfg, cfg[profile])
    platform.save(state / "rollout-progress.json", {"phase": "installing_monitoring", "profile": profile,
                                                  "lifecycle_runs": lifecycle, "workload": workload})
    # Monitoring is safe during builds: no VM, listener or workflow route changes.
    # Retirement commands must separately enforce require_idle immediately before draining.
    cfg = host_services.install(cfg, state, snapshot.get("repositories", [repository]))
    cfg = install_guest_exporters(cfg, state)
    host_services.atomic(config_path or state / "config.json", (json.dumps(cfg, indent=2) + "\n").encode())
    # monitor performs an atomic, readiness-checked Helm upgrade and verifies scrapes.
    # It does not resize, stop or delete any VM or disable any legacy runner.
    platform.monitor(cfg, profile, state)
    grafana_url = host_services.grafana_access(state)
    result = {"phase": "supported_pilot_complete", "migration_complete": False,
              "monitoring": "verified", "grafana_url": grafana_url,
              "profile": profile, "lifecycle_runs": lifecycle,
              "workload": workload, "gates": remaining_gates(state, snapshot),
              "completed_at": dt.datetime.now(dt.timezone.utc).isoformat()}
    platform.save(state / "rollout-progress.json", result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Examples:\n  rollout.py status\n  rollout.py run --repository acme/toolbox --validation-run 12345\n"
        "Environment: Run in the macOS host terminal with gh, limactl, kubectl and helm on PATH."),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("status", "run"))
    parser.add_argument("--config", type=Path, default=ROOT / ".local/config.json")
    parser.add_argument("--profile", choices=("pilot", "full"), default="pilot")
    parser.add_argument("--repository", help="Repository containing the canaries and real workload")
    parser.add_argument("--validation-run", type=int, help="Successful representative ARC workload run ID")
    args = parser.parse_args(argv)
    if args.command == "run" and (not args.repository or not args.validation_run):
        parser.error("run requires --repository and --validation-run")
    if args.repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("--repository must be OWNER/REPO")
    state = args.config.resolve().parent
    try:
        cfg = platform.load_config(args.config)
        if args.command == "status":
            print(json.dumps(collect(cfg, state), indent=2))
            return 0
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (state / "rollout.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("Verifying lifecycle evidence, real CI, queues, workers and capacity…", flush=True)
            result = complete(cfg, args.profile, state, args.repository, args.validation_run, args.config)
        print(json.dumps(result, indent=2))
        print("Monitoring verified. Remaining migration gates are recorded above; no legacy VM was stopped.")
        return 2
    except (platform.PlatformError, host_services.platform.PlatformError,
            OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Rollout stopped: {error}", file=sys.stderr)
        print("Existing runner services and VM disks are retained. Inspect .local/rollout-progress.json before retrying.",
              file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted. Existing VM disks and legacy runner services are retained; rerun to resume.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
