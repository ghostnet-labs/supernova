#!/usr/bin/env python3
"""Install private node exporters in running legacy Ubuntu Lima guests."""
import argparse
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import stat
import sys
import tempfile
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guest_exporter_platform", ROOT / "platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)
DEFAULT_VMS = {"gh-build": 19100, "gh-ubuntu": 19101}
HOST_GATEWAY = "192.168.5.2"
RECORD = "guest-exporters.json"
UNIT = "ghostnet-runner-node-exporter.service"

# Downloads a signed-repository package and extracts it, never installs it with
# dpkg/apt. Thus the distro service cannot autostart with a wildcard listener.
# This script only owns UNIT and /var/lib/ghostnet-runner-platform/node-exporter.
GUEST = r'''import base64, fcntl, hashlib, json, os, re, shutil, socket, stat, subprocess, sys, tempfile, time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, build_opener
BASE = Path('/var/lib/ghostnet-runner-platform/node-exporter')
UNIT = 'ghostnet-runner-node-exporter.service'
UNIT_PATH = Path('/etc/systemd/system') / UNIT
MANIFEST = BASE / 'ownership.json'

def run(argv, okay=False):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180, env=dict(os.environ, LC_ALL='C'))
    if result.returncode and not okay:
        raise RuntimeError('Guest command failed: ' + Path(argv[0]).name)
    return result.stdout.strip()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def atomic(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix='.node-exporter-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def trusted(path, mode):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != mode:
        raise RuntimeError('Managed guest file ownership or mode changed.')

def unit_text(binary, port):
    return ('[Unit]\nDescription=Private runner platform node exporter\nAfter=network.target\n'
            '[Service]\nType=simple\nUser=nobody\nGroup=nogroup\n'
            'ExecStart=' + str(binary) + ' --web.listen-address=127.0.0.1:' + str(port) +
            ' --collector.disable-defaults --collector.cpu --collector.meminfo'
            ' --collector.filesystem --collector.diskstats --collector.netdev --collector.uname\n'
            'Restart=on-failure\nRestartSec=5\nNoNewPrivileges=yes\nPrivateTmp=yes\n'
            'ProtectKernelTunables=yes\n'
            'ProtectKernelModules=yes\nProtectControlGroups=yes\nMemoryMax=96M\nCPUQuota=15%\n'
            '[Install]\nWantedBy=multi-user.target\n').encode()

def current():
    record = None
    if MANIFEST.exists() or MANIFEST.is_symlink():
        trusted(MANIFEST, 0o600)
        record = json.loads(MANIFEST.read_text())
        if UNIT_PATH.exists() or UNIT_PATH.is_symlink():
            trusted(UNIT_PATH, 0o644)
            if sha(UNIT_PATH.read_bytes()) != record['unit_sha256']:
                raise RuntimeError('Managed guest unit differs from ownership record.')
        elif not record.get('pending'):
            raise RuntimeError('Managed guest unit disappeared.')
        binary = Path(record['binary'])
        if binary.parent != BASE or not re.fullmatch(r'node-exporter-[a-f0-9]{64}', binary.name):
            raise RuntimeError('Unexpected managed exporter binary path.')
        trusted(binary, 0o755)
        if sha(binary.read_bytes()) != record['binary_sha256']:
            raise RuntimeError('Managed exporter binary differs from ownership record.')
    elif UNIT_PATH.exists() or UNIT_PATH.is_symlink():
        raise RuntimeError('Unmanaged guest unit exists; refusing replacement.')
    fragment = run(['systemctl', 'show', UNIT, '--property=FragmentPath', '--value'], okay=True)
    if fragment and (record is None or fragment != str(UNIT_PATH)):
        raise RuntimeError('An unmanaged service uses the reserved unit name.')
    return record

def active():
    return run(['systemctl', 'is-active', UNIT], okay=True) == 'active'

def enabled():
    return run(['systemctl', 'is-enabled', UNIT], okay=True) == 'enabled'

def listeners(port):
    return run(['ss', '-H', '-ltnp', 'sport = :' + str(port)]).splitlines()

def assert_port(port, record):
    rows = listeners(port)
    if not rows: return
    if record is None or not active() or record['port'] != port:
        raise RuntimeError('Guest exporter port is occupied by an unmanaged listener.')
    pid = run(['systemctl', 'show', UNIT, '--property=MainPID', '--value'])
    if len(rows) != 1 or rows[0].split()[3] != '127.0.0.1:' + str(port) or not re.search(r'pid=' + re.escape(pid) + r'[,)]', rows[0]):
        raise RuntimeError('Guest listener is not the managed loopback service.')

def idle():
    for entry in Path('/proc').iterdir():
        try:
            if entry.name.isdigit() and (entry / 'comm').read_text().strip() == 'Runner.Worker':
                raise RuntimeError('A Runner.Worker is active; retry after its build completes.')
        except (FileNotFoundError, ProcessLookupError):
            pass

def metric_text(text):
    names = ('node_exporter_build_info', 'node_cpu_seconds_total', 'node_memory_MemTotal_bytes',
             'node_filesystem_size_bytes', 'node_disk_read_bytes_total',
             'node_network_receive_bytes_total', 'node_uname_info')
    if not all(re.search(r'^' + name + r'(?:\{|\s)', text, re.M) for name in names):
        raise RuntimeError('Guest exporter lacks required node metric families.')
    failed = re.findall(r'^node_scrape_collector_success\{([^\n]*)\} 0(?:\.0)?$', text, re.M)
    if failed:
        names = sorted({match.group(1) if (match := re.search(r'\bcollector="([a-zA-Z0-9_]+)"', labels)) else 'unknown'
                        for labels in failed})
        raise RuntimeError('Guest node exporter collectors failed: ' + ', '.join(names))

def verify(record, allow_pending=False):
    if not record or (record.get('pending') and not allow_pending) or not active() or not enabled():
        raise RuntimeError('Managed guest exporter is not active and enabled.')
    assert_port(record['port'], record)
    opener = build_opener(ProxyHandler({}))
    with opener.open('http://127.0.0.1:' + str(record['port']) + '/metrics', timeout=10) as response:
        metric_text(response.read(8 * 1024 * 1024).decode())
    return dict(record, hostname=socket.gethostname())

def restore(record):
    # Ownership is rechecked before stopping anything. A changed/unmanaged service
    # is never stopped merely because it happens to have the same unit name.
    actual = current()
    if not actual or actual.get('transaction') != record.get('transaction'):
        raise RuntimeError('Rollback ownership no longer matches this installation.')
    run(['systemctl', 'stop', UNIT], okay=True)
    run(['systemctl', 'disable', UNIT], okay=True)
    previous = record['previous']
    if previous['unit'] is None:
        UNIT_PATH.unlink(missing_ok=True)
        MANIFEST.unlink()
    else:
        atomic(UNIT_PATH, base64.b64decode(previous['unit']), 0o644)
        atomic(MANIFEST, base64.b64decode(previous['manifest']))
    run(['systemctl', 'daemon-reload'])
    if previous['unit'] is not None:
        if previous['enabled']: run(['systemctl', 'enable', UNIT])
        if previous['active']: run(['systemctl', 'start', UNIT])

def package_binary():
    if 'ID=ubuntu' not in Path('/etc/os-release').read_text().splitlines():
        raise RuntimeError('Only Ubuntu signed apt repositories are supported.')
    apt_flags = ['-o', 'Acquire::AllowInsecureRepositories=false', '-o', 'APT::Get::AllowUnauthenticated=false']
    policy = run(['apt-cache', 'policy', 'prometheus-node-exporter'])
    if 'Candidate: (none)' in policy or 'Candidate:' not in policy:
        idle()
        run(['apt-get', *apt_flags, 'update'])
        policy = run(['apt-cache', 'policy', 'prometheus-node-exporter'])
    match = re.search(r'Candidate:\s+(\S+)', policy)
    if not match or match[1] == '(none)': raise RuntimeError('Ubuntu node exporter package unavailable.')
    version = match[1]
    # Restrict this installer to Canonical archive/ports/security endpoints.
    # A custom mirror must be reviewed and installed independently.
    candidates, selected = [], False
    for line in policy.splitlines():
        version_line = re.fullmatch(r'\s*(?:\*\*\*\s+)?(\S+)\s+\d+\s*', line)
        if version_line:
            selected = version_line[1] == version
        elif selected:
            candidates.extend(re.findall(r'https?://[^\s]+', line))
    if not candidates or not all(re.fullmatch(r'(?:(?:[a-z]{2}\.)?archive|ports|security)\.ubuntu\.com', urlsplit(uri).hostname or '')
                                 for uri in candidates):
        raise RuntimeError('Expected the selected package version from an official Ubuntu archive.')
    with tempfile.TemporaryDirectory(prefix='runner-exporter-package-') as directory:
        downloaded = subprocess.run(['apt-get', *apt_flags, 'download', 'prometheus-node-exporter=' + version],
                                    cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, env=dict(os.environ, LC_ALL='C'))
        if downloaded.returncode: raise RuntimeError('Signed Ubuntu package download failed.')
        packages = list(Path(directory).glob('*.deb'))
        if len(packages) != 1: raise RuntimeError('Unexpected Ubuntu package download result.')
        extracted = Path(directory) / 'extracted'
        run(['dpkg-deb', '--extract', str(packages[0]), str(extracted)])
        source = extracted / 'usr/bin/prometheus-node-exporter'
        if not source.is_file() or source.is_symlink(): raise RuntimeError('Exporter binary missing in package.')
        payload = source.read_bytes()
        digest = sha(payload)
        binary = BASE / ('node-exporter-' + digest)
        if binary.exists() or binary.is_symlink():
            trusted(binary, 0o755)
            if binary.read_bytes() != payload: raise RuntimeError('Versioned guest exporter binary was modified.')
        else:
            atomic(binary, payload, 0o755)
        run([str(binary), '--version'])
    return binary, digest, version

def install(port):
    idle()
    old = current()
    if old and old.get('pending'):
        restore(old)
        old = None
    if old and old['port'] != port: raise RuntimeError('Refusing to move an already-managed exporter port.')
    assert_port(port, old)
    if old:
        # Idempotent reruns preserve the authenticated package and unit version.
        verify(old)
        return dict(old, changed=False, hostname=socket.gethostname())
    previous = {'unit': None, 'manifest': None, 'active': False, 'enabled': False}
    binary, digest, version = package_binary()
    idle()
    # Another process may have claimed the name/port while apt downloaded.
    if current() is not None: raise RuntimeError('Guest exporter state changed during download.')
    assert_port(port, None)
    data = unit_text(binary, port)
    record = {'port': port, 'binary': str(binary), 'binary_sha256': digest,
              'unit_sha256': sha(data), 'package_version': version,
              'transaction': os.urandom(16).hex(), 'previous': previous, 'pending': True}
    # The journal precedes the unit so interruption cannot create an orphan unit.
    atomic(MANIFEST, (json.dumps(record) + '\n').encode())
    try:
        atomic(UNIT_PATH, data, 0o644)
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', UNIT])
        run(['systemctl', 'start', UNIT])
        for attempt in range(30):
            try:
                verify(record, allow_pending=True)
                record.pop('pending')
                atomic(MANIFEST, (json.dumps(record) + '\n').encode())
                return dict(record, changed=True, hostname=socket.gethostname())
            except (RuntimeError, OSError):
                if attempt == 29: raise
                time.sleep(.5)
    except BaseException:
        restore(record)
        raise

def main():
    if os.geteuid() != 0: raise RuntimeError('Guest installer needs sudo.')
    action, payload = sys.argv[1], json.loads(sys.argv[2])
    BASE.mkdir(mode=0o755, parents=True, exist_ok=True)
    info = BASE.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise RuntimeError('Managed exporter directory is not root-owned and private from writes.')
    with (BASE / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if action == 'install': result = install(int(payload['port']))
        elif action == 'verify': result = verify(current())
        elif action == 'rollback': restore(payload); result = {'rolled_back': True}
        else: raise RuntimeError('Unknown guest exporter action.')
    print(json.dumps(result))

if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('Guest exporter stopped: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
'''


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".guest-exporters-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def records(state):
    path = state / RECORD
    if not path.exists():
        return {}
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise platform.PlatformError("Guest exporter manifest is not an owned private regular file.")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise platform.PlatformError("Invalid guest exporter manifest.")
    return value


def guest(vm, action, payload):
    return json.loads(platform.run(["limactl", "shell", vm, "--", "sudo", "python3", "-", action,
                                    json.dumps(payload, separators=(",", ":"))],
                                   input_text=GUEST, capture=True, timeout=600))


def scopes(cfg, vms):
    values = dict(DEFAULT_VMS if vms is None else vms)
    if cfg["vm_name"] in values:
        raise platform.PlatformError("Kubernetes VM is monitored by its chart exporter; refusing duplicate installation.")
    for vm, port in values.items():
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", vm) or not isinstance(port, int) or not 1024 <= port <= 65535:
            raise platform.PlatformError("Invalid guest exporter VM or unprivileged port.")
    if len(set(values.values())) != len(values) or set(values.values()) & {9100, 9108, cfg["api_host_port"], cfg["ssh_host_port"]}:
        raise platform.PlatformError("Guest exporter ports must be unique and distinct from platform ports.")
    return values


def free_port(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError as error:
            raise platform.PlatformError("Reserved guest exporter host port is already occupied.") from error


def metrics_match(text, hostname):
    required = ("node_exporter_build_info", "node_cpu_seconds_total", "node_memory_MemTotal_bytes",
                "node_filesystem_size_bytes", "node_disk_read_bytes_total", "node_network_receive_bytes_total")
    if not all(re.search(r"^" + name + r"(?:\{|\s)", text, re.M) for name in required):
        raise platform.PlatformError("Legacy VM exporter is missing required metrics.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", hostname) or not re.search(
            r'^node_uname_info\{[^\n]*\bnodename="' + re.escape(hostname) + r'"', text, re.M):
        raise platform.PlatformError("Forwarded exporter does not identify the intended guest hostname.")
    failed = re.findall(r"^node_scrape_collector_success\{([^\n]*)\} 0(?:\.0)?$", text, re.M)
    if failed:
        names = sorted({match.group(1) if (match := re.search(r'\bcollector="([a-zA-Z0-9_]+)"', labels)) else "unknown"
                        for labels in failed})
        raise platform.PlatformError("Legacy VM node exporter collectors failed: " + ", ".join(names))


def reachable(cfg, vm, record, *, attempts=30):
    opener = build_opener(ProxyHandler({}))
    port = record["port"]
    last = None
    for attempt in range(attempts):
        try:
            with opener.open(f"http://127.0.0.1:{port}/metrics", timeout=5) as response:
                metrics_match(response.read(8 * 1024 * 1024).decode(), record["hostname"])
            text = platform.run(["limactl", "shell", cfg["vm_name"], "--", "curl", "--fail", "--silent", "--show-error",
                                 "--noproxy", "*", "--connect-timeout", "3", "--max-time", "10",
                                 f"http://{HOST_GATEWAY}:{port}/metrics"], capture=True, timeout=20)
            metrics_match(text, record["hostname"])
            return {"vm": vm, "hostname": record["hostname"], "port": port,
                    "address": f"{HOST_GATEWAY}:{port}", "loopback_verified": True}
        except (platform.PlatformError, OSError, URLError, UnicodeError) as error:
            last = error
            if attempt + 1 < attempts:
                time.sleep(1)
    raise platform.PlatformError("Legacy VM exporter is not reachable through private Lima forwarding: " + vm) from last


def install(cfg, state, *, vms=None):
    """Return updated config only after every running selected VM is verified."""
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (state / "guest-exporters.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return install_locked(cfg, state, vms=vms)


def install_locked(cfg, state, *, vms=None):
    selected = scopes(cfg, vms)
    running = {vm["name"]: vm for vm in platform.lima_state()}
    if running.get(cfg["vm_name"], {}).get("status") != "Running":
        raise platform.PlatformError("Kubernetes guest must be running to verify exporter reachability.")
    owned = records(state)
    # Preflight every intended target before changing the first guest.
    for vm, port in selected.items():
        status = running.get(vm, {}).get("status")
        if status in (None, "Stopped"):
            continue
        if status != "Running":
            raise platform.PlatformError("Unknown legacy VM state; refusing exporter changes: " + vm)
        if vm not in owned:
            free_port(port)
        elif owned[vm].get("port") != port:
            raise platform.PlatformError("Managed guest exporter port changed; refusing relocation.")
    updated = copy.deepcopy(cfg)
    proof = []
    for vm, port in selected.items():
        if running.get(vm, {}).get("status") != "Running":
            continue
        # Reserve ownership before the remote transaction. If the host process is
        # interrupted, rerunning can inspect/reconcile the root-owned guest record.
        owned.setdefault(vm, {"port": port, "pending": True})
        atomic(state / RECORD, owned)
        print(f"Installing and checking private node exporter in {vm}…", flush=True)
        result = guest(vm, "install", {"port": port})
        owned[vm] = result
        atomic(state / RECORD, owned)  # Recovery ownership survives an interrupted host process.
        try:
            proof.append(reachable(cfg, vm, result))
            print(f"Guest exporter verified: {vm}.", flush=True)
        except BaseException:
            if result.get("changed"):
                guest(vm, "rollback", result)
                owned.pop(vm)
                atomic(state / RECORD, owned)
            raise
    names = {"legacy-node-" + vm for vm in selected}
    # No stale scrape target for a stopped VM, and no healthy claim for an unconfigured one.
    updated["host_exporters"] = [target for target in cfg.get("host_exporters", []) if target["name"] not in names]
    updated["host_exporters"].extend({"name": "legacy-node-" + item["vm"], "address": item["address"],
                                       "os": "linux", "kind": "node", "vm": item["vm"]} for item in proof)
    platform.save(state / "guest-exporters-evidence.json", {"verified_at": now(), "guests": proof,
                                                           "not_running": [vm for vm in selected if running.get(vm, {}).get("status") != "Running"]})
    return updated


def verify(cfg, state):
    owned = records(state)
    configured = [target for target in cfg.get("host_exporters", []) if target.get("vm")]
    proof = []
    for target in configured:
        vm = target["vm"]
        if vm not in owned:
            raise platform.PlatformError("A configured legacy VM has no managed exporter ownership record.")
        result = guest(vm, "verify", {})
        if result.get("unit_sha256") != owned[vm].get("unit_sha256") or result.get("port") != owned[vm].get("port"):
            raise platform.PlatformError("Guest exporter differs from its host ownership record.")
        proof.append(reachable(cfg, vm, result))
    evidence = {"verified_at": now(), "guests": proof}
    platform.save(state / "guest-exporters-evidence.json", evidence)
    return evidence


def now():
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc).isoformat()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Examples: guest-exporters.py --install; guest-exporters.py --verify. "
        "Environment: requires normal host Lima access, guest sudo and authenticated official Ubuntu apt repositories."))
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--install", action="store_true", help="Install and verify only running legacy guests")
    action.add_argument("--verify", action="store_true", help="Recheck configured managed guests and private forwarding")
    parser.add_argument("--config", type=Path, default=ROOT / ".local/config.json")
    args = parser.parse_args(argv)
    try:
        cfg = platform.load_config(args.config)
        state = args.config.resolve().parent
        if args.install:
            platform.save(args.config, install(cfg, state))
        else:
            verify(cfg, state)
        print("Running legacy guest exporters and private forwarding verified.")
        return 0
    except (platform.PlatformError, OSError, ValueError, KeyError) as error:
        print("Guest monitoring stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
