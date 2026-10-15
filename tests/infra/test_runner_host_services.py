#!/usr/bin/env python3
# setup-test: Private persistent runner host monitoring
"""Verify host service ownership, private binds and rollback without launchctl."""
import importlib.util
import io
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("runner_host_services_test", ROOT / "infra/runner-platform/host-services.py")
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostServicesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.state = self.home / ".local"
        self.state.mkdir(mode=0o700)
        self.label = host.LABELS["node"]
        self.plist = self.home / "Library/LaunchAgents" / (self.label + ".plist")

    def test_atomic_files_are_private_and_have_no_partial_sibling(self):
        host.atomic(self.plist, b"test")
        self.assertEqual(self.plist.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.plist.parent.iterdir()), [self.plist])

    def test_unmanaged_plist_or_loaded_label_cannot_be_replaced(self):
        host.atomic(self.plist, b"unrelated")
        with self.assertRaisesRegex(host.platform.PlatformError, "refusing replacement"):
            host.check_managed(self.home, {}, {})
        self.plist.unlink()
        with self.assertRaises(host.platform.PlatformError):
            host.check_managed(self.home, {}, {self.label: 123})

    def test_symlink_or_changed_plist_is_rejected(self):
        target = self.home / "elsewhere"
        host.atomic(target, b"original")
        self.plist.parent.mkdir(parents=True)
        self.plist.symlink_to(target)
        with self.assertRaises(host.platform.PlatformError):
            host.check_managed(self.home, {self.label: {"plist_sha256": host.digest(b"original")}}, {})
        self.plist.unlink()
        host.atomic(self.plist, b"changed")
        with self.assertRaises(host.platform.PlatformError):
            host.check_managed(self.home, {self.label: {"plist_sha256": host.digest(b"original")}}, {})

    def test_definition_is_loopback_only_and_copies_no_auth_environment(self):
        cfg = {"github_url": "https://github.com/acme"}
        definitions = host.definitions(cfg, self.state, ["acme/toolbox"], "/opt/node_exporter", "/opt/python3",
                                       "/opt/gh/bin/gh", self.home)
        node = definitions[host.LABELS["node"]]
        collector = definitions[host.LABELS["github"]]
        self.assertIn("--web.listen-address=127.0.0.1:9100", node["ProgramArguments"])
        self.assertIn("--use-gh-auth", collector["ProgramArguments"])
        self.assertIn("127.0.0.1", collector["ProgramArguments"])
        self.assertEqual(set(collector["EnvironmentVariables"]), {"PATH"})
        copied = Path(collector["ProgramArguments"][1])
        self.assertEqual(copied.stat().st_mode & 0o777, 0o400)
        self.assertTrue(copied.is_absolute())

    def test_wildcard_listener_is_rejected(self):
        with patch.object(host.platform, "run", return_value="p123\nn*:9100\n"):
            with self.assertRaisesRegex(host.platform.PlatformError, "non-loopback"):
                host.loopback_only(123, 9100)
        with patch.object(host.platform, "run", return_value="p123\nn127.0.0.1:9100\n"):
            host.loopback_only(123, 9100)

    def test_failed_new_bootstrap_removes_only_its_managed_plist(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if "bootstrap" in args:
                raise host.platform.PlatformError("bootstrap failed")
        definition = {"Label": self.label, "ProgramArguments": ["/opt/node_exporter"]}
        with patch.object(host.platform, "run", side_effect=run), patch.object(host, "loaded", return_value={}):
            with self.assertRaises(host.platform.PlatformError):
                host.reconcile(self.home, self.state, {self.label: definition}, {}, {})
        self.assertFalse(self.plist.exists())
        self.assertEqual(json.loads((self.state / "host-services.json").read_text()), {})
        self.assertTrue(all(args[0] == "launchctl" for args in calls))
        self.assertFalse(any("stop" in args or "delete" in args for args in calls))

    def test_failed_upgrade_restores_only_the_old_managed_definition(self):
        old = plistlib.dumps({"Label": self.label, "ProgramArguments": ["/opt/old-exporter"]})
        host.atomic(self.plist, old)
        records = {self.label: {"plist_sha256": host.digest(old), "program": "/opt/old-exporter"}}
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if "bootstrap" in args and sum("bootstrap" in row for row in calls) == 1:
                raise host.platform.PlatformError("new exporter failed")
        wanted = {"Label": self.label, "ProgramArguments": ["/opt/new-exporter"]}
        with patch.object(host.platform, "run", side_effect=run), patch.object(host, "loaded", return_value={}):
            with self.assertRaises(host.platform.PlatformError):
                host.reconcile(self.home, self.state, {self.label: wanted}, records, {self.label: 123})
        self.assertEqual(self.plist.read_bytes(), old)
        self.assertEqual(records[self.label]["program"], "/opt/old-exporter")
        self.assertEqual(sum("bootstrap" in row for row in calls), 2)

    def test_same_loaded_definition_does_not_restart_or_rewrite(self):
        wanted = {"Label": self.label, "ProgramArguments": ["/opt/node_exporter"]}
        data = plistlib.dumps(wanted, sort_keys=True)
        host.atomic(self.plist, data)
        with patch.object(host.platform, "run") as run:
            host.reconcile(self.home, self.state, {self.label: wanted}, {}, {self.label: 123})
        run.assert_not_called()

    def test_help_never_installs_or_inspects_host(self):
        with patch.object(host.platform, "run") as run, patch.object(host.platform, "load_config") as load:
            with self.assertRaises(SystemExit) as exited:
                host.main(["--help"])
        self.assertEqual(exited.exception.code, 0)
        run.assert_not_called()
        load.assert_not_called()

    def test_executable_rejects_group_writable_binary(self):
        binary = self.home / "exporter"
        binary.write_text("binary")
        binary.chmod(0o775)
        with self.assertRaises(host.platform.PlatformError):
            host.executable(binary)
        binary.chmod(0o755)
        self.assertEqual(host.executable(binary), str(binary.resolve()))
        self.assertEqual(binary.stat().st_uid, os.getuid())

    def test_grafana_collision_does_not_replace_or_kill_existing_service(self):
        with patch.object(host, "loaded", return_value={}), patch.object(
            host, "available", side_effect=host.platform.PlatformError("port occupied")), patch.object(
            host, "reconcile") as reconcile, patch.object(host.platform, "run") as run:
            with self.assertRaisesRegex(host.platform.PlatformError, "port occupied"):
                host.grafana_access(self.state, home=self.home)
        reconcile.assert_not_called()
        run.assert_not_called()

    def test_grafana_uses_only_loopback_and_checks_health_without_credentials(self):
        host.atomic(self.state / "kubeconfig", b"private-config")
        captured = {}
        def reconcile(home, state, definitions, records, services):
            captured.update(definitions)
        opener = unittest.mock.Mock()
        opener.open.return_value = io.BytesIO(b'{"database":"ok"}')
        with patch.object(host, "loaded", side_effect=[{}, {host.LABELS["grafana"]: 123}]), patch.object(
            host, "available"), patch.object(host, "executable", return_value="/opt/kubectl"), patch.object(
            host, "reconcile", side_effect=reconcile), patch.object(host, "loopback_only") as loopback, patch.object(
            host, "build_opener", return_value=opener):
            self.assertEqual(host.grafana_access(self.state, home=self.home, attempts=1), "http://127.0.0.1:3000")
        args = captured[host.LABELS["grafana"]]["ProgramArguments"]
        self.assertEqual(args[-4:], ["--address", "127.0.0.1", "service/ci-monitoring-grafana", "3000:80"])
        self.assertEqual(args[0], "/opt/kubectl")
        self.assertNotIn("EnvironmentVariables", captured[host.LABELS["grafana"]])
        loopback.assert_called_once_with(123, 3000)
        opener.open.assert_called_once_with("http://127.0.0.1:3000/api/health", timeout=10)


if __name__ == "__main__":
    unittest.main()
