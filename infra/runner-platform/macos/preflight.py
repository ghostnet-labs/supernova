#!/usr/bin/env python3
"""Inspect macOS VM capacity or render an isolated Lima guest without starting it."""
import argparse
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

GIB = 1024 ** 3
IMAGE_VERSION = (27, 0, 1)
IMAGE_URL = ("https://updates.cdn-apple.com/2026FallFCS/"
             "59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw")
IMAGE_DIGEST = "sha256:2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1"
LIMA_SOURCE = "https://github.com/lima-vm/lima/blob/v2.2.1/templates/_images/macos-27.yaml"


def read_command(args):
    result = subprocess.run(args, text=True, capture_output=True, check=True, timeout=30)
    return result.stdout.strip()


def version(value):
    match = re.search(r"\b(\d+)\.(\d+)(?:\.(\d+))?\b", value)
    if not match:
        raise ValueError("Version could not be determined")
    return tuple(int(item or 0) for item in match.groups())


def parse_vms(value):
    """Lima emits one JSON object per line, including permission-unknown states."""
    rows = [json.loads(line) for line in value.splitlines() if line.strip()]
    for row in rows:
        if (not isinstance(row, dict) or not isinstance(row.get("name"), str)
                or row.get("status") not in ("Running", "Stopped")
                or row.get("errors") or not isinstance(row.get("memory"), int)
                or row["memory"] <= 0):
            raise ValueError("Lima inventory is incomplete or contains an unknown/Broken VM; use the host terminal")
    if len({row["name"] for row in rows}) != len(rows):
        raise ValueError("Lima inventory contains duplicate VM names")
    return rows


def assess(host, vms, name, memory_gib=6, reserve_gib=8, disk_gib=80):
    """Fail closed when capacity or inventory is unavailable; this never authorizes retirement."""
    blockers = list(host.get("errors", []))
    if host.get("system") != "Darwin" or host.get("arch") not in ("arm64", "aarch64"):
        blockers.append("An Apple Silicon macOS host is required")
    if tuple(host.get("os_version", ())) < IMAGE_VERSION:
        blockers.append("Host macOS must be at least the pinned guest version 27.0.1")
    if tuple(host.get("lima_version", ())) < (2, 1, 0):
        blockers.append("Lima 2.1 or newer is required for experimental macOS guests")
    if any(row["name"] == name for row in vms):
        blockers.append("The proposed VM name already exists; existing VM configuration is never overwritten")
    running_gib = sum(row["memory"] for row in vms if row["status"] == "Running") / GIB
    total_gib = host["memory_bytes"] / GIB if host.get("memory_bytes") else None
    if total_gib is None:
        blockers.append("Host memory allocation budget is unknown")
    elif total_gib < running_gib + memory_gib + reserve_gib:
        blockers.append("Running VM allocations plus the proposed guest exceed the host reserve budget")
    # A new sparse disk can grow to its full size; leave 20 GiB for restore/download overhead.
    if host.get("free_bytes", 0) < (disk_gib + 20) * GIB:
        blockers.append("Need the full proposed disk size plus 20 GiB free for restore/download overhead")
    return {"schema_version": 1, "ready_to_provision": not blockers,
            "vm_name": name, "blockers": blockers,
            "budget_gib": {"host": total_gib, "running_vms": running_gib,
                           "proposed_guest": memory_gib, "host_reserve": reserve_gib,
                           "remaining_after_reserve": (total_gib - running_gib - memory_gib - reserve_gib
                                                       if total_gib is not None else None)},
            "vms": [{key: row[key] for key in ("name", "status", "memory")} for row in vms],
            "image_source": LIMA_SOURCE,
            "acceptance": "Provisioning readiness does not prove guest boot, toolchain, isolation or workload acceptance"}


def inspect_host():
    host = {"system": platform.system(), "arch": platform.machine(), "errors": []}
    for key, args, convert in (
        ("os_version", ["sw_vers", "-productVersion"], version),
        ("memory_bytes", ["sysctl", "-n", "hw.memsize"], int),
        ("lima_version", ["limactl", "--version"], version),
    ):
        try:
            host[key] = convert(read_command(args))
        except (OSError, subprocess.SubprocessError, ValueError):
            host["errors"].append(f"Cannot determine {key}; run from the unrestricted host terminal")
    try:
        host["free_bytes"] = shutil.disk_usage(Path.home() / ".lima").free
    except OSError:
        host["errors"].append("Cannot read free disk space at the Lima data directory")
    try:
        vms = parse_vms(read_command(["limactl", "list", "--json"]))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        host["errors"].append(f"Cannot verify Lima inventory: {error}")
        vms = []
    return host, vms


def guest_config(memory_gib=6, cpus=2, disk_gib=80):
    """Do not inherit template:_default/mounts: it shares the host home directory."""
    return {"minimumLimaVersion": "2.1.0", "vmType": "vz", "os": "Darwin", "arch": "aarch64",
            "images": [{"location": IMAGE_URL, "arch": "aarch64", "digest": IMAGE_DIGEST}],
            "cpus": cpus, "memory": f"{memory_gib}GiB", "disk": f"{disk_gib}GiB",
            "mounts": [], "mountInotify": False, "plain": True,
            "ssh": {"loadDotSSHPubKeys": False, "forwardAgent": False,
                    "forwardX11": False, "forwardX11Trusted": False},
            "containerd": {"system": False, "user": False},
            "video": {"display": "default"}, "audio": {"device": "none"},
            "propagateProxyEnv": False, "nestedVirtualization": False,
            "provision": [{"mode": "data", "path": "/etc/ci-runner-vm",
                           "permissions": "0444", "owner": "root:wheel",
                           "content": "runner-platform-macos-v1\n"}]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n  preflight.py report\n  preflight.py render --output .local/macos-vm.yaml\n\n"
               "Environment:\n  Requires macOS host tools sw_vers, sysctl and limactl. Never starts or stops a VM.")
    parser.add_argument("command", choices=("report", "render"))
    parser.add_argument("--name", default="ci-macos", help="New guest name (default: ci-macos)")
    parser.add_argument("--memory-gib", type=int, default=6, help="Guest memory, at least 6 GiB")
    parser.add_argument("--cpus", type=int, default=2, help="Guest vCPU, at least 2")
    parser.add_argument("--disk-gib", type=int, default=80, help="Guest disk, at least 80 GiB")
    parser.add_argument("--host-reserve-gib", type=int, default=8, help="Host memory reserve, at least 8 GiB")
    parser.add_argument("--output", type=Path, help="New JSON-compatible YAML file for render; existing files refused")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,50}", args.name):
        parser.error("--name must contain lowercase letters, numbers or hyphens and start with a letter")
    if args.memory_gib < 6 or args.cpus < 2 or args.disk_gib < 80 or args.host_reserve_gib < 8:
        parser.error("Minimum allocations are 6 GiB RAM, 2 vCPU, 80 GiB disk and 8 GiB host reserve")
    if args.command == "render" and not args.output:
        parser.error("render requires --output")
    if args.command == "report" and args.output:
        parser.error("--output is only supported for render")
    host, vms = inspect_host()
    report = assess(host, vms, args.name, args.memory_gib, args.host_reserve_gib, args.disk_gib)
    if args.command == "render":
        try:
            # Render inactive configuration even when capacity is blocked; no host state changes.
            with args.output.open("x") as handle:
                handle.write(json.dumps(guest_config(args.memory_gib, args.cpus, args.disk_gib), indent=2) + "\n")
            report["rendered_config"] = str(args.output.resolve())
            report["next_command_after_blockers_resolved"] = ["limactl", "start", "--name=" + args.name,
                                                             str(args.output.resolve())]
        except OSError as error:
            print(f"Render stopped: {error}", file=sys.stderr)
            return 1
    print(json.dumps(report, indent=2))
    return 0 if report["ready_to_provision"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
