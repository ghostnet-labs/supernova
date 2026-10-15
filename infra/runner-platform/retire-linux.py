#!/usr/bin/env python3
"""Retire the five legacy Linux slots, keeping their VM and rollback configuration."""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import signal
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("retire_rollout", ROOT / "rollout.py")
rollout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollout)
platform = rollout.platform
VM = "gh-ubuntu"
SLOTS = tuple(f"studio-ubuntu-{n}" for n in range(1, 6))
LABELS = tuple("com.ghostnet.jit." + slot for slot in SLOTS)
AUTOSTART = "com.ghostnet.lima-gh-ubuntu"
RECORD = "linux-retirement.json"
CI_EXPRESSION = "${{ github.event_name == 'workflow_dispatch' && inputs.linux_runner || 'ubuntu-latest' }}"

# No process arguments or environment are emitted: those can contain credentials.
# Freeze every listener in one guest transaction; resume every paused process on error.
GUEST = r'''import json, os, signal, sys, time
from pathlib import Path
action, payload = sys.argv[1], json.loads(sys.argv[2])
def processes(name):
    return [int(p.name) for p in Path('/proc').iterdir() if p.name.isdigit()
            and (p / 'comm').exists() and (p / 'comm').read_text().strip() == name]
def identity(pid):
    p = Path('/proc') / str(pid)
    return {'pid': pid, 'exe': str((p / 'exe').resolve()),
            'started': (p / 'stat').read_text().rsplit(')', 1)[1].split()[19]}
def matches(item):
    try: return identity(item['pid']) == item
    except (FileNotFoundError, ProcessLookupError): return False
def idle():
    if processes('Runner.Worker'): raise RuntimeError('A runner worker exists; retry after completion.')
    for pid in processes('Runner.Listener'):
        children = Path('/proc') / str(pid) / 'task' / str(pid) / 'children'
        if children.read_text().strip(): raise RuntimeError('A listener has children; refusing retirement.')
def checked():
    current = [identity(pid) for pid in processes('Runner.Listener')]
    expected = {str((Path(d) / 'bin/Runner.Listener').resolve()) for d in payload['directories']}
    if any(item['exe'] not in expected for item in current):
        raise RuntimeError('An unexpected listener exists; refusing retirement.')
    return current, expected
if action == 'resume':
    current, expected = checked()
    for item in current: os.kill(item['pid'], signal.SIGCONT)
elif action == 'freeze':
    paused = []
    try:
        idle()
        current, expected = checked()
        if len(current) != 5 or {i['exe'] for i in current} != expected:
            raise RuntimeError('Expected exactly the five inspected listeners.')
        for item in current:
            if not matches(item): raise RuntimeError('Listener identity changed.')
            os.kill(item['pid'], signal.SIGSTOP)
            paused.append(item)
        for attempt in range(100):
            if all(matches(i) and '\nState:\tT' in (Path('/proc') / str(i['pid']) / 'status').read_text()
                   for i in paused): break
            time.sleep(.02)
        else: raise RuntimeError('Listeners did not pause.')
        idle()
        print(json.dumps(paused))
    except BaseException:
        for item in paused:
            if matches(item): os.kill(item['pid'], signal.SIGCONT)
        raise
elif action in ('check', 'terminate', 'empty'):
    idle()
    current, expected = checked()
    records = payload.get('listeners', [])
    if any(item not in records for item in current): raise RuntimeError('A new listener appeared.')
    if action == 'check' and (current != records and sorted(current, key=lambda i:i['pid']) != sorted(records, key=lambda i:i['pid'])):
        raise RuntimeError('A listener disappeared during retirement.')
    if action == 'check':
        for item in current:
            if '\nState:\tT' not in (Path('/proc') / str(item['pid']) / 'status').read_text():
                raise RuntimeError('A listener resumed during retirement.')
    if action == 'terminate':
        for item in current:
            if not matches(item): raise RuntimeError('Listener identity changed.')
            os.kill(item['pid'], signal.SIGTERM)
            os.kill(item['pid'], signal.SIGCONT)
        for attempt in range(120):
            idle()
            if not processes('Runner.Listener'): break
            time.sleep(.25)
        else: raise RuntimeError('Listeners did not exit; VM remains running.')
    if action == 'empty' and current: raise RuntimeError('A listener remains; VM remains running.')
else: raise RuntimeError('Unknown guest action.')
'''


def durable(path, value):
    """Publish the recovery record atomically before changing host or guest state."""
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        os.fchmod(output.fileno(), 0o600)
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def guest(action, record):
    payload = {"directories": [slot["directory"] for slot in record["slots"]],
               "listeners": record.get("listeners", [])}
    return platform.run(["limactl", "shell", VM, "--", "sudo", "python3", "-c", GUEST,
                         action, json.dumps(payload)], capture=True, timeout=90)


def services():
    result = {}
    for line in platform.run(["launchctl", "list"], capture=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            result[fields[2]] = int(fields[0]) if fields[0].isdigit() else None
    return result


def process_started(pid):
    value = platform.run(["ps", "-p", str(pid), "-o", "lstart="], capture=True).strip()
    if not value:
        raise platform.PlatformError("The inspected host process exited.")
    return value


def signal_parent(slot, sig):
    if services().get(slot["label"]) != slot["pid"] or process_started(slot["pid"]) != slot["started"]:
        raise platform.PlatformError("Host JIT process identity changed; refusing to signal it.")
    os.kill(slot["pid"], sig)


def inspect_slots(home):
    loaded = services()
    if any("watchdog" in label for label in loaded):
        raise platform.PlatformError("A watchdog is loaded; configure maintenance exclusion first.")
    slots = []
    for label, slot in zip(LABELS, SLOTS):
        path = home / "Library/LaunchAgents" / (label + ".plist")
        data = plistlib.loads(path.read_bytes())
        args = data.get("ProgramArguments", [])
        index = next((i for i, arg in enumerate(args) if arg.endswith("/jit-slot.sh")), None)
        if (data.get("Label") != label or index is None or len(args) != index + 5
                or args[index + 1] != VM or args[index + 3] != slot
                or set(args[index + 4].split(",")) != {"self-hosted", "ARM64", "Linux"}):
            raise platform.PlatformError("Unexpected Linux slot LaunchAgent: " + label)
        directory = args[index + 2]
        if not directory.startswith("/home/runner/") or ".." in Path(directory).parts:
            raise platform.PlatformError("Unexpected Linux slot guest directory.")
        pid = loaded.get(label)
        if not pid:
            raise platform.PlatformError("The expected Linux slot has no host process: " + label)
        actual = shlex.split(platform.run(["ps", "-ww", "-p", str(pid), "-o", "command="], capture=True))
        if actual != args:
            raise platform.PlatformError("The host process differs from its LaunchAgent: " + label)
        slots.append({"label": label, "plist": str(path), "directory": directory,
                      "pid": pid, "started": process_started(pid)})
    if len({slot["directory"] for slot in slots}) != 5:
        raise platform.PlatformError("Linux slots do not have five distinct directories.")
    path = home / "Library/LaunchAgents" / (AUTOSTART + ".plist")
    auto = plistlib.loads(path.read_bytes())
    args = auto.get("ProgramArguments", [])
    if (auto.get("Label") != AUTOSTART or AUTOSTART not in loaded or len(args) != 3
            or Path(args[0]).name != "limactl" or args[1:] != ["start", VM]):
        raise platform.PlatformError("Unexpected legacy VM autostart LaunchAgent.")
    return slots, {"label": AUTOSTART, "plist": str(path), "loaded": AUTOSTART in loaded}


def input_choices(document, name):
    value = document.get("on", {}).get("workflow_dispatch", {}).get("inputs", {}).get(name, {})
    options = value.get("options")
    if (value.get("type") != "choice" or not isinstance(options, list) or not options
            or any(not isinstance(option, str) or "${{" in option for option in options)
            or value.get("default") not in options):
        raise platform.PlatformError("Runner expression needs a closed, defaulted choice input: " + name)
    return options


def route_labels(route, document):
    if isinstance(route, str) and route == CI_EXPRESSION:
        return [[choice] for choice in input_choices(document, "linux_runner")] + [["ubuntu-latest"]]
    if isinstance(route, str):
        match = re.fullmatch(r"\$\{\{\s*inputs[.]([A-Za-z_][A-Za-z_0-9]*)\s*\}\}", route)
        if match:
            return [[choice] for choice in input_choices(document, match[1])]
        if "${{" in route:
            raise platform.PlatformError("Unmapped dynamic runs-on expression.")
        return [[route]]
    if isinstance(route, list) and route and all(isinstance(label, str) and "${{" not in label for label in route):
        return [route]
    if isinstance(route, dict) and set(route) == {"labels"}:
        return route_labels(route["labels"], document)
    raise platform.PlatformError("Unmapped runs-on structure or runner group.")


def workflow_routes(workflows, legacy_labels):
    blockers = []
    for entry in workflows:
        where = f"{entry['repository']}@{entry['branch']}:{entry['path']}"
        try:
            document = json.loads(platform.run(["yq", "-o=json", ".", "-"],
                                               input_text=entry["content"], capture=True))
            if not isinstance(document, dict) or not isinstance(document.get("jobs"), dict):
                raise platform.PlatformError("Workflow jobs cannot be inspected.")
            for job_id, job in document["jobs"].items():
                if "uses" in job:
                    raise platform.PlatformError("Reusable workflow routing needs an explicit audit: " + job_id)
                for labels in route_labels(job.get("runs-on"), document):
                    lower = {label.lower() for label in labels}
                    if any(lower <= known for known in legacy_labels) or any(
                            label.lower().startswith("studio-ubuntu-") for label in labels):
                        blockers.append(where + ":" + job_id + " still routes to legacy Linux")
        except (platform.PlatformError, ValueError, KeyError, TypeError) as error:
            blockers.append(where + ": " + str(error))
    if blockers:
        raise platform.PlatformError("Retirement workflow blockers:\n" + "\n".join(blockers))


def registrations(cfg):
    scope = platform.github_path(cfg["github_url"])
    rows = platform.gh_pages(scope + "/actions/runners?per_page=100", "runners")
    result = []
    for slot in SLOTS:
        matches = [row for row in rows if row["name"] == slot or row["name"].startswith(slot + "-")]
        if len(matches) != 1 or matches[0].get("busy") or matches[0].get("status") != "online":
            raise platform.PlatformError("Expected one online, idle registration for " + slot)
        result.append(matches[0])
    return result


def open_pr_workflows(cfg, workflows):
    """Include reachable open PR heads, including fork heads absent from branch lists."""
    result = list(workflows)
    seen = {(entry["repository"], entry["commit"]) for entry in workflows}
    for repository in rollout.repositories(cfg):
        pulls = platform.gh_pages(f"repos/{repository}/pulls?state=open&per_page=100")
        for pull in pulls:
            head = pull.get("head", {})
            source = (head.get("repo") or {}).get("full_name")
            sha = head.get("sha")
            if not source or not sha:
                raise platform.PlatformError("An open PR head cannot be inspected in " + repository)
            if (source, sha) in seen:
                continue
            seen.add((source, sha))
            scope = "repos/" + source
            tree = platform.gh_json(scope + f"/git/trees/{sha}?recursive=1")
            if tree.get("truncated"):
                raise platform.PlatformError("An open PR workflow tree is truncated in " + repository)
            for entry in tree["tree"]:
                if entry["type"] == "blob" and re.fullmatch(r"[.]github/workflows/[^/]+[.]ya?ml", entry["path"]):
                    blob = platform.gh_json(scope + "/git/blobs/" + entry["sha"])
                    result.append({"repository": repository, "branch": f"pull/{pull['number']}/head",
                                   "commit": sha, "path": entry["path"],
                                   "content": base64.b64decode(blob["content"]).decode()})
    return result


def gates(cfg, state, repository, run_id):
    rollout.lifecycle_evidence(cfg, state, repository)
    workload = rollout.real_workload(cfg, repository, run_id)
    if not workload.get("arc_jobs"):
        raise platform.PlatformError("No successful real Linux workload evidence.")
    run = platform.gh_json(f"repos/{repository}/actions/runs/{run_id}")
    jobs = platform.gh_pages(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100", "jobs")
    full_jobs = [job for job in jobs if job["id"] in workload["arc_jobs"]
                 and job.get("name") == "Lint and test on Ubuntu"
                 and any(step.get("name") == "Run ./setup.sh --test" and step.get("conclusion") == "success"
                         for step in job.get("steps", []))]
    if run.get("path") != ".github/workflows/ci.yml" or not full_jobs:
        raise platform.PlatformError("The validation run must include the complete Linux repository suite on ARC.")
    # Recheck actual cluster state, including collector scrapes, rather than trusting an old report.
    platform.verify_monitoring(cfg, state)
    rollout.require_idle(rollout.collect(cfg, state))
    return workload


def preflight(cfg, state, repository, run_id, home):
    gates(cfg, state, repository, run_id)
    platform.inventory(cfg, state)
    rows = registrations(cfg)
    workflows = open_pr_workflows(cfg, json.loads((state / "workflow-inventory.json").read_text()))
    workflow_routes(workflows, [{label["name"].lower() for label in row["labels"]} for row in rows])
    slots, autostart = inspect_slots(home)
    vm = next((vm for vm in platform.lima_state() if vm["name"] == VM), None)
    if not vm or vm["status"] != "Running" or vm["memory"] != 6 * platform.GIB:
        raise platform.PlatformError("Expected the running legacy 6 GiB Linux VM.")
    return {"phase": "prepared", "vm": VM, "memory": vm["memory"], "slots": slots,
            "autostart": autostart, "registration_ids": [row["id"] for row in rows],
            "repository": repository, "validation_run": run_id,
            "prepared_at": dt.datetime.now(dt.timezone.utc).isoformat()}


def restore_services(record):
    domain = f"gui/{os.getuid()}"
    errors = []
    for service in [*record["slots"], record["autostart"]]:
        try:
            platform.run(["launchctl", "enable", f"{domain}/{service['label']}"])
            if service["label"] not in services() and service.get("loaded", True):
                platform.run(["launchctl", "bootstrap", domain, service["plist"]])
        except BaseException as error:
            errors.append(str(error))
    if errors:
        raise platform.PlatformError("Service recovery needs inspection: " + "; ".join(errors))


def recover(record):
    errors = []
    try:
        guest("resume", record)
    except BaseException as error:
        errors.append(str(error))
    finally:
        for slot in record["slots"]:
            try:
                if services().get(slot["label"]) == slot["pid"]:
                    signal_parent(slot, signal.SIGCONT)
            except ProcessLookupError:
                pass
            except BaseException as error:
                errors.append(str(error))
        try:
            restore_services(record)
        except BaseException as error:
            errors.append(str(error))
    if errors:
        raise platform.PlatformError("Retirement recovery needs inspection: " + "; ".join(errors))


def retire(cfg, state, repository, run_id, home):
    path = state / RECORD
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get("phase") == "stopped":
            vm = next((vm for vm in platform.lima_state() if vm["name"] == VM), None)
            if vm and vm["status"] == "Stopped" and not (set(LABELS) | {AUTOSTART}) & services().keys():
                print("Legacy Linux VM is already retired; disk and configuration retained.")
                return
        if previous.get("phase") != "restored":
            raise platform.PlatformError("An incomplete or changed retirement exists; run rollback before retrying.")
    record = preflight(cfg, state, repository, run_id, home)
    durable(path, record)
    try:
        for slot in record["slots"]:
            signal_parent(slot, signal.SIGSTOP)
        record["listeners"] = json.loads(guest("freeze", record))
        record["phase"] = "paused"
        durable(path, record)
        rollout.require_idle(rollout.collect(cfg, state))
        if [row["id"] for row in registrations(cfg)] != record["registration_ids"]:
            raise platform.PlatformError("Legacy registrations changed during retirement.")
        guest("check", record)
        domain = f"gui/{os.getuid()}"
        for service in [*record["slots"], record["autostart"]]:
            platform.run(["launchctl", "disable", f"{domain}/{service['label']}"])
        record["phase"] = "disabled"
        durable(path, record)
        for slot in record["slots"]:
            signal_parent(slot, signal.SIGCONT)
        for service in [*record["slots"], record["autostart"]]:
            if service["label"] in services():
                platform.run(["launchctl", "bootout", f"{domain}/{service['label']}"], timeout=90)
        guest("terminate", record)
        rollout.require_idle(rollout.collect(cfg, state))
        guest("empty", record)
        if (set(LABELS) | {AUTOSTART}) & services().keys():
            raise platform.PlatformError("A legacy LaunchAgent reappeared; VM remains running.")
        platform.run(["limactl", "stop", VM], timeout=180)
        record["phase"] = "stopped"
        durable(path, record)
    except BaseException:
        record["phase"] = "recovery_required"
        durable(path, record)
        try:
            recover(record)
            record["phase"] = "restored"
            durable(path, record)
        except BaseException:
            print("Recovery needs inspection; run retire-linux.py rollback.", file=sys.stderr)
        raise
    print("Legacy Linux VM stopped. Five JIT slots and its autostart disabled; disk retained.")


def rollback(cfg, state):
    path = state / RECORD
    if not path.exists():
        raise platform.PlatformError("No retirement recovery record exists.")
    record = json.loads(path.read_text())
    if record.get("vm") != VM or tuple(slot["label"] for slot in record["slots"]) != LABELS:
        raise platform.PlatformError("Recovery record does not name the exact legacy Linux slots.")
    if record["phase"] == "restored":
        print("Legacy Linux services were already restored.")
        return
    instances = platform.lima_state()
    old = next((vm for vm in instances if vm["name"] == VM), None)
    if not old or old["memory"] != record["memory"]:
        raise platform.PlatformError("Legacy VM allocation changed; inspect recovery before restart.")
    if old["status"] != "Running":
        running = sum(vm["memory"] for vm in instances if vm["status"] == "Running")
        host_memory = int(platform.run(["sysctl", "-n", "hw.memsize"], capture=True))
        if running + old["memory"] + 8 * platform.GIB > host_memory:
            # A guest name alone is not ownership or authorization to stop it.
            # Only a managed record may release a new macOS guest's allocation.
            mac_path = state / "ci-macos-created.json"
            mac = json.loads(mac_path.read_text()) if mac_path.exists() else {}
            candidate = next((vm for vm in instances if vm["name"] == mac.get("vm_name")
                              and vm["name"] == "ci-macos" and vm["status"] == "Running"), None)
            if (not candidate or mac.get("schema_version") != 1
                    or mac.get("created_by") != "runner-platform-macos" or not mac.get("created_at")
                    or not managed_macos_configuration(state, mac, candidate)
                    or mac.get("memory_gib") != 6 or candidate["memory"] != 6 * platform.GIB
                    or mac.get("cpus") != 2 or candidate.get("cpus") != 2
                    or candidate.get("disk") != 80 * platform.GIB
                    or running - candidate["memory"] + old["memory"] + 8 * platform.GIB > host_memory):
                raise platform.PlatformError("Rollback exceeds the 8 GiB host reserve; drain and stop the new guest first.")
            rollout.require_idle(rollout.collect(cfg, state))
            platform.run(["limactl", "stop", candidate["name"]], timeout=180)
            durable(mac_path, dict(mac, stopped_for_linux_rollback=True))
        platform.run(["limactl", "start", "--tty=false", VM], timeout=600)
    recover(record)
    durable(path, dict(record, phase="restored"))
    print("Legacy Linux VM and exact original services restored; all disks retained.")


def managed_macos_configuration(state, record, candidate):
    if not candidate:
        return False
    path = Path(record.get("configuration", ""))
    if path != (state / "ci-macos.yaml").resolve():
        return False
    try:
        for owned in (path, state / "ci-macos-created.json"):
            info = owned.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) & 0o077):
                return False
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != record.get("configuration_sha256"):
            return False
        saved = json.loads(content)
        live = candidate.get("config", {})
        return all(live.get(key) == saved.get(key) for key in
                   ("os", "arch", "mounts", "plain", "ssh", "images")) and saved.get("os") == "Darwin"
    except (OSError, ValueError):
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n  retire-linux.py plan --repository acme/toolbox --validation-run 123\n"
               "  retire-linux.py retire --repository acme/toolbox --validation-run 123\n"
               "  retire-linux.py rollback\nEnvironment: Run in the normal macOS host terminal; gh, limactl, yq and kubectl are required.")
    parser.add_argument("command", choices=("plan", "retire", "rollback"))
    parser.add_argument("--config", type=Path, default=ROOT / ".local/config.json")
    parser.add_argument("--repository", help="Repository containing lifecycle and full Linux workload evidence")
    parser.add_argument("--validation-run", type=int, help="Successful full Linux workload run on ARC")
    args = parser.parse_args(argv)
    if args.command != "rollback" and (not args.repository or not args.validation_run):
        parser.error("plan and retire require --repository and --validation-run")
    if args.repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("--repository must be OWNER/REPO")
    try:
        if sys.platform != "darwin":
            raise platform.PlatformError("Run in the normal macOS host terminal.")
        cfg = platform.load_config(args.config)
        if cfg["github_url"] != "https://github.com/ghostnet-labs":
            raise platform.PlatformError("This helper is scoped to the inspected Studio organization.")
        platform.identity(cfg)
        state = args.config.resolve().parent
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (state / "pilot.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.command == "rollback":
                rollback(cfg, state)
            elif args.command == "retire":
                retire(cfg, state, args.repository, args.validation_run, Path.home())
            else:
                record = preflight(cfg, state, args.repository, args.validation_run, Path.home())
                print(json.dumps(record, indent=2))
        return 0
    except (platform.PlatformError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Linux retirement stopped: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted; inspect the recovery record and run rollback before retrying.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
