#!/usr/bin/env python3
# setup-test: Legacy Linux retirement guards
"""Exercise retirement, recovery and route checks without live host mutations."""
import importlib.util
import hashlib
import json
import signal
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("runner_retire_linux", ROOT / "infra/runner-platform/retire-linux.py")
retire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retire)


def record():
    return {"phase": "prepared", "vm": retire.VM, "memory": 6 * retire.platform.GIB,
            "slots": [{"label": label, "plist": "/tmp/" + label + ".plist", "directory": "/home/runner/slot" + str(n),
                       "pid": n + 100, "started": "start"} for n, label in enumerate(retire.LABELS)],
            "autostart": {"label": retire.AUTOSTART, "plist": "/tmp/autostart.plist", "loaded": True},
            "registration_ids": [1, 2, 3, 4, 5]}


def idle():
    return {"runners": [], "active_runs": [], "workers": {retire.VM: "idle"}, "arc_runner_pods": []}


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.cfg = {"general_scale_set": "acme-linux-arm64"}

    def retirement_patches(self, guest=None, run=None, snapshot=None):
        patches = [patch.object(retire, "preflight", return_value=record()),
                   patch.object(retire, "signal_parent"),
                   patch.object(retire, "guest", side_effect=guest or (lambda action, rec: "[]" if action == "freeze" else "")),
                   patch.object(retire.rollout, "collect", return_value=snapshot or idle()),
                   patch.object(retire, "registrations", return_value=[{"id": n} for n in range(1, 6)]),
                   patch.object(retire, "services", return_value={}),
                   patch.object(retire.platform, "run", side_effect=run or (lambda args, **kwargs: "")),
                   patch.object(retire, "recover")]
        return [self.enterContext(item) for item in patches]

    def test_new_worker_after_freeze_resumes_before_any_disable(self):
        snapshot = dict(idle(), workers={retire.VM: "busy"})
        mocks = self.retirement_patches(snapshot=snapshot)
        with self.assertRaisesRegex(retire.platform.PlatformError, "Worker"):
            retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        mocks[-1].assert_called_once()
        mocks[-2].assert_not_called()
        self.assertEqual(json.loads((self.state / retire.RECORD).read_text())["phase"], "restored")

    def test_queued_job_after_freeze_refuses_shutdown(self):
        mocks = self.retirement_patches(snapshot=dict(idle(), active_runs=[{"id": 1}]))
        with self.assertRaisesRegex(retire.platform.PlatformError, "queued"):
            retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        mocks[-2].assert_not_called()
        mocks[-1].assert_called_once()

    def test_guest_worker_refusal_resumes_all_host_slots(self):
        mocks = self.retirement_patches(guest=lambda action, rec: (_ for _ in ()).throw(
            retire.platform.PlatformError("Worker appeared")))
        with self.assertRaises(retire.platform.PlatformError):
            retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        self.assertEqual(mocks[1].call_count, 5)
        self.assertTrue(all(call.args[1] == signal.SIGSTOP for call in mocks[1].call_args_list))
        mocks[-1].assert_called_once()
        mocks[-2].assert_not_called()

    def test_partial_disable_failure_recovers_exact_original_services(self):
        calls = []
        def fail(args, **kwargs):
            calls.append(args)
            if len(calls) == 3:
                raise retire.platform.PlatformError("launchctl failed")
            return ""
        mocks = self.retirement_patches(run=fail)
        with self.assertRaisesRegex(retire.platform.PlatformError, "launchctl"):
            retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        mocks[-1].assert_called_once()
        self.assertFalse(any(args[0] == "limactl" for args in calls))

    def test_rollback_record_exists_mode600_before_first_signal(self):
        mocks = self.retirement_patches()
        def inspect(slot, sig):
            path = self.state / retire.RECORD
            self.assertTrue(path.exists())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        mocks[1].side_effect = inspect
        retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        commands = [call.args[0] for call in mocks[-2].call_args_list]
        self.assertEqual(commands[-1], ["limactl", "stop", retire.VM])
        self.assertEqual(len([args for args in commands if args[:2] == ["launchctl", "disable"]]), 6)
        self.assertFalse(any("delete" in args for args in commands))
        self.assertEqual(json.loads((self.state / retire.RECORD).read_text())["phase"], "stopped")

    def test_repeated_success_has_no_mutations(self):
        retire.durable(self.state / retire.RECORD, dict(record(), phase="stopped"))
        with patch.object(retire.platform, "lima_state", return_value=[{"name": retire.VM, "status": "Stopped"}]), \
                patch.object(retire, "services", return_value={}), patch.object(retire, "preflight") as preflight, \
                patch.object(retire.platform, "run") as run:
            retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        preflight.assert_not_called()
        run.assert_not_called()

    def test_unknown_or_incomplete_previous_retirement_requires_rollback(self):
        retire.durable(self.state / retire.RECORD, dict(record(), phase="paused"))
        with patch.object(retire, "preflight") as preflight:
            with self.assertRaisesRegex(retire.platform.PlatformError, "rollback"):
                retire.retire(self.cfg, self.state, "acme/toolbox", 10, self.state)
        preflight.assert_not_called()

    def test_process_identity_change_never_signals_reused_pid(self):
        slot = record()["slots"][0]
        with patch.object(retire, "services", return_value={slot["label"]: slot["pid"]}), \
                patch.object(retire, "process_started", return_value="different"), patch.object(retire.os, "kill") as kill:
            with self.assertRaisesRegex(retire.platform.PlatformError, "identity changed"):
                retire.signal_parent(slot, signal.SIGSTOP)
        kill.assert_not_called()

    def test_restore_enables_and_bootstraps_only_six_recorded_agents(self):
        with patch.object(retire, "services", return_value={}), patch.object(retire.platform, "run") as run:
            retire.restore_services(record())
        self.assertEqual(run.call_count, 12)
        labels = {call.args[0][-1].split("/")[-1] for call in run.call_args_list if call.args[0][1] == "enable"}
        self.assertEqual(labels, set(retire.LABELS) | {retire.AUTOSTART})

    def test_recovery_restores_services_despite_guest_and_pid_check_errors(self):
        with patch.object(retire, "guest", side_effect=retire.platform.PlatformError("guest unavailable")), \
                patch.object(retire, "services", return_value={slot["label"]: slot["pid"] for slot in record()["slots"]}), \
                patch.object(retire, "signal_parent", side_effect=retire.platform.PlatformError("identity changed")) as signal_it, \
                patch.object(retire, "restore_services") as restore:
            with self.assertRaisesRegex(retire.platform.PlatformError, "recovery needs inspection"):
                retire.recover(record())
        self.assertEqual(signal_it.call_count, 5)
        restore.assert_called_once()

    def test_canary_success_is_not_full_linux_suite_evidence(self):
        with patch.object(retire.rollout, "lifecycle_evidence"), \
                patch.object(retire.rollout, "real_workload", return_value={"arc_jobs": [1]}), \
                patch.object(retire.platform, "gh_json", return_value={"path": ".github/workflows/runner-canary.yml"}), \
                patch.object(retire.platform, "gh_pages", return_value=[{"id": 1, "name": "canary", "steps": []}]), \
                patch.object(retire.platform, "verify_monitoring") as monitor:
            with self.assertRaisesRegex(retire.platform.PlatformError, "complete Linux"):
                retire.gates(self.cfg, self.state, "acme/toolbox", 123)
        monitor.assert_not_called()

    def test_idempotent_rollback_does_not_restart_vm(self):
        retire.durable(self.state / retire.RECORD, dict(record(), phase="restored"))
        with patch.object(retire.platform, "lima_state") as vms, patch.object(retire.platform, "run") as run:
            retire.rollback(self.cfg, self.state)
        vms.assert_not_called()
        run.assert_not_called()

    def test_capacity_rollback_never_stops_unowned_mac_guest(self):
        retire.durable(self.state / retire.RECORD, dict(record(), phase="stopped"))
        vms = [{"name": retire.VM, "status": "Stopped", "memory": 6 * retire.platform.GIB},
               {"name": "ci-macos", "status": "Running", "memory": 6 * retire.platform.GIB},
               {"name": "ci-k3s", "status": "Running", "memory": 20 * retire.platform.GIB}]
        with patch.object(retire.platform, "lima_state", return_value=vms), \
                patch.object(retire.platform, "run", return_value=str(32 * retire.platform.GIB)) as run:
            with self.assertRaisesRegex(retire.platform.PlatformError, "reserve"):
                retire.rollback(self.cfg, self.state)
        self.assertEqual(run.call_count, 1)

    def test_capacity_rollback_stops_owned_idle_mac_guest_before_old_vm(self):
        retire.durable(self.state / retire.RECORD, dict(record(), phase="stopped"))
        config = self.state / "ci-macos.yaml"
        definition = {"os": "Darwin", "arch": "aarch64", "mounts": [], "plain": True,
                      "ssh": {"forwardAgent": False}, "images": [{"location": "pinned-image"}]}
        config.write_text(json.dumps(definition))
        config.chmod(0o600)
        retire.durable(self.state / "ci-macos-created.json", {"schema_version": 1, "vm_name": "ci-macos",
            "memory_gib": 6, "cpus": 2, "configuration": str(config.resolve()), "created_by": "runner-platform-macos",
            "created_at": "now", "configuration_sha256": hashlib.sha256(config.read_bytes()).hexdigest()})
        vms = [{"name": retire.VM, "status": "Stopped", "memory": 6 * retire.platform.GIB},
               {"name": "ci-macos", "status": "Running", "memory": 6 * retire.platform.GIB,
                "cpus": 2, "disk": 80 * retire.platform.GIB, "config": definition},
               {"name": "ci-k3s", "status": "Running", "memory": 18 * retire.platform.GIB}]
        with patch.object(retire.platform, "lima_state", return_value=vms), \
                patch.object(retire.platform, "run", side_effect=lambda args, **kwargs: str(32 * retire.platform.GIB)
                    if args[0] == "sysctl" else "") as run, patch.object(retire, "recover"), \
                patch.object(retire.rollout, "collect", return_value=idle()):
            retire.rollback(self.cfg, self.state)
        self.assertEqual([call.args[0] for call in run.call_args_list][1:3],
                         [["limactl", "stop", "ci-macos"], ["limactl", "start", "--tty=false", retire.VM]])


class RouteTests(unittest.TestCase):
    def check(self, document):
        workflow = {"repository": "acme/toolbox", "branch": "main", "path": ".github/workflows/ci.yml", "content": ""}
        with patch.object(retire.platform, "run", return_value=json.dumps(document)):
            retire.workflow_routes([workflow], [{"self-hosted", "linux", "arm64"}])

    def test_generic_old_labels_are_rejected_with_exact_workflow_context(self):
        for route in ("self-hosted", "Linux", ["self-hosted", "ARM64", "Linux"], "studio-ubuntu-1-123"):
            with self.assertRaisesRegex(retire.platform.PlatformError, "acme/toolbox@main"):
                self.check({"jobs": {"build": {"runs-on": route}}})

    def test_static_hosted_and_distinct_firmware_routes_are_proven_safe(self):
        for route in ("ubuntu-latest", "macos-latest", "acme-linux-arm64", ["self-hosted", "openwrt-build"]):
            self.check({"jobs": {"build": {"runs-on": route}}})

    def test_arbitrary_input_and_matrix_routes_fail_closed(self):
        for route in ("${{ inputs.runner }}", "${{ matrix.os }}", {"group": "unknown"}):
            with self.assertRaises(retire.platform.PlatformError):
                self.check({"jobs": {"build": {"runs-on": route}}})

    def test_known_ci_expression_proves_entire_choice_set(self):
        document = {"on": {"workflow_dispatch": {"inputs": {"linux_runner": {
            "type": "choice", "default": "ubuntu-latest", "options": ["ubuntu-latest", "acme-linux-arm64"]}}}},
            "jobs": {"build": {"runs-on": retire.CI_EXPRESSION}}}
        self.check(document)
        document["on"]["workflow_dispatch"]["inputs"]["linux_runner"]["options"].append("Linux")
        with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
            self.check(document)

    def test_reusable_workflow_requires_explicit_mapping(self):
        with self.assertRaisesRegex(retire.platform.PlatformError, "Reusable workflow"):
            self.check({"jobs": {"build": {"uses": "acme/workflows/.github/workflows/build.yml@main"}}})

    def test_unknown_event_condition_keeps_both_runner_branches(self):
        route = "${{ github.event_name == 'pull_request' && fromJSON('[\"self-hosted\",\"Linux\",\"ARM64\"]') || 'ubuntu-latest' }}"
        with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
            self.check({"jobs": {"build": {"runs-on": route}}})
        self.check({"jobs": {"build": {"runs-on": route.replace("Linux", "macOS")}}})

    def test_finite_matrix_dimensions_and_includes_detect_legacy(self):
        job = {"runs-on": "${{ matrix.os }}", "strategy": {"matrix": {
            "os": ["ubuntu-latest", "macos-latest"], "include": [{"os": "Linux"}]}}}
        with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
            self.check({"jobs": {"build": job}})
        job["strategy"]["matrix"]["include"] = [{"os": "ubuntu-24.04-arm"}]
        self.check({"jobs": {"build": job}})

    def test_fromjson_matrix_and_literal_label_elements(self):
        self.check({"jobs": {"build": {"runs-on": ["self-hosted", "${{ matrix.os }}"],
            "strategy": {"matrix": "${{ fromJSON('{\"os\":[\"macOS\"]}') }}"}}}})

    def test_unmapped_interpolation_and_functions_fail_closed(self):
        for route in ("ubuntu-${{ matrix.version }}", "${{ format('ubuntu-{0}', inputs.os) }}"):
            with self.assertRaises(retire.platform.PlatformError):
                self.check({"jobs": {"build": {"runs-on": route}}})

    def test_matrix_incomplete_include_does_not_prove_unknown_route(self):
        with self.assertRaises(retire.platform.PlatformError):
            self.check({"jobs": {"build": {"runs-on": "${{ matrix.os }}", "strategy": {
                "matrix": {"include": [{"os": "ubuntu-latest"}, {"version": 1}]}}}}})

    def reusable_check(self, documents, supplied=None):
        workflows = [{"repository": "acme/toolbox", "branch": "main", "commit": "a" * 40,
                      "path": path, "content": json.dumps(document)} for path, document in documents.items()]
        with patch.object(retire.platform, "run", side_effect=lambda args, **kwargs: kwargs["input_text"]):
            retire.workflow_routes(workflows, [{"self-hosted", "linux", "arm64"}])

    def test_alternative_matrices_keep_absent_dimension_unknown(self):
        route = "${{ matrix.os || 'self-hosted' }}"
        matrix = "${{ inputs.choice && fromJSON('{\"os\":[\"ubuntu-latest\"]}') || fromJSON('{\"arch\":[\"ARM64\"]}') }}"
        with self.assertRaises(retire.platform.PlatformError):
            self.check({"jobs": {"build": {"runs-on": route, "strategy": {"matrix": matrix}}}})

    def test_dispatch_choice_does_not_constrain_workflow_call_string(self):
        with self.assertRaises(retire.platform.PlatformError):
            self.check({"on": {"workflow_dispatch": {"inputs": {"runner": {
                "type": "choice", "options": ["ubuntu-latest"], "default": "ubuntu-latest"}}},
                "workflow_call": {"inputs": {"runner": {"type": "string"}}}},
                "jobs": {"build": {"runs-on": "${{ inputs.runner }}"}}})

    def test_dispatch_inputs_absent_on_push_keep_legacy_fallback(self):
        with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
            self.check({"on": {"push": {}, "workflow_dispatch": {"inputs": {"runner": {
                "type": "choice", "options": ["ubuntu-latest"], "default": "ubuntu-latest"}}}},
                "jobs": {"build": {"runs-on": "${{ inputs.runner || 'self-hosted' }}"}}})

    def test_unknown_matrix_does_not_block_static_route(self):
        self.check({"jobs": {"build": {"runs-on": "ubuntu-latest", "strategy": {
            "matrix": "${{ fromJSON(needs.prepare.outputs.matrix) }}"}}}})

    def test_object_identity_equality_never_hides_legacy_branch(self):
        with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
            self.check({"jobs": {"build": {"runs-on":
                "${{ fromJSON('[]') == fromJSON('[]') && 'ubuntu-latest' || 'self-hosted' }}"}}})

    def test_local_reusable_resolves_at_exact_caller_commit(self):
        self.reusable_check({".github/workflows/main.yml": {"jobs": {"call": {
            "uses": "./.github/workflows/child.yml"}}}, 
            ".github/workflows/child.yml": {"on": {"workflow_call": {}},
                "jobs": {"build": {"runs-on": "ubuntu-latest"}}}})
        with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
            self.reusable_check({".github/workflows/main.yml": {"jobs": {"call": {
                "uses": "./.github/workflows/child.yml"}}},
                ".github/workflows/child.yml": {"jobs": {"build": {"runs-on": "Linux"}}}})

    def test_local_reusable_missing_commit_and_cycle_fail_closed(self):
        with self.assertRaisesRegex(retire.platform.PlatformError, "exact caller commit"):
            self.check({"jobs": {"call": {"uses": "./.github/workflows/child.yml"}}})
        with self.assertRaisesRegex(retire.platform.PlatformError, "cycle"):
            self.reusable_check({".github/workflows/main.yml": {"jobs": {"call": {
                "uses": "./.github/workflows/main.yml"}}}})

    def test_reusable_inputs_propagate_without_rejecting_unrelated_unknown_values(self):
        self.reusable_check({".github/workflows/main.yml": {"jobs": {"call": {
            "uses": "./.github/workflows/child.yml", "with": {"irrelevant": "${{ format('build-{0}', github.sha) }}"}}}},
            ".github/workflows/child.yml": {"on": {"workflow_call": {"inputs": {
                "irrelevant": {"type": "string"}}}}, "jobs": {"build": {"runs-on": "ubuntu-latest"}}}})

    def test_reusable_default_expression_never_uses_caller_input_context(self):
        import base64
        child = json.dumps({"on": {"workflow_call": {"inputs": {
            "x": {"type": "string", "default": "self-hosted"},
            "runner": {"type": "string", "default": "${{ inputs.x }}"}}}},
            "jobs": {"build": {"runs-on": "${{ inputs.runner }}"}}})
        response = {"encoding": "base64", "content": base64.b64encode(child.encode()).decode()}
        with patch.object(retire.platform, "gh_json", return_value=response):
            with self.assertRaises(retire.platform.PlatformError):
                self.reusable_check({".github/workflows/main.yml": {"on": {"workflow_dispatch": {
                    "inputs": {"x": {"type": "choice", "options": ["ubuntu-latest"], "default": "ubuntu-latest"}}}},
                    "jobs": {"call": {"uses": "acme/other/.github/workflows/build.yml@" + "b" * 40}}}})

    def test_sha_pinned_remote_reusable_audited_and_cached(self):
        import base64
        child = json.dumps({"jobs": {"build": {"runs-on": "Linux"}}})
        response = {"encoding": "base64", "content": base64.b64encode(child.encode()).decode()}
        with patch.object(retire.platform, "gh_json", return_value=response) as fetch:
            with self.assertRaisesRegex(retire.platform.PlatformError, "legacy Linux"):
                self.reusable_check({".github/workflows/main.yml": {"jobs": {
                    name: {"uses": "acme/other/.github/workflows/build.yml@" + "b" * 40}
                    for name in ("first", "second")}}})
        fetch.assert_called_once()

    def test_unreadable_fork_pr_head_blocks_inventory(self):
        with patch.object(retire.rollout, "repositories", return_value=["acme/toolbox"]), \
                patch.object(retire.platform, "gh_pages", return_value=[{"head": {"repo": None}}]):
            with self.assertRaisesRegex(retire.platform.PlatformError, "PR head"):
                retire.open_pr_workflows({}, [])

    def test_fork_pr_workflow_is_included_with_base_repository_context(self):
        with patch.object(retire.rollout, "repositories", return_value=["acme/toolbox"]), \
                patch.object(retire.platform, "gh_pages", return_value=[{
                    "number": 42, "head": {"repo": {"full_name": "example/toolbox"}, "sha": "abc"}}]), \
                patch.object(retire.platform, "gh_json", side_effect=[{
                    "tree": [{"type": "blob", "path": ".github/workflows/ci.yml", "sha": "blob"}]},
                    {"content": "eA=="}]):
            rows = retire.open_pr_workflows({}, [])
        self.assertEqual(rows[0]["branch"], "pull/42/head")
        self.assertEqual(rows[0]["repository"], "acme/toolbox")
        self.assertEqual(rows[0]["content"], "x")


if __name__ == "__main__":
    unittest.main()
