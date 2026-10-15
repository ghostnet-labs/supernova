#!/usr/bin/env python3
"""Start an isolated macOS VM or run one foreground JIT canary in an existing guest."""
import argparse
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("macos_vm_preflight", ROOT / "preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)
MARKER_CHECK = r'''set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]
[[ -f /etc/ci-runner-vm && ! -L /etc/ci-runner-vm ]]
[[ "$(cat /etc/ci-runner-vm)" == runner-platform-macos-v1 ]]
[[ "$(stat -f '%u' /etc/ci-runner-vm)" == 0 ]]
[[ "$(stat -f '%Lp' /etc/ci-runner-vm)" =~ ^(400|444|600|644)$ ]]
'''
TOOLS_CHECK = MARKER_CHECK + r'''
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for tool in swift git python3 yq; do command -v "$tool" >/dev/null; done
swift --version >/dev/null
yq --version | grep -q mikefarah
root="$HOME/actions-runner"
[[ ! -L "$root" && ! -e "$root/.runner" && ! -e "$root/.credentials" ]]
if pgrep -x Runner.Worker >/dev/null || pgrep -x Runner.Listener >/dev/null; then
  printf '%s\n' 'An existing guest runner is active; refusing a second slot.' >&2
  exit 1
fi
'''
INSTALL = TOOLS_CHECK + r'''
version=$1 digest=$2
mkdir -p "$root"
chmod 0700 "$root"
cd "$root"
asset="actions-runner-osx-arm64-${version}.tar.gz"
curl -fsSL "https://github.com/actions/runner/releases/download/v${version}/$asset" -o "$asset"
printf '%s  %s\n' "$digest" "$asset" | shasum -a 256 --check >/dev/null
tar -xzf "$asset"
rm -f "$asset"
'''
ONE_JOB = MARKER_CHECK + r'''
cd "$HOME/actions-runner"
cleanup() {
  unset ACTIONS_RUNNER_INPUT_JITCONFIG
  rm -rf -- _work
  rm -f -- .runner .credentials .credentials_rsaparams
}
trap cleanup EXIT
export ACTIONS_RUNNER_INPUT_JITCONFIG="$(cat)"
[[ -n "$ACTIONS_RUNNER_INPUT_JITCONFIG" ]]
./run.sh
'''
CLEANUP_CHECK = MARKER_CHECK + r'''
root="$HOME/actions-runner"
[[ ! -e "$root/_work" && ! -e "$root/.runner" && ! -e "$root/.credentials" ]]
if pgrep -x Runner.Worker >/dev/null || pgrep -x Runner.Listener >/dev/null; then exit 1; fi
'''


def command(args, *, data=None, capture=True, timeout=30):
    return subprocess.run(args, input=data, text=True, check=True, capture_output=capture, timeout=timeout)


def guest(vm, script, *args, data=None, capture=True, timeout=30):
    return command(["limactl", "shell", vm, "--", "bash", "-lc", script, "runner-platform", *args],
                   data=data, capture=capture, timeout=timeout)


def observe_guest(name):
    host, vms = preflight.inspect_host()
    if host["errors"]:
        raise ValueError("Host inventory is not observable: " + "; ".join(host["errors"]))
    if host.get("memory_bytes", 0) < sum(row["memory"] for row in vms if row["status"] == "Running") + 8 * preflight.GIB:
        raise ValueError("Running VM allocations leave less than the 8 GiB host reserve")
    raw = [json.loads(line) for line in preflight.read_command(["limactl", "list", "--json"]).splitlines() if line.strip()]
    selected = [row for row in raw if row.get("name") == name]
    if len(selected) != 1:
        raise ValueError("Expected exactly one existing guest with the selected name")
    vm = selected[0]
    cfg = vm.get("config", {})
    ssh = cfg.get("ssh", {})
    if (vm.get("status") != "Running" or cfg.get("os") != "Darwin"
            or cfg.get("arch") != "aarch64" or cfg.get("mounts")
            or cfg.get("plain") is not True or ssh.get("forwardAgent") is not False
            or ssh.get("loadDotSSHPubKeys") is not False or cfg.get("propagateProxyEnv") is not False):
        raise ValueError("Guest must be running ARM64 macOS in plain mode with no mounts, forwarded agent or host keys")
    guest(name, TOOLS_CHECK, timeout=60)


def release_digest(version):
    record = json.loads(command(["gh", "api", f"repos/actions/runner/releases/tags/v{version}"]).stdout)
    assets = [asset for asset in record.get("assets", [])
              if asset.get("name") == f"actions-runner-osx-arm64-{version}.tar.gz"]
    if len(assets) != 1 or not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", assets[0].get("digest") or ""):
        raise ValueError("Official runner release lacks the required SHA256 digest; refusing an unverified download")
    return assets[0]["digest"].split(":", 1)[1]


def run_one(args):
    identity = command(["gh", "api", "user", "--jq", ".login"]).stdout.strip()
    if identity != args.expected_login:
        raise ValueError("GitHub CLI identity differs from --expected-login")
    observe_guest(args.name)
    digest = release_digest(args.runner_version)
    guest(args.name, INSTALL, args.runner_version, digest, timeout=300)
    # Check isolation and idleness again immediately before issuing the JIT registration.
    observe_guest(args.name)
    registration_name = f"{args.name}-{int(time.time())}"
    endpoint = f"orgs/{args.organization}/actions/runners/generate-jitconfig"
    request = {"name": registration_name, "runner_group_id": args.runner_group_id,
               # Avoid matching generic native macOS/ARM64 workflow routes during validation.
               "labels": ["macos-vm"], "work_folder": "_work"}
    result = json.loads(command(["gh", "api", "--method", "POST", endpoint, "--input", "-"],
                                data=json.dumps(request)).stdout)
    config = result.get("encoded_jit_config")
    runner_id = result.get("runner", {}).get("id")
    if not isinstance(config, str) or not config or not isinstance(runner_id, int):
        raise ValueError("GitHub returned an incomplete JIT configuration")
    print(f"One-job macOS runner {registration_name} is starting; dispatch only the scoped macos-vm canary.", flush=True)
    try:
        # Secret exists only in process memory and stdin. It is never in argv, a file or printed.
        guest(args.name, ONE_JOB, data=config, capture=False, timeout=args.timeout_minutes * 60)
    finally:
        config = None
        # Revoke an idle/abandoned registration if runner failure interrupted GitHub's automatic removal.
        # An active job is never deleted merely because the driver's timeout elapsed.
        pages = json.loads(command(["gh", "api", f"orgs/{args.organization}/actions/runners?per_page=100",
                                    "--paginate", "--slurp"]).stdout)
        remaining = [row for page in pages for row in page.get("runners", []) if row.get("id") == runner_id]
        if remaining and remaining[0].get("busy") is False:
            command(["gh", "api", "--method", "DELETE",
                     f"orgs/{args.organization}/actions/runners/{runner_id}"], capture=False)
        elif remaining:
            raise ValueError("Runner is still busy or its state is unknown; registration retained and cleanup unverified")
    guest(args.name, CLEANUP_CHECK)
    print("The one-job runner exited. Reimage the guest before running another untrusted job.")


def save_record(path, record):
    fd, temporary = tempfile.mkstemp(prefix=".macos-record-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def start_guest(args):
    host, vms = preflight.inspect_host()
    report = preflight.assess(host, vms, args.name)
    if not report["ready_to_provision"]:
        raise ValueError("Cannot provision: " + "; ".join(report["blockers"]))
    args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = args.state / f"{args.name}.yaml"
    content = json.dumps(preflight.guest_config(), indent=2) + "\n"
    if path.exists() or path.is_symlink():
        if path.is_symlink() or path.stat().st_uid != os.getuid() or path.read_text() != content:
            raise ValueError("Existing rendered configuration differs; inspect it before retrying")
    else:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
    command(["limactl", "validate", str(path)])
    # Final capacity check immediately before the only VM mutation. Never stops another VM.
    host, vms = preflight.inspect_host()
    report = preflight.assess(host, vms, args.name)
    if not report["ready_to_provision"]:
        raise ValueError("Capacity changed before start: " + "; ".join(report["blockers"]))
    record = {"schema_version": 1, "vm_name": args.name, "memory_gib": 6, "cpus": 2,
              "configuration": str(path.resolve()), "created_by": "runner-platform-macos",
              "configuration_sha256": hashlib.sha256(content.encode()).hexdigest(),
              "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
              "acceptance_verified": False, "phase": "prepared"}
    record_path = args.state / f"{args.name}-created.json"
    if record_path.exists() or record_path.is_symlink():
        if record_path.is_symlink() or record_path.stat().st_uid != os.getuid():
            raise ValueError("Ownership record is not an owned regular file")
        previous = json.loads(record_path.read_text())
        if (previous.get("created_by") != record["created_by"]
                or previous.get("configuration_sha256") != record["configuration_sha256"]
                or previous.get("vm_name") != args.name):
            raise ValueError("Existing VM ownership record differs; inspect before retrying")
        record["created_at"] = previous["created_at"]
    save_record(record_path, record)
    try:
        command(["limactl", "start", "--name=" + args.name, str(path)], capture=False, timeout=1800)
    except BaseException:
        save_record(record_path, dict(record, phase="start_unverified"))
        raise
    save_record(record_path, dict(record, phase="started"))
    print("Guest created. Complete any guest setup/license prompts and install workflow dependencies before run-one.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n  host-runner.py start\n  host-runner.py run-one --organization acme --expected-login maintainer\n\n"
               "Environment:\n  Run in the normal host terminal with limactl and authenticated gh. No host credentials enter the guest.")
    parser.add_argument("command", choices=("start", "run-one"))
    parser.add_argument("--name", default="ci-macos", help="Guest VM name")
    parser.add_argument("--state", type=Path, default=ROOT.parent / ".local", help="Local rendered configuration directory")
    parser.add_argument("--organization", help="GitHub organization for the one-job registration")
    parser.add_argument("--expected-login", help="Required personal gh login for run-one")
    parser.add_argument("--runner-group-id", type=int, default=1, help="Runner group allowed to accept the canary")
    parser.add_argument("--runner-version", default="2.338.0", help="Official Actions runner release version")
    parser.add_argument("--timeout-minutes", type=int, default=60, help="Maximum foreground wait (1-240 minutes)")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,50}", args.name):
        parser.error("--name must be a lowercase VM name")
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.runner_version) or not 1 <= args.timeout_minutes <= 240:
        parser.error("Invalid runner version or timeout")
    if args.command == "run-one" and (not args.organization or not args.expected_login):
        parser.error("run-one requires --organization and --expected-login")
    if args.organization and not re.fullmatch(r"[A-Za-z0-9-]+", args.organization):
        parser.error("Invalid organization name")
    try:
        args.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (args.state / f"{args.name}.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            start_guest(args) if args.command == "start" else run_one(args)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Do not echo CalledProcessError command output: it could contain registration data.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"macOS runner stopped: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
