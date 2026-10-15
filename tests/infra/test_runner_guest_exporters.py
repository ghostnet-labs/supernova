#!/usr/bin/env python3
# setup-test: Private legacy VM exporters
"""Exercise private exporter rollout without contacting or changing a guest."""
import ast
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("guest_exporters_test", ROOT / "infra/runner-platform/guest-exporters.py")
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)


class GuestExporterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)
        self.cfg = {"vm_name": "cluster", "api_host_port": 16443, "ssh_host_port": 52222,
                    "host_exporters": []}
        self.vms = [{"name": "cluster", "status": "Running"},
                    {"name": "legacy", "status": "Running"}]

    def test_port_or_kubernetes_guest_collisions_are_refused(self):
        for selected in ({"cluster": 19100}, {"a": 19100, "b": 19100}, {"legacy": 9100}):
            with self.subTest(selected=selected), self.assertRaises(guest.platform.PlatformError):
                guest.scopes(self.cfg, selected)

    def test_unknown_guest_state_stops_before_guest_mutation(self):
        self.vms[1]["status"] = "Broken"
        with patch.object(guest.platform, "lima_state", return_value=self.vms), \
                patch.object(guest, "guest") as mutate, self.assertRaises(guest.platform.PlatformError):
            guest.install(self.cfg, self.state, vms={"legacy": 19100})
        mutate.assert_not_called()

    def test_stopped_guest_removes_stale_target_without_installing(self):
        self.vms[1]["status"] = "Stopped"
        self.cfg["host_exporters"] = [{"name": "legacy-node-legacy", "address": "old:19100"}]
        with patch.object(guest.platform, "lima_state", return_value=self.vms), \
                patch.object(guest, "guest") as mutate:
            result = guest.install(self.cfg, self.state, vms={"legacy": 19100})
        mutate.assert_not_called()
        self.assertEqual(result["host_exporters"], [])
        self.assertEqual(len(self.cfg["host_exporters"]), 1)

    def test_busy_host_port_is_checked_before_install(self):
        with patch.object(guest.platform, "lima_state", return_value=self.vms), \
                patch.object(guest, "free_port", side_effect=guest.platform.PlatformError("occupied")), \
                patch.object(guest, "guest") as mutate, self.assertRaises(guest.platform.PlatformError):
            guest.install(self.cfg, self.state, vms={"legacy": 19100})
        mutate.assert_not_called()

    def test_reachability_failure_rolls_back_only_the_changed_guest(self):
        result = {"port": 19100, "changed": True, "hostname": "legacy-vm"}
        with patch.object(guest.platform, "lima_state", return_value=self.vms), \
                patch.object(guest, "free_port"), patch.object(guest, "guest", return_value=result) as mutate, \
                patch.object(guest, "reachable", side_effect=guest.platform.PlatformError("unreachable")), \
                self.assertRaises(guest.platform.PlatformError):
            guest.install(self.cfg, self.state, vms={"legacy": 19100})
        self.assertEqual([call.args[1] for call in mutate.call_args_list], ["install", "rollback"])
        self.assertEqual(json.loads((self.state / guest.RECORD).read_text()), {})

    def test_targets_are_recorded_only_after_private_reachability_passes(self):
        result = {"port": 19100, "changed": True, "hostname": "legacy-vm"}
        proof = {"vm": "legacy", "hostname": "legacy-vm", "port": 19100,
                 "address": "192.168.5.2:19100", "loopback_verified": True}
        with patch.object(guest.platform, "lima_state", return_value=self.vms), \
                patch.object(guest, "free_port"), patch.object(guest, "guest", return_value=result), \
                patch.object(guest, "reachable", return_value=proof):
            cfg = guest.install(self.cfg, self.state, vms={"legacy": 19100})
        self.assertEqual(cfg["host_exporters"][0]["address"], proof["address"])
        self.assertEqual((self.state / guest.RECORD).stat().st_mode & 0o777, 0o600)

    def test_forwarded_endpoint_requires_correct_host_and_complete_metrics(self):
        names = ("node_exporter_build_info", "node_cpu_seconds_total", "node_memory_MemTotal_bytes",
                 "node_filesystem_size_bytes", "node_disk_read_bytes_total", "node_network_receive_bytes_total")
        text = "\n".join(name + " 1" for name in names) + '\nnode_uname_info{nodename="legacy-vm"} 1\n'
        guest.metrics_match(text, "legacy-vm")
        for bad in (text.replace("legacy-vm", "another-vm"), text.replace("node_disk_read_bytes_total", "missing"),
                    text + 'node_scrape_collector_success{collector="diskstats"} 0\n'):
            with self.assertRaises(guest.platform.PlatformError):
                guest.metrics_match(bad, "legacy-vm")

    def test_real_systemd_definition_is_unprivileged_and_loopback_only(self):
        tree = ast.parse(guest.GUEST)
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "unit_text")
        namespace = {}
        exec(compile(ast.Module(body=[function], type_ignores=[]), "guest-unit", "exec"), namespace)
        unit = namespace["unit_text"](Path("/managed/exporter"), 19100).decode()
        self.assertIn("User=nobody", unit)
        self.assertIn("--web.listen-address=127.0.0.1:19100", unit)
        self.assertIn("NoNewPrivileges=yes", unit)
        self.assertIn("MemoryMax=96M", unit)


if __name__ == "__main__":
    unittest.main()
