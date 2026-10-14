#!/usr/bin/env python3
"""Stage the Studio pilot while preserving the second builder for rollback."""
import argparse
import fcntl
import importlib.util
import json
import os
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("runner_platform", ROOT / "platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
OLD_VM = "gh-build-2"
SLOT = "studio-build-2"
LABEL = "com.ghostnet.jit." + SLOT

# Freeze the listener before checking workers so it cannot start another job
# during the drain. A failed check resumes it inside the guest.
FREEZE = r"""set -euo pipefail
mapfile -t listeners < <(pgrep -x Runner.Listener || true)
[ "${#listeners[@]}" -eq 1 ] || { echo 'Expected exactly one runner listener.' >&2; exit 1; }
pid=${listeners[0]}
exe=$(readlink -f "/proc/$pid/exe")
expected=$(readlink -f "$1/bin/Runner.Listener")
[ "$exe" = "$expected" ] || { echo 'Listener directory does not match the slot.' >&2; exit 1; }
trap 'kill -CONT "$pid" 2>/dev/null || true' ERR
kill -STOP "$pid"
stopped=false
for attempt in {1..50}; do
  if grep -q '^State:.*T' "/proc/$pid/status"; then stopped=true; break; fi
  sleep 0.02
done
$stopped || { echo 'Listener did not pause.' >&2; false; }
if pgrep -x Runner.Worker >/dev/null || pgrep -P "$pid" >/dev/null; then
  echo 'An active build or runner child exists; leaving the builder running.' >&2
  false
fi
trap - ERR
printf '%s\n' "$pid"
"""

TERMINATE = r"""set -euo pipefail
pid=$1
if pgrep -x Runner.Worker >/dev/null; then
  echo 'A worker appeared; refusing shutdown.' >&2
  exit 1
fi
if [ -d "/proc/$pid" ]; then
  [ "$(cat "/proc/$pid/comm")" = Runner.Listener ] || exit 1
  kill -TERM "$pid"
  kill -CONT "$pid"
  for attempt in {1..60}; do
    [ -d "/proc/$pid" ] || exit 0
    sleep 0.5
  done
  echo 'Runner did not exit; VM remains running.' >&2
  exit 1
fi
"""


def guest(script, *args):
    return platform.run(["limactl", "shell", OLD_VM, "--", "sudo", "bash", "-s", "--", *args],
                        input_text=script, capture=True, timeout=90)


def slot_runners(runners):
    matches = [r for r in runners if r.get("name") == SLOT or r.get("name", "").startswith(SLOT + "-")]
    if len(matches) != 1:
        raise platform.PlatformError("Expected one live studio-build-2 registration; refusing drain.")
    if matches[0].get("busy"):
        raise platform.PlatformError("studio-build-2 is busy; wait for its build to finish and retry.")
    if matches[0].get("status") != "online":
        raise platform.PlatformError("studio-build-2 is not online; inspect it before draining.")
    return matches[0]


def services():
    output = platform.run(["launchctl", "list"], capture=True)
    found = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3:
            found[fields[2]] = int(fields[0]) if fields[0].isdigit() else None
    return found


def registration_list():
    return platform.gh_pages("orgs/ghostnet-labs/actions/runners?per_page=100", "runners")


def validate_slot(plist):
    data = plistlib.loads(plist.read_bytes())
    arguments = data.get("ProgramArguments", [])
    script = next((i for i, a in enumerate(arguments) if a.endswith("/jit-slot.sh")), None)
    if (data.get("Label") != LABEL or script is None or len(arguments) != script + 5
            or arguments[script + 1] != OLD_VM or arguments[script + 3] != SLOT):
        raise platform.PlatformError("LaunchAgent differs from the inspected slot; refusing drain.")
    directory = arguments[script + 2]
    if not directory.startswith("/home/runner/") or ".." in Path(directory).parts:
        raise platform.PlatformError("Unexpected guest runner directory.")
    return directory


def resume(plist, parent_pid=None, listener_pid=None):
    try:
        if listener_pid:
            guest('if [ -f "/proc/$1/comm" ] && [ "$(cat "/proc/$1/comm")" = Runner.Listener ]; then\n'
                  '  kill -CONT "$1"\nfi\n', str(listener_pid))
        elif parent_pid:
            # Interrupted SSH may lose the pause command's returned PID.
            # Resume only this slot's executable, without exposing its arguments.
            guest('set -e\nexpected=$(readlink -f "$1/bin/Runner.Listener")\n'
                  'for pid in $(pgrep -x Runner.Listener || true); do\n'
                  '  if [ "$(readlink -f "/proc/$pid/exe")" = "$expected" ]; then\n'
                  '    kill -CONT "$pid"\n  fi\ndone\n', validate_slot(plist))
    finally:
        # A guest connectivity failure must not leave the host loop paused.
        loaded = services()
        if parent_pid and loaded.get(LABEL) == parent_pid:
            try:
                os.kill(parent_pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        domain = f"gui/{os.getuid()}"
        platform.run(["launchctl", "enable", f"{domain}/{LABEL}"])
        if LABEL not in loaded:
            platform.run(["launchctl", "bootstrap", domain, plist])


def drain(state, plist):
    directory = validate_slot(plist)
    loaded = services()
    if any("watchdog" in label for label in loaded):
        raise platform.PlatformError("A watchdog is loaded. Configure its maintenance exclusion before draining.")
    parent = loaded.get(LABEL)
    if not parent:
        raise platform.PlatformError("The builder LaunchAgent has no process; inspect it before draining.")
    before = registration_list()
    registration = slot_runners(before)
    platform.save(state / "runner-inventory-before-drain.json", before)
    platform.save(state / "build2-drain.json", {"phase": "preparing", "runner": registration,
                                               "parent_pid": parent, "plist": str(plist)})
    listener = None
    try:
        os.kill(parent, signal.SIGSTOP)  # prevent another registration when this runner exits
        listener = int(guest(FREEZE, directory).strip())
        platform.save(state / "build2-drain.json", {"phase": "paused", "runner": registration,
                                                   "parent_pid": parent, "listener_pid": listener,
                                                   "plist": str(plist)})
        current = slot_runners(registration_list())
        if current["id"] != registration["id"]:
            raise platform.PlatformError("Registration changed during drain; refusing shutdown.")
        domain = f"gui/{os.getuid()}"
        platform.run(["launchctl", "disable", f"{domain}/{LABEL}"])
        os.kill(parent, signal.SIGCONT)  # it still waits on the paused guest listener
        platform.run(["launchctl", "bootout", f"{domain}/{LABEL}"], timeout=90)
        guest(TERMINATE, str(listener))
        listener = None
        platform.run(["limactl", "stop", OLD_VM], timeout=180)
    except BaseException:
        try:
            resume(plist, parent, listener)
        except BaseException:
            print("Drain recovery needs inspection; use the rollback command.", file=sys.stderr)
        raise
    platform.save(state / "build2-drain.json", {"phase": "stopped", "runner": registration,
                                               "plist": str(plist)})
    print("Second builder stopped; its disk and configuration are retained.", flush=True)


def configure(state):
    path = state / "config.json"
    if not path.exists():
        cfg = json.loads((ROOT / "config.example.json").read_text())
        cfg.update(expected_github_login="stupidmonk37", github_url="https://github.com/ghostnet-labs",
                   vm_name="ci-k3s", general_scale_set="ghostnet-linux-arm64",
                   heavy_scale_set="ghostnet-firmware-arm64")
        platform.save(path, cfg)
    cfg = platform.load_config(path)
    if (cfg["expected_github_login"] != "stupidmonk37" or cfg["github_url"] != "https://github.com/ghostnet-labs"
            or cfg["vm_name"] != "ci-k3s"):
        raise platform.PlatformError("Pilot configuration differs from this Studio migration.")
    return cfg


def prepare(cfg, state):
    for tool in ("gh", "limactl", "kubectl", "helm"):
        platform.command_exists(tool)
    platform.identity(cfg)
    platform.check_client_version(cfg)
    release = platform.gh_json("repos/k3s-io/k3s/releases/tags/" + cfg["versions"]["k3s"])
    if release.get("draft") or release.get("prerelease"):
        raise platform.PlatformError("Selected K3s release is not a stable published release.")
    assets = {a["name"] for a in release.get("assets", [])}
    if not {"k3s-arm64", "sha256sum-arm64.txt"} <= assets:
        raise platform.PlatformError("Pinned K3s ARM64 assets are unavailable.")
    loaded = services()
    if any("watchdog" in label for label in loaded):
        raise platform.PlatformError("Configure loaded watchdog maintenance before this migration.")
    memory = int(platform.run(["sysctl", "-n", "hw.memsize"], capture=True))
    if platform.run(["uname", "-m"], capture=True).strip() != "arm64":
        raise platform.PlatformError("Pilot requires Apple Silicon.")
    sleep_settings = platform.run(["pmset", "-g", "custom"], capture=True)
    if not any(line.split() == ["sleep", "0"] for line in sleep_settings.splitlines()):
        raise platform.PlatformError("Host system sleep must be disabled before deployment.")
    instances = platform.lima_state()
    old = next((vm for vm in instances if vm["name"] == OLD_VM), None)
    if not old:
        raise platform.PlatformError("Expected old builder VM is missing.")
    new = next((vm for vm in instances if vm["name"] == cfg["vm_name"]), None)
    if new:
        record = state / "build2-drain.json"
        if not record.exists() or json.loads(record.read_text()).get("phase") != "stopped":
            raise platform.PlatformError("An existing pilot VM lacks this command's drain record.")
        profile = cfg["pilot"]
        if (new["cpus"] != profile["cpus"] or new["memory"] != profile["memory_gib"] * platform.GIB
                or new["disk"] != profile["disk_gib"] * platform.GIB):
            raise platform.PlatformError("Existing pilot VM has a different allocation.")
    else:
        for port in (cfg["api_host_port"], cfg["ssh_host_port"]):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", port))
    planned = [dict(vm, status="Stopped") if vm["name"] == OLD_VM else vm for vm in instances]
    platform.capacity(cfg, cfg["pilot"], planned, memory, shutil.disk_usage(ROOT).free)
    output = platform.render(cfg, "pilot", state)
    platform.run(["limactl", "validate", output / "lima.yaml"])
    return old


def rollback(cfg, state, plist):
    record_path = state / "build2-drain.json"
    if not record_path.exists():
        raise platform.PlatformError("No managed drain record exists; refusing to alter VMs.")
    record = json.loads(record_path.read_text())
    instances = platform.lima_state()
    new = next((vm for vm in instances if vm["name"] == cfg["vm_name"]), None)
    if new and new["status"] == "Running":
        if (state / "deployment.json").exists():
            # ARC is not installed by this command, but refuse to stop a pilot
            # that has since been used for jobs by another deployment step.
            pods = json.loads(platform.kube(state, "get", "pods", "-A", "-o", "json", capture=True))
            if any(p["metadata"].get("labels", {}).get("ci-platform-runner") == "true"
                   for p in pods["items"]):
                raise platform.PlatformError("Pilot has runner pods; drain them before rollback.")
        platform.run(["limactl", "stop", cfg["vm_name"]], timeout=180)
    platform.run(["limactl", "start", "--tty=false", OLD_VM], timeout=600)
    resume(plist, record.get("parent_pid") if record["phase"] == "paused" else None,
           record.get("listener_pid") if record["phase"] == "paused" else None)
    platform.save(record_path, dict(record, phase="restored"))
    print("Old builder restored. Pilot disk retained. Verify its replacement JIT registration in GitHub.")


def repair_ports(cfg, state):
    platform.check_deployment(cfg, "pilot", state)
    pods = json.loads(platform.kube(state, "get", "pods", "-A", "-o", "json", capture=True))
    if any(p["metadata"]["namespace"] in ("arc-system", "arc-runners") for p in pods["items"]):
        raise platform.PlatformError("ARC is already running; drain it before restarting this pilot.")
    config = Path.home() / ".lima" / cfg["vm_name"] / "lima.yaml"
    backup = state / "lima-before-port-repair.yaml"
    if not backup.exists():
        backup.write_bytes(config.read_bytes())
        backup.chmod(0o600)
    platform.run(["limactl", "stop", cfg["vm_name"]], timeout=180)
    expression = ".portForwards=" + json.dumps(platform.port_forwards(cfg), separators=(",", ":"))
    platform.run(["limactl", "edit", "--tty=false", cfg["vm_name"], "--set", expression])
    platform.start(cfg, "pilot", state)
    platform.kube(state, "get", "pods", "-A")
    print("Port rules repaired and K3s system deployments ready.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "rollback", "repair-ports"), nargs="?", default="start")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        print("Run this command in the Studio's normal macOS Terminal.", file=sys.stderr)
        return 1
    state = ROOT / ".local"
    state.mkdir(mode=0o700, exist_ok=True)
    plist = Path.home() / "Library" / "LaunchAgents" / (LABEL + ".plist")
    with (state / "pilot.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            cfg = configure(state)
            if args.command == "rollback":
                rollback(cfg, state, plist)
                return 0
            if args.command == "repair-ports":
                repair_ports(cfg, state)
                return 0
            print("Checking tools, account, releases, capacity and Lima configuration…", flush=True)
            old = prepare(cfg, state)
            if old["status"] == "Running":
                drain(state, plist)
            else:
                record = state / "build2-drain.json"
                if not record.exists() or json.loads(record.read_text()).get("phase") != "stopped":
                    raise platform.PlatformError("Old VM stopped without this command's drain record; inspect it first.")
            print("Starting the 4 CPU / 6 GiB Kubernetes pilot…", flush=True)
            platform.start(cfg, "pilot", state)
            platform.kube(state, "get", "nodes", "-o", "wide")
            platform.kube(state, "get", "pods", "-A")
            print("Pilot is ready. ARC credentials and a canary are the next step.")
            return 0
        except (platform.PlatformError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            print(f"Stopped: {error}", file=sys.stderr)
            print("Rollback: python3 " + str(Path(__file__).resolve()) + " rollback", file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            print("Interrupted. Rerun start to resume, or run rollback to restore the old builder.", file=sys.stderr)
            return 130


if __name__ == "__main__":
    raise SystemExit(main())
