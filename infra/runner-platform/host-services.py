#!/usr/bin/env python3
"""Install and verify private, persistent macOS runner monitoring services."""
import argparse
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("runner_platform_host", ROOT / "platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
LABELS = {"node": "com.ghostnet.runner-platform.node-exporter",
          "github": "com.ghostnet.runner-platform.github-metrics",
          "grafana": "com.ghostnet.runner-platform.grafana"}
BASE_KINDS = ("node", "github")
PORTS = {"node": 9100, "github": 9108}
GUEST_HOST = "192.168.5.2"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".runner-platform-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise platform.PlatformError("Managed service state must be an owned private regular file.")


def executable(path):
    candidate = Path(path).resolve(strict=True)
    info = candidate.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid())
            or stat.S_IMODE(info.st_mode) & 0o022 or not os.access(candidate, os.X_OK)):
        raise platform.PlatformError("Monitoring executable is not a trusted, non-writable binary.")
    return str(candidate)


def loaded():
    output = platform.run(["launchctl", "list"], capture=True, timeout=30)
    return {fields[2]: int(fields[0]) if fields[0].isdigit() else None
            for line in output.splitlines() if len(fields := line.split()) == 3}


def manifest(state):
    path = state / "host-services.json"
    if not path.exists():
        return {}
    private_file(path)
    data = json.loads(path.read_text())
    if set(data) - set(LABELS.values()):
        raise platform.PlatformError("Unexpected service label in managed manifest.")
    return data


def check_managed(home, records, services):
    for label in LABELS.values():
        path = home / "Library/LaunchAgents" / (label + ".plist")
        record = records.get(label)
        if path.exists() or path.is_symlink():
            private_file(path)
            if not record or digest(path.read_bytes()) != record.get("plist_sha256"):
                raise platform.PlatformError("Existing LaunchAgent differs from the managed record; refusing replacement.")
        elif record or label in services:
            raise platform.PlatformError("Managed service ownership cannot be verified; inspect the missing plist.")


def available(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError as error:
            raise platform.PlatformError(f"Port {port} is already occupied by an unmanaged service.") from error


def definitions(cfg, state, repositories, node_binary, python_binary, gh_binary, home):
    payload = (ROOT / "metrics.py").read_bytes()
    script = state / "services" / ("metrics-" + digest(payload) + ".py")
    if script.exists():
        private_file(script)
        if script.read_bytes() != payload:
            raise platform.PlatformError("Versioned collector content changed unexpectedly.")
    else:
        atomic(script, payload, 0o400)
    scope = platform.github_path(cfg["github_url"])
    args = [python_binary, str(script), "--mode", "github", "--use-gh-auth", "--listen", "127.0.0.1",
            "--port", str(PORTS["github"]), "--interval", "120"]
    if scope.startswith("orgs/"):
        args.extend(["--organization", scope.removeprefix("orgs/")])
    for repo in sorted(set(repositories)):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise platform.PlatformError("Invalid collector repository.")
        args.extend(["--repository", repo])
    if not repositories and not scope.startswith("orgs/"):
        raise platform.PlatformError("A repository is required for the GitHub collector.")
    definitions = {}
    for kind, argv in (("node", [node_binary, "--web.listen-address=127.0.0.1:9100"]), ("github", args)):
        label = LABELS[kind]
        definitions[label] = {"Label": label, "ProgramArguments": argv,
                              "EnvironmentVariables": {"PATH": str(Path(gh_binary).parent) + ":/usr/bin:/bin:/usr/sbin:/sbin"},
                              "WorkingDirectory": str(state), "RunAtLoad": True, "KeepAlive": True,
                              "ThrottleInterval": 30, "ProcessType": "Background",
                              "StandardOutPath": str(state / "services" / (kind + ".log")),
                              "StandardErrorPath": str(state / "services" / (kind + ".log"))}
    return definitions


def reconcile(home, state, definitions, records, services):
    domain = f"gui/{os.getuid()}"
    for label, definition in definitions.items():
        path = home / "Library/LaunchAgents" / (label + ".plist")
        data = plistlib.dumps(definition, sort_keys=True)
        if path.exists() and path.read_bytes() == data and label in services:
            continue
        previous = path.read_bytes() if path.exists() else None
        prior_record = records.get(label)
        changed = False
        try:
            if label in services:
                platform.run(["launchctl", "bootout", f"{domain}/{label}"], timeout=60)
            atomic(path, data)
            changed = True
            records[label] = {"plist_sha256": digest(data), "program": definition["ProgramArguments"][0]}
            atomic(state / "host-services.json", (json.dumps(records, indent=2) + "\n").encode())
            platform.run(["launchctl", "enable", f"{domain}/{label}"], timeout=30)
            platform.run(["launchctl", "bootstrap", domain, path], timeout=60)
        except BaseException:
            # Recover only our own service. Never start a retired VM to recover monitoring.
            if not changed:
                raise
            if label in loaded():
                platform.run(["launchctl", "bootout", f"{domain}/{label}"], timeout=60)
            if previous is not None:
                atomic(path, previous)
                records[label] = prior_record
                atomic(state / "host-services.json", (json.dumps(records, indent=2) + "\n").encode())
                platform.run(["launchctl", "bootstrap", domain, path], timeout=60)
            else:
                if path.exists() and digest(path.read_bytes()) == digest(data):
                    path.unlink()
                records.pop(label, None)
                atomic(state / "host-services.json", (json.dumps(records, indent=2) + "\n").encode())
            raise


def loopback_only(pid, port):
    text = platform.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                        capture=True, timeout=15)
    names = [line[1:] for line in text.splitlines() if line.startswith("n")]
    if names != [f"127.0.0.1:{port}"]:
        raise platform.PlatformError("Monitoring service has an unexpected non-loopback listener.")


def metric_text(kind, text):
    if kind == "node":
        required = ("node_exporter_build_info", "node_cpu_seconds_total", "node_filesystem_size_bytes",
                    "node_network_receive_bytes_total", "node_disk_read_bytes_total")
        if not all(re.search(r"^" + name + r"(?:\{|\s)", text, re.M) for name in required):
            raise platform.PlatformError("Native node exporter is missing required host metric families.")
        if not re.search(r"^node_memory_(?:total|MemTotal)_bytes(?:\{|\s)", text, re.M):
            raise platform.PlatformError("Native node exporter is missing host memory metrics.")
    elif not re.search(r"^ci_metrics_collection_success 1(?:\.0)?$", text, re.M):
        raise platform.PlatformError("GitHub metrics have not completed a successful collection.")


def verify(cfg, state, *, home=None, attempts=60):
    home = Path(home) if home else Path.home()
    records = manifest(state)
    services = loaded()
    check_managed(home, records, services)
    if not {LABELS[kind] for kind in BASE_KINDS} <= set(records):
        raise platform.PlatformError("Host monitoring services are not installed by this command.")
    opener = build_opener(ProxyHandler({}))
    last = None
    for attempt in range(attempts):
        try:
            services = loaded()
            for kind in BASE_KINDS:
                label = LABELS[kind]
                pid = services.get(label)
                if not pid:
                    raise platform.PlatformError("Managed monitoring service is not running.")
                loopback_only(pid, PORTS[kind])
                with opener.open(f"http://127.0.0.1:{PORTS[kind]}/metrics", timeout=15) as response:
                    metric_text(kind, response.read(8 * 1024 * 1024).decode())
                # Lima's default user-mode NIC maps192.168.5.2 to Mac127.0.0.1.
                # Validate from the actual guest rather than assuming this path exists.
                guest = platform.run(["limactl", "shell", cfg["vm_name"], "--", "curl", "--fail", "--silent",
                                      "--show-error", "--noproxy", "*", "--connect-timeout", "3", "--max-time", "15",
                                      f"http://{GUEST_HOST}:{PORTS[kind]}/metrics"], capture=True, timeout=30)
                metric_text(kind, guest)
            evidence = {"verified_at": dt_now(), "bind_address": "127.0.0.1", "guest_host": GUEST_HOST,
                        "node_port": PORTS["node"], "github_port": PORTS["github"]}
            platform.save(state / "host-services-evidence.json", evidence)
            return evidence
        except (platform.PlatformError, OSError, URLError, UnicodeError) as error:
            last = error
            if attempt + 1 < attempts:
                time.sleep(5)
    raise platform.PlatformError("Private host monitoring verification failed: " + str(last))


def dt_now():
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc).isoformat()


def install(cfg, state, repositories, *, home=None):
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (state / "host-services.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return install_locked(cfg, state, repositories, home=home)


def install_locked(cfg, state, repositories, *, home=None):
    if sys.platform != "darwin":
        raise platform.PlatformError("Host service installation requires the normal macOS host terminal.")
    home = Path(home) if home else Path.home()
    state = state.resolve()
    records = manifest(state)
    services = loaded()
    check_managed(home, records, services)
    for kind in BASE_KINDS:
        label = LABELS[kind]
        if label not in services:
            available(PORTS[kind])
    gh_binary = executable(shutil.which("gh") or "")
    python_binary = executable(sys.executable)
    brew_path = shutil.which("brew")
    if brew_path not in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        raise platform.PlatformError("Expected the standard Homebrew installation for the official exporter.")
    brew = executable(brew_path)
    prefix = platform.run([brew, "--prefix", "node_exporter"], capture=True, timeout=30).strip()
    node = str(Path(prefix) / "bin/node_exporter")
    if not Path(node).is_file():
        platform.run([brew, "install", "node_exporter"], timeout=900)
        prefix = platform.run([brew, "--prefix", "node_exporter"], capture=True, timeout=30).strip()
        node = str(Path(prefix) / "bin/node_exporter")
    node_binary = executable(node)
    if "Cellar/node_exporter/" not in node_binary:
        raise platform.PlatformError("Expected the official versioned Homebrew node_exporter binary.")
    wanted = definitions(cfg, state, repositories, node_binary, python_binary, gh_binary, home)
    reconcile(home, state, wanted, records, services)
    verify(cfg, state, home=home)
    updated = copy.deepcopy(cfg)
    names = {"studio-host", "github-actions"}
    updated["host_exporters"] = [target for target in cfg.get("host_exporters", []) if target["name"] not in names] + [
        {"name": "studio-host", "address": f"{GUEST_HOST}:9100", "os": "darwin"},
        {"name": "github-actions", "address": f"{GUEST_HOST}:9108", "os": "darwin"}]
    updated["actions_repositories"] = sorted(set(repositories))
    return updated


def grafana_access(state, *, home=None, attempts=30):
    """Persist verified loopback Grafana access after the monitoring release is ready."""
    home = Path(home) if home else Path.home()
    state = state.resolve()
    with (state / "host-services.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        records = manifest(state)
        services = loaded()
        check_managed(home, records, services)
        label = LABELS["grafana"]
        if label not in services:
            available(3000)
        kubectl = executable(shutil.which("kubectl") or "")
        kubeconfig = state / "kubeconfig"
        private_file(kubeconfig)
        definition = {"Label": label,
                      "ProgramArguments": [kubectl, "--kubeconfig", str(kubeconfig), "--namespace", "monitoring",
                                           "port-forward", "--address", "127.0.0.1",
                                           "service/ci-monitoring-grafana", "3000:80"],
                      "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
                      "ProcessType": "Background", "WorkingDirectory": str(state),
                      "StandardOutPath": str(state / "services/grafana-forward.log"),
                      "StandardErrorPath": str(state / "services/grafana-forward.log")}
        reconcile(home, state, {label: definition}, records, services)
        opener = build_opener(ProxyHandler({}))
        last = None
        for attempt in range(attempts):
            try:
                pid = loaded().get(label)
                if not pid:
                    raise platform.PlatformError("Grafana access service is not running.")
                loopback_only(pid, 3000)
                with opener.open("http://127.0.0.1:3000/api/health", timeout=10) as response:
                    health = json.load(response)
                if health.get("database") != "ok":
                    raise platform.PlatformError("Grafana health API is not ready.")
                platform.save(state / "grafana-access-evidence.json",
                              {"url": "http://127.0.0.1:3000", "verified_at": dt_now(), "bind_address": "127.0.0.1"})
                return "http://127.0.0.1:3000"
            except (platform.PlatformError, OSError, ValueError, URLError) as error:
                last = error
                if attempt + 1 < attempts:
                    time.sleep(2)
        raise platform.PlatformError("Persistent Grafana access verification failed: " + str(last))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Examples: host-services.py --install --repository acme/toolbox; host-services.py --verify. "
        "Environment: uses the logged-in user's existing gh authentication and Homebrew; no token copies."))
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--install", action="store_true", help="Install official exporter and managed LaunchAgents, then verify")
    mode.add_argument("--verify", action="store_true", help="Verify ownership, loopback listeners and guest reachability")
    parser.add_argument("--config", type=Path, default=ROOT / ".local/config.json")
    parser.add_argument("--repository", action="append", default=[], help="Repository to collect, repeatable")
    args = parser.parse_args(argv)
    try:
        cfg = platform.load_config(args.config)
        state = args.config.resolve().parent
        platform.identity(cfg)
        if args.install:
            updated = install(cfg, state, args.repository or cfg.get("actions_repositories", []))
            atomic(args.config, (json.dumps(updated, indent=2) + "\n").encode())
        else:
            verify(cfg, state)
        print("Private host and GitHub monitoring services verified from the Lima guest.")
        return 0
    except (platform.PlatformError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Host monitoring stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
