#!/usr/bin/env python3
# setup-test: Local runner platform
"""Exercise deployment guards without touching host VMs or GitHub."""
import base64
import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PLATFORM = ROOT / "infra" / "runner-platform"
spec = importlib.util.spec_from_file_location("runner_platform", PLATFORM / "platform.py")
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.cfg = json.loads((PLATFORM / "config.example.json").read_text())
        self.cfg.update(github_url="https://github.com/acme",
                        expected_github_login="test-admin")

    def test_capacity_refuses_existing_full_allocation(self):
        running = [{"name": "old", "status": "Running", "memory": 24 * platform.GIB}]
        with self.assertRaises(platform.PlatformError):
            platform.capacity(self.cfg, self.cfg["pilot"], running, 32 * platform.GIB, 172 * platform.GIB)

    def test_capacity_ignores_stopped_not_unknown(self):
        stopped = [{"name": "old", "status": "Stopped", "memory": 24 * platform.GIB}]
        self.assertEqual(platform.capacity(self.cfg, self.cfg["pilot"], stopped,
                                          32 * platform.GIB, 172 * platform.GIB)["other_running_vm_gib"], 0)
        with patch.object(platform, "command_exists"), patch.object(
            platform, "run", return_value=json.dumps({"name": "old", "status": "Broken"})):
            with self.assertRaises(platform.PlatformError):
                platform.lima_state()

    def test_disk_reserve(self):
        with self.assertRaises(platform.PlatformError):
            platform.capacity(self.cfg, self.cfg["pilot"], [], 32 * platform.GIB, 49 * platform.GIB)

    def test_incompatible_client_refuses_startup(self):
        with patch.object(platform, "command_exists"), patch.object(
            platform, "run", return_value='{"clientVersion":{"gitVersion":"v1.32.2"}}'):
            with self.assertRaisesRegex(platform.PlatformError, "minor-version"):
                platform.check_client_version(self.cfg)
        with patch.object(platform, "command_exists"), patch.object(
            platform, "run", return_value='{"clientVersion":{"gitVersion":"v1.37.1"}}'):
            platform.check_client_version(self.cfg)

    def test_profile_and_host_isolation(self):
        template = platform.lima_template(self.cfg, "pilot")
        self.assertEqual(template["memory"], "6GiB")
        self.assertEqual(template["mounts"], [])
        self.assertFalse(template["ssh"]["forwardAgent"])
        self.assertEqual(template["portForwards"][0]["hostIP"], "127.0.0.1")
        self.assertTrue(template["portForwards"][1]["ignore"])
        deny = template["portForwards"][1]
        self.assertEqual(deny["guestIP"], "0.0.0.0")
        self.assertEqual(deny["proto"], "any")
        self.assertFalse(deny["guestIPMustBeZero"])
        script = template["provision"][0]["script"]
        self.assertIn("secrets-encryption", script)
        self.assertIn("container-log-max-size", script)

    def test_initial_node_ready_also_waits_for_system_deployments(self):
        required = ["coredns", "local-path-provisioner", "metrics-server"]
        responses = iter([[], [{"metadata": {"name": name}} for name in required]])
        calls = []
        def kube(state, *args, **kwargs):
            calls.append(args)
            if args[:2] == ("get", "deployments"):
                return json.dumps({"items": next(responses)})
            return ""
        with patch.object(platform, "kube", side_effect=kube), patch.object(platform.time, "sleep") as sleep:
            platform.wait_cluster(Path("/private/state"))
        sleep.assert_called_once_with(2)
        rollouts = [args[2] for args in calls if args[:2] == ("rollout", "status")]
        self.assertEqual(rollouts, ["deployment/" + name for name in required])

    def test_runner_bounds_and_no_host_socket(self):
        values = platform.runner_values(self.cfg, "pilot")
        self.assertEqual(values["minRunners"], 0)
        self.assertEqual(values["maxRunners"], 1)
        spec = values["template"]["spec"]
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertNotIn("hostPath", json.dumps(spec))
        self.assertFalse(spec["containers"][0]["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(values["controllerServiceAccount"]["namespace"], "arc-system")
        self.assertEqual(platform.quota(self.cfg, "pilot")["spec"]["hard"]["limits.memory"], "3Gi")
        self.assertEqual(spec["imagePullSecrets"], [{"name": "ci-registry"}])

    def test_secret_uses_stdin_not_process_arguments(self):
        calls = []
        with patch.object(platform, "kube", side_effect=lambda *a, **k: calls.append((a, k))):
            platform.secret(Path("/private/state"), "app", "arc-runners", {"key": "PRIVATE"})
        args, kwargs = calls[0]
        self.assertNotIn("PRIVATE", str(args))
        self.assertIn("data", json.loads(kwargs["input_text"]))

    def test_registry_prompt_sends_token_only_through_secret_stdin(self):
        with patch.object(platform, "load_config", return_value=self.cfg), patch.object(platform.sys.stdin, "isatty", return_value=True), patch.object(
            platform.getpass, "getpass", return_value="REGISTRY-SECRET"), patch.object(platform, "apply_object"), patch.object(
            platform, "secret") as secret:
            self.assertEqual(platform.main(["registry-secret", "--username", "account", "--prompt"]), 0)
            payload = json.loads(secret.call_args.args[3][".dockerconfigjson"])
            self.assertEqual(base64.b64decode(payload["auths"]["ghcr.io"]["auth"]).decode(), "account:REGISTRY-SECRET")

    def test_registry_prompt_refuses_noninteractive_stdin(self):
        with patch.object(platform, "load_config", return_value=self.cfg), patch.object(platform.sys.stdin, "isatty", return_value=False), patch.object(
            platform.getpass, "getpass") as prompt:
            self.assertEqual(platform.main(["registry-secret", "--username", "account", "--prompt"]), 1)
            prompt.assert_not_called()

    def test_deploy_requires_digest_before_reading_credentials(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(platform, "check_deployment"):
                with self.assertRaisesRegex(platform.PlatformError, "immutable"):
                    platform.deploy_arc(self.cfg, "pilot", Path(temp), Path(temp) / "absent.json")

    def test_pilot_uses_bounded_monitoring(self):
        values = platform.monitoring_values(self.cfg, "pilot")
        self.assertEqual(values["prometheus"]["prometheusSpec"]["resources"]["limits"]["memory"], "512Mi")
        self.assertEqual(values["prometheus"]["prometheusSpec"]["retention"], "48h")
        self.assertEqual(values["grafana"]["resources"]["limits"]["memory"], "512Mi")

    def test_pagination_combines_pages(self):
        with patch.object(platform, "gh_json", return_value=[
            {"runners": [{"id": 1}]}, {"runners": [{"id": 2}]}]):
            self.assertEqual(platform.gh_pages("endpoint", "runners"), [{"id": 1}, {"id": 2}])

    def test_inventory_all_branches_and_scopes(self):
        def pages(endpoint, key=None):
            if "/actions/runners" in endpoint:
                return [{"id": 1, "name": "old", "os": "linux", "status": "online",
                         "busy": False, "labels": [{"name": "ARM64"}]}]
            if "/runner-groups" in endpoint:
                return []
            if "/repos?" in endpoint:
                return [{"full_name": "acme/project"}]
            if "/branches?" in endpoint:
                return [{"name": "main", "commit": {"sha": "aaa"}},
                        {"name": "release", "commit": {"sha": "bbb"}}]
            self.fail(endpoint)

        def api(endpoint):
            if "/git/trees/" in endpoint:
                return {"tree": [{"path": ".github/workflows/test.yml",
                                  "type": "blob", "sha": "ccc"}]}
            if "/git/blobs/" in endpoint:
                return {"content": "cnVucy1vbjogdGVzdA=="}
            self.fail(endpoint)

        with tempfile.TemporaryDirectory() as temp:
            with patch.object(platform, "identity"), patch.object(platform, "gh_pages", side_effect=pages), patch.object(
                platform, "gh_json", side_effect=api):
                platform.inventory(self.cfg, Path(temp))
            ledger = json.loads((Path(temp) / "migration-ledger.json").read_text())
            self.assertEqual(len(ledger), 2)
            self.assertFalse(ledger[0]["retire"])
            workflows = json.loads((Path(temp) / "workflow-inventory.json").read_text())
            self.assertEqual({w["branch"] for w in workflows}, {"main", "release"})
            self.assertEqual((Path(temp) / "migration-ledger.json").stat().st_mode & 0o777, 0o600)

    def test_canary_requires_correct_scale_set(self):
        def api(endpoint):
            return {"status": "completed", "conclusion": "success", "html_url": "https://example.org/run"}
        with patch.object(platform, "identity"), patch.object(platform, "gh_json", side_effect=api), patch.object(
            platform, "gh_pages", return_value=[{"labels": ["old"], "conclusion": "success"}]):
            with self.assertRaisesRegex(platform.PlatformError, "intended"):
                platform.verify_canary(self.cfg, Path("/unused"), "acme/project", 1)

    def test_canary_records_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(platform, "identity"), patch.object(
                platform, "gh_json", return_value={"status": "completed", "conclusion": "success",
                                                  "html_url": "https://example.org/run"}), patch.object(
                platform, "gh_pages", return_value=[{"labels": [self.cfg["general_scale_set"]],
                                                    "conclusion": "success"}]), patch.object(
                platform, "kube", return_value='{"items": []}'):
                platform.verify_canary(self.cfg, Path(temp), "acme/project", 1)
            self.assertTrue(json.loads((Path(temp) / "canary-evidence.json").read_text())["ephemeral_cleanup"])

    def test_canary_expected_failure_rejects_unrelated_failure(self):
        jobs = [{"labels": [self.cfg["general_scale_set"]], "conclusion": "failure",
                 "steps": [{"name": "Checkout", "conclusion": "failure"}]}]
        with patch.object(platform, "identity"), patch.object(platform, "gh_json", return_value={
            "status": "completed", "conclusion": "failure"}), patch.object(platform, "gh_pages", return_value=jobs):
            with self.assertRaisesRegex(platform.PlatformError, "intentional"):
                platform.verify_canary(self.cfg, Path("/unused"), "acme/project", 2, "failure")

    def test_queued_cancellation_does_not_count_as_runner_cleanup(self):
        with patch.object(platform, "identity"), patch.object(platform, "gh_json", return_value={
            "status": "completed", "conclusion": "cancelled"}), patch.object(platform, "gh_pages", return_value=[{
                "labels": [self.cfg["general_scale_set"]], "conclusion": "cancelled", "runner_name": "", "steps": []}]):
            with self.assertRaisesRegex(platform.PlatformError, "before a runner"):
                platform.verify_canary(self.cfg, Path("/unused"), "acme/project", 3, "cancelled")

    def test_failure_and_cancellation_cleanup_keep_each_run_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            platform.save(state / "canary-evidence.json", {"run_id": 1, "ephemeral_cleanup": True})
            cases = [(2, "failure", [{"name": "Optional failure", "conclusion": "failure"}]),
                     (3, "cancelled", [{"name": "Set up job", "conclusion": "success"}])]
            for run_id, conclusion, steps in cases:
                with patch.object(platform, "identity"), patch.object(platform, "gh_json", return_value={
                    "status": "completed", "conclusion": conclusion, "html_url": "https://example.org/run"}), patch.object(
                    platform, "gh_pages", return_value=[{"labels": [self.cfg["general_scale_set"]], "conclusion": conclusion,
                                                       "runner_name": "test-runner", "steps": steps}]), patch.object(
                    platform, "kube", return_value='{"items": []}'):
                    platform.verify_canary(self.cfg, state, "acme/project", run_id, conclusion)
            for run_id in (1, 2, 3):
                self.assertTrue(json.loads((state / f"canary-evidence-{run_id}.json").read_text())["ephemeral_cleanup"])

    def test_render_does_not_contact_hosts(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(platform, "run") as run:
                output = platform.render(self.cfg, "pilot", Path(temp))
                run.assert_not_called()
            for path in output.glob("*.yaml"):
                json.loads(path.read_text())

    def test_monitoring_budget_and_dashboard_json(self):
        values = platform.monitoring_values(self.cfg)
        prom = values["prometheus"]["prometheusSpec"]
        self.assertEqual(prom["retention"], "7d")
        self.assertEqual(prom["resources"]["limits"]["memory"], "2Gi")
        self.assertEqual(values["grafana"]["service"]["type"], "ClusterIP")
        for path in (PLATFORM / "monitoring").glob("*.json"):
            obj = json.loads(path.read_text())
            if obj["kind"] == "ConfigMap":
                for text in obj["data"].values():
                    json.loads(text)

    def test_host_inventory_skips_credential_files_and_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            runner = home / "actions-runner-1"
            runner.mkdir(parents=True)
            (runner / ".runner").write_text("\ufeff" + json.dumps({"agentId": 1, "agentName": "old"}))
            (runner / ".credentials").write_text("DO-NOT-READ")
            agents = home / "Library" / "LaunchAgents"
            agents.mkdir(parents=True)
            (agents / "runner.plist").write_bytes(plistlib.dumps({"Label": "runner.one",
                "ProgramArguments": ["helper", "DO-NOT-EXPORT"],
                "EnvironmentVariables": {"TOKEN": "DO-NOT-EXPORT"}}))
            state = Path(temp) / "state"
            platform.inventory_host(state, home)
            result = (state / "host-inventory.json").read_text()
            self.assertNotIn("DO-NOT", result)
            self.assertEqual(json.loads(result)["registrations"][0]["id"], 1)

    def test_help_does_not_need_config(self):
        for script in ("platform.py", "metrics.py"):
            result = subprocess.run([sys.executable, str(PLATFORM / script), "--help"],
                                    text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("usage:", result.stdout)


if __name__ == "__main__":
    unittest.main()

