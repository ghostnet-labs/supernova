#!/usr/bin/env python3
# setup-test: Studio pilot drain guards
"""Exercise runner draining without touching real VMs, signals or GitHub."""
import importlib.util
import json
import plistlib
import signal
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("runner_pilot", ROOT / "infra/runner-platform/pilot.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


def runner(**updates):
    return dict(dict(id=1813, name="studio-build-2-123456", busy=False, status="online"), **updates)


class DrainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.plist = self.state / "builder.plist"
        self.plist.write_bytes(plistlib.dumps({"Label": pilot.LABEL, "ProgramArguments": [
            "/bin/bash", "/Users/example/jit/jit-slot.sh", "gh-build-2",
            "/home/runner/build", "studio-build-2", "self-hosted,openwrt-build"]}))

    def test_live_identity_is_exact_not_build20(self):
        self.assertEqual(pilot.slot_runners([runner(), dict(runner(), name="studio-build-20-1")])["id"], 1813)
        for rows in ([], [runner(), runner()], [dict(runner(), busy=True)], [dict(runner(), status="offline")]):
            with self.assertRaises(pilot.platform.PlatformError):
                pilot.slot_runners(rows)

    def test_plist_requires_exact_slot_and_guest(self):
        self.assertEqual(pilot.validate_slot(self.plist), "/home/runner/build")
        data = plistlib.loads(self.plist.read_bytes())
        data["ProgramArguments"][2] = "gh-build"
        self.plist.write_bytes(plistlib.dumps(data))
        with self.assertRaises(pilot.platform.PlatformError):
            pilot.validate_slot(self.plist)

    def test_busy_runner_is_never_signalled_or_stopped(self):
        with patch.object(pilot, "services", return_value={pilot.LABEL: 123}), patch.object(
            pilot, "registration_list", return_value=[dict(runner(), busy=True)]), patch.object(
            pilot.os, "kill") as kill, patch.object(pilot.platform, "run") as run:
            with self.assertRaises(pilot.platform.PlatformError):
                pilot.drain(self.state, self.plist)
            kill.assert_not_called()
            run.assert_not_called()

    def test_busy_after_listener_pause_resumes_without_vm_stop(self):
        with patch.object(pilot, "services", return_value={pilot.LABEL: 123}), patch.object(
            pilot, "registration_list", side_effect=[[runner()], [dict(runner(), busy=True)]]), patch.object(
            pilot, "guest", return_value="789\n"), patch.object(pilot.os, "kill") as kill, patch.object(
            pilot, "resume") as resume, patch.object(pilot.platform, "run") as run:
            with self.assertRaises(pilot.platform.PlatformError):
                pilot.drain(self.state, self.plist)
            resume.assert_called_once_with(self.plist, 123, 789)
            kill.assert_called_once_with(123, signal.SIGSTOP)
            run.assert_not_called()

    def test_worker_refusal_resumes_host_loop(self):
        with patch.object(pilot, "services", return_value={pilot.LABEL: 123}), patch.object(
            pilot, "registration_list", return_value=[runner()]), patch.object(
            pilot, "guest", side_effect=pilot.platform.PlatformError("Worker exists")), patch.object(
            pilot.os, "kill"), patch.object(pilot, "resume") as resume, patch.object(pilot.platform, "run") as run:
            with self.assertRaises(pilot.platform.PlatformError):
                pilot.drain(self.state, self.plist)
            resume.assert_called_once_with(self.plist, 123, None)
            run.assert_not_called()

    def test_success_only_stops_selected_vm_and_preserves_inventory(self):
        calls = []
        with patch.object(pilot, "services", return_value={pilot.LABEL: 123}), patch.object(
            pilot, "registration_list", return_value=[runner()]), patch.object(
            pilot, "guest", side_effect=["789\n", ""]), patch.object(pilot.os, "kill"), patch.object(
            pilot.platform, "run", side_effect=lambda args, **kwargs: calls.append(args)):
            pilot.drain(self.state, self.plist)
        self.assertEqual(calls[-1], ["limactl", "stop", "gh-build-2"])
        self.assertFalse(any("delete" in args for args in calls))
        self.assertEqual(json.loads((self.state / "build2-drain.json").read_text())["phase"], "stopped")
        self.assertEqual(json.loads((self.state / "runner-inventory-before-drain.json").read_text()), [runner()])

    def test_guest_recovery_failure_still_resumes_host(self):
        with patch.object(pilot, "guest", side_effect=pilot.platform.PlatformError("SSH failed")), patch.object(
            pilot, "services", return_value={pilot.LABEL: 123}), patch.object(pilot.os, "kill") as kill, patch.object(
            pilot.platform, "run") as run:
            with self.assertRaises(pilot.platform.PlatformError):
                pilot.resume(self.plist, 123, 789)
            kill.assert_called_once_with(123, signal.SIGCONT)
            self.assertEqual(run.call_args.args[0][:2], ["launchctl", "enable"])

    def test_watchdog_blocks_drain_before_any_api_or_signal(self):
        with patch.object(pilot, "services", return_value={pilot.LABEL: 123, "com.ghostnet.runner-watchdog": 10}), patch.object(
            pilot, "registration_list") as inventory, patch.object(pilot.os, "kill") as kill:
            with self.assertRaisesRegex(pilot.platform.PlatformError, "watchdog"):
                pilot.drain(self.state, self.plist)
            inventory.assert_not_called()
            kill.assert_not_called()

    def test_interrupted_pause_recovers_only_matching_executable(self):
        with patch.object(pilot, "guest", return_value="") as guest, patch.object(
            pilot, "services", return_value={pilot.LABEL: 123}), patch.object(pilot.os, "kill"), patch.object(
            pilot.platform, "run"):
            pilot.resume(self.plist, 123, None)
            self.assertEqual(guest.call_args.args[1], "/home/runner/build")
            self.assertIn('/proc/$pid/exe', guest.call_args.args[0])
            self.assertIn('kill -CONT', guest.call_args.args[0])

    def test_rollback_without_record_never_stops_anything(self):
        with patch.object(pilot.platform, "run") as run:
            with self.assertRaises(pilot.platform.PlatformError):
                pilot.rollback({"vm_name": "ghostnet-k3s"}, self.state, self.plist)
            run.assert_not_called()

    def test_port_repair_refuses_existing_arc_before_stopping_vm(self):
        with patch.object(pilot.platform, "check_deployment"), patch.object(pilot.platform, "kube", return_value=json.dumps({
            "items": [{"metadata": {"namespace": "arc-runners"}}]})), patch.object(pilot.platform, "run") as run:
            with self.assertRaisesRegex(pilot.platform.PlatformError, "ARC"):
                pilot.repair_ports({"vm_name": "ci-k3s"}, self.state)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
