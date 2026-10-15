#!/usr/bin/env python3
# setup-test: Runner rollout acceptance and preservation guards
"""Exercise pilot orchestration without accessing GitHub, Kubernetes or VMs."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("runner_rollout", ROOT / "infra/runner-platform/rollout.py")
rollout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollout)


def idle():
    return {"runners": [{"busy": False}], "active_runs": [], "workers": {"host": "idle"},
            "arc_runner_pods": []}


class RolloutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)
        self.cfg = {"general_scale_set": "ci-linux-arm64", "pilot": {"memory_gib": 6}}

    def evidence(self, conclusion, run_id):
        record = {"run_id": run_id, "url": f"https://github.com/acme/toolbox/actions/runs/{run_id}",
                  "scale_set": "ci-linux-arm64", "ephemeral_cleanup": True,
                  "verified_at": "2026-01-01T00:00:00+00:00", "expected_conclusion": conclusion}
        path = self.state / f"canary-evidence-{run_id}.json"
        path.write_text(json.dumps(record))
        return path, record

    def test_missing_failure_or_cancellation_proof_blocks_rollout(self):
        self.evidence("success", 1)
        with self.assertRaisesRegex(rollout.platform.PlatformError, "cancelled, failure"):
            rollout.lifecycle_evidence(self.cfg, self.state, "acme/toolbox")

    def test_other_repository_or_scale_cleanup_does_not_count(self):
        for conclusion, run_id in (("success", 1), ("failure", 2), ("cancelled", 3)):
            path, record = self.evidence(conclusion, run_id)
            if conclusion == "cancelled":
                record["scale_set"] = "different-scale"
                path.write_text(json.dumps(record))
        with self.assertRaises(rollout.platform.PlatformError):
            rollout.lifecycle_evidence(self.cfg, self.state, "acme/toolbox")
        with self.assertRaises(rollout.platform.PlatformError):
            rollout.lifecycle_evidence(self.cfg, self.state, "acme/other")

    def test_all_distinct_lifecycle_outcomes_are_required(self):
        for conclusion, run_id in (("success", 1), ("failure", 2), ("cancelled", 3)):
            self.evidence(conclusion, run_id)
        self.assertEqual(rollout.lifecycle_evidence(self.cfg, self.state, "acme/toolbox"),
                         {"success": 1, "failure": 2, "cancelled": 3})

    def test_busy_queued_and_unknown_worker_states_fail_closed(self):
        for field, value in (("runners", [{"busy": True}]),
                             ("active_runs", [{"id": 12, "status": "queued"}]),
                             ("workers", {"guest": ""}), ("workers", {"guest": "busy"}),
                             ("arc_runner_pods", ["runner-active"])):
            with self.subTest(field=field, value=value):
                snapshot = idle()
                snapshot[field] = value
                with self.assertRaises(rollout.platform.PlatformError):
                    rollout.require_idle(snapshot)

    def test_monitoring_may_run_during_queued_work_without_vm_mutation(self):
        snapshot = idle()
        snapshot["active_runs"] = [{"id": 12, "status": "queued"}]
        with patch.object(rollout, "lifecycle_evidence", return_value={}), patch.object(rollout, "real_workload", return_value={}), patch.object(
            rollout, "collect", return_value=snapshot), patch.object(rollout.platform, "monitor") as monitor, patch.object(
            rollout.platform, "check_deployment"), patch.object(rollout.platform, "preflight"), patch.object(
            rollout, "install_guest_exporters", return_value=self.cfg), patch.object(
            rollout.host_services, "grafana_access", return_value="http://127.0.0.1:3000"), patch.object(
            rollout.host_services, "install", return_value=self.cfg), patch.object(rollout.platform, "run") as run:
            rollout.complete(self.cfg, "pilot", self.state, "acme/toolbox", 12)
            monitor.assert_called_once()
            run.assert_not_called()
        self.assertTrue((self.state / "rollout-progress.json").exists())

    def test_hosted_success_without_arc_runner_is_rejected(self):
        record = {"status": "completed", "conclusion": "success", "repository": {"full_name": "acme/toolbox"}}
        with patch.object(rollout.platform, "gh_json", return_value=record), patch.object(
            rollout.platform, "gh_pages", return_value=[{"labels": ["ubuntu-latest"], "conclusion": "success"}]):
            with self.assertRaisesRegex(rollout.platform.PlatformError, "intended ARC"):
                rollout.real_workload(self.cfg, "acme/toolbox", 12)

    def test_monitor_failure_does_not_restore_stopped_builder_or_claim_success(self):
        with patch.object(rollout, "lifecycle_evidence", return_value={}), patch.object(
            rollout, "real_workload", return_value={}), patch.object(rollout, "collect", return_value=idle()), patch.object(
            rollout.platform, "check_deployment"), patch.object(rollout.platform, "preflight"), patch.object(
            rollout, "install_guest_exporters", return_value=self.cfg), patch.object(
            rollout.host_services, "grafana_access", return_value="http://127.0.0.1:3000"), patch.object(
            rollout.host_services, "install", return_value=self.cfg), patch.object(
            rollout.platform, "monitor", side_effect=rollout.platform.PlatformError("atomic install failed")), patch.object(
            rollout.platform, "run") as run:
            with self.assertRaisesRegex(rollout.platform.PlatformError, "atomic install failed"):
                rollout.complete(self.cfg, "pilot", self.state, "acme/toolbox", 12)
            run.assert_not_called()
        progress = json.loads((self.state / "rollout-progress.json").read_text())
        self.assertEqual(progress["phase"], "installing_monitoring")
        self.assertNotIn("migration_complete", progress)

    def test_small_arc_canary_is_not_accepted_as_the_full_workload(self):
        record = {"status": "completed", "conclusion": "success", "repository": {"full_name": "acme/toolbox"},
                  "path": ".github/workflows/runner-canary.yml"}
        job = {"labels": ["ci-linux-arm64"], "conclusion": "success", "runner_name": "ephemeral"}
        with patch.object(rollout.platform, "gh_json", return_value=record), \
                patch.object(rollout.platform, "gh_pages", return_value=[job]), \
                self.assertRaisesRegex(rollout.platform.PlatformError, "full Linux CI"):
            rollout.real_workload(self.cfg, "acme/toolbox", 12)

    def test_monitor_retry_is_idempotent_and_keeps_unvalidated_gates(self):
        with patch.object(rollout, "lifecycle_evidence", return_value={}), patch.object(
            rollout, "real_workload", return_value={}), patch.object(rollout, "collect", return_value=idle()), patch.object(
            rollout.platform, "check_deployment"), patch.object(rollout.platform, "preflight"), patch.object(
            rollout, "install_guest_exporters", return_value=self.cfg), patch.object(
            rollout.host_services, "grafana_access", return_value="http://127.0.0.1:3000"), patch.object(
            rollout.host_services, "install", return_value=self.cfg), patch.object(
            rollout.platform, "monitor") as monitor, patch.object(rollout.platform, "run") as run:
            for _ in range(2):
                result = rollout.complete(self.cfg, "pilot", self.state, "acme/toolbox", 12)
            self.assertEqual(monitor.call_count, 2)
            run.assert_not_called()
        self.assertEqual(result["monitoring"], "verified")
        self.assertFalse(result["migration_complete"])
        self.assertEqual({gate["id"] for gate in result["gates"]},
                         {"legacy-linux-retirement", "firmware-migration", "macos-vm-migration", "pro-migration"})

    def test_help_does_not_load_config_or_contact_systems(self):
        with patch.object(rollout.platform, "load_config") as load, patch.object(
            rollout.platform, "run") as run, self.assertRaises(SystemExit) as exited:
            rollout.main(["--help"])
        self.assertEqual(exited.exception.code, 0)
        load.assert_not_called()
        run.assert_not_called()

    def test_retirement_record_requires_live_stopped_vm_and_all_services_unloaded(self):
        expected = [f"com.ghostnet.jit.studio-ubuntu-{index}" for index in range(1, 6)]
        (self.state / "linux-retirement.json").write_text(json.dumps({
            "phase": "stopped", "vm": "gh-ubuntu", "slots": [{"label": label} for label in expected]}))
        snapshot = {"vms": [{"name": "gh-ubuntu", "status": "Running"}], "launch_agents": []}
        self.assertIn("legacy-linux-retirement", {g["id"] for g in rollout.remaining_gates(self.state, snapshot)})
        snapshot["vms"][0]["status"] = "Stopped"
        snapshot["launch_agents"] = [expected[0]]
        self.assertIn("legacy-linux-retirement", {g["id"] for g in rollout.remaining_gates(self.state, snapshot)})
        snapshot["launch_agents"] = []
        self.assertNotIn("legacy-linux-retirement", {g["id"] for g in rollout.remaining_gates(self.state, snapshot)})


if __name__ == "__main__":
    unittest.main()
